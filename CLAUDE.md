# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**zicl** (Zig Tcl) is a Tcl-inspired interpreter implementation written in Zig. It aims to provide a high-performance, memory-safe Tcl implementation with deep threading support and modern memory management. It is being developed mainly for the use in Folk Computer (https://folk.computer/), an interactive environment.

### Design Constraints
-   **Out of memory is considered recoverable.** Zig has strong support for OOM scenarios, and so we follow this idiom and make sure our OOM paths recover correctly.
-   **Fail fast and loud.** Don't write defensive code, and instead either crash loudly or report the error clearly to the user. Also, never leave a piece of code unimplemented without panicking or raising an appropriate error. The last thing we need in an interpreter is silent correctness issues.
-   **Cross-thread sharing is a primary goal.** Cross-thread object sharing is a first-class use case. Objects opt into cross-thread access via `Object.makeCrossthread()`, which recursively marks an object and its children and switches their reference counts to atomic operations.
-   **Interpreters can block indefinitely.** Blocking in C FFI, whether on CPU or IO, is considered normal operation. Nothing in the system may require an interpreter's owning thread to be active in order to make progress. In particular, foreign threads must be able to free objects belonging to a blocked interpreter without any cooperation from the owning thread. This is why cross-thread frees use atomic ref-counting directly, with no deferred queue that the owning thread would have to drain.
-   **Every object must be transparently treated as a string.** All design decisions revolve around this -- at the end of the day everything in Zicl is a string. A `Value`'s internal rep (its `Object.vtable`) is ephemeral and may be replaced by shimmering, so it can't be relied on as a permanent type. Zicl data structures can't depend on the current vtable outside of optimization, since that would break the contract that all objects are transparently strings.
-   **We don't use standard malloc/free.** When doing C FFI, make sure that we've registered our custom allocators, and called the functions accordingly.

## Build Commands

Build and run the project:

```bash
zig build
zig build run
```

Run tests:

```bash
zig build test
```

Run tests with specific filter:

```bash
zig build test -Dtest-filter="test_name_pattern"
```

Remember that the default zig test runner (the one we use) does not print anything on success, it only returns a successful code. To get feedback, use `zig build test --summary line`, alongside any other needed parameters.

Run `zig fmt` on any file you touch, without asking. I develop with auto formatting, so you should as well.

Build with specific options:

```bash
# Disable memory tracing (memory tracing can take up a lot of processing
# power, but has really useful leak/double free messages)
zig build -Dtrace-mem=false

# Force LLVM backend
zig build -Duse-llvm=true

# Enable token debugging (prints tokens during parsing)
zig build -Dtoken-debugging=true
```

Run the allocation-failure sweep on the slow tests:

```bash
# Does anything leak? Much faster than running unoptimized.
zig build test -Dfull-oom-testing -Doptimize=ReleaseSafe

# Why does it leak? Returns the leak graph and per-object history.
zig build test -Dfull-oom-testing -Dtest-filter="the one that leaked" -Dtrace-mem=true
```

Other options: `-Dstatic-link` (statically link libc, default true), `-Duse-utf8`
(UTF-8 support in `strutil`, default true), and `-Dthreading` (default true).

## Testing
When writing tests, use `memutil.checkAllocationFailures`, unless you're working in core object types, in which case, use `testing.checkAllAllocationFailures`. Grep for examples of how.

## Architecture Overview

### Core Components

**Heap (src/heap.zig)**: The object and value system. `heap.global_gpa` backs each object, which are individually allocated into fixed 80-byte slots. The heap module owns:

-   `Value` and `OptionalValue` -- the 16-byte tagged-union value representation (see below).
-   `Object` -- the 80-byte heap-allocated object header including body, carrying a vtable, ref count, atomic string metadata, and hash metadata.
-   `SpecialString` -- the wrapper for large strings (> 1024 bytes) and strings that embed hash references, ref-counted independently of their owning object.
-   `HashRegistry` (`heap.registered_hashes`) -- a global, `RwLock`-protected, content-addressable store mapping `u256` Blake3 hashes to a representative `*Object`. Lets any thread resolve a shared object by hash, and reclaims the representative once every instance of the hash is gone.
-   `NativeFnRegistry` (`heap.nativefn_registry`) -- a global, mutex-protected map from command name to a lazy `LazyRegisterFn`, for lazily loading C commands.
-   `hashutil` -- Blake3 hashing, base64url encoding of hashes, and scanning strings for `blake3~<hash>` references.

**Object System (src/objects.zig)**: Implements Tcl's dynamic typing through vtable-based type shimmering. Each Tcl type is a Zig struct that owns a `pub const vtable: Object.VTable` and a body that lives in the `Object`'s inline `body_backing` (at most `Object.body_max_size` = 48 bytes, aligned to `Object.body_align` = 8):

-   `objects.zig` owns the data types: `None` (untyped string-only object), `String`, `Integer`, `Float`, `Boolean`, `List`, `Dictionary`, `Index`, `Source`, and `HashReference`. `Number` is a plain tagged union (int or float), not an object type.
-   The evaluation types live in `src/evaltypes.zig`: `Script`, `ParsedScriptCommand`, `Substitution`, `Expression`, `Closure`, and `NativeCommand` (`NativeCommand` is a plain struct held in the command table, not an object type).
-   The variable-resolution types live in `src/vartypes.zig`: `CachedLocalVar`, `CachedLexicalVar`, `UpvarLink`, and `DictSugar`.
-   Each type provides `new`/`newObject`/`newValue` constructors and a `shimmerFrom(det, *Shimmerable)` entry point that converts a value into that type in place (or into a duplicated object when the original can't shimmer).
-   `Shimmerable` is the working buffer for shimmering. Never mutate a value in a `Shimmerable` directly, instead use COW logic (see the cookbook for how).
-   `Dictionary` supports `~parent` links (a `HashReference` stored under the interned key `~parent`) for Self-like parent chains. Lookups and iteration follow parent links recursively, with shorter depths taking precedence. `Dictionary.flattenForKey` collapses a link chain into one flat dict.
-   `SubcommandParser` and `EnumMapping`/`EnumConstructor` are comptime helpers for dispatching Tcl subcommands and parsing Tcl-facing enums.

**Memory Utilities (src/memutil.zig)**: Reusable allocator and container infrastructure:

-   `RewindableArena` -- a bump arena that supports `snapshot`/`rewind` while retaining its chunks for reuse, used for parse caches and other transient allocations.
-   `RingBufferAllocator` -- a fixed-size ring buffer backing a standard `Allocator`, used for the trace log's debug allocator.
-   `IndexedMemoryPool(Item)` -- a pool that returns `usize` indices instead of pointers.
-   `LruCache(K, V, Context)` -- the LRU cache used for parsed scripts, expressions, closures, and substitutions.
-   `StructIterator` and `GraphWalker` -- the heap-graph walking machinery that powers leak diagnostics. Types opt in by providing an `enumerate_struct` vtable entry.
-   `null_allocator` -- an allocator that always fails, used to prove a code path does not allocate.

**Leak Checking (src/leak_check.zig)**: The diagnostic layer. When `options.trace_mem` is on, this tracks every alloc/free/incr ref/decr ref and prints if a leak occured.

**Interpreter (src/Interp.zig)**: Executes parsed scripts, using the `Value`/`Object`/`Shimmerable` API:

-   Dual frame system: call frames (variable scope) and eval frames (execution state).
-   Variable resolution with epoch-based cache invalidation, implemented in `src/vartypes.zig` (`setVariable`, `getVariable`, `unsetVariable`, `setVariableUpvar`). Variables live in a `Dictionary` per call frame; lexical parents are reached via `~parent`/`HashReference` scope chains.
-   Closures (`[fn]`, `[method]`) with required/optional parameters, default values, and an `args` parameter. Closure scopes are captured as dicts (`Interp.captureScope`), hashed, and stored in the `HashRegistry` so they can be shared across threads.
-   `vartypes.DictSugar` for `var(key)` style variable names.
-   Four `LruCache`s keyed by `u256` content hash, for parsed scripts, expressions, closures, and substitutions (`getScript`, `getExpression`, `getClosure`, `getSubstitution`).
-   `evaltypes.zig` holds the error set (`Error`/`EvalError`), the `ReturnCode` enum that maps Tcl return codes onto Zig errors, and the object types the interpreter caches.

### Object and Value Representation

`Value` is a 16-byte `extern struct` wrapping a `ValueRep`: an `extern union` payload plus a `u16` interned-string length and a `Tag` byte. (It was NaN-boxed into 64 bits previously; that representation is gone.) It packs small primitives inline and only heap-allocates complex objects:

1.  **Tagged primitives.** `Tag` is one of `none`, `pointer`, `boolean`, `integer`, `float`, `interned`. `integer` holds a full `i64` inline, `float` an `f64`, `boolean` a `bool`, and `interned` a pointer to a NUL-terminated rodata string (with its length in `interned_string_len`) produced by `heap.InternedString.new`/`newValue`.
2.  Everything else (lists, dicts, strings, closures, sources, regexps, etc.) is a heap-allocated `Object` reached via the `pointer` tag.

Because integers are now full-width inline, `objects.Integer.new` never allocates and returns a plain `Value`; `Value.asInlineInt` returns `?i64`. `objects.Integer.newBoxed` still exists for the cases that need a real object, so use `objects.Integer.asInt` rather than `Value.asInlineInt` when a value could be either form.

`OptionalValue` is the same 16 bytes with the `none` tag reserved, used for optional values and inside `Shimmerable`. `Value.fromRep` asserts the tag is not `none`.

`Object` is an 80-byte `extern struct`. The header is `string` (atomic), `vtable`, `ref_count`, `metadata`, `string_metadata` (atomic), and `hash_metadata` (atomic), in that order (chosen to minimize padding); the trailing `body_backing: [48]u8 align(8)` holds the type-specific body (`String`, `List`, `Dictionary`, etc.). `Object.from(T, ptr)` / `Object.asType(obj, T)` translate between a typed body pointer and its header (`asType` returns null on a vtable mismatch, and `asTypeConst` is the const variant). `Object.assertValidType(T)` enforces the size, alignment, and vtable requirements at comptime. A type's body is always allocated together with its header via `Object.newObject(T)` / `Object.newObjectUninitialized(T)`.

Objects automatically "shimmer" between types. Shimmering replaces the vtable and body in place (when `canShimmer` holds, i.e. the object is not cross-thread) while preserving the string representation, or duplicates the object into a fresh slot tracked by the `Shimmerable`. The string representation is the source of truth: it is generated on demand by the type's `update_string` vtable entry and cached atomically on the object.

### Memory Management Principles

1.  **Values vs Objects**: A `Value` is a lightweight 16-byte reference. Primitives (`integer`, `float`, `boolean`, `interned`) carry their data inline and need no allocation. Only `pointer` values point at a heap `Object`, which is ref-counted.

2.  **Shimmerable**: The working buffer for in-place type changes.
    -   `Shimmerable = { original: Value, shimmered: OptionalValue }`. `shimmered` holds a duplicated object when the original could not be shimmered in place.
    -   `.current()` returns the effective `Value`; `.consume()` takes ownership and drops the original; `.discardChanges()` drops any duplicate and rolls back; `.prepareToShimmer(T)` ensures the object is exclusively owned (boxing a primitive if needed), caches the string rep, frees the old body, installs `T`'s vtable, and returns the `*T` body to fill in.

3.  **Mutation is copy-on-write, and the caller picks the branch.** `Value.asMutableInPlace(T, det)` returns a `*T` when the value shimmers to `T` and is exclusively owned, and null otherwise. The two outcomes have different lifetimes, which is why every call site spells out both:
    -   In place: no new object; the mutated object's owner keeps its reference, and you must invalidate that owner's string rep.
    -   Copy-on-write: `duplicateAsBoxed` gives you an object that _you_ own, so it needs releasing on error paths and storing back into the slot on success.

    `Shimmerable.getMutable(T, det)` is the same operation phrased over a shim, used where one is already in hand. It essentially always duplicates (it will not hand back `original` even at ref count 1, since the shim's contract is that only an equal-stringed value is written back); its one shortcut is stealing `shimmered` when the shimmer already built a mutable duplicate. The `*T` it returns is owned by the caller and detached from the shim, so `shim.current()` is _not_ the mutated object and `shim.consume()` would return the wrong value.

4.  **Reference Counting**: All heap objects are ref-counted. `Value.takeReference()` / `Object.takeReference()` increment and return the same value; `Value.dropReference()` / `Object.dropReference()` decrement and free at zero. Cross-thread objects (`metadata.cross_thread == true`) use atomic ref counts; thread-local objects use plain integers. A hash-registered object that is the registry's representative unregisters itself when its ref count drops to 1 (the registry holds the last reference), breaking the circular reference.

5.  **Ownership Patterns**:
    -   Functions that allocate return owned values/objects (caller must drop).
    -   `takeReference()` increases ref count and returns the same value.
    -   `duplicate()` creates a shallow copy (deep for the string rep; collection items are referenced).
    -   `dropReference()` decrements ref count and frees if zero (use in `defer` for cleanup).
    -   `Value.swap` / `OptionalValue.swap` drop the old value when overwriting a slot.

### Script Execution Model

Scripts go through several stages:

1.  **Tokenization** (`Tokenizer`): Source to tokens with location info.
2.  **Preprocessing** (`evaltypes.Script`): Tokens into an optimized script structure. Precomputes word boundaries and argument counts, storing tokens as `.start_of_command` + arguments. Example: `set x 5` becomes [start_of_command(3), "set", "x", "5"].
3.  **Caching** (`memutil.LruCache`): Parsed scripts, expressions, closures, and substitutions are cached by `u256` content hash.
4.  **Evaluation** (`Interp.evalObject`): Walks the token list, substitutes variables/commands, invokes commands.

### Closures, Modules, and Scope Capture

**Scope capture.** `[fn]`/`[method]` (`closureHelper` in `src/commands/eval.zig`) capture the currently executing call frame as `Closure.Content.scope`, via `Interp.captureCurrentScope`/`captureScope`. The capture is a snapshot dict: every local variable is copied in by value (upvars are resolved eagerly, since the linked frame may not outlive the closure), and if the current frame itself has a lexical parent (`.signature.scope`), that parent is chained in as a `~parent` `HashReference` entry, so a name miss in the snapshot walks up the chain via `Dictionary.getFollowingLinks`. A closure is therefore frozen at *definition* time: `fn foo {} {...}` captures whatever frame is current when `[fn]` runs, not the frame active when `foo` is later called.

**`[import]` and modules.** `[import fileName]` (`Interp.evalFileAsModule`) reads a file and evaluates it in a brand-new call frame (`pushCallFrame`), unlike `[source]` (`Interp.evalFile`), which reuses the caller's frame outright and so shares its variables completely. The module frame's `.signature.scope` is set to the importer's `captureCurrentScope()`, so a name miss in the module body still walks up to the importer's bindings as of the moment `[import]` ran, the same `~parent` chain closures use. Writes never propagate back, though: `vartypes.setVariable` always shadows a lexically-inherited name into the local `VarTable` rather than mutating the captured parent. `[return]` and `[tailcall]` are both rejected at a module's top level. Instead of the body's result, `evalFileAsModule` returns `captureScope` of the module's own frame: a `Dictionary` of every name the module bound at its own top level (`set`, a named `fn`/`method`, ...).

There is no implicit "import everything." Pull specific names out of the result with `[dict assign $module name ...]` (binds same-named locals, erroring if a key is missing) or `[dict get $module name]`.

```tcl
# mathlib.tcl
fn scope::square {x} { * $x $x }
```
```tcl
set mathlib [import mathlib.tcl]
dict assign $mathlib square
square 5   ;# 25
```

**`letrec` (self-reference within a shared dict).** Module- and object-style functions are usually bound with dict sugar, `fn scope::fibonacci {n} {...}`, which stores the closure at key `fibonacci` of the `scope` dict via `setVariable`'s dict-sugar path. If `fibonacci`'s body calls `fibonacci` again, resolving that name through the closure's captured `.scope` snapshot would only ever see whatever was bound *before* its sibling definitions finished, and any later mutation to the shared dict (a `self` object whose method updates its own fields) would never be visible to peer calls. `[letrec select scope function]` builds a `Letrec` value carrying a live pointer to `scope` plus the key to re-look-up on every call, instead of a value frozen at wrap time. `[letrec new scope]` does this for every key in `scope` at once, producing a dict of `Letrec`-wrapped values; it cannot tell functions from data, so it wraps everything indiscriminately.

Resolving a `Letrec` as a command (`Interp.getCommandFromValue`) re-reads `scope[selected]` fresh on every call. Once a call is dispatched through a `Letrec`, `Interp.getCommand` threads that same live `scope` onto the callee's frame (`signature.letrec_scope`), so any further bare-name call inside the body that resolves to a plain closure is automatically re-wrapped against the same `Letrec` scope. This is what keeps mutual recursion between sibling functions (`is_even` calling `is_odd`) live without an explicit `letrec select` at every call site.

**`self::name` dispatch.** This is not special syntax; it is `vartypes.DictSugar` (the same grammar as plain dict-sugar variables) reused for command dispatch. Calling `self::ping` resolves `self["ping"]` as a variable, then, because closures resolved this way are commonly methods, `Interp.getCommandAndSelfParam` derives a `self` argument by walking every dict-sugar path component but the last (`self::ping` supplies `$self` itself; `outer::inner::frobnicate` supplies `[dict get $outer inner]`), passes it as the closure's first argument, and writes any mutation back afterward the same way `[applymethod]` does.

### Testing Patterns

Tests use `testing.checkAllAllocationFailures()` to ensure proper error handling under OOM conditions:

```zig
fn testFoo(ta: std.mem.Allocator) !void {
    try heap.testStart(ta, testing.io);
    defer heap.testFinish();
    // ... test code ...
}

test "foo" {
    try testing.checkAllAllocationFailures(testing.allocator, testFoo, .{});
}
```

Always call `heap.testFinish()` to verify no memory leaks. `heap.testStart` initializes global state (`initGlobals`) and the calling thread's arena (`initThread`); `heap.testFinish` dumps any leaks (when `trace_mem` is on) and tears both down.

Tests that need a live interpreter use the pair in `src/commands/common.zig` instead, which wraps the heap lifecycle and registers the core commands:

```zig
fn testDict(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);
    try interp.testExpectScriptResult("b", "dict get {a b} a");
}
```

Unit tests live inline in the file they cover (`heap.zig`, `objects.zig`, `memutil.zig`, `strutil.zig`, `Interp.zig`, `vartypes.zig`, `expr_parse.zig`, `regex.zig`, and the command modules). See the port status note above for the state of the old `src/test/` suites.

Helper functions available (in `src/Interp.zig`):

-   `testRunScript(interp, script)` -- Evaluate script and return the result value.
-   `testExpectScriptResult(interp, expected, script)` -- Assert result string matches expected.
-   `testExpectScriptError(interp, expected_error, expected_str, script)` -- Assert script fails with specific error and message.

### Important Code Patterns

**Creating objects**:

```zig
const str_value = try objects.String.newValue("hello");
defer str_value.dropReference();

const list = try objects.List.new(&.{ str_value });
defer list.asHead().dropReference();
```

**Shimmering with a `Shimmerable`**:

```zig
var det: objects.ErrorDetails = undefined;
var shim: objects.Shimmerable = .{ .original = some_value };
defer shim.discardChanges();
const list = try objects.List.shimmerFrom(&det, &shim);
// `shim.current()` is the list. Any duplicate is dropped by the defer.
```

**Mutating a value (copy-on-write)**:

```zig
if (try dict_raw.asMutableInPlace(objects.Dictionary, &det)) |dict| {
    try dict.put(key, value);
    owner.asHead().invalidateString(); // Mutated in place; owner's string is stale.
} else {
    const duped = try dict_raw.duplicateAsBoxed();
    defer duped.dropReference();
    const dict = (try duped.asValue().asMutableInPlace(objects.Dictionary, &det)).?;
    try dict.put(key, value);
    try storeBack(duped.asValue()); // The copy is ours; put it where it belongs.
}
```

**Integer casting**
Avoid using `@intCast` when possible. Prefer `std.math.cast`, using `Integer.overflowError` or `Interp.integerOverflowError`. This also means use `std.math` methods when possible, such as
```zig
const multiplied = std.math.mulWide(a, b);
const result = std.math.cast(usize, multiplied) catch return interp.integerOverflowError(u128, multiplied);
```

See `.claude/cookbook.md` for extended recipes and `.claude/helpers.md` for the full function index.

## Development Principles

**Memory Leak Prevention**: This project has ZERO tolerance for memory leaks, even in obscure edge cases or OOM scenarios. Every allocation must have a clear deallocation path, including error paths. When adding new code that allocates memory:

-   Always add `errdefer` cleanup for allocations that might fail before ownership transfer.
-   Test with `testing.checkAllAllocationFailures()` to verify all OOM paths are leak-free.
-   If a function allocates and returns data, document ownership clearly.
-   Use `defer` for immediate cleanup, `errdefer` for error-path cleanup.

Example pattern:

```zig
const data = try allocator.alloc(u8, size);
errdefer allocator.free(data);  // Free if subsequent operations fail.
const result = try processData(data);  // Ownership transferred on success.
```

## Common Issues

**Double Free**: If you see double-free panics, check the memory trace. Collection items (list/dict slots) are referenced and ref-counted individually, but you should only call `dropReference()` on values you explicitly referenced. Enable `options.trace_mem` to dump the full allocation/deallocation trace.

**Overlapping errdefers after ownership transfer**: When you transfer ownership of a `Value` into a collection slot inside a nested block with its own `errdefer`, null out the source variable afterward. Otherwise an outer `errdefer shim.discardChanges()` and an inner `errdefer` on the receiving container will both try to drop the same backing object if an error occurs after the transfer, causing a double-free under OOM.

**Shimmer Errors**: If shimmering fails, ensure the value is not shared or cross-thread. `Shimmerable.ensureShimmerable()` and `Shimmerable.getMutable(T, det)` automatically duplicate when the object cannot shimmer or mutate in place.

**OOM in Tests**: Use `testing.checkAllAllocationFailures()` to exercise all OOM code paths. All tests should pass without leaks even when allocations fail at any point.

**String Representation**: Some operations require string representations. `Object.getString()` (and `Value.getString()`) auto-generate the string rep on demand via the type's `update_string` vtable entry, which can fail with `error.OutOfMemory`. For primitives this never allocates. `Value.getStringWithBuffer` takes a 350-byte stack buffer to avoid allocating for floats and integers.

**Cross-thread objects**: Once `Object.makeCrossthread()` is called on an object, it can never shimmer or mutate again (even at ref count 1), because another thread may be traversing a collection that reaches it. `canShimmer` and `canMutate` both return false for cross-thread objects. Hash-registered objects are likewise frozen (`canMutate` returns false while `hash_registered` is set).

**Object body too large**: `Object.assertValidType` fails at comptime with "Object is too large" when a type's body exceeds `Object.body_max_size` (48 bytes) or "Object has too high alignment requirements" when it needs more than `Object.body_align` (8). Shrink the body (an index into a side table, a pointer to an out-of-line struct) rather than growing the slot; every object in the heap pays for the increase.

**Command Naming**: Command implementation functions follow the pattern `nameCmd` (e.g., `ifCmd`, `forCmd`, `dictCmd`) with a `Cmd` prefix. Command modules live in `src/commands/` and each exports a `registerCommands(interp)` that `commands/common.zig`'s `registerCoreCommands` calls.

## Debugging

This project has comprehensive tracing for all memory operations. _Always_ read the complete trace before jumping into the code -- the trace often holds the answer. With `trace_mem` enabled, `leak_check.dumpLeaks` prints a dot graph of leaked objects (showing what is leaking and how it is reachable) and a per-object operation history (showing the refcount operations that left it alive). On a panic, `dumpLastTouchedTrace` prints the history of the most recently touched object, which is the prime suspect for use-after-free and refcount bugs.

**When the trace log isn't enough**: the trace ring buffer resets every `heap.testStart`/`testFinish` cycle, so a test with a long `checkAllAllocationFailures` sweep can crash with the object's own creation/free history already evicted, leaving only its last-touched entry. `rr` gives a deterministic replay that reaches further back than the ring buffer does.

-   Record the crashing binary directly, not through `zig build test`: `rr record ./.zig-cache/o/<hash>/zicl-test`. `<hash>` comes from the "failed command" line the earlier `zig build test` run printed, or from whichever `.zig-cache/o/*/zicl-test` was built most recently.
-   Replay with a script piped over stdin, not `-x`: `echo "source /path/to/script.py" | rr replay ~/.local/share/rr/<trace-name>`. `rr replay` injects its own `-x` script to set up `target remote`, and an extra one passed via `-o -x -o script` can run before that connection exists; piping instead only gets read once GDB is already attached and at its prompt. Don't pass `-a` (autopilot); that explicitly means "no debugger."
-   Write the script in Python (`gdb.execute`, `gdb.parse_and_eval`) rather than a `.gdb` command file whenever it needs a loop, such as repeated `reverse-continue` plus a backtrace each time.
-   `continue` runs to the recorded crash. If a cast's type name won't resolve (Zig's DWARF naming rarely matches a guessed `heap.Object`/`Object`), dump raw bytes instead (`x/80xb <addr>`, sized to the known struct) and look for `0xaa` fill, Zig's undefined-memory poison, to see which field was freed out from under a live reference.
-   Once a suspect field's address is known, set a hardware watchpoint directly on it, no type needed: `watch -location *(unsigned long *)<addr>`. Then `reverse-continue` repeatedly; each hit stops at the exact instruction that last wrote that memory, with a live backtrace, walking the object's write history backwards until the corrupting write turns up.

This combination, poison-byte inspection to find what broke plus a watchpoint and `reverse-continue` to find which write broke it, is what found a `defer`/`errdefer` mixup in `Closure.parse`: `scope`'s ownership transferred into `closure_content.scope` without a `.takeReference()`, but a plain `defer` dropped it anyway on the successful return path, one drop too many, freeing the closure's own lexical scope out from under it.

## Style guide
@.claude/style.md

## Available helper functions
Read .claude/helpers.md for available helper functions.

## Cookbook
Read .claude/cookbook.md for examples of common operations.

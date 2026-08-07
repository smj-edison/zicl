# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**zicl** (Zig Tcl) is a Tcl interpreter implementation written in Zig. It aims to provide a high-performance, memory-safe Tcl implementation with optional threading support and modern memory management. It is being developed mainly for the use in Folk Computer (https://folk.computer/), an interactive environment.

### Design Constraints
-   **Out of memory is considered recoverable.** Zig has strong support for OOM scenarios, and so we follow this idiom and make sure our OOM paths recover correctly.
-   **Fail fast and loud.** This has come up so so many times, please stop writing defensive code and either crash loudly or report the error clearly to the user. Also, don't _ever_ leave a piece of code unimplemented without panicking or raising an appropriate error. The last thing we need in an interpreter is silent correctness issues.
-   **Cross-thread sharing is a primary goal.** Cross-thread object sharing is a first-class use case, not an afterthought. Objects opt into cross-thread access via `Object.makeCrossthread()`, which recursively marks an object and its children and switches their reference counts to atomic operations. The global `HashRegistry` lets any thread resolve a shared object by content hash without cooperation from the originating thread.
-   **Interpreters can block indefinitely.** Blocking in C FFI (or otherwise) is considered normal operation. Nothing in the system may require an interpreter's owning thread to be active in order to make progress. In particular, foreign threads must be able to free objects belonging to a blocked interpreter without any cooperation from the owning thread. This is why cross-thread frees use atomic ref-counting directly, with no deferred queue that the owning thread would have to drain.
-   **Every object must be transparently treated as a string.** All design decisions revolve around this -- at the end of the day everything in Zicl is a string. A `Value`'s runtime type (its `Object.vtable`) is ephemeral and may be replaced by shimmering, so it can't be relied on as a permanent type. Zicl data structures can't depend on the current vtable outside of optimization, since that would break the contract that all objects are transparently strings.
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

Run `zig fmt` on any file you touch, without asking. The editor formats on save, so an unformatted file just shows up as noise in the next diff.

Build with specific options:

```bash
# Disable memory tracing (memory tracing can take up a lot of processing
# power, but has really useful leak/double free messages)
zig build -Dtrace-mem=false

# Disable the expensive internal state checks (on by default in Debug)
zig build -Dexpensive-checks=false

# Force LLVM backend
zig build -Duse-llvm=true

# Enable token debugging (prints tokens during parsing)
zig build -Dtoken-debugging=true
```

Run the allocation-failure sweep on the slow tests:

```bash
# Does anything leak? Roughly six times faster than Debug.
zig build test -Dfull-oom-testing -Doptimize=ReleaseSafe

# Why does it leak? Keeps the leak graph and per-object history, which
# ReleaseSafe would otherwise switch off along with `trace_mem`.
zig build test -Dfull-oom-testing -Doptimize=ReleaseSafe -Dtrace-mem=true
```

Tests that drive a whole interpreter re-run once per allocation they make under
`testing.checkAllAllocationFailures`, which costs roughly the square of how much
they allocate. Those go through `memutil.checkAllocationFailures`, which takes a
`memutil.OomTesting` saying how that test takes part:

-   `.exhaustive` -- sweep every allocation, but only under this flag. Otherwise
    run once.
-   `.unsupported = "reason"` -- never inject, because a failure part-way leaves
    state that says nothing about whether the code is correct. The reason is
    recorded so a later reader can tell whether it still holds.

The mode belongs on the test rather than on the file, since whether injection
means anything depends on what the test does. Adding a new way of injecting
failures means adding a variant, not reclassifying files.

Object-level tests are cheap enough to sweep on every build and call
`checkAllAllocationFailures` directly. Run the flag periodically: the paths it
reaches are reached by nothing else, and real leaks hide there.

Other options: `-Dstatic-link` (statically link libc, default true), `-Duse-utf8`
(UTF-8 support in `strutil`, default true), and `-Dthreading` (default true).

## Current port status

The project is mid-way through a ground-up rewrite of its heap and object system. The new foundation lives in `src/heap.zig` and `src/objects.zig` and is the source of truth for everything described below. The interpreter layer has largely been migrated onto it:

-   `src/heap.zig`, `src/objects.zig`, `src/memutil.zig`, `src/strutil.zig`, `src/ioutil.zig`, `src/leak_check.zig`, `src/tripwire.zig` -- new foundation, compiles and is tested.
-   `src/Interp.zig`, `src/evaltypes.zig`, `src/vartypes.zig`, `src/expr_parse.zig`, `src/regex.zig`, `src/Tokenizer.zig` -- ported and wired into the test root (`src/root.zig`).
-   `src/commands/` -- every command module is ported, registered by `commands/common.zig`'s `registerCoreCommands`, and imported by its test block.
-   `src/test/` is gone. Every suite has moved next to the code it exercises, so tests live in the same file as their implementation.
-   `src/root.zig`'s `main` still panics; there is no working REPL yet.

The old `src/Heap.zig`, `src/objutil.zig`, and `src/StringAllocator.zig` have been deleted. Do not resurrect them. Use `src/heap.zig` and `src/objects.zig` instead.

## Architecture Overview

### Core Components

**Heap (src/heap.zig)**: The object and value system. A single global allocator (`heap.global_gpa`) backs every heap object. There is no per-thread heap and no buddy allocator; objects are individually allocated into fixed 88-byte slots. The heap module owns:

-   `Value` and `OptionalValue` -- the 16-byte tagged-union value representation (see below).
-   `Object` -- the 88-byte heap-allocated object header plus body, carrying a vtable, ref count, atomic string metadata, and hash metadata.
-   `SpecialString` -- the wrapper for large strings (> 1024 bytes) and strings that embed hash references, ref-counted independently of their owning object.
-   `HashRegistry` (`heap.registered_hashes`) -- a global, `RwLock`-protected, content-addressable store mapping `u256` Blake3 hashes to a representative `*Object`. Lets any thread resolve a shared object by hash, and reclaims the representative once every instance of the hash is gone.
-   `NativeFnRegistry` (`heap.nativefn_registry`) -- a global, mutex-protected map from command name to a lazy `LazyRegisterFn`, for lazily loading C commands.
-   `hashutil` -- Blake3 hashing, base64url encoding of hashes, and scanning strings for `blake3~<hash>` references.

**Object System (src/objects.zig)**: Implements Tcl's dynamic typing through vtable-based type shimmering. Each Tcl type is a Zig struct that owns a `pub const vtable: Object.VTable` and a body that lives in the `Object`'s inline `body_backing` (at most `Object.body_max_size` = 48 bytes, aligned to `Object.body_align` = 8):

-   `objects.zig` owns the data types: `None` (untyped string-only object), `String`, `Integer`, `Float`, `Boolean`, `List`, `Dictionary`, `Index`, `Source`, and `HashReference`. `Number` is a plain tagged union (int or float), not an object type.
-   The evaluation types live in `src/evaltypes.zig`: `Script`, `ParsedScriptCommand`, `Substitution`, `Expression`, `Closure`, and `NativeCommand` (`NativeCommand` is a plain struct held in the command table, not an object type).
-   The variable-resolution types live in `src/vartypes.zig`: `CachedLocalVar`, `CachedLexicalVar`, `UpvarLink`, and `DictSugar`.
-   `Regexp` lives in `src/regex.zig`, next to the pcre2 bindings, because `heap.zig` drives the pcre2 context lifecycle and so cannot import from `src/commands/`. The [regexp] and [regsub] commands themselves live in `src/commands/regex.zig` like every other command.
-   Each type provides `new`/`newObject`/`newValue` constructors and a `shimmerFrom(det, *Shimmerable)` entry point that converts a value into that type in place (or into a duplicated object when the original can't shimmer).
-   `Shimmerable` is the working buffer for shimmering. Mutation is copy-on-write: `Value.asMutableInPlace(T, det)` returns a `*T` when the value can be shimmered _and_ mutated in place, and null when the caller has to duplicate instead. `Shimmerable.getMutable(T, det)` is the shim-flavored counterpart, and returns an owned copy (see below).
-   `AlwaysCanBeType(T)` wraps a `*Object` so it can shimmer but never mutate in place, used for read-only typed views. Its `getMutable` duplicates rather than mutating the shared object.
-   `Dictionary` supports `~parent` links (a `HashReference` stored under the interned key `~parent`) for lexical scope chains. Lookups and iteration follow parent links recursively, with parent keys taking precedence. `Dictionary.flatten` collapses a link chain into one flat dict.
-   `SubcommandParser` and `EnumMapping`/`EnumConstructor` are comptime helpers for dispatching Tcl subcommands and parsing Tcl-facing enums.

**Memory Utilities (src/memutil.zig)**: Reusable allocator and container infrastructure:

-   `RewindableArena` -- a bump arena that supports `snapshot`/`rewind` while retaining its chunks for reuse, used for parse caches and other transient allocations.
-   `RingBufferAllocator` -- a fixed-size ring buffer backing a standard `Allocator`, used for the trace log's debug allocator.
-   `IndexedMemoryPool(Item)` -- a pool that returns `usize` indices instead of pointers.
-   `LruCache(K, V, Context)` -- the LRU cache used for parsed scripts, expressions, closures, and substitutions.
-   `StructIterator` and `GraphWalker` -- the heap-graph walking machinery that powers leak diagnostics. Types opt in by providing an `enumerate_struct` vtable entry.
-   `null_allocator` -- an allocator that always fails, used to prove a code path does not allocate.

**Failure Injection (src/tripwire.zig)**: Vendored from ghostty. `tripwire.module(FailPoints, func)` builds a per-function set of named fail points; sprinkle `try tw.check(.point)` at the `try`s whose `errdefer` you want to exercise, then drive them from tests with `tw.errorAlways` and friends. Use it when `checkAllAllocationFailures` cannot reach an error path (non-OOM errors, or errors deep behind a cache hit).

**Leak Checking (src/leak_check.zig)**: The diagnostic layer. When `options.trace_mem` is on, every alloc/free/borrow/release on a `Value` is logged with a stack trace into a global ring buffer. `leak_check.captureLeaks` walks every leaked object via `GraphWalker`/`StructIterator` and produces a `LeakResult` that can render a Graphviz dot digraph (`dumpDot`) of the reachable leak graph plus a per-object operation history (`dumpDetails`). `dumpLastTouchedTrace` is hooked into the panic path so a use-after-free prints the refcount history of the last-touched object alongside Zig's own stack trace.

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

`Object` is an 88-byte `extern struct`. The header is `string` (atomic), `metadata`, `vtable`, `ref_count`, `string_metadata` (atomic), and `hash_metadata` (atomic); the trailing `body_backing: [48]u8 align(8)` holds the type-specific body (`String`, `List`, `Dictionary`, etc.). `Object.from(T, ptr)` / `Object.asType(obj, T)` translate between a typed body pointer and its header (`asType` returns null on a vtable mismatch, and `asTypeConst` is the const variant). `Object.assertValidType(T)` enforces the size, alignment, and vtable requirements at comptime. A type's body is always allocated together with its header via `Object.newObject(T)` / `Object.newObjectUninitialized(T)`.

Objects automatically "shimmer" between types. Shimmering replaces the vtable and body in place (when `canShimmer` holds, i.e. the object is not cross-thread) while preserving the string representation, or duplicates the object into a fresh slot tracked by the `Shimmerable`. The string representation is the source of truth: it is generated on demand by the type's `update_string` vtable entry and cached atomically on the object.

### Memory Management Principles

1.  **Values vs Objects**: A `Value` is a lightweight 16-byte reference. Primitives (`integer`, `float`, `boolean`, `interned`) carry their data inline and need no allocation. Only `pointer` values point at a heap `Object`, which is ref-counted.

2.  **Shimmerable**: The working buffer for in-place type changes.
    -   `Shimmerable = { original: Value, shimmered: OptionalValue }`. `shimmered` holds a duplicated object when the original could not be shimmered in place.
    -   `.current()` returns the effective `Value`; `.consume()` takes ownership and releases the original; `.discardChanges()` releases any duplicate and rolls back; `.prepareToShimmer(T)` ensures the object is exclusively owned (boxing a primitive if needed), caches the string rep, frees the old body, installs `T`'s vtable, and returns the `*T` body to fill in.

3.  **Mutation is copy-on-write, and the caller picks the branch.** `Value.asMutableInPlace(T, det)` returns a `*T` when the value shimmers to `T` and is exclusively owned, and null otherwise. The two outcomes have different lifetimes, which is why every call site spells out both:
    -   In place: no new object; the mutated object's owner keeps its reference, and you must invalidate that owner's string rep.
    -   Copy-on-write: `duplicateAsBoxed` gives you an object that _you_ own, so it needs releasing on error paths and storing back into the slot on success.

    `Shimmerable.getMutable(T, det)` is the same operation phrased over a shim, used where one is already in hand. It essentially always duplicates (it will not hand back `original` even at ref count 1, since the shim's contract is that only an equal-stringed value is written back); its one shortcut is stealing `shimmered` when the shimmer already built a mutable duplicate. The `*T` it returns is owned by the caller and detached from the shim, so `shim.current()` is _not_ the mutated object and `shim.consume()` would return the wrong value.

4.  **Reference Counting**: All heap objects are ref-counted. `Value.borrow()` / `Object.borrow()` increment and return the same value; `Value.release()` / `Object.release()` decrement and free at zero. Cross-thread objects (`metadata.cross_thread == true`) use atomic ref counts; thread-local objects use plain integers. A hash-registered object that is the registry's representative unregisters itself when its ref count drops to 1 (the registry holds the last borrow), breaking the circular reference.

5.  **Ownership Patterns**:
    -   Functions that allocate return owned values/objects (caller must release).
    -   `borrow()` increases ref count and returns the same value.
    -   `duplicate()` creates a shallow copy (deep for the string rep; collection items are borrowed).
    -   `release()` decrements ref count and frees if zero (use in `defer` for cleanup).
    -   `Value.swap` / `OptionalValue.swap` release the old value when overwriting a slot.

### Script Execution Model

Scripts go through several stages:

1.  **Tokenization** (`Tokenizer`): Source to tokens with location info.
2.  **Preprocessing** (`evaltypes.Script`): Tokens into an optimized script structure. Precomputes word boundaries and argument counts, storing tokens as `.start_of_command` + arguments. Example: `set x 5` becomes [start_of_command(3), "set", "x", "5"].
3.  **Caching** (`memutil.LruCache`): Parsed scripts, expressions, closures, and substitutions are cached by `u256` content hash.
4.  **Evaluation** (`Interp.evalObject`): Walks the token list, substitutes variables/commands, invokes commands.

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
defer str_value.release();

const list = try objects.List.new(&.{ str_value });
defer list.asHead().release();
```

**Shimmering with a `Shimmerable`**:

```zig
var det: objects.ErrorDetails = undefined;
var shim: objects.Shimmerable = .{ .original = some_value };
defer shim.discardChanges();
const list = try objects.List.shimmerFrom(&det, &shim);
// `shim.current()` is the list. Any duplicate is released by the defer.
```

**Mutating a value (copy-on-write)**:

```zig
if (try dict_raw.asMutableInPlace(objects.Dictionary, &det)) |dict| {
    try dict.put(key, value);
    owner.asHead().invalidateString(); // Mutated in place; owner's string is stale.
} else {
    const duped = try dict_raw.duplicateAsBoxed();
    defer duped.release();
    const dict = (try duped.asValue().asMutableInPlace(objects.Dictionary, &det)).?;
    try dict.put(key, value);
    try storeBack(duped.asValue()); // The copy is ours; put it where it belongs.
}
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

**Double Free**: If you see double-free panics, check the memory trace. Collection items (list/dict slots) are borrowed and ref-counted individually, but you should only call `release()` on values you explicitly borrowed. Enable `options.trace_mem` to dump the full allocation/deallocation trace.

**Overlapping errdefers after ownership transfer**: When you transfer ownership of a `Value` into a collection slot inside a nested block with its own `errdefer`, null out the source variable afterward. Otherwise an outer `errdefer shim.discardChanges()` and an inner `errdefer` on the receiving container will both try to release the same backing object if an error occurs after the transfer, causing a double-free under OOM.

**Shimmer Errors**: If shimmering fails, ensure the value is not shared or cross-thread. `Shimmerable.ensureShimmerable()` and `Shimmerable.getMutable(T, det)` automatically duplicate when the object cannot shimmer or mutate in place.

**OOM in Tests**: Use `testing.checkAllAllocationFailures()` to exercise all OOM code paths. All tests should pass without leaks even when allocations fail at any point.

**String Representation**: Some operations require string representations. `Object.getString()` (and `Value.getString()`) auto-generate the string rep on demand via the type's `update_string` vtable entry, which can fail with `error.OutOfMemory`. For primitives this never allocates. `Value.getStringWithBuffer` takes a 350-byte stack buffer to avoid allocating for floats and integers.

**Cross-thread objects**: Once `Object.makeCrossthread()` is called on an object, it can never shimmer or mutate again (even at ref count 1), because another thread may be traversing a collection that reaches it. `canShimmer` and `canMutate` both return false for cross-thread objects. Hash-registered objects are likewise frozen (`canMutate` returns false while `hash_registered` is set).

**Object body too large**: `Object.assertValidType` fails at comptime with "Object is too large" when a type's body exceeds `Object.body_max_size` (48 bytes) or "Object has too high alignment requirements" when it needs more than `Object.body_align` (8). Shrink the body (an index into a side table, a pointer to an out-of-line struct) rather than growing the slot; every object in the heap pays for the increase.

**Command Naming**: Command implementation functions follow the pattern `nameCmd` (e.g., `ifCmd`, `forCmd`, `dictCmd`) with a `Cmd` prefix. Command modules live in `src/commands/` and each exports a `registerCommands(interp)` that `commands/common.zig`'s `registerCoreCommands` calls.

## Debugging

This project has comprehensive tracing for all memory operations. _Always_ read the complete trace before jumping into the code -- the trace often holds the answer. With `trace_mem` enabled, `leak_check.dumpLeaks` prints a dot graph of leaked objects (showing what is leaking and how it is reachable) and a per-object operation history (showing the refcount operations that left it alive). On a panic, `dumpLastTouchedTrace` prints the history of the most recently touched object, which is the prime suspect for use-after-free and refcount bugs.

## Style guide
-   Write for a reader who is fluent in low-level programming, but only has a high level understanding of this project, and who was not present for the discussion that produced the code actively being written. Assume they can read Zig and reason about atomics, ownership, and memory layout. Do not assume they know why some alternative was rejected, what a symbol used to be called, which bug prompted a line, or what any of it looked like an hour ago. A comment that only makes sense to someone who watched the code being written is scratch work, not documentation.
-   Write Tcl as Tcl, not TCL.
-   Prefer commas or parenthesis over em-dashes. Also, write in ASCII characters exclusively (i.e. no — or →). Double hypens, --, can substitute for a proper em dash.
-   Use "why" commands, and occasional "how" comments, but avoid "what" comments unless the logic is dense.
-   Split a function's comments by what the reader needs. The doc comment on the signature says how to call it: what it takes, what it gives back, what the caller is then responsible for, plus whatever rationale a caller has to know to use it correctly. Everything about _how_ it works goes in the body, next to the code it explains. A signature that opens with three paragraphs on lock ordering is telling callers something they cannot act on and burying it from the person changing the implementation.
-   Comment the exceptions, not the conventions. If a reader who knows this codebase would already predict what a line does, leave it alone; spend the comment where the code departs from what they'd predict. This is the "what" comment rule applied to design rules rather than to syntax: that `interp.getInteger` reports its own errors is the convention and needs no note, whereas a call site that deliberately bypasses it does.
-   Seek for brevity in all comments. Unnecessary details and only tenously related points make it harder to follow.
-   Give a complicated edge case a concrete example, in a triple-backtick block under the prose that introduces it (see `DictSugar` in `src/vartypes.zig`). If a comment describes a situation the reader has to construct in their head (an aliased variable, a shared object, a specific argument shape), show the two or three lines of Tcl that produce it. An edge case worth an example is usually also worth a test.
-   End every comment with a period, exclaimation point, or similar (what's important is that the thought is properly terminated).
-   Don't use UPPERCASE, instead use _emphasis_. TODO, FIXME, PERF, HACK, etc are exceptions to this rule, as they're used for grepping.
-   If there's a short `if (optional) |val|`, use `val` as the capture name, not `h`.
-   Avoid using overly terse names, like `ef` for an evaluation frame. Use something like `frame` or `eval_frame` instead. Use `err` instead of `e` as well.
-   Follow the known-new contract when writing: every sentence, always introduce something that the reader has previously read before introducing something new.
-   Whenever you refer to a variable or a piece of code, enclose it in backticks. Exceptions to this rule include integer types (i.e. i64, u5), error types (i.e. error.OutOfMemory), and command/subcommand names surrounded by brackets (e.g. [puts], not `puts`).
-   Don't remove comments when porting code. There's been multiple instances where code lost important comments during porting or refactoring. It makes it unnecessarily hard to reason about.
-   Make sure comments don't include internal thought processes or references to temporary state. Comments should be written for future readers of the code, not for scratch work.
-   Don't leave comments behind after fixing ownership/ref counting bugs, unless it's significantly outside of normal ownership patterns. They quickly balloon out of control and make the code incomprehensible. See "don't make comments with internal thought process."

## Available helper functions
@.claude/helpers.md

## Cookbook
@.claude/cookbook.md
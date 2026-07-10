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

## Current port status

The project is mid-way through a ground-up rewrite of its heap and object system. The new foundation lives in `src/heap.zig` and `src/objects.zig` and is the source of truth for everything described below. The interpreter layer is being migrated onto it:

-   `src/heap.zig`, `src/objects.zig`, `src/memutil.zig`, `src/strutil.zig`, `src/ioutil.zig`, `src/leak_check.zig` -- new foundation, compiles and is tested.
-   `src/Interp.zig` -- partially ported. It still references the old `objutil`, `Heap`, `Handle`, `OptionalHandle`, `Mutable`, and `expr_parse` names in places that haven't been rewritten yet. When working in this file, port those call sites to the new `heap`/`objects` API (see `.claude/cookbook.md` and `.claude/helpers.md`).
-   `src/expr_parse.zig`, `src/commands.zig`, `src/regex.zig`, `src/Tokenizer.zig` -- not yet wired into the new root (`src/root.zig`); they are commented out in the test import block until their port lands.

The old `src/Heap.zig`, `src/objutil.zig`, and `src/StringAllocator.zig` have been deleted. Do not resurrect them. Use `src/heap.zig` and `src/objects.zig` instead.

## Architecture Overview

### Core Components

**Heap (src/heap.zig)**: The object and value system. A single global allocator (`heap.global_gpa`) backs every heap object. There is no per-thread heap and no buddy allocator; objects are individually allocated with `global_gpa.alignedAlloc` into fixed 80-byte slots. The heap module owns:

-   `Value` and `OptionalValue` -- the 64-bit NaN-boxed value representation (see below).
-   `Object` -- the 80-byte heap-allocated object header, carrying a vtable, ref count, atomic string metadata, and hash metadata.
-   `SpecialString` -- the wrapper for large strings (> 1024 bytes) and strings that embed hash references, ref-counted independently of their owning object.
-   `HashRegistry` (`heap.registered_hashes`) -- a global, `RwLock`-protected, content-addressable store mapping `u256` Blake3 hashes to a representative `*Object`. Lets any thread resolve a shared object by hash, and reclaims the representative once every instance of the hash is gone.
-   `NativeFnRegistry` (`heap.nativefn_registry`) -- a global, mutex-protected map from command name to a lazy `NativeInitFn`, for lazily loading C commands.
-   `hashutil` -- Blake3 hashing, base64url encoding of hashes, and scanning strings for `blake3~<hash>` references.

**Object System (src/objects.zig)**: Implements Tcl's dynamic typing through vtable-based type shimmering. Each Tcl type is a Zig struct that owns a `pub const vtable: Object.VTable` and a body laid out immediately after the `Object` header in the same 80-byte allocation:

-   `None` (untyped string-only object), `String`, `Integer`, `Float`, `Boolean`, `List`, `Dictionary`, `Index`, `Source`, `HashReference`, `Regexp`, `ParsedScript`, `ParsedScriptCommand`.
-   Each type provides `new`/`newObject`/`newValue` constructors and a `shimmerFrom(det, *Shimmerable)` entry point that converts a value into that type in place (or into a duplicated object when the original can't shimmer).
-   `Shimmerable` is the single working buffer for both shimmer and mutation. `Shimmerable.getMutable(T, det)` returns a `*T` you can mutate directly, duplicating first if the original is shared or cross-thread. The old separate `Mutable` struct is gone.
-   `AlwaysType(T)` wraps a `*T` so it can shimmer but never mutate, used for read-only typed views.
-   `Dictionary` supports `~parent` links (a `HashReference` stored under the interned key `~parent`) for lexical scope chains. Lookups and iteration follow parent links recursively, with parent keys taking precedence. `Dictionary.flatten` collapses a link chain into one flat dict.
-   `SubcommandParser` and `EnumMapping`/`EnumConstructor` are comptime helpers for dispatching Tcl subcommands and parsing Tcl-facing enums.

**Memory Utilities (src/memutil.zig)**: Reusable allocator and container infrastructure:

-   `RewindableArena` -- a bump arena that supports `snapshot`/`rewind` while retaining its chunks for reuse, used for parse caches and other transient allocations.
-   `RingBufferAllocator` -- a fixed-size ring buffer backing a standard `Allocator`, used for the trace log's debug allocator.
-   `IndexedMemoryPool(Item)` -- a pool that returns `usize` indices instead of pointers.
-   `LruCache(K, V, Context)` -- the LRU cache used for parsed scripts, expressions, closures, and substitutions.
-   `StructIterator` and `GraphWalker` -- the heap-graph walking machinery that powers leak diagnostics. Types opt in by providing an `enumerate_struct` vtable entry.

**Leak Checking (src/leak_check.zig)**: The diagnostic layer. When `options.trace_mem` is on, every alloc/free/borrow/release on a `Value` is logged with a stack trace into a global ring buffer. `leak_check.captureLeaks` walks every leaked object via `GraphWalker`/`StructIterator` and produces a `LeakResult` that can render a Graphviz dot digraph (`dumpDot`) of the reachable leak graph plus a per-object operation history (`dumpDetails`). `dumpLastTouchedTrace` is hooked into the panic path so a use-after-free prints the refcount history of the last-touched object alongside Zig's own stack trace.

**Interpreter (src/Interp.zig)**: Executes parsed scripts. The parts that are already ported use the new `Value`/`Object`/`Shimmerable` API and follow the same design as before:

-   Dual frame system: call frames (variable scope) and eval frames (execution state).
-   Variable resolution with epoch-based cache invalidation. Variables live in a `Dictionary` per call frame; lexical parents are reached via `~parent`/`HashReference` scope chains.
-   Closures (`[fn]`, `[method]`) with required/optional parameters, default values, and an `args` parameter. Closure scopes are captured as dicts, hashed, and stored in the `HashRegistry` so they can be shared across threads.
-   `DictSugar` for `var(key)` style variable names.

See the port status note above for what is still using old names.

### Object and Value Representation

`Value` is a 64-bit NaN-boxed enum (`enum(ValueBacking)` where `ValueBacking = u64`). It packs small primitives inline and only heap-allocates complex objects:

1.  **Floats** occupy the full 64 bits as an IEEE-754 `f64`, with a canonical NaN reserved as the tag namespace.
2.  **Tagged primitives** use the NaN payload: a 3-bit `Tag` (`int`, `false`, `true`, `interned`, `none`, `ptr`, `canonical_nan`) plus a 48-bit payload. `int` holds an `i32` inline; `interned` holds a pointer to a length-prefixed, NUL-terminated rodata string produced by `heap.createInternedString`; `ptr` holds a 48-bit pointer to a heap `Object`.
3.  Everything else (lists, dicts, strings, closures, sources, regexps, etc.) is a heap-allocated `Object` reached via the `.ptr` tag.

`OptionalValue` is the same 64 bits with a dedicated `.none` representation, used for optional values and inside `Shimmerable`.

`Object` is an 80-byte struct (`Object.object_size`). The first `@sizeOf(Object)` bytes are the header (`vtable`, `ref_count`, atomic `string`/`string_metadata`, `metadata`, `hash_metadata`); the remaining bytes hold the type-specific body (`String`, `List`, `Dictionary`, etc.). `Object.from(T, ptr)` / `Object.castTo(obj, T)` translate between a typed body pointer and its header. A type's body is always allocated together with its header via `Object.newObject(T)` / `Object.newObjectUninitialized(T)`.

Objects automatically "shimmer" between types. Shimmering replaces the vtable and body in place (when `canShimmer` holds, i.e. the object is not cross-thread) while preserving the string representation, or duplicates the object into a fresh slot tracked by the `Shimmerable`. The string representation is the source of truth: it is generated on demand by the type's `update_string` vtable entry and cached atomically on the object.

### Memory Management Principles

1.  **Values vs Objects**: A `Value` is a lightweight 64-bit reference. Primitives (`int`, `float`, `bool`, `interned`) carry their data inline and need no allocation. Only `.ptr` values point at a heap `Object`, which is ref-counted.

2.  **Shimmerable**: The single working buffer for in-place type changes and mutations.
    -   `Shimmerable = { original: Value, shimmered: OptionalValue }`. `shimmered` holds a duplicated object when the original could not be shimmered or mutated in place.
    -   `.current()` returns the effective `Value`; `.consume()` takes ownership and releases the original; `.discardChanges()` releases any duplicate and rolls back; `.prepareToShimmer()` ensures the object is exclusively owned and has its string rep cached before the body is overwritten.
    -   For mutations, call `.getMutable(T, det)` to get a `*T` you can write to. It duplicates first if the object is shared, cross-thread, or hash-registered (i.e. whenever `canMutate` is false).
    -   The old `Mutable` struct no longer exists. Use `Shimmerable` for both shimmer and mutation.

3.  **Reference Counting**: All heap objects are ref-counted. `Value.borrow()` / `Object.borrow()` increment and return the same value; `Value.release()` / `Object.release()` decrement and free at zero. Cross-thread objects (`metadata.cross_thread == true`) use atomic ref counts; thread-local objects use plain integers. A hash-registered object that is the registry's representative unregisters itself when its ref count drops to 1 (the registry holds the last borrow), breaking the circular reference.

4.  **Ownership Patterns**:
    -   Functions that allocate return owned values/objects (caller must release).
    -   `borrow()` increases ref count and returns the same value.
    -   `duplicate()` creates a shallow copy (deep for the string rep; collection items are borrowed).
    -   `release()` decrements ref count and frees if zero (use in `defer` for cleanup).
    -   `Value.swap` / `OptionalValue.swap` release the old value when overwriting a slot.

### Script Execution Model

Scripts go through several stages:

1.  **Tokenization** (`Tokenizer`): Source to tokens with location info.
2.  **Preprocessing** (`objects.ParsedScript`): Tokens into an optimized script structure. Precomputes word boundaries and argument counts, storing tokens as `.start_of_command` + arguments. Example: `set x 5` becomes [start_of_command(3), "set", "x", "5"].
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

The unit tests for the foundation live inline in `src/heap.zig` and `src/objects.zig`. The end-to-end test suites under `src/test/` (arithmetic, closure, dict, eval, list, parsing, regex, strings, subst, try_catch, variables) cover the interpreter and are re-enabled as the port lands.

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

**Mutating through a `Shimmerable`**:

```zig
var shim: objects.Shimmerable = .{ .original = dict_value };
errdefer shim.discardChanges();
const dict = try shim.getMutable(objects.Dictionary, &det);
_ = try dict.put(key, value);
dict_value = shim.consume();
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

**Command Naming**: Command implementation functions follow the pattern `nameCmd` (e.g., `ifCmd`, `forCmd`, `dictCmd`) with a `Cmd` prefix.

## Debugging

This project has comprehensive tracing for all memory operations. _Always_ read the complete trace before jumping into the code -- the trace often holds the answer. With `trace_mem` enabled, `leak_check.dumpLeaks` prints a dot graph of leaked objects (showing what is leaking and how it is reachable) and a per-object operation history (showing the refcount operations that left it alive). On a panic, `dumpLastTouchedTrace` prints the history of the most recently touched object, which is the prime suspect for use-after-free and refcount bugs.

## Style guide
-   Write Tcl as Tcl, not TCL.
-   Prefer commas or parenthesis over em-dashes. Also, write in ASCII characters exclusively (i.e. no — or →). Double hypens, --, can substitute for a proper em dash.
-   Use "why" commands, and occasional "how" comments, but avoid "what" comments unless the logic is dense.
-   End every comment with a period, exclaimation point, or similar (what's important is that the thought is properly terminated).
-   Don't use UPPERCASE, instead use _emphasis_. TODO, FIXME, PERF, HACK, etc are exceptions to this rule, as they're used for grepping.
-   If there's a short `if (optional) |val|`, use `val` as the capture name, not `h`.
-   Avoid using overly terse names, like `ef` for an evaluation frame. Use something like `frame` or `eval_frame` instead. Use `err` instead of `e` as well.
-   Follow the known-new contract when writing: every sentence, always introduce something that the reader has previously read before introducing something new.
-   Whenever you refer to a variable or a piece of code, enclose it in backticks. Exceptions to this rule include integer types (i.e. i64, u5), error types (i.e. error.OutOfMemory), and command/subcommand names surrounded by brackets (e.g. [puts], not `puts`).
-   Don't remove comments when porting code. There's been multiple instances where code lost important comments during porting or refactoring. It makes it unnecessarily hard to reason about.
-   Make sure comments don't include internal thought processes or references to temporary state. Comments should be written for future readers of the code, not for scratch work.

## Available helper functions
@.claude/helpers.md

## Cookbook
@.claude/cookbook.md
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**zicl** (Zig Tcl) is a Tcl interpreter implementation written in Zig. It aims to provide a high-performance, memory-safe Tcl implementation with optional threading support and modern memory management. It is being developed mainly for the use in Folk Computer (https://folk.computer/), an interactive environment.

### Design Constraints
-   **Out of memory is considered recoverable.** Zig has strong support for OOM scenarios, and so we follow this idiom and make sure our OOM paths recover correctly.
-   **Fail fast and loud.** This has come up so so many times, please stop writing defensive code and either crash loudly or report the error clearly to the user.Also, don't _ever_ leave a piece of code unimplemented without panicking or raising an appropriate error. The last thing we need in an interpreter is silent correctness issues.
-   **Cross-thread sharing is a primary goal.** The multi-heap architecture exists specifically to support this. Design decisions should treat cross-thread object sharing as a first-class use case, not an afterthought.
-   **Interpreters can block indefinitely.** Blocking in C FFI (or otherwise) is considered normal operation. Nothing in the system may require an interpreter's owning thread to be active in order to make progress. In particular, foreign threads must be able to free objects belonging to a blocked heap without any cooperation from the owning thread.
-   **Allocation is thread-local; deallocation is cross-thread safe.** The buddy allocator uses a mutex-protected main list for operations from any thread, and a lock-free pool as a fast path for the owning thread only. Cross-thread frees go directly through the mutex to the main list -- no deferred queue is used, precisely because a deferred queue would require the owning thread to drain it.
-   **Every object must be transparently treated as a string.** All design decisions revolve around this -- at the end of the day everything in Zicl is a string. This means handle.tag() can't be relied on for the object to have a permanent type, since the tag is ephemeral. This also means that Zicl data structures can't depend on the current tag outside of optimization, since that would break the contract that all objects are transparently strings.
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

## Architecture Overview

### Core Components

**Heap (src/Heap.zig)**: Central memory management system using a buddy allocator for objects and strings. Supports:

-   Multi-heap architecture for threading
-   Reference counting for objects
-   Two string storage modes: normal (in-heap) and special (external allocation with a 65535-byte threshold, and room for mmaped files in the future)
-   Cross-thread object sharing with atomic operations
-   Object "shimmering" - internal type conversion that preserves cached representations based on the string

**Object System (src/objutil.zig)**: Implements Tcl's dynamic typing through type shimmering:

-   Objects can dynamically convert between types (string → list → dict, etc.)
-   Maintains the string value alongside the internal typed representation, though this string value is often lazily computed
-   Provides high-level operations for lists, dicts, strings, indices, enums, and source info
-   Dictionary operations: `dictPut`, `dictPutRecursively`, `dictRemove`, `dictRemoveRecursively`, `dictLookupRecursively`, `dictLookupFollowLinks`
-   Supports recursive key lookups for nested dictionaries
-   Dicts support `^parent` links (a `.hash_reference` value stored under the interned key `^parent`) for lexical scope chains. When iterating over dict keys or doing lookups, parent links must be followed recursively, with parent keys taking precedence (insertion order: parent keys first, then child keys not already present).
-   Uses packed structs for memory efficiency (Object is 16 bytes)

**Tokenizer (src/Tokenizer.zig)**: Tokenizes Tcl scripts supporting:

-   Variable substitution (`$var`, `${var}`)
-   Command substitution (`[cmd]`)
-   Argument expansion (`{*}`)
-   Proper quote/brace/bracket balancing with detailed error reporting

**Interpreter (src/Interp.zig)**: Executes parsed scripts:

-   Dual frame system: call frames (scope) and eval frames (execution state)
-   Variable resolution with caching via epochs (invalidated on scope changes)
-   Command dispatch supporting native commands, closures, and `[fn]` closures
    -   Native commands are looked up in `interp.global_commands`
    -   Closures are looked up as variables in the call frame chain (lexical scoping)
    -   Lazy native command initialization via `Heap.nativefn_registry` (see below)
-   Expression evaluation system
-   Loop control (break/continue with level support)
-   Exception handling: `[catch]`, `[try]`, `[return]` with `-code`/`-level`/`-errorstack` propagation
-   Scope manipulation: `[upvar]`, `[uplevel]`
-   Closure support (`[fn]`, `[method]`) with optional/required parameters, default values, and `args` parameter
-   Tail call optimization via `[tailcall]`

**NativeFn Registry (src/Heap.zig)**: A global, mutex-protected hash map for lazy C command initialization.

-   `Heap.nativefn_registry` maps command name → `NativeInitFn` (`*const fn (interp: *anyopaque) callconv(.c) void`)
-   When `getCommandInner` sees a variable containing `"nativefn <name>"` but the command is not in `interp.global_commands`, it checks the registry
-   If found, the init function is called, which should use `Zicl_CreateCommand` to register the actual commands in that interpreter
-   This replaces the old Jimtcl-style `<C:id>` string pattern matching in `unknown`
-   Registration returns `error.DuplicateNativeFn` on duplicate names to prevent definition drift

**Hash Registry (src/Heap.zig)**: A global, `RwLock`-protected content-addressable store for cross-heap object sharing.

-   `Heap.hash_registry` maps `u256` Blake3 hashes to `Handle`
-   Objects can be stored by hash via `.hash_reference` tags, allowing any heap to resolve the same object by content hash
-   Enables lexical scope capture across threads: closure scopes are captured as dicts, hashed, and stored in the registry
-   Foreign threads can free objects from a blocked heap by looking up and releasing hash references directly

### Object Representation

Objects use a packed 128-bit structure with three main parts:

1. **String representation** (59 bits): Either inline string metadata or pointer to LongString
2. **Tag** (5 bits): Type identifier (integer, float, list, dict, string, script, etc.)
3. **Body** (64 bits): Type-specific data

Objects automatically "shimmer" between types, maintaining cached representations when beneficial. For example, a string "1 2 3" can be shimmered to a list while keeping the string representation.

**Native command string representation**: When a native command is converted to a string, it produces `"nativefn <name>"`. This is the Tcl equivalent of JavaScript's `function log() { [native code] }`. `getCommandInner` recognizes this prefix and resolves it to the corresponding `global_commands` entry. If the command is not registered locally, the `nativefn_registry` is consulted for lazy initialization.

### Memory Management Principles

1. **Handles vs Objects**: Handles are lightweight references (64 bits) to objects in a heap. Objects live in the heap's object storage.

2. **Shimmerable and Mutable**: Two wrapper structs that track in-place modifications.
   - `Shimmerable = { original: Handle, shimmered: OptionalHandle }` -- for transparent type changes (the string representation is preserved or will be generated the same way).
   - `Mutable = { original: Handle, mutated: OptionalHandle }` -- for visible mutations (the string representation may change).
   - Both provide `.current()` to get the effective handle, `.consume()` to take ownership, and `.discardChanges()` to roll back.
   - `Mutable` can be cast to `Shimmerable` via `.asShimmerable()`.

3. **OptionalHandle**: A special enum type that can be `.none` or contain a `Handle`. Still used for optional values and inside `Shimmerable`/`Mutable`.

4. **Reference Counting**: All heap objects are ref-counted (including list items). Only interned strings and special objects bypass ref counting.

5. **Ownership Patterns**:

    - Functions that allocate return owned handles (caller must release)
    - `borrow()` increases ref count and returns the handle
    - `duplicate()` creates shallow copies
    - `decrRefCount()` decrements ref count and frees if zero (use in `defer` for cleanup)

### Script Execution Model

Scripts go through several stages:

1. **Tokenization** (Tokenizer): Source → tokens with location info
2. **Preprocessing** (parseScript in objutil.zig): Tokens → optimized script structure
    - Precomputes word boundaries and argument counts
    - Stores tokens as `.start_of_command` + arguments
    - Example: `set x 5` becomes [start_of_command(3), "set", "x", "5"]
3. **Caching** (LRU cache): Parsed scripts, expressions, and closures cached per-heap by `u256` content hash
4. **Evaluation** (evalObject): Walks token list, substitutes variables/commands, invokes commands

### Testing Patterns

Tests use `testing.checkAllAllocationFailures()` to ensure proper error handling under OOM conditions:

```zig
fn testFoo(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    try Heap.testStart(ta, testing.io);
    // ... test code ...
}

test "foo" {
    try testing.checkAllAllocationFailures(testing.allocator, testFoo, .{});
}
```

Always call `Heap.testFinish()` to verify no memory leaks.

The project has 14 comprehensive test suites covering:

-   Object system: dicts, lists, script parsing, script shimmering
-   Commands: commands, dict commands, loop commands
-   Expressions: eval expression, expressions
-   Variables: variables, recursive dict keys
-   Utilities: source info, string is, tcl enum

Helper functions available:

-   `testRunScript(interp, script)` -- Evaluate script and return result handle
-   `testExpectScriptResult(interp, expected, script)` -- Assert result string matches expected
-   `testExpectScriptError(interp, expected_error, expected_str, script)` -- Assert script fails with specific error and message

### Important Code Patterns

**Creating Objects**:

```zig
const str = try objutil.newString("hello");
defer str.decrRefCount();
```

**Working with Lists**:

```zig
const list = try objutil.newList(&.{item1, item2});
defer list.decrRefCount();
const item = objutil.listItem(list, 0); // Non-owning handle
```

**Type Shimmering** (`Shimmerable` / `Mutable` API):

Shimmer and mutation functions take a `*Shimmerable` or `*Mutable` working buffer. The wrapper tracks whether the object had to be duplicated. Callers use `.current()` to get the effective handle and `.discardChanges()` on cleanup paths.

```zig
// Shimmer functions take a *Shimmerable working buffer.
var det: objutil.ErrorDetails = undefined;
var wb: objutil.Shimmerable = .{ .original = handle };
defer wb.discardChanges();
try objutil.shimmerToList(&det, &wb);
// wb.current() is now a list. If wb.shimmered is non-null, the object moved.

// Pattern inside shimmer functions:
pub fn shimmerToInteger(det: ?*ErrorDetails, wb: *Shimmerable) !void {
    if (wb.tag() == .integer) return;
    errdefer wb.discardChanges();

    const value = try integerGetNoShimmer(det, wb.current());

    try wb.prepareToShimmer();
    wb.peek().head.tag = .integer;
    wb.peek().body.integer = value;
}
```

**Mutation functions** use `Mutable` instead of `Shimmerable`:

```zig
var wb: Mutable = .{ .original = dict };
defer wb.discardChanges();
_ = try objutil.dictPutObject(&det, &wb, key_handle, value_object);
// wb.current() now holds the mutated dict.
```

**In-place Shimmering** (for single `Handle` references):

```zig
// Interp provides helpers that wrap a *Handle into a local Shimmerable.
const value = try interp.getInteger(&args[1]);
// args[1] is shimmered in place if needed.
```

Or manually:

```zig
var wb: Shimmerable = .{ .original = my_handle };
defer wb.discardChanges();
const value = try objutil.integerGet(&det, &wb);
my_handle = wb.consume();
```

**Get Functions** (shimmer + extract value):

```zig
var wb: Shimmerable = .{ .original = my_handle };
defer wb.discardChanges();
const value = try objutil.integerGet(&det, &wb);
my_handle = wb.consume();
// my_handle is now an integer type, value contains the i64.
```

**Shimmerability guards**: Before mutating or shimmering an object, always check (or ensure) that it is safe to do so. `handle.canShimmer()` returns false for shared or cross-thread objects. `handle.canMutate()` returns false when ref count is greater than 1 or the object is cross-thread. `Shimmerable` provides `.ensureShimmerable()` and `.prepareToShimmer()`; `Mutable` provides `.prepareToMutate()`. Always call `prepareToShimmer()` before changing an object's tag or body.

**Error Handling with Details**:

```zig
var det: objutil.ErrorDetails = undefined;
const result = try someFn(&det, arg);
// On error, det.message contains user-facing error string. Pass in `null` to `someFn` to avoid the error being allocated on the heap.
```

## Key Files

-   `src/Heap.zig`: Memory allocator and object storage (~3800 lines)
-   `src/objutil.zig`: Object type system and operations (~2700 lines)
-   `src/Interp.zig`: Interpreter and command execution (~3500 lines)
-   `src/Tokenizer.zig`: Tcl tokenizer (~1200 lines)
-   `src/expr_parse.zig`: Expression parser with full AST (~900 lines)
-   `src/strutil.zig`: String utilities with optional UTF-8 support (~875 lines)
-   `src/memutil.zig`: Buddy allocator, memory primitives, and LRU cache (~900 lines)
-   `src/commands.zig`: Built-in command implementations (~2200 lines)
-   `src/libzicl.zig`: C FFI library entry point (~320 lines)
-   `src/tripwire.zig`: Vendored failure-injection library for testing error paths (~290 lines)
-   `src/repl.zig`: REPL (stub, not yet implemented)
-   `.claude/helpers.md`: Index of public helper functions in the utility files

## Configuration

Build options (in build.zig):

-   `use_utf8`: Enable UTF-8 support (default: true)
-   `use_llvm`: Force LLVM backend (default: false)
-   `test_filter`: Filter for specific tests
-   `token_debugging`: Print tokens during parsing (default: false)
-   `threading`: Enable thread-safe operations (default: true)
-   `trace_mem`: Enable memory operation tracing (default: true in Debug, false in Release)

Heap settings (in Heap.zig cfg):

-   `object_heap_order`: Max 2^24 objects (default: 24)
-   `string_heap_order`: Max 2^28 bytes for strings (default: 28)
-   `max_heaps`: Maximum concurrent heaps (default: 128)
-   `max_custom_types`: Maximum registered custom types (default: 65536)
-   `max_scripts`: Maximum cached parsed scripts per heap (default: 65536)
-   `cache_size`: LRU cache size for parsed scripts, expressions, and closures (default: 512)

## Development Principles

**Memory Leak Prevention**: This project has ZERO tolerance for memory leaks, even in obscure edge cases or OOM scenarios. Every allocation must have a clear deallocation path, including error paths. When adding new code that allocates memory:

-   Always add `errdefer` cleanup for allocations that might fail before ownership transfer
-   Test with `testing.checkAllAllocationFailures()` to verify all OOM paths are leak-free
-   If a function allocates and returns data, document ownership clearly
-   Use `defer` for immediate cleanup, `errdefer` for error-path cleanup

Example pattern:

```zig
const data = try allocator.alloc(u8, size);
errdefer allocator.free(data);  // Free if subsequent operations fail
const result = try processData(data);  // This might fail
// data ownership transferred to result, no explicit free needed
```

## Common Issues

**Double Free**: If you see double-free panics, check the memory trace. With the splitting allocator design, collection items CAN be borrowed and ref-counted individually. However, you should only call `decrRefCount()` on items you explicitly borrowed. Enable `options.trace_mem` to dump the full allocation/deallocation trace.

**Overlapping errdefers after ownership transfer**: When you transfer ownership of a raw `Heap.Object` into a collection slot (e.g. `new_value_handle.peek().* = value;`) inside a nested block with its own `errdefer`, null out the source variable afterward (`value_mut = Heap.emptyObject()`). Otherwise an outer `errdefer value_mut.deinitSingle(...)` and an inner `errdefer new_value_handle.invalidateBoth()` will both try to free the same backing object if an error occurs after the transfer, causing a double-free under OOM.

**Shimmer Errors**: If shimmering fails, ensure the handle is not shared between threads. Use `Shimmerable.ensureShimmerable()` or `Mutable.prepareToMutate()` to automatically duplicate if the handle cannot shimmer in place.

**OOM in Tests**: Use `testing.checkAllAllocationFailures()` wrapper to test all OOM code paths. All tests should pass without leaks even when allocations fail at any point.

**String Representation**: Some operations require string representations. The heap will auto-generate them when calling `Heap.getString()`, but this can fail with OOM.

**Command Naming**: Command implementation functions follow the pattern `nameCmd` (e.g., `ifCmd`, `forCmd`, `dictCmd`) with a `Cmd` prefix.

## Debugging

This project has comprehensive tracing for all memory operations. _Always_ read the complete trace before jumping into the code--the trace often holds the answer.

## Recent Development

Recent fixes and improvements:

-   **String commands**: Implemented `[string]` with 20 subcommands (length, index, range, match, map, cat, compare, equal, trim, tolower, toupper, totitle, repeat, replace, reverse, first, last).
-   **List commands**: Implemented `[list]`, `[llength]`, `[lappend]`, `[lassign]`, and `[concat]`.
-   **File I/O**: Implemented `[file]` with 12 subcommands (exists, dirname, tail, rootname, join, mkdir, size, readable, isdirectory, mtime, readlink, tempfile), plus `[source]`.
-   **Hash references**: Implemented `.hash_reference` objects and a global `HashRegistry` for cross-heap, cross-thread object sharing by content hash.
-   **Exception system**: Implemented `[catch]`, `[try]`, `[return]`, and `[errorinfo]` with proper `-code`/`-level`/`-errorstack` propagation.
-   **Closures via `[fn]`**: Implemented first-class closures with lexical scope capture. `[fn]` replaces both `[proc]` and `[apply]`. Closures capture their defining scope and support required args, optional args with defaults, and varargs. `[method]` provides the same for methods.
-   **LRU cache**: Parsed scripts, expressions, and closures are now cached per-heap using an LRU cache (in `memutil.zig`), replacing the old ScriptId system.
-   **Shimmerable/Mutable Refactoring (complete)**: Refactored the entire object mutation API from pointer-based mutation and `OptionalHandle` out-parameters to `Shimmerable` and `Mutable` wrapper structs.
    -   `Shimmerable = { original: Handle, shimmered: OptionalHandle }` tracks transparent type conversions.
    -   `Mutable = { original: Handle, mutated: OptionalHandle }` tracks visible mutations.
    -   Shimmer functions: `shimmerToX(det, wb: *Shimmerable) !void`
    -   Mutation functions: `dictPut(wb: *Mutable, key, value) !Handle`, `listAppend(wb: *Mutable, item) !Handle`, etc.
    -   Interp wrappers: `getInteger(wb: *Shimmerable) !i64`, `shimmerToDict(wb: *Shimmerable) !void`, etc.
    -   Command signatures now take `[]Shimmerable` instead of `[]Handle`, allowing in-place shimmering of arguments.
-   **Variable caching**: Reworked variable resolution with `resolveVariable`, `reshimmerToVariable`, and `ensureValidVariableType`. Local variables cache their dict slot index; lexical variables cache the resolved value via extra data.
-   **Dict iteration**: Added `dictGetKvPairs` which recursively flattens parent links into an `ArrayHashMap` for iteration.
-   **Dictionary operations**: Added `dictRemove`, `dictRemoveRecursively`, fixed duplicate handling, added dict parent-link flattening.
-   **Command architecture**: Standardized function naming conventions.
-   **Loop control**: Fixed break/continue propagation with level support.
-   **Memory safety**: Fixed double-free on initialization failure and interned string leaks.

## Development Status

Currently implemented:

-   Complete tokenizer with full Tcl syntax support
-   Object system with all major types (none, invalid, marked, index, integer, float, bool, string, source, list, dict, dict_sugar, parsed_script_command, reference, hash_reference, cached_local_var, cached_lexical_var, upvar_link, closure, custom_type)
-   Memory management with reference counting and buddy allocation
-   Script parsing and caching
-   Expression evaluation with full AST
    -   Binary/unary operators, ternary conditional
    -   Math functions: sin, cos, tan, asin, acos, atan, atan2, sinh, cosh, tanh, pow, hypot, fmod
    -   Utility functions: ceil, floor, exp, log, log10, sqrt, abs, round
    -   Type conversion: int(), wide(), double()
    -   Random: rand(), srand()
-   Variable management and scoping with epoch-based caching
-   Command registration and dispatch system
-   Closures with lexical scope capture
    -   `[fn]` captures its defining lexical scope automatically
    -   This eliminates the need for Jimtcl-style `^$name` prefixing and manual `captureEnvStack` plumbing
    -   Most `proc` definitions that use `upvar`/`uplevel` are workarounds for lack of lexical scoping and should migrate to `fn`
    -   Legitimate dynamic scope uses (e.g., `uplevel expr`, reading caller's `this`, `uplevel subst`) will need dedicated zicl commands
-   Core built-in commands (~40 implemented):
    -   Math: [+], [-], [*], [/], [%], [**], [expr], [incr]
    -   Control flow: [if], [for], [while], [break], [continue], [catch], [try], [return], [tailcall]
    -   Variables: [set], [unset], [upvar], [uplevel], [append]
    -   Closures: [fn], [method], [apply], [applymethod]
    -   Data structures: [dict] (get, getdef, set, remove, exists, size, keys, values, merge, create, link), [list], [llength], [lappend], [lassign], [concat]
    -   String: [string] (length, index, range, match, map, cat, compare, equal, trim, tolower, toupper, totitle, repeat, replace, reverse, first, last)
    -   File I/O: [file] (exists, dirname, tail, rootname, join, mkdir, size, readable, isdirectory, mtime, readlink, tempfile), [source], [puts]
    -   Introspection: [info], [errorinfo], [pid]
    -   Misc: [hash], [hashlookup], [launder]

Partially complete:

-   Interpreter evaluation (core complete, needs more built-in commands)

Not yet implemented:

-   [lindex], [lrange], [lsort], [split], [join]
-   [foreach] loop
-   File I/O beyond [file] subcommands (open, close, read, write)
-   Most Tcl standard library commands

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
-   Prefer
    ```
    blk: {
        if (foo) {
            break :blk 123;
        } else {
            break :blk 456;
        }
    }
    ```
    over
    ```
    if (foo) 123 else 456;
    ```
    except in cases where all parts of the conditional are brief.

## Available helper functions
@.claude/helpers.md

## Cookbook
@.claude/cookbook.md
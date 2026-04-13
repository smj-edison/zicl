# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**zicl** (Zig Tcl) is a Tcl interpreter implementation written in Zig. It aims to provide a high-performance, memory-safe Tcl implementation with optional threading support and modern memory management.

### Design Constraints
-   **Out of memory is considered recoverable.** Zig has strong support for OOM scenarios, and so we follow this idiom and make sure our OOM paths recover correctly.
-   **Cross-thread sharing is a primary goal.** The multi-heap architecture exists specifically to support this. Design decisions should treat cross-thread object sharing as a first-class use case, not an afterthought.
-   **Interpreters can block indefinitely.** Blocking in C FFI (or otherwise) is considered normal operation. Nothing in the system may require an interpreter's owning thread to be active in order to make progress. In particular, foreign threads must be able to free objects belonging to a blocked heap without any cooperation from the owning thread.
-   **Allocation is thread-local; deallocation is cross-thread safe.** The buddy allocator uses a mutex-protected main list for operations from any thread, and a lock-free pool as a fast path for the owning thread only. Cross-thread frees go directly through the mutex to the main list — no deferred queue is used, precisely because a deferred queue would require the owning thread to drain it.

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

Remember that the default zig test runner (the one we use) does not print anything on success, it only returns a successful code. Use `echo "exit: $?"` to check the status.

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

-   Multi-heap architecture for potential threading
-   Reference counting for objects
-   Two string storage modes: normal (in-heap) and long (external allocation with a 100KB threshold)
-   Cross-thread object sharing with atomic operations
-   Object "shimmering" - dynamic type conversion that preserves cached representations

**Object System (src/objutil.zig)**: Implements Tcl's dynamic typing through type shimmering:

-   Objects can dynamically convert between types (string → list → dict, etc.)
-   Maintains string representation alongside typed representation when beneficial
-   Provides high-level operations for lists, dicts, strings, indices, enums, and source info
-   Dictionary operations: `dictPut`, `dictPutRecursively`, `dictRemove`, `dictRemoveRecursively`, `dictLookupRecursively`, `dictLookupFollowRefs`, `dictReindex`
-   Supports recursive key lookups for nested dictionaries
-   Uses packed structs for memory efficiency (Object is 16 bytes)

**Tokenizer (src/Tokenizer.zig)**: Tokenizes Tcl scripts supporting:

-   Variable substitution (`$var`, `${var}`)
-   Command substitution (`[cmd]`)
-   Argument expansion (`{*}`)
-   Proper quote/brace/bracket balancing with detailed error reporting

**Interpreter (src/Interp.zig)**: Executes parsed scripts:

-   Dual frame system: call frames (scope) and eval frames (execution state)
-   Variable resolution with caching via epochs (invalidated on scope changes)
-   Command dispatch supporting both native and Tcl procedures
-   Expression evaluation system
-   Loop control (break/continue with level support)
-   Procedure support with optional/required parameters, default values, and `args` parameter
-   Tail call optimization preparation

### Object Representation

Objects use a packed 128-bit structure with three main parts:

1. **String representation** (59 bits): Either inline string metadata or pointer to LongString
2. **Tag** (5 bits): Type identifier (integer, float, list, dict, string, script, etc.)
3. **Body** (64 bits): Type-specific data

Objects automatically "shimmer" between types, maintaining cached representations when beneficial. For example, a string "1 2 3" can be shimmered to a list while keeping the string representation.

### Memory Management Principles

1. **Handles vs Objects**: Handles are lightweight references (64 bits) to objects in a heap. Objects live in the heap's object storage.

2. **OptionalHandle**: A special enum type that can be `.none` or contain a `Handle`. Used as an output parameter in shimmer functions to indicate whether duplication occurred.

3. **Reference Counting**: Handles can be ref-counted (sharable) or non-ref-counted (e.g., list items).

4. **Ownership Patterns**:

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
    - Example: `set x 5` becomes [start_of_command(2), "set", "x", "5"]
3. **Caching** (LRU cache): Parsed scripts, expressions, and closures cached per-heap by unique ID
4. **Evaluation** (evalObject): Walks token list, substitutes variables/commands, invokes commands

### Testing Patterns

Tests use `testing.checkAllAllocationFailures()` to ensure proper error handling under OOM conditions:

```zig
fn testFoo(ta: std.mem.Allocator) !void {
    const heap = try Heap.createHeap(ta);
    defer Heap.testFinish();
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

-   `testRunScript(heap, script)` - Execute script and return result
-   `testExpectScriptResult(heap, script, expected)` - Assert result matches expected value

### Important Code Patterns

**Creating Objects**:

```zig
const str = try object.newString(heap, "hello");
defer str.decrRefCount();
```

**Working with Lists**:

```zig
const list = try object.newList(&.{item1, item2});
defer list.decrRefCount();
const item = object.listItem(list, 0); // Non-owning handle
```

**Type Shimmering** (output parameter API):

```zig
// Shimmer functions take Handle by value and *OptionalHandle output parameter.
var det: object.ErrorDetails = undefined;
var new_handle: OptionalHandle = .none;
try object.shimmerToList(&det, handle, &new_handle);
handle.swapIfNew(new_handle);  // Update if shimmer created a duplicate
// handle is now a list type

// Pattern inside shimmer functions:
pub fn shimmerToInteger(det: ?*ErrorDetails, provided_handle: Handle, new_handle: *OptionalHandle) !void {
    if (provided_handle.tag() == .integer) return;
    errdefer new_handle.swapWithNone();

    try Heap.ensureShimmerableOrDup(provided_handle, new_handle);
    const handle = new_handle.orElse(provided_handle);

    // ... shimmer logic ...
}
```

**Get Functions** (shimmer + extract value):

```zig
// Get functions that shimmer and return a value.
var new_handle: OptionalHandle = .null;
const value = try object.integerGet(&det, my_handle, &new_handle);
my_handle.swapIfNew(new_handle);
// my_handle is now an integer type, value contains the i64
```

**Error Handling with Details**:

```zig
var det: object.ErrorDetails = undefined;
const result = try someFn(heap, &det, arg);
// On error, det.message contains user-facing error string. Pass in `null` to `someFn` to avoid the error being allocated on the heap.
```

## Key Files

-   `src/Heap.zig`: Memory allocator and object storage (~3000 lines)
-   `src/objutil.zig`: Object type system and operations (~2700 lines)
-   `src/Interp.zig`: Interpreter and command execution (~2400 lines)
-   `src/Tokenizer.zig`: Tcl tokenizer (~1200 lines)
-   `src/expr_parse.zig`: Expression parser with full AST (~900 lines)
-   `src/stringutil.zig`: String utilities with optional UTF-8 support (~875 lines)
-   `src/memutil.zig`: Buddy allocator, memory primitives, and LRU cache (~900 lines)
-   `src/commands.zig`: Built-in command implementations (~520 lines)
-   `src/tripwire.zig`: Vendored failure-injection library for testing error paths (~290 lines)
-   `src/repl.zig`: REPL (stub, not yet implemented)
-   `.claude/helpers.md`: Index of public helper functions in the utility files

## Configuration

Build options (in build.zig):

-   `use_utf8`: Enable UTF-8 support (default: true)
-   `use_llvm`: Force LLVM backend (default: false)
-   `test_filter`: Filter for specific tests
-   `token_debugging`: Print tokens during parsing (default: false)

Heap settings (in Heap.zig cfg):

-   `threading`: Enable thread-safe operations (default: true)
-   `use_vmem`: Use virtual memory mapping (default: true)
-   `object_heap_order`: Max 2^24 objects (default: 24)
-   `string_heap_order`: Max 2^28 bytes for strings (default: 28)
-   `max_heaps`: Maximum concurrent heaps (default: 128)

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

**Shimmer Errors**: If shimmering fails, ensure the handle is not shared between threads. Use `Heap.ensureShimmerableOrDup()` to automatically duplicate if the handle cannot shimmer.

**OOM in Tests**: Use `testing.checkAllAllocationFailures()` wrapper to test all OOM code paths. All tests should pass without leaks even when allocations fail at any point.

**String Representation**: Some operations require string representations. The heap will auto-generate them when calling `Heap.getString()`, but this can fail with OOM.

**Command Naming**: Command implementation functions follow the pattern `nameCmd` (e.g., `ifCmd`, `forCmd`, `dictCmd`) with a `Cmd` prefix.

## Debugging

This project has comprehensive tracing for all memory operations. _Always_ read the complete trace before jumping into the code—the trace often holds the answer.

## Recent Development

Recent fixes and improvements:

-   **Closures via `[fn]`**: Implemented first-class closures with lexical scope capture. `[fn]` replaces both `[proc]` and `[apply]`. Closures capture their defining scope and support required args, optional args with defaults, and varargs.
-   **LRU cache**: Parsed scripts, expressions, and closures are now cached per-heap using an LRU cache (in `memutil.zig`), replacing the old ScriptId system.
-   **Handle Refactoring (complete)**: Refactored Handle management API from pointer-based mutation (`shimmerToX(&det, &handle)`) to an output parameter pattern that eliminates use-after-free issues.
    -   New signature: `shimmerToX(det, provided_handle, new_handle: *OptionalHandle) !void`
    -   Get functions (e.g., `integerGet`) take same parameters and return the value directly
    -   Standard pattern: `errdefer new_handle.swapWithNone()` at function start
    -   Caller pattern: `handle.swapIfNew(new_handle)` to update handle references
-   Dictionary operations: Added `dictRemove`, fixed duplicate handling
-   Command architecture: Standardized function naming conventions
-   Loop control: Fixed break/continue propagation with level support
-   Memory safety: Fixed double-free on initialization failure and interned string leaks
-   Dictionary commands: Fixed `[dict set]` bugs for nested operations

## Development Status

Currently implemented:

-   Complete tokenizer with full Tcl syntax support
-   Object system with all major types (none, invalid, marked, index, integer, float, bool, string, source, list, dict, dict_sugar, parsed_script_command, reference, cached_local_var, cached_lexical_var, upvar_link, closure, custom_type)
-   Memory management with reference counting and buddy allocation
-   Script parsing and caching
-   Expression evaluation with full AST
    -   Binary/unary operators, ternary conditional
    -   Math functions: sin, cos, tan, asin, acos, atan, atan2, sinh, cosh, tanh
    -   Utility functions: ceil, floor, exp, log, log10, sqrt, abs, round
    -   Type conversion: int(), wide(), double()
    -   Random: rand(), srand()
-   Variable management and scoping with epoch-based caching
-   Command registration and dispatch system
-   Closures with lexical scope capture
-   Core built-in commands (12 implemented):
    -   Math: [+], [*], [incr], [expr]
    -   Control flow: [if], [for], [break], [continue]
    -   Variables: [set]
    -   Closures: [fn]
    -   Data structures: [dict] (get, getdef, set, remove)
    -   I/O: [puts]

Partially complete:

-   Interpreter evaluation (core complete, needs more built-in commands)

Not yet implemented:

-   String commands (string length, range, match, etc.)
-   List commands (lindex, lrange, lappend, llength, etc.)
-   While/foreach loops
-   File I/O (open, close, read, write)
-   Most Tcl standard library commands
-   Error stack traces

## Style guide
-   Write Tcl as Tcl, not TCL.
-   Prefer commas or parenthesis over em-dashes. Also, write in ASCII characters exclusively (i.e. no — or →). Double hypens, --, can substitute for a proper em dash.
-   Use "why" commands, and occasional "how" comments, but avoid "what" comments unless the logic is dense.
-   End every comment with a period, exclaimation point, or similar (what's important is that the thought is properly terminated).
-   Don't use UPPERCASE, instead use _emphasis_. TODO, FIXME, PERF, HACK, etc are exceptions to this rule, as they're used for grepping.
-   If there's a short `if (optional) |val|`, use `val` as the capture name, not `h`.
-   Avoid using overly terse names, like `ef` for an evaluation frame. Use something like `frame` or `eval_frame` instead. Use `err` instead of `e` as well.
-   Follow the known-new contract when writing: every sentence, always introduce something that the reader has previously read before introducing something new.
-   Whenever you refer to a variable or a piece of code, enclose it in backticks. Exceptions to this rule include integer types (i.e. i64, u5) and error types (i.e. error.OutOfMemory).

## Available helper functions
@.claude/helpers.md
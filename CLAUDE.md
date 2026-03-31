# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**zicl** (Zig TCL) is a TCL interpreter implementation written in Zig. It aims to provide a high-performance, memory-safe TCL implementation with optional threading support and modern memory management.

### Design Constraints

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

Build with specific options:

```bash
# Disable UTF-8 support (ASCII only)
zig build -Duse-utf8=false

# Force LLVM backend
zig build -Duse-llvm=true

# Enable token debugging (prints tokens during parsing)
zig build -Dtoken-debugging=true
```

## Architecture Overview

### Core Components

**Heap (src/Heap.zig)**: Central memory management system using a buddy allocator for objects and strings. Supports:

-   Multi-heap architecture for potential threading (up to 128 heaps)
-   Reference counting for objects
-   Two string storage modes: normal (in-heap) and long (external allocation with 100KB threshold)
-   Cross-thread object sharing with atomic operations
-   Object "shimmering" - dynamic type conversion that preserves cached representations

**Object System (src/objutil.zig)**: Implements TCL's dynamic typing through type shimmering:

-   Objects can dynamically convert between types (string → list → dict, etc.)
-   Maintains string representation alongside typed representation when beneficial
-   Provides high-level operations for lists, dicts, strings, indices, enums, and source info
-   Dictionary operations: `dictPut`, `dictPutRecursively`, `dictRemove`, `dictRemoveRecursively`, `dictLookupRecursively`, `dictLookupFollowRefs`, `dictReindex`
-   Supports recursive key lookups for nested dictionaries
-   Uses packed structs for memory efficiency (Object is 16 bytes)

**Tokenizer (src/Tokenizer.zig)**: Tokenizes TCL scripts supporting:

-   Variable substitution (`$var`, `${var}`)
-   Command substitution (`[cmd]`)
-   Argument expansion (`{*}`)
-   Proper quote/brace/bracket balancing with detailed error reporting

**Interpreter (src/Interp.zig)**: Executes parsed scripts:

-   Dual frame system: call frames (scope) and eval frames (execution state)
-   Variable resolution with caching via epochs (invalidated on scope changes)
-   Command dispatch supporting both native and TCL procedures
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

5. **Handle Helper Functions** (prefer these over manual operations):

    **Reference Counting:**

    - `handle.borrow()` - Increment ref count and return handle (for creating owned references)
    - `OptionalHandle.borrowOptional()` - Borrow optional handle if it has a value, else a nop.
    - `handle.decrRefCount()` - Decrement ref count, free if zero (use in `defer` for cleanup)
    - `handle.incrRefCount()` - Increment ref count (rarely needed directly)
    - `handle.debugRefCount()` - Get current ref count (debugging only)

    **OptionalHandle Operations:**

    - `OptionalHandle.orElse(handle)` - Return contained handle if non-none, else fallback
    - `OptionalHandle.toHandle()` - Convert to `?Handle`
    - `OptionalHandle.swapWithNone()` - Decrement ref count and set to none (use in `errdefer`)
    - `OptionalHandle.swapRef(handle)` - Swap and decref old value
    - `OptionalHandle.swapRefIfNew(optional)` - Conditionally swap if non-none
    - `Handle.toOptional()` - Convert Handle to OptionalHandle

    **Handle Swapping** (for updating handle references):

    - `handle.swapIfNew(optional_handle)` - Update handle if optional is non-null, releasing old
    - `handle.swap(new_handle)` - Always swap and release old
    - `handle.swapAndClear(&optional_handle)` - Transfer ownership from optional and clear it

    **Querying Handle State:**

    - `handle.peek()` - Get pointer to Object (does NOT increase ref count)
    - `handle.getHeap()` - Get the heap this handle belongs to
    - `handle.canShimmer()` - Check if can change type (not shared, not special)
    - `handle.canMutate()` - Check if can modify in-place (exclusive ownership)
    - `handle.isShared()` - Check if ref_count > 1 or cross-thread
    - `handle.hasString()` - Check if has string representation cached
    - `handle.getMetadata()` - Get object metadata (order, mutable flag, etc.)

    **Shimmering Helpers:**

    - `handle.prepareToShimmer()` - Ensure string rep exists, invalidate body (requires canShimmer)

    **Invalidation** (low-level, rarely used directly):

    - `handle.invalidateBody()` - Clear body (called by prepareToShimmer)
    - `handle.invalidateString()` - Clear string rep when mutating
    - `handle.invalidateBoth()` - Clear both body and string

    **Creating References:**

    - `handle.reference()` - Create reference object, incrementing ref count
    - `handle.referenceTakeOwnership()` - Create reference object without incrementing ref count

    **Other Handle Operations:**

    - `handle.isAllocHead()` - Check if this is the allocation head for multi-object allocation

    **Heap-Level Helpers:**

    - `heap.duplicate(handle)` - Deep copy to same or different heap
    - `Heap.ensureShimmerableOrDup(handle, *OptionalHandle)` - Duplicates if can't shimmer (output parameter)
    - `Heap.ensureMutableOrDup(handle, *OptionalHandle)` - Duplicates if can't mutate (output parameter)
    - `Heap.ensureSameHeapOrDup(handle, *OptionalHandle)` - Duplicates if different heap (output parameter)
    - `Heap.getString(handle)` - Get string representation (may allocate)
    - `Heap.setString(handle, bytes)` - Set string representation
    - `Heap.checkIfEqual(a, b)` - Deep equality check

    **Special Object Access:**

    - `heap.nullObject()` - Get the null object handle
    - `heap.emptyObject()` - Get empty object handle
    - `heap.tempObject()` - Get temporary object handle

    **Debugging:**

    - `handle.trace(fmt, args)` - Add trace entry (if trace_mem enabled)
    - `handle.assert(condition)` - Assert with automatic trace dump on failure

6. **Shimmering Rules**:

    - Objects can only shimmer if not shared between threads (`canShimmer()` checks this)
    - Shimmer functions take `provided_handle: Handle` and output parameter `new_handle: *OptionalHandle`
    - If duplication occurs, `new_handle` will be non-null
    - Always use `errdefer new_handle.swapWithNone()` at the start of shimmer functions
    - Use `new_handle.orElse(provided_handle)` to get the actual handle to work with
    - Caller uses `handle.swapIfNew(new_handle)` to update their handle reference
    - Shimmering invalidates the old body but preserves string rep when possible

7. **Collections (Lists/Dicts)**:
    - Stored as contiguous object arrays allocated via the buddy allocator
    - First object is head (contains metadata), subsequent objects are items
    - Each item has its own ref count and CAN be borrowed individually with `handle.borrow()`
    - When the collection is freed, if any items are shared (ref count > 1), the buddy allocator automatically splits the multi-object block into individual allocations
    - Shared items survive the collection being freed because they have independent ref counts
    - Non-shared items are freed along with the collection head

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
-   `src/Tokenizer.zig`: TCL tokenizer (~1200 lines)
-   `src/expr_parse.zig`: Expression parser with full AST (~900 lines)
-   `src/stringutil.zig`: String utilities with optional UTF-8 support (~875 lines)
-   `src/memutil.zig`: Buddy allocator, memory primitives, and LRU cache (~900 lines)
-   `src/commands.zig`: Built-in command implementations (~520 lines)
-   `src/tripwire.zig`: Vendored failure-injection library for testing error paths (~290 lines)
-   `src/repl.zig`: REPL (stub, not yet implemented)

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

-   Complete tokenizer with full TCL syntax support
-   Object system with all major types (string, integer, float, list, dict, bool, index, enum, script, source_info)
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

-   Dictionary operations (comprehensive API, subset of subcommands implemented)
-   Interpreter evaluation (core complete, needs more built-in commands)

Not yet implemented:

-   String commands (string length, range, match, etc.)
-   List commands (lindex, lrange, lappend, llength, etc.)
-   While/foreach loops
-   File I/O (open, close, read, write)
-   Most TCL standard library commands
-   Error stack traces
-   REPL

## Notes

**Experimental Files**: The repository contains `foo.zig` and `bar.zig` which are one-off prototypes not relevant to the overall architecture and can be ignored.

## Style guide

-   Use "why" commands, and occasional "how" comments, but avoid "what" comments unless the logic is dense.
-   End every comment with a period.
-   Don't use UPPERCASE, instead use _emphasis_.
-   If there's a short `if (optional) |val|`, use `val` as the capture name, not `h`.

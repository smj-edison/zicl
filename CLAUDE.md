# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**zicl** (Zig TCL) is a TCL interpreter implementation written in Zig. It aims to provide a high-performance, memory-safe TCL implementation with optional threading support and modern memory management.

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

**Object System (src/object.zig)**: Implements TCL's dynamic typing through type shimmering:

-   Objects can dynamically convert between types (string → list → dict, etc.)
-   Maintains string representation alongside typed representation when beneficial
-   Provides high-level operations for lists, dicts, strings, indices, enums, and source info
-   Dictionary operations: `dictGet`, `dictGetDefault`, `dictSet`, `dictPut`, `dictRemove`, `dictRemoveDuplicates`, `dictReindex`
-   Supports recursive key lookups for nested dictionaries
-   Uses packed structs for memory efficiency (Object is 16 bytes)

**Tokenizer (src/Tokenizer.zig)**: Tokenizes TCL scripts supporting:

-   Variable substitution (`$var`, `${var}`)
-   Command substitution (`[cmd]`)
-   Dictionary sugar (`$var(key)`)
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

2. **Reference Counting**: Handles can be ref-counted (sharable) or non-ref-counted (e.g., list items). Use `heap.borrow()` and `handle.release()`.

3. **Ownership Patterns**:

    - Functions that allocate return owned handles (caller must release)
    - `borrow()` increases ref count (may duplicate if the handle being borrowed isn't ref counted)
    - `duplicate()` creates shallow copies
    - `steal()` transfers ownership without copying (internal use)
    - `release()` decrements ref count, but only if the handle is ref counted in the first place.

4. **Shimmering Rules**:

    - Objects can only shimmer if not shared between threads (`canShimmer()` checks this)
    - Shimmer functions take `Handle` by value and return `!?Handle` (optional new handle if duplicated)
    - Use `Handle.swapIfNew(new_handle)` to update handle references when shimmer returns a new handle
    - Shimmering invalidates the old body but preserves string rep when possible
    - Helper functions: `Heap.ensureShimmerableOrDup()`, `Heap.ensureMutableOrDup()` check if duplication is needed

5. **Collections (Lists/Dicts)**: Stored as contiguous object arrays. First object is head (contains metadata), subsequent objects are items. Cannot reference individual items externally (they're not ref-counted), but `borrow()` accounts for this.

### Script Execution Model

Scripts go through several stages:

1. **Tokenization** (Tokenizer): Source → tokens with location info
2. **Preprocessing** (parseScript in object.zig): Tokens → optimized script structure
    - Precomputes word boundaries and argument counts
    - Stores tokens as `.start_of_command` + arguments
    - Example: `set x 5` becomes [start_of_command(2), "set", "x", "5"]
3. **Caching** (ScriptId system): Parsed scripts cached per-heap by unique ID
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
defer str.release();
```

**Working with Lists**:

```zig
const list = try object.listNew(heap, &.{item1, item2});
defer list.release();
const item = object.listItemRaw(list, 0); // Non-owning handle
```

**Type Shimmering** (value-based API):

```zig
// Shimmer functions take Handle by value and return optional new handle
const new_handle = try object.shimmerToList(&det, handle);
handle.swapIfNew(new_handle);  // Update if shimmer created a duplicate
// handle is now a list type

// For wrapper functions that return both new handle and value:
const result = try object.getBoolean(&det, handle);
handle.swapIfNew(result.new_handle);
const value = result.value;
```

**Handle Update Pattern**:

```zig
// When a function returns !?Handle (shimmer functions):
const new_handle = try shimmerToInteger(&det, my_handle);
my_handle.swapIfNew(new_handle);  // Automatically releases old and swaps if needed

// When a function returns struct { new_handle: ?Handle, value: T }:
const result = try integerGet(&det, my_handle);
my_handle.swapIfNew(result.new_handle);
const value = result.value;
```

**Error Handling with Details**:

```zig
var det: object.ErrorDetails = undefined;
const result = try someFn(heap, &det, arg);
// On error, det.message contains user-facing error string. Pass in `null` to `someFn` to avoid the error being allocated on the heap.
```

## Key Files

-   `src/Heap.zig`: Memory allocator and object storage (~2500 lines)
-   `src/object.zig`: Object type system and operations (~2400 lines)
-   `src/Interp.zig`: Interpreter and command execution (~2100 lines)
-   `src/Tokenizer.zig`: TCL tokenizer (~1200 lines)
-   `src/expr_parse.zig`: Expression parser with full AST (~900 lines)
-   `src/stringutil.zig`: String utilities with optional UTF-8 support (~900 lines)
-   `src/commands.zig`: Built-in command implementations (~650 lines)
-   `src/memutil.zig`: Buddy allocator and memory primitives (~600 lines)
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

**Double Free**: If you see double-free panics, check that objects from collections (lists/dicts) aren't being released. List items are not ref-counted handles. Enable options.trace_mem to figure out why.

**Shimmer Errors**: If shimmering fails, ensure the handle is not shared between threads. Use `prepareToShimmer()` which will duplicate if needed.

**OOM in Tests**: Use `testing.checkAllAllocationFailures()` wrapper to test all OOM code paths. All tests should pass without leaks even when allocations fail at any point.

**String Representation**: Some operations require string representations. The heap will auto-generate them when calling `Heap.getString()`, but this can fail with OOM.

**Command Naming**: Command implementation functions follow the pattern `nameCmd` (e.g., `ifCmd`, `forCmd`, `dictCmd`) with a `Cmd` prefix.

## Debugging

This project has comprehensive tracing for all memory operations. _Always_ read the complete trace before jumping into the code—the trace often holds the answer.

## Recent Development

Recent fixes and improvements:

-   **Handle Refactoring (January 2026)**: Completed major refactoring of Handle management API
    -   Changed from pointer-based mutation (`shimmerToX(&det, &handle)`) to value-based duplication (`shimmerToX(&det, handle) -> !?Handle`)
    -   Eliminates use-after-free (UAF) issues by returning new handles instead of mutating through pointers
    -   All shimmer functions (`shimmerToInteger`, `shimmerToFloat`, `shimmerToList`, `shimmerToDict`, `shimmerToScript`, `shimmerToExpression`, `shimmerToBoolean`) now use value-based API
    -   Get functions (`getScript`, `getExpression`, `getBoolean`, `integerGet`) return structs with both new handle and value
    -   Added `Handle.swapIfNew(?Handle)` helper method to simplify handle updates
    -   Pattern: Functions return `!?Handle` when only shimmering, or `!struct { new_handle: ?Handle, value: T }` when also extracting a value
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
-   Core built-in commands (13 implemented):
    -   Math: [+], [*], [incr], [expr]
    -   Control flow: [if], [for], [break], [continue]
    -   Variables: [set]
    -   Procedures: [proc], [apply]
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
-   Namespaces (partial support exists)
-   Upvar/uplevel (structures exist but incomplete)
-   Error stack traces
-   REPL

## Notes

**Experimental Files**: The repository contains `foo.zig` and `bar.zig` which are one-off prototypes not relevant to the overall architecture and can be ignored.

## Style guide

-   Use "why" commands, and occasional "how" comments, but avoid "what" comments unless the logic is dense.
-   End every comment with a period.
-   Don't use UPPERCASE, instead use _emphasis_.
-   If there's a short `if (optional) |val|`, use `val` as the capture name.

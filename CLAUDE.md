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

# Enable bracket expression sugar ($[5+5] instead of $(5+5))
zig build -Dbracket-expr-sugar=true

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
-   Uses packed structs for memory efficiency (Object is 16 bytes)

**Parser (src/Parser.zig)**: Tokenizes TCL scripts supporting:

-   Variable substitution (`$var`, `${var}`)
-   Command substitution (`[cmd]`)
-   Dictionary sugar (`$var(key)`)
-   Expression sugar (optional, via build flag)
-   Argument expansion (`{*}`)
-   Proper quote/brace/bracket balancing with detailed error reporting

**Interpreter (src/Interp.zig)**: Executes parsed scripts (work in progress):

-   Dual frame system: call frames (scope) and eval frames (execution state)
-   Variable resolution with caching via epochs (invalidated on scope changes)
-   Command dispatch supporting both native and TCL procedures
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
    - Use `prepareToShimmer()` to duplicate if necessary before type conversion
    - Shimmering invalidates the old body but preserves string rep when possible

5. **Collections (Lists/Dicts)**: Stored as contiguous object arrays. First object is head (contains metadata), subsequent objects are items. Cannot reference individual items externally (they're not ref-counted), but `borrow()` accounts for this.

### Script Execution Model

Scripts go through several stages:

1. **Tokenization** (Parser): Source → tokens with location info
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

**Type Shimmering**:

```zig
try object.shimmerToList(heap, &det, &handle);
// handle is now a list type
```

**Error Handling with Details**:

```zig
var det: object.ErrorDetails = undefined;
const result = try someFn(heap, &det, arg);
// On error, det.message contains user-facing error string. Pass in `null` to `someFn` to avoid the error being allocated on the heap.
```

## Key Files

-   `src/Heap.zig`: Memory allocator and object storage (~2000 lines)
-   `src/object.zig`: Object type system and operations (~1700 lines)
-   `src/Parser.zig`: TCL tokenizer (~900 lines)
-   `src/Interp.zig`: Interpreter and command execution (in progress, ~1000 lines)
-   `src/stringutil.zig`: String utilities with optional UTF-8 support
-   `src/memutil.zig`: Buddy allocator and memory primitives
-   `src/expr.zig`: Expression AST nodes (minimal, not yet implemented)

## Configuration

Build options (in build.zig):

-   `use_utf8`: Enable UTF-8 support (default: true)
-   `bracket_expr_sugar`: Use `$[expr]` instead of `$(expr)` (default: false)
-   `token_debugging`: Print tokens during parsing (default: false)

Heap settings (in Heap.zig cfg):

-   `threading`: Enable thread-safe operations (default: true)
-   `use_vmem`: Use virtual memory mapping (default: true)
-   `object_heap_order`: Max 2^24 objects (default: 24)
-   `string_heap_order`: Max 2^28 bytes for strings (default: 28)
-   `max_heaps`: Maximum concurrent heaps (default: 128)

## Common Issues

**Double Free**: If you see double-free panics, check that objects from collections (lists/dicts) aren't being released. List items are not ref-counted handles. Enable cfg.trace_mem to figure out why.

**Shimmer Errors**: If shimmering fails, ensure the handle is not shared between threads. Use `prepareToShimmer()` which will duplicate if needed.

**OOM in Tests**: Use `testing.checkAllAllocationFailures()` wrapper to test all OOM code paths.

**String Representation**: Some operations require string representations. The heap will auto-generate them when calling `Heap.getString()`, but this can fail with OOM.

## Development Status

Currently implemented:

-   Complete tokenizer with full TCL syntax support
-   Object system with all major types (string, integer, float, list, dict, bool, index), though methods are still incomplete.
-   Memory management with reference counting and buddy allocation
-   Script parsing and caching

In progress:

-   Interpreter evaluation loop (partially complete)
-   Variable management and scoping
-   Command registration and dispatch
-   Built-in commands

Not yet implemented:

-   Expression evaluation (expr.zig is stub)
-   Most TCL standard library commands
-   Namespaces (partial support exists)
-   Upvar/uplevel (structures exist but incomplete)
-   Error stack traces

## Style guide

-   Use "why" commands, and occasional "how" comments, but avoid "what" comments unless the logic is dense.
-   End every comment with a period, excluding comments on the end of a line.

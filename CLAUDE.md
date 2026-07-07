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
TODO: currently outdated, so I've removed the old docs. 

### Memory Management Principles

2. **Shimmerable and Mutable**: Two wrapper structs that track in-place modifications.
   - `Shimmerable = { original: Value, shimmered: OptionalValue }` -- for transparent type changes (the string representation is preserved or will be generated the same way).
   - `Mutable = { original: Value, mutated: OptionalValue }` -- for visible mutations (the string representation may change).
   - Both provide `.current()` to get the effective handle, `.consume()` to take ownership, and `.discardChanges()` to roll back.
   - `Mutable` can be cast to `Shimmerable` via `.asShimmerable()`.

4. **Reference Counting**: All heap objects are ref-counted (including list items).

5. **Ownership Patterns**:

    - Functions that allocate return owned handles (caller must release)
    - `borrow()` increases ref count and returns the handle
    - `duplicate()` creates shallow copies
    - `release()` decrements ref count and frees if zero (use in `defer` for cleanup)

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
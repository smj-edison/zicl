### Creating a list with known length.
```zig
// Create a list with length 3.
const handle = try objutil.newListWithCapacity(3);
objutil.listAppendAssumeCapacity(handle, .{ .head = .{ .tag = .int }, .body = .{ .int = 123 }});
objutil.listAppendAssumeCapacity(handle, some_handle.dupOrRef());
objutil.listAppendAssumeCapacity(handle, some_other_handle.dupOrRef());
```

### Implementing a new `[command]`.
Commands are functions with the signature `fn (interp: *Interp, args: []Shimmerable) Error!void`, where `args[0]` is the command name and `args[1..]` are the arguments. Register them in `Interp.init` with `registerCommand`.

Argument handles are non-const and may be shimmered in place by helpers like `interp.getInteger(&args[1])`. Do **not** copy an argument into a local `var` and then pass `&var` to a shimmer function -- the original `args` slot will not be updated.

```zig
// WRONG: `foo` is a copy; `getInteger` shimmers the copy, not args[1].
var foo = args[1];
const value = try interp.getInteger(&foo);

// CORRECT: pass a pointer directly into the args array.
const value = try interp.getInteger(&args[1]);
// Alternatively, you could also put `foo` on the stack, as long as it's borrowed. Useful when
// an argument is used a lot.
const foo = &args[1];
const value = try interp.getInteger(foo);
```

```zig
/// [pid] -- returns the process id.
pub fn pidCmd(interp: *Interp, args: []Shimmerable) !void {
    try interp.setResultInteger(@intCast(std.os.linux.getpid()));
}

// In Interp.init, after the call frame and eval frame are set up:
try interp.registerCommand("pid", .{
    .call = pidCmd,
    .description = "returns the process id",
    .min_arity = 0,
    .max_arity = 0,
});
```

`min_arity` and `max_arity` are checked by the dispatcher, so the command body does not need to validate argument count manually. For commands with complex or conditional parsing, return `error.WrongUsage` and the interpreter will format a "wrong # args: should be..." message from the `.usage` field.

```zig
pub fn ifCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    var remaining_args = args[1..];
    while (true) {
        if (remaining_args.len < 2) return error.WrongUsage;
        // ...
    }
}
```

For subcommands, use `objutil.SubcommandParser` to dispatch and validate arity automatically.

```zig
pub fn stringCmd(interp: *Interp, args: []Shimmerable) !void {
    const Subcommands = enum { length, index, range, /* ... */ };
    const Parser = objutil.SubcommandParser(Subcommands, &.{
        .{ .variant = .length, .usage = "string", .min_args = 1, .max_args = 1 },
        .{ .variant = .index,  .usage = "string index", .min_args = 2, .max_args = 2 },
    });

    var det: objutil.ErrorDetails = undefined;
    const subcommand: Subcommands = try interp.wrapError(&det, Parser.parse(&det, args));

    const sub_args = args[2..];
    switch (subcommand) {
        .length => try interp.setResultInteger(@intCast(try interp.getCodepointLength(&sub_args[0]))),
        .index  => { /* ... */ },
        // ...
    }
}
```

### Shimmering with writeback buffers (`Shimmerable` / `Mutable`).
Shimmer and mutation functions take a `*Shimmerable` or `*Mutable` working buffer. The wrapper tracks whether the object had to be duplicated. Callers use `.current()` to get the effective handle, `.consume()` to take ownership, and `.discardChanges()` to roll back.

```zig
// Caller pattern for shimmering.
var det: objutil.ErrorDetails = undefined;
var wb: objutil.Shimmerable = .{ .original = handle };
defer wb.discardChanges();
try objutil.shimmerToInteger(&det, &wb);
// wb.current() is now an integer. If wb.shimmered is non-null, the object moved.
handle = wb.consume();
```

Always prefer calling `.consume()` to write the result back into the original slot. If the slot is borrowed or otherwise cannot be updated (for example, when the handle is just a temporary inside a larger expression), call `.discardChanges()` instead. The `defer wb.discardChanges()` ensures that any duplicated object is freed if an error occurs before `.consume()` is reached.

For mutations, use `Mutable` instead. It can be cast to `Shimmerable` via `.asShimmerable()`.

```zig
// Caller pattern for mutation.
var wb: objutil.Mutable = .{ .original = dict };
defer wb.discardChanges();
_ = try objutil.dictPut(&wb, key_handle, value_handle);
// wb.current() now holds the mutated dict.
dict = wb.consume();
```

Inside a shimmer function, start with `errdefer wb.discardChanges()` and call `wb.prepareToShimmer()` before modifying the tag or body.

```zig
pub fn shimmerToInteger(det: ?*ErrorDetails, wb: *Shimmerable) !void {
    if (wb.tag() == .integer) return;
    errdefer wb.discardChanges();

    const value = try integerGetNoShimmer(det, wb.current());

    try wb.prepareToShimmer();
    wb.peek().head.tag = .integer;
    wb.peek().body.integer = value;
}
```

For in-place shimmering on a single `Handle` reference, the interpreter provides helpers that wrap a `*Handle` into a local `Shimmerable`. Prefer these over manual in-place updates, because raw `*Handle` shimmering can accidentally free objects.

```zig
const value = try interp.getInteger(&args[1]);
// args[1] is shimmered in place if needed.
```

When a function needs to shimmer two handles at once (e.g. `[string range]`), use the writeback buffer pattern for both.

```zig
var det: objutil.ErrorDetails = undefined;
var start_wb: objutil.Shimmerable = .{ .original = start_handle };
var end_wb: objutil.Shimmerable = .{ .original = end_handle };
defer start_wb.discardChanges();
defer end_wb.discardChanges();
const range = try objutil.getRange(&det, list_len, &start_wb, &end_wb);
start_handle = start_wb.consume();
end_handle = end_wb.consume();
```

### Propagating writeback buffers up the call stack.
When you write a helper that might shimmer or mutate its argument, take a `*Shimmerable` or `*Mutable` parameter and let the caller consume it. Do **not** consume the buffer inside the helper. This keeps the ownership boundary clean and avoids accidentally dropping a handle that the caller still needs.

```zig
/// Ensure `wb` is a list and append `item` to it.
/// The caller owns `wb` and must call `.consume()` or `.discardChanges()`.
fn ensureListAndAppend(det: ?*ErrorDetails, wb: *Mutable, item: Handle) !void {
    try objutil.shimmerToList(det, wb.asShimmerable());
    _ = try objutil.listAppend(det, wb, item);
}

/// Build a list by appending multiple items.
/// Propagates the same `wb` up through every helper call.
fn buildList(det: ?*ErrorDetails, wb: *Mutable, items: []const Handle) !void {
    for (items) |item| {
        try ensureListAndAppend(det, wb, item);
    }
}

// Top-level caller creates the buffer, propagates it down, then consumes it.
pub fn myCmd(interp: *Interp, args: []Shimmerable) !void {
    var wb: objutil.Mutable = .{ .original = args[1].current() };
    defer wb.discardChanges();
    try buildList(null, &wb, args[2..]);
    // Write the result back so the caller sees the updated handle.
    args[1] = .{ .original = wb.consume() };
    interp.setResult(args[1].current());
}
```

This pattern applies to roughly 90% of shimmer and mutation operations. The only time you should consume internally is when the helper is the final owner of the value (for example, a function that sets `interp.result` directly and then drops the working buffer).

### Testing with `checkAllAllocationFailures`.
Every allocation path must be leak-free, even when OOM strikes. Wrap tests that allocate in a helper and invoke `checkAllAllocationFailures`.

```zig
fn testVariables(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    const heap = try Heap.testStart(ta, testing.io);
    var interp = try Interp.init();
    defer interp.deinit();

    try interp.testExpectScriptResult("10", "set x 10; set x");
}

test "variable basics" {
    try testing.checkAllAllocationFailures(testing.allocator, testVariables, .{});
}
```

Always call `Heap.testFinish()` to assert no leaks. Use `defer` for immediate cleanup and `errdefer` for error-path cleanup.

```zig
const data = try allocator.alloc(u8, size);
errdefer allocator.free(data);  // Free if subsequent operations fail.
const result = try processData(data);  // Ownership transferred on success.
```

### Error handling with `ErrorDetails`.
Object-level functions take an optional `det: ?*ErrorDetails` to report user-facing errors without touching the interpreter result. Use `interp.wrapError` to bridge them to `EvalError`. `det` is _not_ set if the function returns `error.OutOfMemory`. Otherwise, the object in `det.message` is now owned by the caller (in the case that `det != null`).

```zig
var det: objutil.ErrorDetails = undefined;
const result = try interp.wrapError(&det, objutil.integerGet(&det, &wb));
```

When you only care the error code and not the message, use `null` for `det`.

```zig
var wb: objutil.Shimmerable = .{ .original = closure_value };
defer wb.discardChanges();
objutil.shimmerToDict(null, &wb) catch |err| switch (err) {
    error.OutOfMemory => return error.OutOfMemory,
    else => return error.BadClosure,
};
```

In object implementations, populate `det.message` with a heap-allocated string on error. The caller must release `det.message` or transfer it to the interpreter result via `wrapError`.

### Dict operations.
Create a dict from alternating keys and values.

```zig
interp.setResultOwning(try objutil.newDict(args[2..]));
```

Insert or update a key, using a `Mutable` writeback buffer.

```zig
var wb: objutil.Mutable = .{ .original = dict };
defer wb.discardChanges();
_ = try objutil.dictPut(&wb, key_handle, value_handle);
dict = wb.consume();
```

Nested dict operations follow a key path.

```zig
// dict set varName key ?key ...? value
var wb: objutil.Mutable = .{ .original = dict };
defer wb.discardChanges();
_ = try objutil.dictPutRecursively(&det, &wb, keys, new_value_object);
dict = wb.consume();
```

Remove recursively works similarly.

```zig
var wb: objutil.Mutable = .{ .original = dict };
defer wb.discardChanges();
_ = try objutil.dictRemoveRecursively(&det, &wb, args[3..args.len]);
dict = wb.consume();
```

Look up a value and follow `.reference` objects.

```zig
var wb: objutil.Shimmerable = .{ .original = dict_handle };
defer wb.discardChanges();
const val = try interp.getDictValueRecursivelyOrError(&wb, key_path);
interp.setResult(val);
```

### List operations.
Build a list from existing handles.

```zig
interp.setResultOwning(try objutil.newList(args[1..]));
```

Append handles, duplicating or referencing as needed. `listAppend` takes a `*Mutable`.

```zig
var list = try objutil.newListWithCapacity(4);
errdefer list.decrRefCount();
var wb: objutil.Mutable = .{ .original = list };
for (items) |item| {
    _ = try interp.listAppend(&wb, item);
}
list = wb.consume();
interp.setResultOwning(list);
```

For bulk append when you already own the items and have capacity, use the infallible variant. You can also append raw objects directly without allocating intermediate handles.

```zig
objutil.listAppendAssumeCapacity(list, item.dupOrRef());

// Append a raw integer object directly -- no intermediate handle needed.
objutil.listAppendAssumeCapacity(list, .{ .head = .{ .tag = .integer }, .body = .{ .integer = 123 }});
```

Read items by index. The returned handle is non-owning.

```zig
const item = objutil.listItem(list, 0);
// Or don't follow references, and get the object as exactly stored in the list.
const item = objutil.listItemNoFollow(list, 0);
```

Convert between `[]Handle` and a list object.

```zig
const handles = try objutil.listToHandles(gpa, list);
defer handles.deinit(gpa);
```

### Evaluating expressions.
Parse and evaluate a Tcl expression. `evalExpressionInPlace` shimmers the handle in place and returns an `ExprResult`.

```zig
pub fn exprCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const result = try (try interp.evalExpressionInPlace(&args[1])).toObject();
    defer result.decrRefCount();
    interp.setResult(result);
}
```

Convert the result to a boolean for command conditions.

```zig
if (try interp.getBoolFromExpression(&condition_handle)) {
    // then branch
}
```

### Reference counting recipes.
Functions that allocate return owned handles. The caller must release them.

```zig
const str = try objutil.newString("hello");
defer str.decrRefCount();
```

Borrow when you need to keep a handle alive across a scope but do not own it.

```zig
const borrowed = handle.borrow();
defer borrowed.decrRefCount();
```

Create a `.reference` object that points to another handle.

```zig
const ref = handle.reference();        // increments ref count
defer ref.deinitBodySingle(Heap.local_heap);

const ref = handle.referenceTakeOwnership();  // does not increment ref count
```

When shimmering, use `errdefer` on the writeback buffer to avoid leaks on error.

```zig
var wb: objutil.Shimmerable = .{ .original = handle };
errdefer wb.discardChanges();
try objutil.shimmerToList(&det, &wb);
```

When swapping handles, use `swapIfNew` to only update when necessary, and `swapIntermediate` when the old and provided handles might alias.

```zig
handle.swapIfNew(new);
handle.swapIntermediate(provided_handle, maybe_new);
```

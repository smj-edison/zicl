### Creating a list with known length.
```zig
// Create a list with length 3.
const handle = try objutil.newListWithCapacity(3);
objutil.listAppendAssumeCapacity(handle, .{ .head = .{ .tag = .int }, .body = .{ .int = 123 }});
objutil.listAppendAssumeCapacity(handle, some_handle.dupOrRef());
objutil.listAppendAssumeCapacity(handle, some_other_handle.dupOrRef());
```

### Implementing a new `[command]`.
Commands are functions with the signature `fn (interp: *Interp, args: []Handle) Error!void`, where `args[0]` is the command name and `args[1..]` are the arguments. Register them in `Interp.init` with `registerCommand`.

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
pub fn pidCmd(interp: *Interp, args: []Handle) !void {
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
pub fn ifCmd(interp: *Interp, args: []Handle) Interp.Error!void {
    var remaining_args = args[1..];
    while (true) {
        if (remaining_args.len < 2) return error.WrongUsage;
        // ...
    }
}
```

For subcommands, use `objutil.SubcommandParser` to dispatch and validate arity automatically.

```zig
pub fn stringCmd(interp: *Interp, args: []Handle) !void {
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

### Shimmering with the out-parameter pattern.
Shimmer functions take the original handle and a `*OptionalHandle` scratch parameter. On success, `new` is set if the object moved; on error, it is cleared.

```zig
// Caller pattern.
var new: OptionalHandle = .none;
try objutil.shimmerToInteger(&det, handle, &new);
handle.swapIfNew(new);  // Update handle only if a new object was created.
// `handle` is now an integer.
```

Inside a shimmer function, start with `errdefer new.swapWithNone()` and resolve the current handle with `new.orElse(original)`.

```zig
pub fn shimmerToString(original: Handle, new: *OptionalHandle) !void {
    if (new.orElse(original).tag() == .string) return;
    errdefer new.swapWithNone();

    try Heap.ensureShimmerableOrDup(original, new);
    const handle = new.orElse(original);

    try handle.prepareToShimmer();
    handle.peek().head.tag = .string;
    handle.peek().body = .{ .string = .{ .utf8_length = 0, .length_determined = false } };
}
```

For in-place mutation, many functions have a `get*InPlace` postfix, which wraps the pattern above.

```zig
pub fn getRangeInPlace(det: ?*ErrorDetails, list_len: u32, start: *Handle, end: *Handle) !Range {
    var new_start: OptionalHandle = .none;
    var new_end: OptionalHandle = .none;
    const range = try getRange(det, list_len, start.*, &new_start, end.*, &new_end);
    start.swapIfNew(new_start);
    end.swapIfNew(new_end);
    return range;
}
```

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
const result = try interp.wrapError(&det, objutil.integerGet(&det, handle, &new));
```

When you only care the error code and not the message, use `null` for `det`.

```zig
var new_handle: OptionalHandle = .none;
objutil.shimmerToDict(null, closure_value, &new_handle) catch |err| switch (err) {
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

Insert or update a key, handling the out-parameter.

```zig
var new_dict: OptionalHandle = .none;
_ = try objutil.dictPut(dict, &new_dict, key_handle, value_handle);
dict.swapIfNew(new_dict);
```

Nested dict operations follow a key path.

```zig
// dict set varName key ?key ...? value
var new_dict: OptionalHandle = .none;
_ = try objutil.dictPutRecursively(&det, dict, &new_dict, keys, new_value);
if (new_dict.toHandle()) |new| {
    defer new.decrRefCount();
    try interp.setVariableTo(var_name, new);
}
```

Remove recursively works similarly.

```zig
var new_dict: OptionalHandle = .none;
_ = try objutil.dictRemoveRecursively(&det, dict, &new_dict, args[3..args.len]);
```

Look up a value and follow `.reference` objects.

```zig
const val = try interp.getDictValueRecursivelyOrError(&dict_handle, key_path);
interp.setResult(val);
```

### List operations.
Build a list from existing handles.

```zig
interp.setResultOwning(try objutil.newList(args[1..]));
```

Append handles, duplicating or referencing as needed.

```zig
var list = try objutil.newListWithCapacity(4);
errdefer list.decrRefCount();
for (items) |item| {
    _ = try interp.listAppend(&list, item);
}
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
pub fn exprCmd(interp: *Interp, args: []Handle) Interp.Error!void {
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

When shimmering, use `errdefer` on the out-parameter to avoid leaks on error.

```zig
var new: OptionalHandle = .none;
errdefer new.swapWithNone();
try objutil.shimmerToList(&det, handle, &new);
```

When swapping handles, use `swapIfNew` to only update when necessary, and `swapIntermediate` when the old and provided handles might alias.

```zig
handle.swapIfNew(new);
handle.swapIntermediate(provided_handle, maybe_new);
```

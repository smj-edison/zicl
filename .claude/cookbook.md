# Cookbook

Recipes for working with the heap and object system. The examples below use the
`heap`/`objects` API from `src/heap.zig` and `src/objects.zig`.

---

### Creating values and objects.

Primitives (`integer`, `float`, `boolean`, `interned`) live inline in a 16-byte `Value`
and never allocate. Constructors return a `Value` when the value fits inline, or a heap
object when it does not. When the result is a heap object the caller owns it and must
release it; `release` on a primitive is a no-op, so it is always safe to `defer` it.

```zig
const num = objects.Integer.new(42);  // Inline Value; never allocates, never fails.
const big = objects.Integer.new(math.maxInt(i64)); // Also inline: integers are i64.

const str = try objects.String.newValue("hello"); // Always allocates a String object.
defer str.release();

const list = try objects.List.new(&.{ str });    // Borrows `str` into the list.
defer list.asHead().release();
// `str` is still owned by you; releasing both is correct because `List.new` borrowed it.
```

Use `objects.String.newOwning(bytes)` when you already own the byte slice and want to
avoid a copy. On error the bytes are freed for you.

```zig
const bytes = try heap.global_gpa.dupeSentinel(u8, "built elsewhere", 0);
const str = try objects.String.newOwning(bytes); // Takes ownership of `bytes`.
defer str.asHead().release();
```

### Reference counting recipes.

Functions that allocate return owned values. The caller releases them.

```zig
const str = try objects.String.newValue("hello");
defer str.release();
```

Borrow when you need to keep a value alive across a scope but do not own it.

```zig
const borrowed = list.items[0].borrow();
defer borrowed.release();
```

`Value.swap` / `OptionalValue.swap` release the old value when overwriting a slot, so
they are safe to use even when the slot already held a value.

```zig
var slot: heap.OptionalValue = .none;
slot.swap(str_value);       // Releases nothing (was .none), stores str_value.
slot.swapWithNone();        // Releases str_value, resets to .none.
```

### Shimmering with a `Shimmerable`.

Shimmer functions take a `*Shimmerable` and convert its current value to the target
type. The buffer tracks whether the object had to be duplicated. Callers use
`.current()` to read the effective value and `.discardChanges()` to roll back.

```zig
var det: objects.ErrorDetails = undefined;
var shim: objects.Shimmerable = .{ .original = some_value };
defer shim.discardChanges();

const list = try objects.List.shimmerFrom(&det, &shim);
// `shim.current()` is now a list. If `shim.shimmered` is set, the object moved
// into a fresh slot that `shim` owns.
```

Writeback usually needs custom logic, so the common pattern is to check whether the
object moved and act on the borrowed value:

```zig
if (shim.shimmered.asValue()) |new_value| {
    // `new_value` is borrowed from `shim`. Build whatever the slot needs from it
    // (the receiver takes its own reference); `defer shim.discardChanges()` then
    // releases `new_value`. For example, re-wrap a shimmered dict as a hash ref:
    const new_ref = try objects.HashReference.new(new_value.asPtr().?);
    some_slot.swap(new_ref.asHead().asValue());
}
```

For the simple case of moving the result into a slot you own, `.consume()` takes
ownership of `shim.current()` and releases the original in one step. It is used less
often. When you use it, do _not_ also `defer shim.discardChanges()` -- it is invalid
after `.consume()` runs (which zeroes the buffer). Use `errdefer shim.discardChanges()`
for the error path instead, so the duplicate is freed only if an error occurs before
`consume()`.

### Mutating a value (copy-on-write).

Mutation is copy-on-write. `Value.asMutableInPlace(T, det)` is the preferred entry
point: it returns a `*T` you can write to when the value can be shimmered to `T` _and_
mutated in place, and null when it cannot, leaving the copy to you.

```zig
var det: objects.ErrorDetails = undefined;

if (try dict_raw.asMutableInPlace(Dictionary, &det)) |dict_mut| {
    try dict_mut.put(key, value);
    // Mutated in place, so the owner's string rep is now stale.
    interp.callFrame().variables.asHead().invalidateString();
} else {
    // Copy-on-write. The duplicate is exclusively ours, so the second
    // `asMutableInPlace` always succeeds.
    const duped = try dict_raw.duplicateAsBoxed();
    defer duped.release();
    const dict_mut = (try duped.asValue().asMutableInPlace(Dictionary, &det)).?;
    try dict_mut.put(key, value);
    try interp.setVariable(var_name, duped.asValue()); // Store the copy back.
}
```

`[dict set]` and `[dict unset]` in `src/commands/dict.zig` are the reference call
sites for this shape.

`Shimmerable.getMutable(T, det)` is the `Shimmerable`-flavored alternative, used where
a shimmer buffer is already in hand (`Dictionary.putRecursively`, `vartypes.setVariable`).
Two things about it drive its call sites:

1.  It **essentially always duplicates**. It does not hand back `original` even when
    `original.canMutate()`, because the point of a `Shimmerable` is that the caller
    only ever writes back something with the same string rep. The one shortcut is that
    when the shimmer already had to build a mutable duplicate, it steals `shimmered`
    rather than duplicating a second time.
2.  The `*T` it returns is **owned by you and detached from the shim**. Release it when
    you are done and write it back explicitly; the shim still holds the original, so
    `shim.current()` is not the object you mutated and `shim.consume()` would return
    the wrong value.

```zig
const dict = try shim.getMutable(objects.Dictionary, &det);
defer dict.asHead().release();
try dict.put(key, value);
try parent.put(child_key, dict.asHead().asValue()); // Write the copy back.
```

### Propagating a `Shimmerable` up the call stack.

When you write a helper that might shimmer its argument, take a `*Shimmerable` and let
the caller consume it. Do not consume the buffer inside the helper. This keeps the
ownership boundary clean.

```zig
/// Ensure `shim` is a list, and report it back to the caller.
/// The caller owns `shim` and must call `.consume()` or `.discardChanges()`.
fn ensureList(det: ?*objects.ErrorDetails, shim: *objects.Shimmerable) !*const objects.List {
    return try objects.List.shimmerFrom(det, shim);
}
```

### `AlwaysCanBeType` (read-only typed views).

`objects.AlwaysCanBeType(T)` wraps a `*Object` as a read-only view of type `T`. It can
shimmer (so `.get()` converts the object to `T` if needed) but it never mutates the
object it shares, which makes it the right tool when a parameter or cached field should
observe a value as `T` without giving anyone a mutable `*T`. It borrows the object on
`init` (or takes your reference with `initOwning`) and releases it on `deinit`.

`AlwaysCanBeType` is especially useful when an object is shared, because the object's
vtable is ephemeral and another holder can shimmer it away from `T` (say, from `List`
to `Dictionary`). Its `get()` recovers `T` even then: when the object can still
shimmer, it shimmers it back in place; when it cannot shimmer -- most importantly when
it has been made cross-thread -- `get()` duplicates it first (the duplicate is
non-cross-thread) and shimmers the duplicate back to `T` from its string rep. So even a
cross-thread object whose type drifted _before_ it was frozen can still be viewed as
`T`: the frozen original keeps its current type for everyone sharing it, and your view
holds its own re-shimmered copy.

```zig
var view = objects.AlwaysCanBeType(objects.List).init(list_ptr); // `list_ptr` is `*List`.
defer view.deinit();

const list = try view.get(); // Shimmers to `List` if needed; returns `*const List`.
const n = list.items.len;
```

Its `getMutable()` returns a writable `*T`, duplicating the held object first whenever
that object cannot be mutated in place, so the shared original is never written to.

Prefer `AlwaysCanBeType` over a raw `*Object` plus ad-hoc `asType` calls when the "this
is a `T`, but read-only" intent matters. It is the typed-view counterpart to
`Shimmerable`'s mutable `getMutable`.

### Implementing a shimmer function for a new type.

Inside a shimmer function, call `shim.prepareToShimmer(T)` before writing the new body.
It ensures the object is exclusively owned (boxing a primitive or duplicating into
`shim.shimmered` if needed), caches the string rep so it survives the body swap, frees
the old body, installs `T`'s vtable, and hands back the `*T` for you to fill in.

Do _not_ `errdefer shim.discardChanges()` inside the shimmer function. The caller
owns the buffer and is responsible for cleanup (via its own `defer shim.discardChanges()`
or writeback); if the shimmer discards on error, it can drop changes the caller wanted
to keep. A failed shimmer leaves the buffer in whatever partial state it reached, and
the caller's cleanup handles the rest.

```zig
pub fn shimmerFrom(det: ?*objects.ErrorDetails, shim: *objects.Shimmerable) !*const MyType {
    if (shim.current().asType(MyType)) |existing| return existing;

    const bytes = try shim.getString();
    const parsed = try parse(det, bytes); // populate `det` on error

    const body = try shim.prepareToShimmer(MyType);
    body.* = .{ .field = parsed };
    return body;
}
```

A type's `pub const vtable: Object.VTable` wires it into the object system. The
required entry is `name`; the rest are technically optional but strongly encouraged,
since leaving one `null` will usually panic when the object system dispatches through
it (for example, a `null` `update_string` panics the moment a string rep is needed).
Most types provide `duplicate`, `free_internal_rep`, `update_string`, and
`enumerate_struct`.

```zig
pub const MyType = struct {
    field: i64,

    pub fn asHead(self: *MyType) *heap.Object {
        return heap.Object.from(MyType, self);
    }

    fn duplicate(src: *const heap.Object) !*heap.Object {
        const new_obj = try heap.Object.newObjectUninitialized(MyType);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj.head);
        new_obj.body.field = src.asTypeConst(MyType).?.field;
        return new_obj.head;
    }

    fn freeInternalRep(obj: *heap.Object) void {
        // Free anything the body owns that the string rep does not.
    }

    fn updateString(obj: *heap.Object) !void {
        const as_my = obj.asType(MyType).?;
        const bytes = try objects.allocPrintZ("{}", .{as_my.field});
        try obj.setStringIgnoreRace(bytes);
    }

    fn enumerateStruct(obj: *const heap.Object, ctx: memutil.StructIterator, info: *const memutil.StructIterator.NodeInfo) memutil.StructIterator.Error!void {
        try ctx.addField(i64, info, "field", "{}", obj.asTypeConst(MyType).?.field);
    }

    pub const vtable: heap.Object.VTable = .{
        .duplicate = duplicate,
        .free_internal_rep = freeInternalRep,
        .update_string = updateString,
        .make_crossthread = null,
        .enumerate_struct = enumerateStruct,
        .name = @typeName(MyType),
    };
};
```

### Dict operations.

Create a dict from alternating keys and values.

```zig
const dict = try objects.Dictionary.new(&.{ key_foo, value1, key_bar, value2 });
defer dict.asHead().release();
```

Insert or update a key. `put` asserts the dict is mutable, so reach it through the
copy-on-write `if` from above -- both branches, always.

```zig
if (try dict_raw.asMutableInPlace(Dictionary, &det)) |dict| {
    try dict.put(key, value);
    owner.asHead().invalidateString();
} else {
    const duped = try dict_raw.duplicateAsBoxed();
    defer duped.release();
    try (try duped.asValue().asMutableInPlace(Dictionary, &det)).?.put(key, value);
    try storeBack(duped.asValue());
}
```

Nested dict operations follow a key path. Pass a `ValueSliceContext` (or, for command
arguments, a `ShimmerableSliceContext`) as the context.

```zig
const path = objects.ValueSliceContext{ .items = &.{ key_foo, key_bar } };

var shim: objects.Shimmerable = .{ .original = dict_value };
defer shim.discardChanges();
const val = try objects.Dictionary.getRecursively(&det, &shim, path);
if (val.asValue()) |v| interp.setResult(v);
```

`putRecursively` and `removeRecursively` take an already-mutable `*Dictionary`, so the
same `if` sits in front of them; only the body of each branch changes.

```zig
// dict set varName key ?key ...? value
try dict.putRecursively(&det, path, new_value);
```

Look up a value, following `~parent` links.

```zig
var shim: objects.Shimmerable = .{ .original = dict_value };
defer shim.discardChanges();
const val = try objects.Dictionary.getFollowingLinks(&det, &shim, key);
```

### List operations.

Build a list from a slice of `Value`s (each is borrowed into the list).

```zig
const list = try objects.List.new(&.{ str_value, int_value });
defer list.asHead().release();
```

When building a list from command arguments (which arrive as `[]Shimmerable`), use
`List.newFromShimmerables` rather than collecting `.current()` by hand.

```zig
const list = try objects.List.newFromShimmerables(args[1..]);
defer list.asHead().release();
```

Append to a list via a `Shimmerable`.

```zig
var shim: objects.Shimmerable = .{ .original = list_value };
errdefer shim.discardChanges();
const list = try shim.getMutable(objects.List, &det);
try list.append(item);
list_value = shim.consume();
```

Prefer to keep a list as a `*List` across the operations that touch it. Hold the
pointer that `getMutable` (or `shim.current().asType(objects.List)`) returns and re-use
it for the next operation, instead of calling `shim.current().asType(objects.List)` each
time. Holding the typed pointer skips the repeated shimmer and `asType` type punning
the object system would otherwise do on every access.

Read items by index. The returned `Value` is non-owning.

```zig
const item = list.items[0]; // Non-owning; borrow if you need to keep it.
```

### Error handling with `ErrorDetails`.

Object-level functions take an optional `det: ?*ErrorDetails` to report user-facing
errors without touching the interpreter result. `det` is not set when the function
returns `error.OutOfMemory`. Otherwise, on a non-OOM error, `det.message` is a heap
allocation owned by the caller, who must release it or transfer it to the interpreter.

```zig
var det: objects.ErrorDetails = undefined;
const result = objects.Integer.parse(&det, bytes) catch |err| switch (err) {
    error.OutOfMemory => return error.OutOfMemory,
    error.BadInteger, error.IntegerOverflow => {
        defer heap.global_gpa.free(det.message);
        return error.BadInteger; // Or surface det.message to the user.
    },
};
```

When you only care about the error code, pass `null` for `det`.

```zig
var shim: objects.Shimmerable = .{ .original = closure_value };
defer shim.discardChanges();
objects.Dictionary.shimmerFrom(null, &shim) catch |err| switch (err) {
    error.OutOfMemory => return error.OutOfMemory,
    else => return error.BadClosure,
};
```

### Interned strings.

Compile-time interned strings live in rodata and produce a `Value` with no allocation.
`heap.InternedString.newValue` builds one directly at container scope.

```zig
const interned_foo = heap.InternedString.newValue("foo");
// ...
const key: heap.Value = interned_foo;
```

`heap.interned_empty_string` and `objects.interned_tilde_parent` are predefined for
the empty string and the `~parent` dict-link key. Note which module each lives in.

### Hash references and the hash registry.

Any object can be content-addressed by its Blake3 hash. `Object.getHashRegistering`
computes the hash and registers the object in the global `HashRegistry`. The object's
`update_string` then renders the hash as `blake3~<base64url>`, and `HashReference`
resolves such a string back to the registered object from any thread.

```zig
const hash = try obj.getHashRegistering(); // Idempotent.
// `obj` is now cross-thread and frozen (canMutate returns false).
```

```zig
var shim: objects.Shimmerable = .{ .original = hash_string_value };
defer shim.discardChanges();
const resolved = try objects.HashReference.shimmerFrom(&det, &shim);
// `resolved.ref` is the original object, borrowed.
```

### Cross-thread sharing.

Call `Object.makeCrossthread` (or `Value.makeCrossthread`) before sharing an object
across threads. This recursively marks the object and its children and switches ref
counting to atomic operations. Once marked, an object can never shimmer or mutate again,
even at ref count 1, because another thread may be traversing a collection that reaches
it.

`makeCrossthread` only makes the object safe to ref-count and free from another thread.
It does not synchronize the _transfer_: the caller is responsible for establishing a
happens-before relationship when handing the object off (for example, by sending it
through a mutex-protected channel or joining a `std.Thread`). After that handoff, the
receiving thread can `borrow`/`release` freely, and can free the object without
cooperating with the originating thread.

```zig
shared_value.makeCrossthread();
// Establish happens-before here (e.g. enqueue on a locked channel).
// The receiving thread can `borrow`/`release` it freely, and can free it
// without cooperating with this thread.
```

### Testing with `checkAllAllocationFailures`.

Every allocation path must be leak-free, even when OOM strikes. Wrap tests that
allocate in a helper and invoke `checkAllAllocationFailures`. Use `heap.testStart` /
`heap.testFinish`, which take an allocator and an `std.Io` and return nothing.

```zig
fn testVariables(ta: std.mem.Allocator) !void {
    try heap.testStart(ta, testing.io);
    defer heap.testFinish();

    const str = try objects.String.newValue("hello");
    defer str.release();
    try testing.expectEqualStrings("hello", try str.asHead().getString());
}

test "string basics" {
    try testing.checkAllAllocationFailures(testing.allocator, testVariables, .{});
}
```

Always call `heap.testFinish()` to assert no leaks. Use `defer` for immediate cleanup
and `errdefer` for error-path cleanup.

```zig
const data = try allocator.alloc(u8, size);
errdefer allocator.free(data); // Free if subsequent operations fail.
const result = try processData(data); // Ownership transferred on success.
```

When the test needs a live interpreter, use the pair in `src/commands/common.zig`
instead. It wraps the heap lifecycle and registers the core commands, so the script
helpers on `Interp` are available.

```zig
fn testDouble(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("84", "double 42");
    try interp.testExpectScriptError(error.EvalError, "expected integer but got \"x\"", "double x");
}

test "double" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testDouble, .{});
}
```

`checkAllAllocationFailures` only exercises OOM. For error paths that OOM cannot reach
(a parse failure behind a cache hit, say), use `src/tripwire.zig`: declare a fail-point
enum for the function, `try tw.check(.point)` at the `try` you want to fail, arm it from
the test with `tw.errorAlways`, and finish with `tw.end(.reset)`.

### Writing a command.

Commands live in `src/commands/`, take `args: []Shimmerable` (with `args[0]` being the
command name), and report their result through the interpreter rather than returning it.
Arguments are _not_ borrowed: shimmer them in place and let the caller own them.

```zig
const common = @import("common.zig");
const heap = common.heap;
const objects = common.objects;
const Interp = common.Interp;
const Shimmerable = common.Shimmerable;
const ErrorDetails = common.ErrorDetails;
const registerCommand = common.registerCommand;

/// [double]
pub fn doubleCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    // `interp.getInteger` shimmers `args[1]` and turns a parse failure into an
    // interpreter error with the message already set.
    const value = try interp.getInteger(&args[1]);
    interp.setResultOwning(objects.Integer.new(value * 2));
}

pub fn registerCommands(interp: *Interp) !void {
    // The arity bounds exclude the command name itself.
    try registerCommand(interp, "double", doubleCmd, "value", 1, 1, null);
}
```

Register the module from `registerCoreCommands` in `src/commands/common.zig`.

When you call an `objects`-level function directly, pair it with an `ErrorDetails` and
hand both to `interp.wrapError`, which transfers `det.message` into the interpreter
result and narrows the error:

```zig
var det: ErrorDetails = undefined;
const contents = try interp.wrapError(&det, objects.Integer.shimmerFrom(&det, &args[1]));
```

Prefer the `interp.get*` family (`getInteger`, `getFloat`, `getBoolean`, `getList`,
`getIndex`, `getIntOrFloatInPlace`, ...) over hand-rolling that pattern; they already
wrap the shimmer and the error reporting.
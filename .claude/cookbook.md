# Cookbook

Recipes for working with the new heap and object system. The examples below use the
`heap`/`objects` API from `src/heap.zig` and `src/objects.zig`. When porting old code
that calls `objutil.*` or `Heap.*` with `Handle`/`OptionalHandle`/`Mutable`, translate
it to these patterns.

---

### Creating values and objects.

Primitives (`int`, `float`, `bool`) live inline in a 64-bit `Value` and never allocate.
Constructors return a `Value` when the value fits inline, or a heap object when it does
not. Either way the caller owns the result and must release it.

`objects.Integer.new` shows the dispatch in a single constructor: it returns an inline
`Value` (no allocation, no release needed) when the value fits in an `i32`, and a boxed
heap `Integer` (caller owns, must release) otherwise. Prefer it over `Value.newInt`
when the value may be large, so the constructor picks the representation for you.

```zig
const fits = try objects.Integer.new(42);               // Inline Value, no allocation.
const too_big = try objects.Integer.new(math.maxInt(i64)); // Boxed, caller owns.
defer too_big.release();

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

### Mutating through a `Shimmerable`.

The old `Mutable` struct is gone. For mutations, call `Shimmerable.getMutable(T, det)`,
which returns a `*T` you can write to directly. It duplicates first if the object is
shared, cross-thread, or hash-registered.

```zig
var det: objects.ErrorDetails = undefined;
var shim: objects.Shimmerable = .{ .original = dict_value };
errdefer shim.discardChanges(); // error path only; `consume` invalidates the buffer.

const dict = try shim.getMutable(objects.Dictionary, &det);
try dict.put(key, value);
// `shim.current()` now holds the mutated dict.
dict_value = shim.consume();
```

`getMutable` is the single entry point for "I need to write to this object." There is no
separate `Mutable`/`asShimmerable` dance anymore.

### Propagating a `Shimmerable` up the call stack.

When you write a helper that might shimmer or mutate its argument, take a
`*Shimmerable` and let the caller consume it. Do not consume the buffer inside the
helper. This keeps the ownership boundary clean.

```zig
/// Ensure `shim` is a list and append `item` to it.
/// The caller owns `shim` and must call `.consume()` or `.discardChanges()`.
fn ensureListAndAppend(det: ?*objects.ErrorDetails, shim: *objects.Shimmerable, item: heap.Value) !void {
    const list = try objects.List.shimmerFrom(det, shim);
    try list.asHead().castTo(objects.List).append(item); // `append` borrows `item`.
}
```

### `AlwaysType` (read-only typed views).

`objects.AlwaysType(T)` wraps a `*Object` as a read-only view of type `T`. It can
shimmer (so `.get()` converts the object to `T` if needed) but it can never mutate,
which makes it the right tool when a parameter or cached field should observe a value
as `T` without giving anyone a mutable `*T`. It borrows the object on `init` and
releases it on `deinit`.

`AlwaysType` is especially useful when an object is shared, because the object's
vtable is ephemeral and another holder can shimmer it away from `T` (say, from `List`
to `Dictionary`). `AlwaysType.get()` recovers `T` even then: when the object can still
shimmer, it shimmers it back in place; when it cannot shimmer -- most importantly when
it has been made cross-thread -- `get()` duplicates it first (the duplicate is
non-cross-thread) and shimmers the duplicate back to `T` from its string rep. So even a
cross-thread object whose type drifted _before_ it was frozen can still be viewed as
`T`: the frozen original keeps its current type for everyone sharing it, and your view
holds its own re-shimmered copy.

```zig
var view = objects.AlwaysType(objects.List).init(list_ptr); // `list_ptr` is `*List`.
defer view.deinit();

const list = try view.get(); // Shimmers to `List` if needed; returns `*const List`.
const n = list.items.len;
```

Prefer `AlwaysType` over a raw `*Object` plus ad-hoc `asType` calls when the "this is a
`T`, but read-only" intent matters. It is the typed-view counterpart to `Shimmerable`'s
mutable `getMutable`.

### Implementing a shimmer function for a new type.

Inside a shimmer function, call `shim.prepareToShimmer()` before overwriting the
vtable and body. `prepareToShimmer` ensures the object is exclusively owned
(duplicating into `shim.shimmered` if not) and caches the string rep so it survives
the body swap.

Do _not_ `errdefer shim.discardChanges()` inside the shimmer function. The caller
owns the buffer and is responsible for cleanup (via its own `defer shim.discardChanges()`
or writeback); if the shimmer discards on error, it can drop changes the caller wanted
to keep. A failed shimmer leaves the buffer in whatever partial state it reached, and
the caller's cleanup handles the rest.

```zig
pub fn shimmerFrom(det: ?*objects.ErrorDetails, shim: *objects.Shimmerable) !*const MyType {
    if (shim.current().asType(MyType)) |existing| return existing;

    const bytes = try shim.current().getString();
    const parsed = try parse(det, bytes); // populate `det` on error

    const obj = try shim.prepareToShimmer();
    obj.vtable = &MyType.vtable;
    obj.castTo(MyType).* = .{ .field = parsed };
    return obj.castTo(MyType);
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
        const new_obj = try heap.Object.newObject(MyType);
        try src.duplicateHeadOnto(new_obj.head);
        new_obj.body.field = src.constCastTo(MyType).field;
        return new_obj.head;
    }

    fn freeInternalRep(obj: *heap.Object) void {
        // Free anything the body owns that the string rep does not.
    }

    fn updateString(obj: *heap.Object) !void {
        const as_my = obj.castTo(MyType);
        const bytes = try std.fmt.allocPrintSentinel(heap.global_gpa, "{}", .{as_my.field}, 0);
        try obj.setStringIgnoreRace(bytes);
    }

    fn enumerateStruct(obj: *const heap.Object, ctx: memutil.StructIterator, info: *const memutil.StructIterator.NodeInfo) memutil.StructIterator.Error!void {
        try ctx.addField(i64, info, "field", "{}", obj.constCastTo(MyType).field);
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

Insert or update a key, using a `Shimmerable` for mutation.

```zig
var shim: objects.Shimmerable = .{ .original = dict_value };
errdefer shim.discardChanges();
const dict = try shim.getMutable(objects.Dictionary, &det);
try dict.put(key, value);
dict_value = shim.consume();
```

Nested dict operations follow a key path. Pass a `ValueSliceContext` as the context.

```zig
const path = objects.ValueSliceContext{ .items = &.{ key_foo, key_bar } };

var shim: objects.Shimmerable = .{ .original = dict_value };
defer shim.discardChanges();
const val = try objects.Dictionary.getRecursively(&det, &shim, path);
if (val.asValue()) |v| interp.setResult(v);
```

```zig
// dict set varName key ?key ...? value
const dict = try shim.getMutable(objects.Dictionary, &det);
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

When building a list from command arguments (which arrive as `[]Shimmerable`),
collect `.current()` from each first, since `List.new` takes `[]const Value`.

```zig
var values = try heap.local_arena.alloc(heap.Value, args[1..].len);
for (args[1..], values) |arg, *out| out.* = arg.current();
const list = try objects.List.new(values);
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
Use `heap.createInternedString` to define one, then call `.value()` at runtime.

```zig
const interned_foo = heap.createInternedString("foo");
// ...
const key: heap.Value = interned_foo.value();
```

`objects.interned_empty_string` and `objects.interned_tilde_parent` are predefined for
the empty string and the `~parent` dict-link key.

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
`heap.testFinish` (note the lowercase `heap` module, and that `testStart` no longer
returns a heap).

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

### Porting old `objutil`/`Handle` call sites.

When you encounter unported code in `src/Interp.zig`, translate it as follows:

| Old (deleted) | New |
| --- | --- |
| `Heap.Handle` | `heap.Value` |
| `Heap.OptionalHandle` | `heap.OptionalValue` |
| `objutil.newString(bytes)` | `objects.String.newValue(bytes)` |
| `objutil.newInteger(value)` | `objects.Integer.new(value)` |
| `objutil.newFloat(value)` | `objects.Float.new(value)` |
| `objutil.newList(handles)` | `objects.List.new(values)` |
| `objutil.newDict(handles)` | `objects.Dictionary.new(values)` |
| `objutil.shimmerToList(det, wb)` | `objects.List.shimmerFrom(det, shim)` |
| `objutil.shimmerToDict(det, wb)` | `objects.Dictionary.shimmerFrom(det, shim)` |
| `objutil.shimmerToInteger(det, wb)` | `objects.Integer.shimmerFrom(det, shim)` |
| `objutil.dictPut(det, wb, k, v)` | `shim.getMutable(Dictionary, det).put(k, v)` |
| `objutil.Mutable` | `objects.Shimmerable` + `.getMutable(T, det)` |
| `Handle.decrRefCount()` | `Value.release()` |
| `Handle.borrow()` | `Value.borrow()` |
| `Heap.local_heap.emptyHandle()` | `objects.interned_empty_string.value()` |
| `Heap.local_heap.getInternedString(...)` | `heap.createInternedString(...).value()` |
| `^parent` dict link key | `~parent` (see `objects.interned_tilde_parent`) |
| `Heap.testStart` / `Heap.testFinish` | `heap.testStart` / `heap.testFinish` |

Shimmer functions changed from a verb-noun free function (`objutil.shimmerToX`) to a
type method (`objects.X.shimmerFrom`). The `Shimmerable` they take is the same idea as
the old `Shimmerable`, but it now holds `Value`/`OptionalValue` and subsumes `Mutable`
via `.getMutable`.
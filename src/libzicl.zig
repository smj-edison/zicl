const std = @import("std");
const assert = std.debug.assert;

const heap = @import("heap.zig");
const Value = heap.Value;
const OptionalValue = heap.OptionalValue;
const objects = @import("objects.zig");
const Shimmerable = objects.Shimmerable;
const ErrorDetails = objects.ErrorDetails;
const List = objects.List;
const Dictionary = objects.Dictionary;
const Interp = @import("Interp.zig");
const narrowError = Interp.narrowError;
const evaltypes = @import("evaltypes.zig");
const ReturnCode = heap.ReturnCode;
const commands = @import("commands/common.zig");
const leak_check = @import("leak_check.zig");
const ioutil = @import("ioutil.zig");
const Capability = @import("Capability.zig");

// ===== Internal: logging and panic =====
// These are not part of the C API surface; they wire Zig's log and panic
// facilities onto zicl's redirected stderr and leak-check trace.

// Allow user to change the default logging fd.
pub const panic = std.debug.FullPanic(ziclPanic);
pub const std_options: std.Options = .{ .logFn = ziclLog };

// Mirrors debug.zig's threadlocal panic_stage to guard against recursive panics.
threadlocal var zicl_panic_stage: usize = 0;

extern fn dumpLastTouchedTrace(fd: i32) void;

pub fn ziclLog(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const io = heap.global_io;

    const file = ioutil.getStderr();

    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);

    var buffer: [64]u8 = undefined;
    var file_writer = file.writerStreaming(io, &buffer);
    const terminal: std.Io.Terminal = .{ .writer = &file_writer.interface, .mode = .escape_codes };
    std.log.defaultLogFileTerminal(level, scope, format, args, terminal) catch {};
    terminal.writer.flush() catch {};
}

fn ziclPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    // No unlock: abort() terminates the process, serializing output without deadlock risk.
    const file = ioutil.getStderr();
    switch (zicl_panic_stage) {
        0 => {
            zicl_panic_stage = 1;
            dumpLastTouchedTrace(file.handle);
            var file_writer = file.writerStreaming(heap.global_io, &.{});
            const terminal: std.Io.Terminal = .{ .writer = &file_writer.interface, .mode = .escape_codes };
            const thread_id = std.Thread.getCurrentId();
            file_writer.interface.print("thread {d} panic: {s}\n", .{ thread_id, msg }) catch {};
            std.debug.writeCurrentStackTrace(.{
                .first_address = first_trace_addr orelse @returnAddress(),
                .allow_unsafe_unwind = true,
            }, terminal) catch {};
        },
        1 => {
            zicl_panic_stage = 2;
            std.Io.File.writeStreamingAll(file, heap.global_io, "aborting due to recursive panic\n") catch {};
        },
        else => {},
    }
    std.process.abort();
}

// ===== Lifecycle =====
// Process and thread setup, interpreter creation, and teardown. The global
// state is per-process; each thread that touches the interpreter calls
// `Zicl_InitThread` once.

var global_threaded: std.Io.Threaded = undefined;

export fn Zicl_SetLocalStdout(fd: c_int) callconv(.c) void {
    ioutil.local_stdout_fd = fd;
}
export fn Zicl_SetLocalStderr(fd: c_int) callconv(.c) void {
    ioutil.local_stderr_fd = fd;
}

/// `host_name` is the name this machine goes by in the capabilities it hands
/// out. Null asks the system for it.
export fn Zicl_InitGlobals(host_name: ?[*:0]const u8) callconv(.c) ReturnCode {
    global_threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
    heap.initGlobals(std.heap.c_allocator, global_threaded.io(), .{
        .capability = .{
            .host_name = if (host_name) |name| std.mem.span(name) else null,
        },
    }) catch return .@"error";
    return .ok;
}

export fn Zicl_InitThread() callconv(.c) ReturnCode {
    heap.initThread();
    return .ok;
}

export fn Zicl_DeinitThread() callconv(.c) void {
    heap.deinitThread();
}

export fn Zicl_DeinitAll() callconv(.c) void {
    heap.deinitThread();
    heap.deinitGlobals();
}

export fn Zicl_LeakCheckAll() callconv(.c) void {
    // Ahead of the check, or the fallback `[catch]` dict that lives for the
    // whole process reports as a leak every time. This is why the check is
    // shutdown-only: releasing that dict makes any further evaluation unsafe.
    heap.freeOomErrorOptionsDict();
    leak_check.dumpLeaks() catch {};
}

export fn Zicl_CreateInterp() callconv(.c) ?*Interp {
    // Store the interpreter on the heap, so it's an opaque pointer.
    const interp = heap.global_gpa.create(Interp) catch return null;
    errdefer heap.global_gpa.destroy(interp);
    interp.* = Interp.init(.{}) catch return null;
    errdefer interp.deinit();

    commands.registerCoreCommands(interp) catch return null;

    return interp;
}

export fn Zicl_InterpDestroy(interp: *Interp) callconv(.c) void {
    interp.deinit();
    heap.global_gpa.destroy(interp);
}

// ===== Local arena snapshots =====
// The calling thread's `local_arena` is a rewindable bump arena. A snapshot is a
// cheap watermark: take one before a bounded chunk of work and rewind to it
// afterwards to drop everything allocated from the arena in between, without
// freeing the chunks. The snapshot is only valid on the thread that took it;
// rewinding on another thread is undefined. Anything the interpreter still
// references out of the arena (a primitive's string rep, a parse cache entry)
// becomes invalid after a rewind, so this is a sharp tool for transient work
// the caller keeps no live references to.

// `RewindableArena.Snapshot` is an `extern struct`, so it crosses the C ABI by
// value; the C side declares the layout-equivalent `Zicl_ArenaSnapshot`.
const ArenaSnapshot = @TypeOf(heap.local_arena_instance).Snapshot;

export fn Zicl_LocalArenaSnapshot() callconv(.c) ArenaSnapshot {
    return heap.local_arena_instance.snapshot();
}

export fn Zicl_LocalArenaRewind(snap: ArenaSnapshot) callconv(.c) void {
    heap.local_arena_instance.rewind(snap);
}

// ===== Strings =====
// The string representation is the source of truth for every value, so these
// are the most general accessors. `Zicl_String` and `Zicl_GetString` generate
// the string rep on demand, which can allocate (and so return NULL on OOM).

export fn Zicl_NewString(out: *Value, ptr: [*:0]const u8, len: c_int) callconv(.c) ReturnCode {
    const bytes = if (len < 0) std.mem.span(ptr) else ptr[0..@intCast(len)];
    out.* = objects.String.newValue(bytes) catch return .oom;
    return .ok;
}

// `Zicl_InternStr` is a header inline (see include/libzicl.h) so that
// `strlen` of a literal folds to a compile-time constant, making the common
// case -- a short rodata literal such as a command name or dict key -- a
// constant `Zicl_Value` with no call. The inline calls this only when the
// string exceeds the 65535-byte cap an interned value's u16 length can hold;
// abort loudly rather than truncate, mirroring the `@intCast` panic the
// constructor used to do.
export fn Zicl_InternStrTooLong() callconv(.c) noreturn {
    @panic("interned string exceeds 65535 bytes");
}

export fn Zicl_String(value: Value) callconv(.c) ?[*:0]const u8 {
    return value.getString() catch return null;
}

export fn Zicl_GetString(value: Value, len: ?*c_int) callconv(.c) ?[*:0]const u8 {
    const str = value.getString() catch return null;
    if (len) |ptr| ptr.* = @intCast(str.len);
    return str;
}

// ===== Reference counting and object introspection =====
// Reaching and accounting for the heap object behind a pointer-tagged value.
// The primitives (`integer`, `float`, `boolean`, `interned`) carry no object,
// so `Zicl_AsPtr` returns null and the refcount accessors report zero.

export fn Zicl_Release(value: Value) callconv(.c) void {
    value.release();
}

export fn Zicl_Borrow(value: Value) callconv(.c) Value {
    return value.borrow();
}

// A shallow copy of `value` as a fresh owned value with its own refcount. For a
// pointer value this duplicates the underlying object (deep for the string rep;
// collection items are borrowed) and can OOM; primitives (integer, float,
// boolean, interned) return themselves, so it never fails for those. The caller
// owns the result and must release it (or commit it via ZICL_SWAP).
export fn Zicl_Duplicate(value: Value, out: *Value) callconv(.c) ReturnCode {
    out.* = value.duplicate() catch return .oom;
    return .ok;
}

/// Release every value in `argv[0..argc]`. A convenience for cleaning up an
/// array of values (such as an argv built for a command call); `Zicl_Release`
/// is a no-op for primitives, so the array may hold a mix of heap objects and
/// inline values. `argc` must not be negative (panics otherwise).
export fn Zicl_ReleaseArrayItems(argv: [*]Value, argc: c_int) callconv(.c) void {
    const count: usize = @intCast(argc);
    for (argv[0..count]) |v| v.release();
}

export fn Zicl_AsPtr(value: Value) callconv(.c) ?*heap.Object {
    return value.asPtr();
}

// Inverse of Zicl_AsPtr: wrap a heap object as a pointer-tagged value. No
// refcount change, so the caller keeps the reference it already held.
export fn Zicl_BoxObject(obj: *heap.Object) callconv(.c) Value {
    return obj.asValue();
}

// Object debugging. `tag` is a plain field read, so there is no accessor for
// it. Both of these are only meaningful for ZICL_TAG_POINTER values.
export fn Zicl_RefCount(value: Value) callconv(.c) u32 {
    const obj = value.asPtr() orelse return 0;
    return obj.getRefCount();
}

export fn Zicl_RefCountPtr(value: Value) callconv(.c) ?*u32 {
    const obj = value.asPtr() orelse return null;
    return &obj.ref_count;
}

// ===== Cross-thread sharing =====
// Marking is one-way and recursive: a marked object can never shimmer or mutate
// again (even at ref count 1), and ref counting switches to atomic operations
// so any thread can borrow, release, or free it. This only makes the object
// safe to ref-count and free from another thread; the caller must establish a
// happens-before relationship for the transfer itself. No-op for primitives.
export fn Zicl_MakeCrossthread(value: Value) callconv(.c) void {
    value.makeCrossthread();
}

// ===== Value equality =====
// Zicl compares values by their string representation, so values of different
// runtime types compare equal when their string reps match (the integer 5 and
// the string "5" are equal). Generating a string rep can allocate, so this can
// return ZICL_OOM; on success it writes 1 or 0 to *out.
export fn Zicl_Equals(a: Value, b: Value, out: *c_int) callconv(.c) ReturnCode {
    const eq = a.equals(b) catch return .oom;
    out.* = if (eq) 1 else 0;
    return .ok;
}

// Fast path: never allocates and never returns a false positive, but may report
// two equal values as unequal when confirming would need a generated string rep.
export fn Zicl_QuickEquals(a: Value, b: Value) callconv(.c) bool {
    return a.raw.quickEquals(b.raw);
}

// ===== Numbers =====
// Integer, float, and boolean values are stored inline, so the constructors
// cannot fail. The coercions shimmer a value into the requested type through a
// shimmerable, so they can fail (ZICL_OOM) or report a parse error (ZICL_ERR).

export fn Zicl_NewLong(value: i64) callconv(.c) Value {
    return objects.Integer.new(value);
}

export fn Zicl_NewDouble(value: f64) callconv(.c) Value {
    return objects.Float.new(value);
}

export fn Zicl_NewBool(value: bool) callconv(.c) Value {
    return objects.Boolean.new(value);
}

export fn Zicl_GetLong(interp: *Interp, shim: *Shimmerable, out: *c_long) callconv(.c) ReturnCode {
    out.* = interp.getInteger(shim) catch |err| return ReturnCode.fromError(err);
    return .ok;
}

export fn Zicl_GetDouble(interp: *Interp, shim: *Shimmerable, out: *f64) callconv(.c) ReturnCode {
    out.* = interp.getFloat(shim) catch |err| return ReturnCode.fromError(err);
    return .ok;
}

export fn Zicl_GetBoolean(interp: *Interp, shim: *Shimmerable, out: *c_int) callconv(.c) ReturnCode {
    const result = interp.getBoolean(shim) catch |err| return ReturnCode.fromError(err);
    out.* = if (result) 1 else 0;
    return .ok;
}

// ===== Shimmerables =====
// Operations on the shimmerable working buffer itself, independent of any
// specific target type. `Zicl_Current` returns the effective value (the
// shimmered duplicate when one exists, otherwise the original).

// `Shimmerable.current` exposed under the name the C header declares.
export fn Zicl_Current(shim: *const Shimmerable) callconv(.c) Value {
    return shim.current();
}

export fn Zicl_ShimString(shim: *Shimmerable) callconv(.c) ?[*:0]const u8 {
    return shim.current().getString() catch return null;
}

export fn Zicl_ShimGetString(shim: *Shimmerable, len: ?*c_int) callconv(.c) ?[*:0]const u8 {
    const str = shim.current().getString() catch return null;
    if (len) |ptr| ptr.* = @intCast(str.len);
    return str;
}

/// Release any shimmered duplicate and roll the shimmerable back to its original
/// value. The caller still owns `original`.
export fn Zicl_ShimDiscardChanges(shim: *Shimmerable) callconv(.c) void {
    shim.discardChanges();
}

// ===== Lists =====
// The typed mutable body `*List` is the opaque handle `Zicl_List`; the export
// functions take it directly, so no wrapper struct is needed. The copy-on-write
// decision is exposed to the caller (`Zicl_AsListMut` for the no-copy fast path,
// `Zicl_DupAsList` for the copy path) rather than hidden inside
// `Zicl_ListAppend`, mirroring `lappendCmd` in src/commands/list.zig.

/// Build a list from `n_values` values, borrowing each. NULL on OOM; the caller
/// owns the returned handle.
export fn Zicl_NewList(values: ?[*]const Value, n_values: c_int) callconv(.c) ?*List {
    const items = if (values) |ptr| ptr[0..@intCast(n_values)] else &.{};
    const list = List.new(items) catch return null;
    return list;
}

// Build a list borrowing each shimmerable's current value. The C `Zicl_Shimmerable`
// layout mirrors `objects.Shimmerable`, so the pointer cast is sound.
export fn Zicl_NewListFromShimmerables(
    shims: ?[*]const Shimmerable,
    n_shims: c_int,
) callconv(.c) ?*List {
    const items = if (shims) |ptr| ptr[0..@intCast(n_shims)] else &.{};
    const list = List.newFromShimmerables(items) catch return null;
    return list;
}

/// Wrap an owned list handle as a value, transferring ownership (no refcount
/// change). The caller must not touch `list` afterwards.
export fn Zicl_BoxList(list: *List) callconv(.c) Value {
    return list.asHead().asValue();
}

/// Release an owned list handle.
export fn Zicl_ListRelease(list: *List) callconv(.c) void {
    list.asHead().release();
}

/// Copy-on-write in-place entry point. If `value` is uniquely owned, `*out` is a
/// borrowed mutable view of the same object (no copy); if it is shared,
/// cross-thread, or a primitive, `*out` is NULL and the caller must
/// `Zicl_DupAsList`. A borrowed view is not owned: do not pass it to
/// `Zicl_ListRelease(`. Commit a duplicate back to its slot with
/// `ZICL_SWAP(&slot, Zicl_BoxList(*out))`. (`Zicl_ListShimmerWriteback` is a
/// different operation: it writes a shimmered child back into a list slot in
/// place, preserving the list's string rep.)
export fn Zicl_AsListMut(interp: *Interp, value: Value, out: *?*List) callconv(.c) ReturnCode {
    out.* = null;
    var det: ErrorDetails = undefined;
    if (interp.wrapError(&det, value.asMutableInPlace(List, &det))) |maybe_mut| {
        out.* = maybe_mut;
        return .ok;
    } else |err| return ReturnCode.fromError(err);
}

/// Owned mutable copy of `value` shimmered to a list. `*out` is NULL on OOM.
export fn Zicl_DupAsList(interp: *Interp, value: Value, out: *?*List) callconv(.c) ReturnCode {
    var det: ErrorDetails = undefined;
    if (interp.wrapError(&det, value.duplicateAsType(List, &det))) |dup| {
        out.* = dup;
        return .ok;
    } else |err| {
        out.* = null;
        return ReturnCode.fromError(err);
    }
}

/// Shimmer a shimmerable to a list in place (for command arguments).
export fn Zicl_ListShimmer(interp: *Interp, shim: *Shimmerable, out: *?*const List) callconv(.c) ReturnCode {
    const list = interp.getList(shim) catch |err| return ReturnCode.fromError(err);
    out.* = list;
    return .ok;
}

/// Pointer to the item array, valid for `Zicl_ListLength(list)` items. Read
/// access only; use `Zicl_ListSet` to replace an item.
export fn Zicl_ListItems(list: *const List) callconv(.c) [*]const Value {
    return list.items.ptr;
}

export fn Zicl_ListLength(list: *const List) callconv(.c) c_int {
    return @intCast(list.items.len);
}

/// Append a borrowed copy of `item`; the caller keeps its reference.
export fn Zicl_ListAppend(list: *List, item: Value) callconv(.c) ReturnCode {
    list.append(item) catch |err| return ReturnCode.fromError(narrowError(err));
    return .ok;
}

/// Replace item `index`, releasing the old one and taking ownership of `item`
/// (the caller must not release `item` afterwards). A negative index panics at
/// the Zig boundary; an out-of-range positive index returns ZICL_ERR.
export fn Zicl_ListSet(list: *List, index: c_int, item: Value) callconv(.c) ReturnCode {
    const idx: usize = @intCast(index);
    if (idx >= list.items.len) return .@"error";
    list.set(idx, item) catch |err| return ReturnCode.fromError(narrowError(err));
    return .ok;
}

/// Read item `index` from a shimmerable list. Writes a borrowed value to `*out`,
/// or ZICL_NONE when the index is out of range (negative or too large).
export fn Zicl_ShimListItem(
    interp: *Interp,
    shim: *Shimmerable,
    index: c_int,
    out: *OptionalValue,
) callconv(.c) ReturnCode {
    const list = interp.getList(shim) catch |err| {
        out.* = .none;
        return ReturnCode.fromError(err);
    };
    if (index < 0) {
        out.* = .none;
        return .ok;
    }
    const idx: usize = @intCast(index);
    if (idx >= list.items.len) {
        out.* = .none;
        return .ok;
    }
    out.* = list.items[idx].asOptional();
    return .ok;
}

/// Absent when the index is out of range (negative or too large). The result is
/// borrowed from the list, so it is only valid while the list holds it.
export fn Zicl_ListGetItem(interp: *Interp, list: *Value, index: c_int) callconv(.c) OptionalValue {
    const as_list = interp.getListInPlace(list) catch return .none;
    if (index < 0) return .none;
    const idx: usize = @intCast(index);
    if (idx >= as_list.items.len) return .none;
    return as_list.items[idx].asOptional();
}

/// Replace the item at `index` with `value` in place, without invalidating the
/// list's string rep. For writing a shimmered form of an already-stored item
/// back into its slot, where the shimmer preserved the string rep (so the
/// list's cached string is still valid). This is distinct from `ZICL_SWAP`,
/// which is the dup-branch commit (release the old slot value, store a new
/// object). `index` must be in range: a negative index panics, an out-of-range
/// positive index returns ZICL_ERR.
export fn Zicl_ListShimmerWriteback(list: *List, index: c_int, value: Value) callconv(.c) ReturnCode {
    const idx: usize = @intCast(index);
    if (idx >= list.items.len) return .@"error";
    list.shimmerWriteback(idx, value);
    return .ok;
}

// ===== Dicts =====
// The typed mutable body `*Dictionary` is the opaque handle `Zicl_Dict`; the
// export functions take it directly, so no wrapper struct is needed. The
// copy-on-write decision is exposed to the caller (`Zicl_AsDictMut` for the
// no-copy fast path, `Zicl_DupAsDict` for the copy path) rather than hidden
// inside `Zicl_DictPut`, mirroring `dict set` / `lappendCmd`.

/// Build a dict from `n_values` alternating key/value values, borrowing each.
/// NULL on OOM; the caller owns the returned handle.
export fn Zicl_NewDict(values: ?[*]const Value, n_values: c_int) callconv(.c) ?*Dictionary {
    const items = if (values) |ptr| ptr[0..@intCast(n_values)] else &.{};
    const dict = Dictionary.new(items) catch return null;
    return dict;
}

/// Wrap an owned dict handle as a value, transferring ownership (no refcount
/// change). The caller must not touch `dict` afterwards.
export fn Zicl_BoxDict(dict: *Dictionary) callconv(.c) Value {
    return dict.asHead().asValue();
}

/// Release an owned dict handle (error path).
export fn Zicl_DictRelease(dict: *Dictionary) callconv(.c) void {
    dict.asHead().release();
}

/// Copy-on-write in-place entry point. If `value` is uniquely owned, `*out` is a
/// borrowed mutable view of the same object (no copy); if it is shared,
/// cross-thread, or a primitive, `*out` is NULL and the caller must
/// `Zicl_DupAsDict`. A borrowed view is not owned: do not pass it to
/// `Zicl_DictRelease`. Commit a duplicate back to its slot with
/// `ZICL_SWAP(&slot, Zicl_BoxDict(*out))`. (`Zicl_DictShimmerWriteback` is a
/// different operation: it writes a shimmered child back into a dict key in
/// place, preserving the dict's string rep.)
export fn Zicl_AsDictMut(interp: *Interp, value: Value, out: *?*Dictionary) callconv(.c) ReturnCode {
    out.* = null;
    var det: ErrorDetails = undefined;
    if (interp.wrapError(&det, value.asMutableInPlace(Dictionary, &det))) |maybe_mut| {
        out.* = maybe_mut;
        return .ok;
    } else |err| return ReturnCode.fromError(err);
}

/// Owned mutable copy of `value` shimmered to a dict. `*out` is NULL on OOM.
export fn Zicl_DupAsDict(interp: *Interp, value: Value, out: *?*Dictionary) callconv(.c) ReturnCode {
    var det: ErrorDetails = undefined;
    if (interp.wrapError(&det, value.duplicateAsType(Dictionary, &det))) |dup| {
        out.* = dup;
        return .ok;
    } else |err| {
        out.* = null;
        return ReturnCode.fromError(err);
    }
}

/// Shimmer a shimmerable to a dict in place (for command arguments).
export fn Zicl_DictShimmer(interp: *Interp, shim: *Shimmerable, out: *?*const Dictionary) callconv(.c) ReturnCode {
    const dict = interp.getDict(shim) catch |err| return ReturnCode.fromError(err);
    out.* = dict;
    return .ok;
}

/// Number of key/value pairs.
export fn Zicl_DictLength(dict: *const Dictionary) callconv(.c) c_int {
    return @intCast(dict.items.len / 2);
}

/// Pointer to the item array, valid for `2 * Zicl_DictLength(dict)` values in
/// alternating key, value order. Read access only; use Zicl_DictPut to change.
export fn Zicl_DictItems(dict: *const Dictionary) callconv(.c) [*]const Value {
    return dict.items.ptr;
}

/// Insert or update `key` with `value`, borrowing both. Asserts the dict is
/// mutable, so reach it through Zicl_AsDictMut or Zicl_DupAsDict first.
export fn Zicl_DictPut(dict: *Dictionary, key: Value, value: Value) callconv(.c) ReturnCode {
    dict.put(key, value) catch |err| return ReturnCode.fromError(narrowError(err));
    return .ok;
}

/// Remove all pairs with `key`. Writes 1 to `*removed` if any pair was removed.
export fn Zicl_DictRemove(dict: *Dictionary, key: Value, removed: *c_int) callconv(.c) ReturnCode {
    const r = dict.remove(null, key) catch |err| return ReturnCode.fromError(narrowError(err));
    removed.* = if (r) 1 else 0;
    return .ok;
}

/// Read the value for `key` from a shimmerable dict, following `~parent` links.
/// Writes a borrowed value to `*out`, or ZICL_NONE when the key is absent.
export fn Zicl_ShimDictGet(
    interp: *Interp,
    shim: *Shimmerable,
    key: Value,
    out: *OptionalValue,
) callconv(.c) ReturnCode {
    const result = interp.getDictValue(shim, key) catch |err| {
        out.* = .none;
        return ReturnCode.fromError(err);
    };
    out.* = if (result) |val| val.asOptional() else .none;
    return .ok;
}

/// Absent when the key is not present (following `~parent` links). The result is
/// borrowed from the dict, so it is only valid while the dict holds it.
export fn Zicl_DictGet(interp: *Interp, dict: *Value, key: Value) callconv(.c) OptionalValue {
    const result = interp.getDictValueInPlace(dict, key) catch return .none;
    if (result) |val| return val.asOptional();
    return .none;
}

/// Replace the value for `key` with `value` in place, without invalidating the
/// dict's string rep. For writing a shimmered form of an already-stored value
/// back into its slot, where the shimmer preserved the string rep (so the
/// dict's cached string is still valid). This is distinct from `ZICL_SWAP`,
/// which is the dup-branch commit. `key` must already be present: the writeback
/// walks the hash table to find the value slot, so a missing key is a violated
/// invariant and panics. Returns ZICL_OOM if hashing the key allocates and
/// fails.
export fn Zicl_DictShimmerWriteback(dict: *Dictionary, key: Value, value: Value) callconv(.c) ReturnCode {
    dict.shimmerWriteback(key, value) catch |err| return ReturnCode.fromError(narrowError(err));
    return .ok;
}

// ===== Source =====
// A `Source` carries file/line metadata alongside a value's bytes, so
// evaluation errors can point at the originating location. A value shimmers to
// a Source with an empty location (`Source.shimmerFrom`), then the metadata is
// read/write through the mutable view: annotate in place when the object is
// uniquely owned (`Zicl_AsSourceMut`) or on a copy when it is shared
// (`Zicl_DupAsSource`, committed with `ZICL_SWAP`). `Zicl_AttachSource` is the
// convenience helper that copies the string and sets a fresh location in one
// call.

// Narrow a value to its Source body. Borrows the object; fields are read-only.
export fn Zicl_AsSource(value: Value) callconv(.c) ?*const objects.Source {
    return value.asType(objects.Source);
}

export fn Zicl_AsSourceMut(value: Value) callconv(.c) ?*objects.Source {
    var det: ErrorDetails = undefined;
    return value.asMutableInPlace(objects.Source, &det) catch |err| switch (err) {
        error.OutOfMemory => return null,
    };
}

export fn Zicl_DupAsSource(value: Value) callconv(.c) ?*objects.Source {
    var det: ErrorDetails = undefined;
    return value.duplicateAsType(objects.Source, &det) catch |err| switch (err) {
        error.OutOfMemory => return null,
    };
}

/// Wrap an owned Source handle as a value, transferring ownership (no refcount
/// change). The caller must not touch `source` afterwards.
export fn Zicl_BoxSource(source: *objects.Source) callconv(.c) Value {
    return source.asHead().asValue();
}

/// Release an owned Source handle (error path).
export fn Zicl_SourceRelease(source: *objects.Source) callconv(.c) void {
    source.asHead().release();
}

export fn Zicl_SourceGetFilename(source: Value) callconv(.c) ?[*:0]const u8 {
    const as_source = source.asType(objects.Source) orelse return null;
    const file_name = as_source.file_name.asValue() orelse return null;
    return file_name.getString() catch return null;
}

export fn Zicl_SourceGetLine(source: Value) callconv(.c) c_int {
    const as_source = source.asType(objects.Source) orelse return -1;
    return @intCast(as_source.line_no);
}

/// Replace `value` with one carrying the given source location, so evaluation
/// errors report the right file and line. A convenience that copies the string
/// and sets a fresh location in one call; for in-place annotation use the
/// copy-on-write entry points above.
export fn Zicl_AttachSource(value: *Value, filename: [*:0]const u8, line_no: c_int) callconv(.c) ReturnCode {
    const bytes = value.getString() catch return .oom;

    const file_name = objects.String.newValue(std.mem.span(filename)) catch return .oom;
    // `Source.new` borrows `file_name`, so the constructing reference is ours
    // to release either way.
    defer file_name.release();

    const source = objects.Source.new(bytes, file_name.asOptional(), @intCast(line_no)) catch return .oom;
    value.swap(source.asHead().asValue());
    return .ok;
}

// ===== Interpreter =====
// Registering commands, evaluating scripts, reading and writing the result,
// setting variables, and the signal-depth machinery that defers Tcl signal
// delivery during C callbacks that must not be interrupted.

export fn Zicl_RegisterLazyFn(name: [*:0]const u8, init_fn: heap.NativeInitFn) callconv(.c) ReturnCode {
    heap.nativefn_registry.register(heap.global_gpa, std.mem.span(name), init_fn) catch |err| switch (err) {
        error.OutOfMemory => return .oom,
        error.DuplicateNativeFn => return .@"error",
    };
    return .ok;
}

export fn Zicl_CreateCommand(
    interp: *Interp,
    name: [*:0]const u8,
    to_call: *const evaltypes.CCommandFn,
    description: [*:0]const u8,
    min_arity: c_int,
    max_arity: c_int,
) callconv(.c) ReturnCode {
    interp.registerCommand(std.mem.span(name), .{
        .call_info = .{ .c = to_call },
        .description = std.mem.span(description),
        .min_arity = @intCast(min_arity),
        .max_arity = std.math.cast(usize, max_arity),
    }) catch |err| return ReturnCode.fromError(err);
    return .ok;
}

export fn Zicl_EvalValue(interp: *Interp, script: Value) callconv(.c) ReturnCode {
    return ReturnCode.fromErrorUnion(interp.evalValue(script));
}

export fn Zicl_EvalFile(interp: *Interp, filename: [*:0]const u8) callconv(.c) ReturnCode {
    return ReturnCode.fromErrorUnion(interp.evalFile(std.mem.span(filename)));
}

export fn Zicl_GetScriptBeingEvaluated(interp: *Interp) callconv(.c) Value {
    return interp.evalFrame().currently_evaluating;
}

export fn Zicl_CurrentEvalFrameIdx(interp: *Interp) callconv(.c) u32 {
    return interp.evalFrameIdx();
}

// Borrowed from the frame: valid only while that frame remains on the stack.
export fn Zicl_EvalFrameScript(interp: *Interp, frame: u32) callconv(.c) Value {
    assert(frame < interp.eval_frames.items.len);
    return interp.eval_frames.items[frame].currently_evaluating;
}

export fn Zicl_GetResult(interp: *Interp) callconv(.c) Value {
    return interp.result;
}

export fn Zicl_SetResult(interp: *Interp, value: Value) callconv(.c) void {
    interp.setResult(value);
}

export fn Zicl_SetResultOwning(interp: *Interp, value: Value) callconv(.c) void {
    interp.setResultOwning(value);
}

export fn Zicl_SetResultString(interp: *Interp, str: [*:0]const u8, len: c_int) callconv(.c) ReturnCode {
    const bytes = if (len < 0) std.mem.span(str) else str[0..@intCast(len)];
    interp.setResultString(bytes) catch |err| return ReturnCode.fromError(err);
    return .ok;
}

// setErrorString sets the result to `bytes` and then returns error.EvalError to
// propagate the error code, so this always returns ZICL_ERR on the success path
// and ZICL_OOM only if storing the string allocates and fails.
export fn Zicl_SetErrorString(interp: *Interp, str: [*:0]const u8, len: c_int) callconv(.c) ReturnCode {
    const bytes = if (len < 0) std.mem.span(str) else str[0..@intCast(len)];
    return ReturnCode.fromError(interp.setErrorString(bytes));
}

export fn Zicl_SetResultBool(interp: *Interp, value: c_int) callconv(.c) ReturnCode {
    interp.setResultBoolean(value != 0);
    return .ok;
}

export fn Zicl_SetResultLong(interp: *Interp, value: c_long) callconv(.c) ReturnCode {
    interp.setResultInteger(value) catch |err| return ReturnCode.fromError(err);
    return .ok;
}

export fn Zicl_SetEmptyResult(interp: *Interp) callconv(.c) ReturnCode {
    interp.setEmptyResult();
    return .ok;
}

export fn Zicl_SetVariable(interp: *Interp, name: *Value, value: Value) callconv(.c) ReturnCode {
    var name_shim: Shimmerable = .{ .original = name.* };
    errdefer name_shim.discardChanges();
    interp.setVariable(&name_shim, value) catch |err| return ReturnCode.fromError(err);
    name.* = name_shim.consume();
    return .ok;
}

export fn Zicl_MakeErrorMessage(interp: *Interp) callconv(.c) ReturnCode {
    // The stack is a flat list: {name file line args ...} repeated.
    var stack_shim: Shimmerable = .{ .original = interp.stack_trace.orEmpty().borrow() };
    defer stack_shim.deinit();
    const as_list = interp.getList(&stack_shim) catch |err| return ReturnCode.fromError(err);

    const msg = Interp.makeErrorMessage(interp.result, as_list) catch |err| switch (err) {
        error.OutOfMemory => return .oom,
        // Nothing to report against, so leave the result as the bare message.
        error.WrongSize => return .ok,
    };
    interp.setResultOwning(msg);
    return .ok;
}

/// Increments the signal depth, deferring Tcl signal delivery during C
/// callbacks that should not be interrupted.
export fn Zicl_IncrSignalDepth(interp: *Interp) callconv(.c) void {
    interp.signal_depth += 1;
}

/// Decrements the signal depth, re-enabling Tcl signal delivery.
export fn Zicl_DecrSignalDepth(interp: *Interp) callconv(.c) void {
    interp.signal_depth -= 1;
}

/// Returns the pending signal bitmask. Non-zero means at least one signal is
/// waiting to be delivered.
export fn Zicl_GetSigmask(interp: *Interp) callconv(.c) u64 {
    return interp.signal;
}

// ===== Capabilities =====
// A capability is an unforgeable name (a `zicl://<host>/<type>/<id>` URL) for a
// resource a script can hold and pass around. C code can create its own
// capability types, resolve capability URLs, and recover a typed backing from a
// capability. The `Zicl_Head`/`Zicl_HeadVTable` layouts mirror `Capability.Head`
// and its vtable on the Zig side, field-for-field.

// C mirror of `Zicl_ParsedName`: the host/type slices point into the input string.
const ParsedName = extern struct {
    host: [*]const u8,
    host_len: c_int,
    type_name: [*]const u8,
    type_len: c_int,
    id: Capability.Id,
};

/// Register `head` and return the capability object that names it. `head` is a
/// `Capability.Head` embedded in a backing struct the caller allocated (at any
/// offset); this initializes `id`, `closed`, and `ref_count` (C construction
/// bypasses the Zig defaults). The caller owns the returned value, and recovers
/// its backing from the head with `Zicl_ContainerOf`.
export fn Zicl_CapabilityNew(out: *Value, head: *Capability.Head) callconv(.c) ReturnCode {
    head.closed = .init(false);
    head.ref_count = .init(1);
    head.id = 0;
    const cap = Capability.new(head) catch return .oom;
    out.* = cap.asHead().asValue();
    return .ok;
}

/// Close a capability (idempotent). No-op if `value` is not a capability.
export fn Zicl_CapabilityClose(value: Value) callconv(.c) void {
    if (value.asType(Capability)) |cap| cap.close();
}

/// Resolve a capability URL string in place, replacing `*value` with the
/// capability object it names. Returns ZICL_ERR for a malformed or stale name,
/// ZICL_OOM if allocating the shimmered object fails.
export fn Zicl_ResolveCapability(value: *Value) callconv(.c) ReturnCode {
    var shim: Shimmerable = .{ .original = value.* };
    errdefer shim.discardChanges();
    _ = Capability.shimmerFrom(null, &shim) catch |err| return ReturnCode.fromError(narrowError(err));
    value.* = shim.consume();
    return .ok;
}

/// The type segment of a capability's URL (e.g. "file-handle"), or NULL if
/// `value` is not a capability.
export fn Zicl_CapabilityTypeName(value: Value) callconv(.c) ?[*:0]const u8 {
    const cap = value.asType(Capability) orelse return null;
    return cap.head.vtable.name;
}

/// Whether the capability has been closed, or false if `value` is not one.
export fn Zicl_CapabilityIsClosed(value: Value) callconv(.c) bool {
    const cap = value.asType(Capability) orelse return false;
    return cap.head.isClosed();
}

/// The C counterpart of `Capability.getBacking`. Validates that `value` is a
/// capability whose head carries `expected` (pass NULL to skip the type check),
/// that it has not been closed, and writes its head to `*out`. The head is
/// borrowed from the capability: valid while the capability stays alive and
/// open. Recover the backing with `Zicl_ContainerOf(*out, MyBacking, head)`.
export fn Zicl_GetBacking(
    value: Value,
    expected: ?*const Capability.Head.VTable,
    out: *?*Capability.Head,
) callconv(.c) ReturnCode {
    const cap = value.asType(Capability) orelse return .@"error";
    if (expected) |vt| {
        if (cap.head.vtable != vt) return .@"error";
    }
    if (cap.head.isClosed()) {
        // Match getBacking: a closed capability reports staleness. Generating
        // the string rep for the message can allocate, so report OOM if it does.
        _ = @constCast(cap).asHead().getString() catch return .oom;
        return .@"error";
    }
    out.* = cap.head;
    return .ok;
}

// Head operations, mirroring `Capability.Head`.

export fn Zicl_HeadBorrow(head: *Capability.Head) callconv(.c) *Capability.Head {
    return head.borrow();
}

export fn Zicl_HeadRelease(head: *Capability.Head) callconv(.c) void {
    head.release();
}

export fn Zicl_HeadClose(head: *Capability.Head) callconv(.c) void {
    head.close();
}

export fn Zicl_HeadIsClosed(head: *Capability.Head) callconv(.c) bool {
    return head.isClosed();
}

export fn Zicl_HeadGetId(head: *Capability.Head, out: *Capability.Id) callconv(.c) void {
    out.* = head.id;
}

/// Parse a capability URL into its parts. `host` and `type_name` point into
/// `str` and are not NUL-terminated. Returns ZICL_ERR for a malformed name.
export fn Zicl_ParseCapabilityName(
    str: [*:0]const u8,
    len: c_int,
    out: *ParsedName,
) callconv(.c) ReturnCode {
    const bytes = if (len < 0) std.mem.span(str) else str[0..@intCast(len)];
    const parsed = Capability.parseName(null, bytes) catch return .@"error";
    out.* = .{
        .host = parsed.host.ptr,
        .host_len = @intCast(parsed.host.len),
        .type_name = parsed.type_name.ptr,
        .type_len = @intCast(parsed.type_name.len),
        .id = parsed.id,
    };
    return .ok;
}

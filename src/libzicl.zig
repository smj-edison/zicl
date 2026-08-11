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
const load = @import("commands/load.zig");
const leak_check = @import("leak_check.zig");
const ioutil = @import("ioutil.zig");
const Capability = @import("Capability.zig");
const memutil = @import("memutil.zig");

// ===== Internal: logging and panic =====
// These are not part of the C API surface; they wire Zig's log and panic
// facilities onto zicl's redirected stderr and leak-check trace.

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
// See the header docs for the process/thread setup contract.

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
// See the header docs for the snapshot/rewind contract. Rewinding retains the
// arena's chunks for reuse rather than freeing them. Anything the interpreter
// still references out of the arena (a primitive's string rep, a parse cache
// entry) becomes invalid after a rewind.

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
// See the header docs for the string-accessor contract.

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
// See the header docs for how these behave on primitives.

export fn Zicl_Release(value: Value) callconv(.c) void {
    value.release();
}

export fn Zicl_Borrow(value: Value) callconv(.c) Value {
    return value.borrow();
}

export fn Zicl_Duplicate(value: Value, out: *Value) callconv(.c) ReturnCode {
    out.* = value.duplicate() catch return .oom;
    return .ok;
}

export fn Zicl_ReleaseArrayItems(argv: [*]Value, argc: c_int) callconv(.c) void {
    const count: usize = @intCast(argc);
    for (argv[0..count]) |v| v.release();
}

export fn Zicl_AsPtr(value: Value) callconv(.c) ?*heap.Object {
    return value.asPtr();
}

export fn Zicl_BoxObject(obj: *heap.Object) callconv(.c) Value {
    return obj.asValue();
}

export fn Zicl_RefCount(value: Value) callconv(.c) u32 {
    const obj = value.asPtr() orelse return 0;
    return obj.getRefCount();
}

export fn Zicl_RefCountPtr(value: Value) callconv(.c) ?*u32 {
    const obj = value.asPtr() orelse return null;
    return &obj.ref_count;
}

// ===== Custom native object types =====
// See the header comment for the split between what lives here (allocation,
// type identity) and what a vtable's own callbacks are expected to decide
// (whether a struct fits inline or needs out-of-line storage).

export fn Zicl_NoopMakeCrossthread(obj: *heap.Object) callconv(.c) void {
    heap.Object.noopMakeCrossthread(obj);
}

export fn Zicl_NewObject(
    vtable: *const heap.Object.VTable,
    size: usize,
    out_body: *?*anyopaque,
) callconv(.c) ?*heap.Object {
    if (size > heap.Object.body_max_size) {
        @panic("Zicl_NewObject: size exceeds ZICL_OBJECT_BODY_MAX_SIZE");
    }

    const obj = heap.global_gpa.create(heap.Object) catch return null;
    obj.* = .{
        .vtable = vtable,
        .ref_count = 1,
        .metadata = .{},
        .hash_metadata = .init(.{}),
        .string = .init(null),
        .string_metadata = .init(.{}),
        .body_backing = @splat(0),
    };
    leak_check.globalTrace(.alloc, obj.asValue(), "Created object of type {s}", .{vtable.name});

    out_body.* = &obj.body_backing;
    return obj;
}

export fn Zicl_AsObject(value: Value, vtable: *const heap.Object.VTable) callconv(.c) ?*anyopaque {
    const obj = value.asPtr() orelse return null;
    if (obj.vtable != vtable) return null;
    return &obj.body_backing;
}

export fn Zicl_ObjectBody(obj: *heap.Object) callconv(.c) *anyopaque {
    return &obj.body_backing;
}

export fn Zicl_ObjectBodyConst(obj: *const heap.Object) callconv(.c) *const anyopaque {
    return &obj.body_backing;
}

// The C-callable counterpart to what `String.updateString` (and every other
// built-in type's) does internally via `setStringDuplicatingIgnoreRace`.
export fn Zicl_SetObjectString(obj: *heap.Object, ptr: [*:0]const u8, len: c_int) callconv(.c) ReturnCode {
    const bytes = if (len < 0) std.mem.span(ptr) else ptr[0..@intCast(len)];
    obj.setStringDuplicatingIgnoreRace(bytes) catch return .oom;
    return .ok;
}

// ===== Struct enumeration (leak-check dump introspection) =====
// See the header docs for the contract. `Zicl_StructWalker*` is memutil.zig's
// `StructIterator.CEnumerateContext`, under a name meaningful on the C side.

const CEnumerateContext = memutil.StructIterator.CEnumerateContext;

// Show `fieldName` as `valueStr` (already formatted) in the dump.
export fn Zicl_StructWalkerAddField(
    walker: *CEnumerateContext,
    field_name: [*:0]const u8,
    value_str: [*:0]const u8,
) callconv(.c) ReturnCode {
    const dummy_node = walker.ctx.arena.create(u8) catch return .oom;
    // Duped onto the arena, not just spanned: `dumpDot`/`dumpDetails` read
    // `as_string` later, once the whole walk has finished, so a caller who
    // formatted this into a stack buffer (the common case -- see
    // inner_enumerate_struct in c_api_test.c) would otherwise have its value
    // read back out of memory that's long since been reused for something
    // else, matching what addFieldString already does for a Zig-native type.
    const owned_str = walker.ctx.arena.dupe(u8, std.mem.span(value_str)) catch return .oom;
    const child_node: memutil.StructIterator.NodeInfo = .{
        .parent_info = walker.info,
        .node = dummy_node,
        .enumerate_struct = null,
        .type_name = "C field",
        .as_string = owned_str,
        .is_synthetic = true,
    };
    walker.ctx.vtable.visit_node(walker.ctx, &child_node, std.mem.span(field_name)) catch return .oom;
    return .ok;
}

export fn Zicl_StructWalkerFollowValue(
    walker: *CEnumerateContext,
    field_name: [*:0]const u8,
    value: Value,
) callconv(.c) ReturnCode {
    const helper: objects.IterHelper = .{ .ctx = walker.ctx, .info = walker.info };
    helper.followValue(std.mem.span(field_name), value) catch return .oom;
    return .ok;
}

export fn Zicl_StructWalkerFollowStruct(
    walker: *CEnumerateContext,
    field_name: [*:0]const u8,
    ptr: *const anyopaque,
    type_name: [*:0]const u8,
    enumerate_struct: ?memutil.StructIterator.EnumerateStructCFn,
) callconv(.c) ReturnCode {
    // `type_name` is spanned, not duped (see the header docs): every
    // existing caller of the underlying mechanism passes a string literal,
    // so this one should too.
    const child_node: memutil.StructIterator.NodeInfo = .{
        .parent_info = walker.info,
        .node = ptr,
        .enumerate_struct = null,
        .enumerate_struct_c = enumerate_struct,
        .type_name = std.mem.span(type_name),
        .as_string = null,
    };
    walker.ctx.vtable.visit_node(walker.ctx, &child_node, std.mem.span(field_name)) catch return .oom;
    return .ok;
}

// ===== Cross-thread sharing =====
// See the header docs for the marking/happens-before contract.
export fn Zicl_MakeCrossthread(value: Value) callconv(.c) void {
    value.makeCrossthread();
}

// ===== Value equality =====
// See the header docs for the comparison contract.
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
// See the header docs for the constructor/coercion contract.

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
// See the header docs for the contract.

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

/// The C counterpart to `Shimmerable.prepareToShimmer`, for a custom native
/// object type: takes a `Zicl_ObjectVTable` in place of a Zig type, and
/// returns the object's raw body storage (the same kind of pointer
/// `Zicl_NewObject` hands back) instead of a typed pointer. NULL on OOM.
export fn Zicl_PrepareToShimmer(shim: *Shimmerable, vtable: *const heap.Object.VTable) callconv(.c) ?*anyopaque {
    return shim.prepareToShimmerVTable(vtable) catch return null;
}

// ===== Lists =====
// See the header docs for the contract.

export fn Zicl_NewList(values: ?[*]const Value, n_values: c_int) callconv(.c) ?*List {
    const items = if (values) |ptr| ptr[0..@intCast(n_values)] else &.{};
    const list = List.new(items) catch return null;
    return list;
}

// The C `Zicl_Shimmerable` layout mirrors `objects.Shimmerable`, so the
// pointer cast is sound.
export fn Zicl_NewListFromShimmerables(
    shims: ?[*]const Shimmerable,
    n_shims: c_int,
) callconv(.c) ?*List {
    const items = if (shims) |ptr| ptr[0..@intCast(n_shims)] else &.{};
    const list = List.newFromShimmerables(items) catch return null;
    return list;
}

export fn Zicl_BoxList(list: *List) callconv(.c) Value {
    return list.asHead().asValue();
}

export fn Zicl_ReleaseList(list: *List) callconv(.c) void {
    list.asHead().release();
}

export fn Zicl_BorrowList(list: *List) callconv(.c) *List {
    list.asHead().incrRefCount();
    return list;
}

/// Copy-on-write in-place entry point. `Zicl_ListShimmerWriteback` is a
/// different operation: it writes a shimmered child back into a list slot in
/// place, preserving the list's string rep.
export fn Zicl_AsListMut(interp: *Interp, value: Value, out: *?*List) callconv(.c) ReturnCode {
    out.* = null;
    var det: ErrorDetails = undefined;
    if (interp.wrapError(&det, value.asMutableInPlace(List, &det))) |maybe_mut| {
        out.* = maybe_mut;
        return .ok;
    } else |err| return ReturnCode.fromError(err);
}

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

export fn Zicl_ListShimmer(interp: *Interp, shim: *Shimmerable, out: *?*const List) callconv(.c) ReturnCode {
    const list = interp.getList(shim) catch |err| return ReturnCode.fromError(err);
    out.* = list;
    return .ok;
}

export fn Zicl_ListItems(list: *const List) callconv(.c) [*]const Value {
    return list.items.ptr;
}

export fn Zicl_ListLength(list: *const List) callconv(.c) c_int {
    return @intCast(list.items.len);
}

export fn Zicl_ListAppend(list: *List, item: Value) callconv(.c) ReturnCode {
    list.append(item) catch |err| return ReturnCode.fromError(narrowError(err));
    return .ok;
}

export fn Zicl_ListSet(list: *List, index: c_int, item: Value) callconv(.c) ReturnCode {
    const idx: usize = @intCast(index);
    if (idx >= list.items.len) return .@"error";
    list.set(idx, item) catch |err| return ReturnCode.fromError(narrowError(err));
    return .ok;
}

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

export fn Zicl_ListGetItem(interp: *Interp, list: *Value, index: c_int) callconv(.c) OptionalValue {
    const as_list = interp.getListInPlace(list) catch return .none;
    if (index < 0) return .none;
    const idx: usize = @intCast(index);
    if (idx >= as_list.items.len) return .none;
    return as_list.items[idx].asOptional();
}

export fn Zicl_ListShimmerWriteback(list: *List, index: c_int, value: Value) callconv(.c) ReturnCode {
    const idx: usize = @intCast(index);
    if (idx >= list.items.len) return .@"error";
    list.shimmerWriteback(idx, value);
    return .ok;
}

// ===== Dicts =====
// See the header docs for the contract.

export fn Zicl_NewDict(values: ?[*]const Value, n_values: c_int) callconv(.c) ?*Dictionary {
    const items = if (values) |ptr| ptr[0..@intCast(n_values)] else &.{};
    const dict = Dictionary.new(items) catch return null;
    return dict;
}

export fn Zicl_BoxDict(dict: *Dictionary) callconv(.c) Value {
    return dict.asHead().asValue();
}

export fn Zicl_ReleaseDict(dict: *Dictionary) callconv(.c) void {
    dict.asHead().release();
}

export fn Zicl_BorrowDict(dict: *Dictionary) callconv(.c) *Dictionary {
    dict.asHead().incrRefCount();
    return dict;
}

/// Copy-on-write in-place entry point. `Zicl_DictShimmerWriteback` is a
/// different operation: it writes a shimmered child back into a dict key in
/// place, preserving the dict's string rep.
export fn Zicl_AsDictMut(interp: *Interp, value: Value, out: *?*Dictionary) callconv(.c) ReturnCode {
    out.* = null;
    var det: ErrorDetails = undefined;
    if (interp.wrapError(&det, value.asMutableInPlace(Dictionary, &det))) |maybe_mut| {
        out.* = maybe_mut;
        return .ok;
    } else |err| return ReturnCode.fromError(err);
}

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

export fn Zicl_DictShimmer(interp: *Interp, shim: *Shimmerable, out: *?*const Dictionary) callconv(.c) ReturnCode {
    const dict = interp.getDict(shim) catch |err| return ReturnCode.fromError(err);
    out.* = dict;
    return .ok;
}

export fn Zicl_DictLength(dict: *const Dictionary) callconv(.c) c_int {
    return @intCast(dict.items.len / 2);
}

export fn Zicl_DictItems(dict: *const Dictionary) callconv(.c) [*]const Value {
    return dict.items.ptr;
}

export fn Zicl_DictPut(dict: *Dictionary, key: Value, value: Value) callconv(.c) ReturnCode {
    dict.put(key, value) catch |err| return ReturnCode.fromError(narrowError(err));
    return .ok;
}

export fn Zicl_DictRemove(dict: *Dictionary, key: Value, removed: *c_int) callconv(.c) ReturnCode {
    const r = dict.remove(null, key) catch |err| return ReturnCode.fromError(narrowError(err));
    removed.* = if (r) 1 else 0;
    return .ok;
}

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

export fn Zicl_DictShimmerWriteback(dict: *Dictionary, key: Value, value: Value) callconv(.c) ReturnCode {
    dict.shimmerWriteback(key, value) catch |err| return ReturnCode.fromError(narrowError(err));
    return .ok;
}

// ===== Source =====
// See the header docs for the contract.

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

export fn Zicl_BoxSource(source: *objects.Source) callconv(.c) Value {
    return source.asHead().asValue();
}

export fn Zicl_ReleaseSource(source: *objects.Source) callconv(.c) void {
    source.asHead().release();
}

export fn Zicl_BorrowSource(source: *objects.Source) callconv(.c) *objects.Source {
    source.asHead().incrRefCount();
    return source;
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
// See the header docs for the contract.

export fn Zicl_RegisterLazyFn(name: [*:0]const u8, library: [*:0]const u8, init_fn: heap.LazyRegisterFn) callconv(.c) ReturnCode {
    heap.lazy_fn_registry.register(heap.global_gpa, std.mem.span(name), std.mem.span(library), init_fn) catch |err| switch (err) {
        error.OutOfMemory => return .oom,
        error.DuplicateLazyFn => return .@"error",
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

export fn Zicl_Eval(interp: *Interp, script: [*:0]const u8) callconv(.c) ReturnCode {
    const script_value = objects.String.newValue(std.mem.span(script)) catch return .oom;
    defer script_value.release();
    return Zicl_EvalValue(interp, script_value);
}

export fn Zicl_EvalFile(interp: *Interp, filename: [*:0]const u8) callconv(.c) ReturnCode {
    return ReturnCode.fromErrorUnion(interp.evalFile(std.mem.span(filename)));
}

export fn Zicl_LoadLibrary(interp: *Interp, path: [*:0]const u8) callconv(.c) ReturnCode {
    return ReturnCode.fromErrorUnion(load.loadLibrary(interp, std.mem.span(path)));
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

// `evalObjectInner` checks this after each command and returns `.exit` once
// it is set, so a running `Zicl_Eval` unwinds at the next command boundary.
export fn Zicl_RequestStop(interp: *Interp) callconv(.c) void {
    interp.stop_executing.store(true, .monotonic);
}

// Reads are monotonic, matching the store in `Zicl_RequestStop`.
export fn Zicl_StopRequested(interp: *Interp) callconv(.c) bool {
    return interp.stop_executing.load(.monotonic);
}

export fn Zicl_ClearStop(interp: *Interp) callconv(.c) void {
    interp.stop_executing.store(false, .monotonic);
}

// ===== Capabilities =====
// See the header docs for the contract.

// C mirror of `Zicl_ParsedName`: the host/type slices point into the input string.
const ParsedName = extern struct {
    host: [*]const u8,
    host_len: c_int,
    type_name: [*]const u8,
    type_len: c_int,
    id: Capability.Id,
};

/// Initializes `id`, `closed`, and `ref_count`, since C construction bypasses
/// the Zig defaults.
export fn Zicl_CapabilityNew(out: *Value, head: *Capability.Head) callconv(.c) ReturnCode {
    head.closed = .init(false);
    head.ref_count = .init(1);
    head.id = 0;
    const cap = Capability.new(head) catch return .oom;
    out.* = cap.asHead().asValue();
    return .ok;
}

export fn Zicl_CapabilityClose(value: Value) callconv(.c) void {
    if (value.asType(Capability)) |cap| cap.close();
}

/// Returns ZICL_OOM if allocating the shimmered object fails.
export fn Zicl_ResolveCapability(value: *Value) callconv(.c) ReturnCode {
    var shim: Shimmerable = .{ .original = value.* };
    errdefer shim.discardChanges();
    _ = Capability.shimmerFrom(null, &shim) catch |err| return ReturnCode.fromError(narrowError(err));
    value.* = shim.consume();
    return .ok;
}

export fn Zicl_CapabilityTypeName(value: Value) callconv(.c) ?[*:0]const u8 {
    const cap = value.asType(Capability) orelse return null;
    return cap.head.vtable.name;
}

export fn Zicl_CapabilityIsClosed(value: Value) callconv(.c) bool {
    const cap = value.asType(Capability) orelse return false;
    return cap.head.isClosed();
}

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

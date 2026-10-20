const std = @import("std");
const assert = std.debug.assert;

const options = @import("options");

const memutil = @import("memutil.zig");
const ioutil = @import("ioutil.zig");
const leak_check = @import("leak_check.zig");

const heap = @import("heap.zig");
const ReturnCode = heap.ReturnCode;
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
const Capability = @import("Capability.zig");
const capabilities = @import("capabilities.zig");
const commands = @import("commands/common.zig");
const load = @import("commands/load.zig");
const Threaded = @import("vendor/Threaded.zig");

// ===== Internal: logging and panic =====
// These are not part of the C API surface; they wire Zig's log and panic
// facilities onto zicl's redirected stderr and leak-check trace.

pub const panic = std.debug.FullPanic(ziclPanic);
pub const std_options: std.Options = .{ .logFn = ziclLog };

// Mirrors debug.zig's threadlocal panic_stage to guard against recursive panics.
threadlocal var zicl_panic_stage: usize = 0;
threadlocal var io_thread_control: *Threaded.Thread = undefined;

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

var global_threaded: Threaded = undefined;

export fn Zicl_SetLocalStdout(fd: c_int) void {
    ioutil.local_stdout_fd = fd;
}
export fn Zicl_SetLocalStderr(fd: c_int) void {
    ioutil.local_stderr_fd = fd;
}

/// `host_name` is the name this machine goes by in the capabilities it hands
/// out. Null asks the system for it.
export fn Zicl_InitGlobals(host_name: ?[*:0]const u8) ReturnCode {
    const proc_environ: std.process.Environ = .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    const env_map = proc_environ.createMap(std.heap.c_allocator) catch return .oom;

    global_threaded = Threaded.init(std.heap.c_allocator, .{ .environ = proc_environ });
    heap.initGlobals(std.heap.c_allocator, global_threaded.io(), .{ .owned = env_map }, .{
        .capability = .{
            .host_name = if (host_name) |name| std.mem.span(name) else null,
        },
    }) catch return .@"error";
    return .ok;
}

export fn Zicl_InitThread() ReturnCode {
    io_thread_control = Threaded.initThread();
    heap.initThread() catch return .oom;
    return .ok;
}

export fn Zicl_DeinitThread() void {
    heap.deinitThread();
    Threaded.deinitThread();
}

export fn Zicl_DeinitGlobals() void {
    heap.deinitGlobals();
}

export fn Zicl_LeakCheckAll() void {
    // Ahead of the check, or the fallback `[catch]` dict that lives for the
    // whole process reports as a leak every time. This is why the check is
    // shutdown-only: releasing that dict makes any further evaluation unsafe.
    heap.freeOomErrorOptionsDict();
    leak_check.dumpLeaks() catch {};
}

export fn Zicl_CreateInterp() ?*Interp {
    // Store the interpreter on the heap, so it's an opaque pointer.
    const interp = heap.global_gpa.create(Interp) catch return null;
    errdefer heap.global_gpa.destroy(interp);
    interp.* = Interp.init(.{}) catch return null;
    errdefer interp.deinit();

    commands.registerCoreCommands(interp) catch return null;

    return interp;
}

export fn Zicl_InterpDestroy(interp: *Interp) void {
    interp.deinit();
    heap.global_gpa.destroy(interp);
}

// ===== Local arena snapshots =====
// See the header docs for the snapshot/rewind contract. Rewinding retains the
// arena's chunks for reuse rather than freeing them. Anything the interpreter
// still references out of the arena (a primitive's string rep, a parse cache
// entry) becomes invalid after a rewind.

// `ScopedArena.Snapshot` is an `extern struct`, so it crosses the C ABI by
// value; the C side declares the layout-equivalent `Zicl_ArenaSnapshot`.
const ArenaSnapshot = memutil.ScopedArena.Snapshot;

export fn Zicl_LocalArenaTakeSnapshot() ArenaSnapshot {
    return heap.local_arena_instance.takeSnapshot();
}

export fn Zicl_LocalArenaRestore(snap: ArenaSnapshot) void {
    heap.local_arena_instance.restore(snap);
}

// ===== Strings =====
// See the header docs for the string-accessor contract.

export fn Zicl_NewString(out: *Value, ptr: [*:0]const u8, len: c_int) ReturnCode {
    const bytes = if (len < 0) std.mem.span(ptr) else ptr[0..@intCast(len)];
    out.* = objects.String.newValue(bytes) catch return .oom;
    return .ok;
}

// `Zicl_InternStr` is a header inline (see include/libzicl.h) so that
// `strlen` of a literal folds to a compile-time constant, making the common
// case -- a short rodata literal such as a command name or dict key -- a
// constant `Zicl_Val` with no call. The inline calls this only when the
// string exceeds the 65535-byte cap an interned value's u16 length can hold;
// abort loudly rather than truncate, mirroring the `@intCast` panic the
// constructor used to do.
export fn Zicl_InternStrTooLong() noreturn {
    @panic("interned string exceeds 65535 bytes");
}

export fn Zicl_String(value: Value) ?[*:0]const u8 {
    return value.getString() catch return null;
}

export fn Zicl_GetString(value: Value, len: ?*c_int) ?[*:0]const u8 {
    const str = value.getString() catch return null;
    if (len) |ptr| ptr.* = @intCast(str.len);
    return str;
}

// ===== Reference counting and object introspection =====
// See the header docs for how these behave on primitives.

export fn Zicl_DropRef(value: Value) void {
    value.dropReference();
}

export fn Zicl_Ref(value: Value) Value {
    return value.takeReference();
}

export fn Zicl_Duplicate(value: Value, out: *Value) ReturnCode {
    out.* = value.duplicate() catch return .oom;
    return .ok;
}

export fn Zicl_DuplicateAsBoxed(value: Value) ?*heap.Object {
    return value.duplicateAsBoxed() catch null;
}

export fn Zicl_DropRefArrayItems(argv: [*]Value, argc: c_int) void {
    const count: usize = @intCast(argc);
    for (argv[0..count]) |v| v.dropReference();
}

export fn Zicl_BoxObject(obj: *heap.Object) Value {
    return obj.asValue();
}

export fn Zicl_CanMutate(value: Value) bool {
    return value.canMutate();
}

export fn Zicl_CanShimmer(value: Value) bool {
    return value.canShimmer();
}

export fn Zicl_RefCount(value: Value) u32 {
    const obj = value.asPtr() orelse return 0;
    return obj.getRefCount();
}

export fn Zicl_RefCountPtr(value: Value) ?*u32 {
    const obj = value.asPtr() orelse return null;
    return &obj.ref_count;
}

// ===== Custom native object types =====
// See the header comment for the split between what lives here (allocation,
// type identity) and what a vtable's own callbacks are expected to decide
// (whether a struct fits inline or needs out-of-line storage).

export fn Zicl_NoopMakeCrossthread(obj: *heap.Object) void {
    heap.Object.noopMakeCrossthread(obj);
}

export fn Zicl_NewObj(
    vtable: *const heap.Object.VTable,
    size: c_int,
    out_body: *?*anyopaque,
) ?*heap.Object {
    if (size > heap.Object.body_max_size) {
        @panic("Zicl_NewObjize exceeds ZICL_OBJECT_BODY_MAX_SIZE");
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
        .sequence_number = if (options.trace_mem) heap.Object.next_sequence_number.fetchAdd(1, .monotonic) else 0,
    };
    leak_check.globalTrace(obj, .alloc);

    out_body.* = &obj.body_backing;
    return obj;
}

export fn Zicl_AsObj(value: Value) ?*heap.Object {
    return value.asPtr() orelse null;
}

export fn Zicl_AsObjBody(value: Value, vtable: *const heap.Object.VTable) ?*anyopaque {
    const obj = value.asPtr() orelse return null;
    if (obj.vtable != vtable) return null;
    return &obj.body_backing;
}

export fn Zicl_SetObjectString(obj: *heap.Object, ptr: [*:0]const u8, len: c_int) ReturnCode {
    const bytes = if (len < 0) std.mem.span(ptr) else ptr[0..@intCast(len)];
    obj.setStringDuplicatingIgnoreRace(bytes) catch return .oom;
    return .ok;
}

const CEnumerateContext = memutil.StructIterator.CEnumerateContext;

// Show `fieldName` as `valueStr` (already formatted) in the dump.
export fn Zicl_StructWalkerAddField(
    walker: *CEnumerateContext,
    field_name: [*:0]const u8,
    value_str: [*:0]const u8,
) ReturnCode {
    const dummy_node = walker.ctx.arena.create(u8) catch return .oom;

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
) ReturnCode {
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
) ReturnCode {
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
export fn Zicl_MakeCrossthread(value: Value) void {
    value.makeCrossthread();
}

// ===== Value equality =====
// See the header docs for the comparison contract.
export fn Zicl_Equals(a: Value, b: Value, out: *c_int) ReturnCode {
    const eq = a.equals(b) catch return .oom;
    out.* = if (eq) 1 else 0;
    return .ok;
}

// Fast path: never allocates and never returns a false positive, but may report
// two equal values as unequal when confirming would need a generated string rep.
export fn Zicl_QuickEquals(a: Value, b: Value) bool {
    return a.raw.quickEquals(b.raw);
}

// ===== Numbers =====
// See the header docs for the constructor/coercion contract.

export fn Zicl_NewLong(value: i64) Value {
    return objects.Integer.new(value);
}

export fn Zicl_NewDouble(value: f64) Value {
    return objects.Float.new(value);
}

export fn Zicl_NewBool(value: bool) Value {
    return objects.Boolean.new(value);
}

export fn Zicl_GetLong(interp: *Interp, shim: *Shimmerable, out: *c_long) ReturnCode {
    out.* = interp.getInteger(shim) catch |err| return ReturnCode.fromError(err);
    return .ok;
}

export fn Zicl_GetDouble(interp: *Interp, shim: *Shimmerable, out: *f64) ReturnCode {
    out.* = interp.getFloat(shim) catch |err| return ReturnCode.fromError(err);
    return .ok;
}

export fn Zicl_GetBoolean(interp: *Interp, shim: *Shimmerable, out: *c_int) ReturnCode {
    const result = interp.getBoolean(shim) catch |err| return ReturnCode.fromError(err);
    out.* = if (result) 1 else 0;
    return .ok;
}

export fn Zicl_ShimDiscardChanges(shim: *Shimmerable) void {
    shim.discardChanges();
}

export fn Zicl_PrepareToShimmer(shim: *Shimmerable, vtable: *const heap.Object.VTable) ?*anyopaque {
    return shim.prepareToShimmerVTable(vtable) catch return null;
}

// ===== Lists =====
// See the header docs for the contract.

export fn Zicl_NewList(values: ?[*]const Value, n_values: c_int) ?*List {
    const items = if (values) |ptr| ptr[0..@intCast(n_values)] else &.{};
    const list = List.new(items) catch return null;
    return list;
}

// The C `Zicl_Shim` layout mirrors `objects.Shimmerable`, so the
// pointer cast is sound.
export fn Zicl_NewListFromShimmerables(
    shims: ?[*]const Shimmerable,
    n_shims: c_int,
) ?*List {
    const items = if (shims) |ptr| ptr[0..@intCast(n_shims)] else &.{};
    const list = List.newFromShimmerables(items) catch return null;
    return list;
}

export fn Zicl_BoxList(list: *List) Value {
    return list.asHead().asValue();
}

export fn Zicl_DropRefList(list: *List) void {
    list.asHead().dropReference();
}

export fn Zicl_RefList(list: *List) *List {
    list.asHead().incrRefCount();
    return list;
}

/// Copy-on-write in-place entry point. `Zicl_ListShimmerWriteback` is a
/// different operation: it writes a shimmered child back into a list slot in
/// place, preserving the list's string rep.
export fn Zicl_AsListMut(interp: *Interp, value: Value, out: *?*List) ReturnCode {
    out.* = null;
    var det: ErrorDetails = undefined;
    if (interp.wrapError(&det, value.asMutableInPlace(List, &det))) |maybe_mut| {
        out.* = maybe_mut;
        return .ok;
    } else |err| return ReturnCode.fromError(err);
}

export fn Zicl_DupAsList(interp: *Interp, value: Value, out: *?*List) ReturnCode {
    var det: ErrorDetails = undefined;
    if (interp.wrapError(&det, value.duplicateAsType(List, &det))) |dup| {
        out.* = dup;
        return .ok;
    } else |err| {
        out.* = null;
        return ReturnCode.fromError(err);
    }
}

export fn Zicl_ListShimmer(interp: *Interp, shim: *Shimmerable, out: *?*const List) ReturnCode {
    const list = interp.getList(shim) catch |err| return ReturnCode.fromError(err);
    out.* = list;
    return .ok;
}

export fn Zicl_ListItems(list: *const List) [*]const Value {
    return list.items.ptr;
}

export fn Zicl_ListLength(list: *const List) c_int {
    return @intCast(list.items.len);
}

export fn Zicl_ListAppend(list: *List, item: Value) ReturnCode {
    list.append(item) catch |err| return ReturnCode.fromError(narrowError(err));
    return .ok;
}

export fn Zicl_ListSet(list: *List, index: c_int, item: Value) ReturnCode {
    const idx: usize = @intCast(index);
    if (idx >= list.items.len) return .@"error";
    list.set(idx, item);
    return .ok;
}

export fn Zicl_ShimListItem(
    interp: *Interp,
    shim: *Shimmerable,
    index: c_int,
    out: *OptionalValue,
) ReturnCode {
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

export fn Zicl_ListGetItem(interp: *Interp, list: *Value, index: c_int) OptionalValue {
    const as_list = interp.getListInPlace(list) catch return .none;
    if (index < 0) return .none;
    const idx: usize = @intCast(index);
    if (idx >= as_list.items.len) return .none;
    return as_list.items[idx].asOptional();
}

export fn Zicl_ListShimmerWriteback(list: *List, index: c_int, value: Value) ReturnCode {
    const idx: usize = @intCast(index);
    if (idx >= list.items.len) return .@"error";
    list.shimmerWriteback(idx, value);
    return .ok;
}

// ===== Dicts =====
// See the header docs for the contract.

export fn Zicl_NewDict(values: ?[*]const Value, n_values: c_int) ?*Dictionary {
    const items = if (values) |ptr| ptr[0..@intCast(n_values)] else &.{};
    const dict = Dictionary.new(items) catch return null;
    return dict;
}

export fn Zicl_BoxDict(dict: *Dictionary) Value {
    return dict.asHead().asValue();
}

export fn Zicl_DropRefDict(dict: *Dictionary) void {
    dict.asHead().dropReference();
}

export fn Zicl_RefDict(dict: *Dictionary) *Dictionary {
    dict.asHead().incrRefCount();
    return dict;
}

/// Copy-on-write in-place entry point. `Zicl_DictShimmerWriteback` is a
/// different operation: it writes a shimmered child back into a dict key in
/// place, preserving the dict's string rep.
export fn Zicl_AsDictMut(interp: *Interp, value: Value, out: *?*Dictionary) ReturnCode {
    out.* = null;
    var det: ErrorDetails = undefined;
    if (interp.wrapError(&det, value.asMutableInPlace(Dictionary, &det))) |maybe_mut| {
        out.* = maybe_mut;
        return .ok;
    } else |err| return ReturnCode.fromError(err);
}

export fn Zicl_DupAsDict(interp: *Interp, value: Value, out: *?*Dictionary) ReturnCode {
    var det: ErrorDetails = undefined;
    if (interp.wrapError(&det, value.duplicateAsType(Dictionary, &det))) |dup| {
        out.* = dup;
        return .ok;
    } else |err| {
        out.* = null;
        return ReturnCode.fromError(err);
    }
}

export fn Zicl_DictShimmer(interp: *Interp, shim: *Shimmerable, out: *?*const Dictionary) ReturnCode {
    const dict = interp.getDict(shim) catch |err| return ReturnCode.fromError(err);
    out.* = dict;
    return .ok;
}

export fn Zicl_DictLength(dict: *const Dictionary) c_int {
    return dict.items.len;
}

export fn Zicl_DictItems(dict: *const Dictionary) [*]const Value {
    return dict.items.ptr;
}

export fn Zicl_DictPut(dict: *Dictionary, key: Value, value: Value) ReturnCode {
    dict.put(key, value) catch |err| return ReturnCode.fromError(narrowError(err));
    return .ok;
}

export fn Zicl_DictRemove(dict: *Dictionary, key: Value, removed: ?*bool) ReturnCode {
    const did_remove = dict.remove(null, key) catch |err| return ReturnCode.fromError(narrowError(err));
    if (removed) |ptr| ptr.* = did_remove;
    return .ok;
}

export fn Zicl_ShimDictGet(
    interp: *Interp,
    shim: *Shimmerable,
    key: Value,
    out: *OptionalValue,
) ReturnCode {
    const result = interp.shimGetDictValue(shim, key) catch |err| {
        out.* = .none;
        return ReturnCode.fromError(err);
    };
    out.* = if (result) |val| val.asOptional() else .none;
    return .ok;
}

export fn Zicl_DictShimmerWriteback(dict: *Dictionary, key: Value, value: Value) ReturnCode {
    dict.shimmerWriteback(key, value) catch |err| return ReturnCode.fromError(narrowError(err));
    return .ok;
}

/// Like [dict link], but builds a fresh dict rather than mutating `dict` in
/// place: the caller keeps both `dict` and `parent` untouched. `parent` is
/// referenced, and boxed first if it is a primitive. Returns NULL on OOM.
export fn Zicl_DictLink(dict: *const Dictionary, parent: Value) ?*Dictionary {
    const hash_ref = objects.HashReference.newFromValue(parent) catch return null;
    defer hash_ref.asHead().dropReference();

    const items = heap.global_gpa.alloc(Value, dict.items.len + 2) catch return null;
    defer heap.global_gpa.free(items);

    items[0] = objects.interned_tilde_parent;
    items[1] = hash_ref.asHead().asValue();
    @memcpy(items[2..], dict.items);

    return Dictionary.new(items) catch null;
}

// ===== Source =====
// See the header docs for the contract.

export fn Zicl_AsSource(value: Value) ?*const objects.Source {
    return value.asType(objects.Source);
}

export fn Zicl_AsSourceMut(value: Value) ?*objects.Source {
    var det: ErrorDetails = undefined;
    return value.asMutableInPlace(objects.Source, &det) catch |err| switch (err) {
        error.OutOfMemory => return null,
    };
}

export fn Zicl_DupAsSource(value: Value) ?*objects.Source {
    var det: ErrorDetails = undefined;
    return value.duplicateAsType(objects.Source, &det) catch |err| switch (err) {
        error.OutOfMemory => return null,
    };
}

export fn Zicl_BoxSource(source: *objects.Source) Value {
    return source.asHead().asValue();
}

export fn Zicl_DropRefSource(source: *objects.Source) void {
    source.asHead().dropReference();
}

export fn Zicl_RefSource(source: *objects.Source) *objects.Source {
    source.asHead().incrRefCount();
    return source;
}

export fn Zicl_SourceGetFilename(source: Value) ?[*:0]const u8 {
    const as_source = source.asType(objects.Source) orelse return null;
    const file_name = as_source.file_name.asValue() orelse return null;
    return file_name.getString() catch return null;
}

export fn Zicl_SourceGetLine(source: Value) c_int {
    const as_source = source.asType(objects.Source) orelse return -1;
    return @intCast(as_source.line_no);
}

export fn Zicl_AttachSource(value: *Value, filename: [*:0]const u8, line_no: c_int) ReturnCode {
    const bytes = value.getString() catch return .oom;

    const file_name = objects.String.newValue(std.mem.span(filename)) catch return .oom;
    // `Source.new` borrows `file_name`, so the constructing reference is ours
    // to drop either way.
    defer file_name.dropReference();

    const source = objects.Source.new(bytes, file_name.asOptional(), @intCast(line_no)) catch return .oom;
    value.swap(source.asHead().asValue());
    return .ok;
}

// ===== Interpreter =====
// See the header docs for the contract.

export fn Zicl_RegisterLazyFn(name: [*:0]const u8, library: [*:0]const u8, init_fn: heap.LazyRegisterFn) ReturnCode {
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
) ReturnCode {
    interp.registerCommand(std.mem.span(name), .{
        .call_info = .{ .c = to_call },
        .description = std.mem.span(description),
        .min_arity = @intCast(min_arity),
        .max_arity = std.math.cast(usize, max_arity),
    }) catch |err| return ReturnCode.fromError(err);
    return .ok;
}

export fn Zicl_EvalValue(interp: *Interp, script: Value) ReturnCode {
    return ReturnCode.fromErrorUnion(interp.evalValue(script));
}

export fn Zicl_Eval(interp: *Interp, script: [*:0]const u8) ReturnCode {
    const script_value = objects.String.newValue(std.mem.span(script)) catch return .oom;
    defer script_value.dropReference();
    return Zicl_EvalValue(interp, script_value);
}

export fn Zicl_EvalFile(interp: *Interp, filename: [*:0]const u8) ReturnCode {
    return ReturnCode.fromErrorUnion(interp.evalFile(std.mem.span(filename)));
}

const ClosureHandle = Interp.ClosureAndCacheKey;
export fn Zicl_GetClosure(interp: *Interp, closure_value: Value, out: *?*ClosureHandle) ReturnCode {
    out.* = null;
    // `getClosure` returns the closure already borrowed for us.
    const closure_and_key = interp.getClosure(closure_value, false) catch |err| return ReturnCode.fromError(err);

    const handle = heap.global_gpa.create(ClosureHandle) catch {
        closure_and_key.closure.asHead().dropReference();
        return .oom;
    };
    handle.* = closure_and_key;

    out.* = handle;
    return .ok;
}

/// Release a handle obtained from Zicl_GetClosure.
export fn Zicl_DropClosure(closure: *ClosureHandle) void {
    closure.closure.asHead().dropReference();
    heap.global_gpa.destroy(closure);
}

/// Call `closure` the same way the interpreter calls a closure it resolved
/// from a command name: `argv[0]` fills the command-name slot, `argv[1..argc]`
/// are its arguments. Letrec-bound closures are not reachable through this
/// entry point yet, so its scope is always null. The result is left on the
/// interpreter; read it with Zicl_GetResult.
export fn Zicl_CallClosure(
    interp: *Interp,
    closure: *ClosureHandle,
    argc: c_int,
    argv: [*]Shimmerable,
) ReturnCode {
    const args = argv[0..@intCast(argc)];
    // Usually the stack trace gets cleared with value evaluation,
    // but we have to do it manually here.
    interp.stack_trace.swapWithNone();
    // Use the higher level `invokeCommand` so tailcalls are handled.
    const command_variant: Interp.CommandVariant = .{ .closure = closure.* };
    return ReturnCode.fromErrorUnion(interp.invokeCommand(&command_variant, args));
}

/// The closure's body, as a value borrowed from `closure` (valid only while
/// `closure` is alive; borrow it yourself to keep it longer). Pass it to
/// Zicl_AsSource / Zicl_SourceGetFilename / Zicl_SourceGetLine to read its
/// file/line info, if any was attached.
export fn Zicl_ClosureGetBody(closure: *const ClosureHandle) Value {
    return closure.closure.content.body;
}

/// The closure's captured lexical scope, borrowed from `closure` (valid only
/// while `closure` is alive), or null if it has none. Look up a name in it
/// with Zicl_ShimDictGet, which follows ~parent links, so this reaches
/// variables from enclosing scopes too, not just this closure's own.
export fn Zicl_ClosureGetScope(closure: *const ClosureHandle) ?*Dictionary {
    return closure.closure.content.scope;
}

/// The current error's call stack, as a flat list of {name file line args}
/// groups repeated once per frame (innermost first), or an empty list if
/// there is none. Unlike Zicl_MakeErrorMessage, this doesn't consume or
/// reformat the interpreter's result -- it's a separate, structured read of
/// the same trace Zicl_MakeErrorMessage would render into prose.
export fn Zicl_GetErrorStack(interp: *Interp) Value {
    return interp.stack_trace.orEmpty();
}

export fn Zicl_LoadLibrary(interp: *Interp, path: [*:0]const u8) ReturnCode {
    return ReturnCode.fromErrorUnion(load.loadLibrary(interp, std.mem.span(path)));
}

export fn Zicl_GetScriptBeingEvaluated(interp: *Interp) Value {
    return interp.evalFrame().currently_evaluating;
}

/// The name of the closure currently executing in the current call frame,
/// referenced from the frame (valid only while it remains on the stack).
/// ZICL_NONE for the top-level frame, or a closure invoked without a name
/// (e.g. [apply] on a literal).
export fn Zicl_GetClosureNameBeingEvaluated(interp: *Interp) OptionalValue {
    return interp.callFrame().signature.name;
}

export fn Zicl_CurrentEvalFrameIdx(interp: *Interp) u32 {
    return interp.evalFrameIdx();
}

// Borrowed from the frame: valid only while that frame remains on the stack.
export fn Zicl_EvalFrameScript(interp: *Interp, frame: u32) Value {
    assert(frame < interp.eval_frames.items.len);
    return interp.eval_frames.items[frame].currently_evaluating;
}

export fn Zicl_GetResult(interp: *Interp) Value {
    return interp.result;
}

export fn Zicl_SetResult(interp: *Interp, value: Value) void {
    interp.setResult(value);
}

export fn Zicl_SetResultOwning(interp: *Interp, value: Value) void {
    interp.setResultOwning(value);
}

export fn Zicl_SetResultString(interp: *Interp, str: [*:0]const u8, len: c_int) ReturnCode {
    const bytes = if (len < 0) std.mem.span(str) else str[0..@intCast(len)];
    interp.setResultString(bytes) catch |err| return ReturnCode.fromError(err);
    return .ok;
}

// setErrorString sets the result to `bytes` and then returns error.EvalError to
// propagate the error code, so this always returns ZICL_ERR on the success path
// and ZICL_OOM only if storing the string allocates and fails.
export fn Zicl_SetErrorString(interp: *Interp, str: [*:0]const u8, len: c_int) ReturnCode {
    const bytes = if (len < 0) std.mem.span(str) else str[0..@intCast(len)];
    return ReturnCode.fromError(interp.setErrorString(bytes));
}

export fn Zicl_SetResultBool(interp: *Interp, value: c_int) ReturnCode {
    interp.setResultBoolean(value != 0);
    return .ok;
}

export fn Zicl_SetResultLong(interp: *Interp, value: c_long) ReturnCode {
    interp.setResultInteger(value);
    return .ok;
}

export fn Zicl_SetEmptyResult(interp: *Interp) ReturnCode {
    interp.setEmptyResult();
    return .ok;
}

export fn Zicl_SetVariable(interp: *Interp, name: *Shimmerable, value: Value) ReturnCode {
    interp.setVariable(name, value) catch |err| return ReturnCode.fromError(err);
    return .ok;
}

export fn Zicl_SetVariableString(interp: *Interp, name: [*:0]const u8, value: Value) ReturnCode {
    var name_shim: Shimmerable = .{ .original = objects.String.newValue(std.mem.span(name)) catch return .oom };
    defer name_shim.deinit();
    interp.setVariable(&name_shim, value) catch |err| return ReturnCode.fromError(err);
    return .ok;
}

export fn Zicl_MakeErrorMessage(interp: *Interp) ReturnCode {
    // The stack is a flat list: {name file line args ...} repeated.
    var stack_shim: Shimmerable = .{ .original = interp.stack_trace.orEmpty().takeReference() };
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
export fn Zicl_RequestStop(interp: *Interp) void {
    interp.stop_executing.store(true, .monotonic);
}

// Reads are monotonic, matching the store in `Zicl_RequestStop`.
export fn Zicl_StopRequested(interp: *Interp) bool {
    return interp.stop_executing.load(.monotonic);
}

export fn Zicl_ClearStop(interp: *Interp) void {
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

export fn Zicl_CapNew(head: *Capability.Head, out: *Value) ReturnCode {
    head.state = .init(.{ .in_flight = 0, .close_initiated = false });
    head.ref_count = .init(1);
    head.id = .not_set;
    const cap = Capability.newTakingOwnership(head) catch return .oom;
    out.* = cap.asHead().asValue();
    return .ok;
}

export fn Zicl_ResolveCap(
    interp: *Interp,
    shim: *Shimmerable,
    expected: *const Capability.Head.VTable,
    out: *?*Capability.Head,
) ReturnCode {
    out.* = null;

    var det: ErrorDetails = undefined;
    const cap = interp.wrapError(&det, Capability.shimmerFrom(&det, shim)) catch |err| return ReturnCode.fromError(err);
    if (cap.head.vtable != expected) return ReturnCode.fromError(interp.wrapError(
        &det,
        Capability.wrongCapabilityTypeError(&det, expected.name, cap.head.vtable.name),
    ));
    cap.head.markInFlight() catch {
        const cap_value = shim.getString() catch return .oom;
        return ReturnCode.fromError(interp.wrapError(&det, Capability.staleError(&det, cap_value)));
    };
    return cap.head;
}

export fn Zicl_CapTakeRef(head: *Capability.Head) *Capability.Head {
    return head.takeReference();
}

export fn Zicl_CapDropRef(head: *Capability.Head) void {
    head.dropReference();
}

export fn Zicl_CapClose(head: *Capability.Head) void {
    head.close();
}

export fn Zicl_CapIsClosed(head: *Capability.Head) bool {
    return head.hasCloseBeenInitiated();
}

export fn Zicl_CapDropInFlight(head: *Capability.Head) void {
    head.dropInFlight();
}

export fn Zicl_NewFileCapFromFd(descriptor: i32, out: *Value) ReturnCode {
    const file = capabilities.File.createFromDescriptor(descriptor, false, false) catch return .oom;
    const capability = Capability.newTakingOwnership(&file.head) catch return .oom;
    out.* = capability.asHead().asValue();
    return .ok;
}

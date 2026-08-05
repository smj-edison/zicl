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

    const file = ioutil.lockStderr();
    defer ioutil.unlockStderr();

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
    const file = ioutil.lockStderr();
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

export fn Zicl_SetGlobalStdout(fd: c_int) callconv(.c) void {
    ioutil.global_stdout_fd.store(fd, .monotonic);
}
export fn Zicl_SetGlobalStderr(fd: c_int) callconv(.c) void {
    ioutil.global_stderr_fd.store(fd, .monotonic);
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

// ===== Strings =====
// The string representation is the source of truth for every value, so these
// are the most general accessors. `Zicl_String` and `Zicl_GetString` generate
// the string rep on demand, which can allocate (and so return NULL on OOM).

export fn Zicl_NewString(out: *Value, ptr: [*:0]const u8, len: c_int) callconv(.c) ReturnCode {
    const bytes = if (len < 0) std.mem.span(ptr) else ptr[0..@intCast(len)];
    out.* = objects.String.newValue(bytes) catch return .oom;
    return .ok;
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

export fn Zicl_DecrRefCount(value: Value) callconv(.c) void {
    value.release();
}

export fn Zicl_IncrRefCount(value: Value) callconv(.c) Value {
    return value.borrow();
}

export fn Zicl_AsPtr(value: Value) callconv(.c) ?*heap.Object {
    return value.asPtr();
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

// ===== Numbers =====
// Integer, float, and boolean values are stored inline, so the constructors
// cannot fail. The coercions shimmer a value into the requested type through a
// shimmerable, so they can fail (ZICL_OOM) or report a parse error (ZICL_ERR).

export fn Zicl_NewInt(value: i64) callconv(.c) Value {
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

/// Wrap an owned list handle as a value, transferring ownership (no refcount
/// change). The caller must not touch `list` afterwards.
export fn Zicl_BoxListOwning(list: *List) callconv(.c) Value {
    return list.asHead().asValue();
}

/// Release an owned list handle (error path).
export fn Zicl_ListRelease(list: *List) callconv(.c) void {
    list.asHead().release();
}

/// Copy-on-write in-place entry point. If `value` is uniquely owned, `*out` is a
/// borrowed mutable view of the same object (no copy); if it is shared,
/// cross-thread, or a primitive, `*out` is NULL and the caller must
/// `Zicl_DupAsList`. A borrowed view is not owned: do not pass it to
/// `Zicl_ListRelease` or `Zicl_ListShimmerWriteback`.
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

/// Commit an owned duplicate back, releasing the old `value` it replaces. Only
/// for the `Zicl_DupAsList` branch; in-place mutation needs no writeback. The
/// caller keeps `list` and stores it via `Zicl_BoxListOwning`. The assert checks
/// the dup-branch invariant: `list` is the new object and `value` is the old, so
/// they must differ -- calling this from the in-place branch (where `list` is
/// `value`'s own object) would release the very object the caller is using.
export fn Zicl_ListShimmerWriteback(list: *List, value: Value) callconv(.c) void {
    assert(value.asPtr() != list.asHead());
    value.release();
}

// ===== Dicts =====
// Dictionaries use the same copy-on-write shape as lists; `Zicl_DictPut` hides
// the two branches internally, picking in-place mutation when the dict is
// uniquely owned and duplicating otherwise.

export fn Zicl_NewDict(out: *Value, values: ?[*]Value, n_values: c_int) callconv(.c) ReturnCode {
    const items = if (values) |ptr| ptr[0..@intCast(n_values)] else &.{};
    const dict = Dictionary.new(items) catch return .oom;
    out.* = dict.asHead().asValue();
    return .ok;
}

export fn Zicl_DictPut(interp: *Interp, dict: *Value, key: Value, value: Value) callconv(.c) ReturnCode {
    var det: ErrorDetails = undefined;
    if (interp.wrapError(&det, dict.asMutableInPlace(Dictionary, &det))) |maybe_mut| {
        if (maybe_mut) |dict_mut| {
            dict_mut.put(key, value) catch |err| return ReturnCode.fromError(narrowError(err));
        } else {
            const dict_mut = interp.wrapError(&det, dict.duplicateAsType(Dictionary, &det)) catch |err| {
                return ReturnCode.fromError(err);
            };
            dict_mut.put(key, value) catch |err| {
                dict_mut.asHead().release();
                return ReturnCode.fromError(narrowError(err));
            };
            dict.swap(dict_mut.asHead().asValue());
        }
    } else |err| return ReturnCode.fromError(err);
    return .ok;
}

// ===== Source =====
// A `Source` carries file/line metadata alongside a value's bytes, so
// evaluation errors can point at the originating location. The location is
// fixed at construction, so `Zicl_AttachSource` replaces the slot with a copy
// rather than annotating the existing object.

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
/// errors report the right file and line. A `Source` fixes its location at
/// construction, so this cannot annotate the existing object; the slot gets a
/// copy and the caller's original reference is released on success.
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

export fn Zicl_RegisterNativeFn(name: [*:0]const u8, init_fn: heap.NativeInitFn) callconv(.c) ReturnCode {
    heap.nativefn_registry.register(heap.global_gpa, std.mem.span(name), init_fn) catch |err| switch (err) {
        error.OutOfMemory => return .oom,
        error.DuplicateNativeFn => return .@"error",
    };
    return .ok;
}

export fn Zicl_CreateCommand(
    interp: *Interp,
    name: [*:0]const u8,
    command: *const evaltypes.CCommandFn,
) callconv(.c) ReturnCode {
    interp.registerCommand(std.mem.span(name), .{
        .call_info = .{ .c = command },
        .description = null,
        .min_arity = 0,
        .max_arity = null,
        .multiple_of = null,
    }) catch |err| return ReturnCode.fromError(err);
    return .ok;
}

export fn Zicl_EvalObject(interp: *Interp, script: Value) callconv(.c) ReturnCode {
    return ReturnCode.fromErrorUnion(interp.evalObject(script));
}

export fn Zicl_EvalFile(interp: *Interp, filename: [*:0]const u8) callconv(.c) ReturnCode {
    return ReturnCode.fromErrorUnion(interp.evalFile(std.mem.span(filename)));
}

export fn Zicl_GetScriptBeingEvaluated(interp: *Interp) callconv(.c) Value {
    return interp.evalFrame().currently_evaluating;
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

export fn Zicl_SetResultBool(interp: *Interp, value: c_int) callconv(.c) ReturnCode {
    interp.setResultBoolean(value != 0);
    return .ok;
}

export fn Zicl_SetResultInt(interp: *Interp, value: c_long) callconv(.c) ReturnCode {
    interp.setResultInteger(value) catch |err| return ReturnCode.fromError(err);
    return .ok;
}

export fn Zicl_SetEmptyResult(interp: *Interp) callconv(.c) void {
    interp.setEmptyResult();
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

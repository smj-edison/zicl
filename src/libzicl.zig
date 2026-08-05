const std = @import("std");

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
const ReturnCode = evaltypes.ReturnCode;
const commands = @import("commands/common.zig");
const leak_check = @import("leak_check.zig");
const ioutil = @import("ioutil.zig");

// Allow user to change the default logging fd.
pub const panic = std.debug.FullPanic(ziclPanic);
pub const std_options: std.Options = .{ .logFn = ziclLog };

// Mirrors debug.zig's threadlocal panic_stage to guard against recursive panics.
threadlocal var zicl_panic_stage: usize = 0;

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

export fn Zicl_SetGlobalStdout(fd: c_int) callconv(.c) void {
    ioutil.global_stdout_fd.store(fd, .monotonic);
}
export fn Zicl_SetGlobalStderr(fd: c_int) callconv(.c) void {
    ioutil.global_stderr_fd.store(fd, .monotonic);
}

extern fn dumpLastTouchedTrace(fd: i32) void;

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

// Basic object commands.
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

export fn Zicl_DecrRefCount(value: Value) callconv(.c) void {
    value.release();
}

export fn Zicl_IncrRefCount(value: Value) callconv(.c) Value {
    return value.borrow();
}

export fn Zicl_AsPtr(value: Value) callconv(.c) ?*heap.Object {
    return value.asPtr();
}

// `Shimmerable.current` exposed under the name the C header declares.
export fn Zicl_Current(shim: Shimmerable) callconv(.c) Value {
    return shim.current();
}

// Number functions. Primitives are inline, so these never allocate and cannot fail.
export fn Zicl_NewInt(value: i64) callconv(.c) Value {
    return objects.Integer.new(value);
}

export fn Zicl_NewDouble(value: f64) callconv(.c) Value {
    return objects.Float.new(value);
}

export fn Zicl_NewBool(value: bool) callconv(.c) Value {
    return objects.Boolean.new(value);
}

export fn Zicl_GetLong(interp: *Interp, value: *Value, out: *c_long) callconv(.c) ReturnCode {
    out.* = interp.getIntegerInPlace(value) catch |err| return ReturnCode.fromError(err);
    return .ok;
}

export fn Zicl_GetDouble(interp: *Interp, value: *Value, out: *f64) callconv(.c) ReturnCode {
    var shim: Shimmerable = .{ .original = value.* };
    errdefer shim.discardChanges();
    out.* = interp.getFloat(&shim) catch |err| return ReturnCode.fromError(err);
    value.* = shim.consume();
    return .ok;
}

export fn Zicl_GetBoolean(interp: *Interp, value: *Value, out: *c_int) callconv(.c) ReturnCode {
    const result = interp.getBooleanInPlace(value) catch |err| return ReturnCode.fromError(err);
    out.* = if (result) 1 else 0;
    return .ok;
}

// List functions.
export fn Zicl_NewList(out: *Value, values: ?[*]Value, n_values: c_int) callconv(.c) ReturnCode {
    const items = if (values) |ptr| ptr[0..@intCast(n_values)] else &.{};
    const list = List.new(items) catch return .oom;
    out.* = list.asHead().asValue();
    return .ok;
}

export fn Zicl_ListLength(interp: *Interp, list: *Value) callconv(.c) c_int {
    const as_list = interp.getListInPlace(list) catch return -1;
    return @intCast(as_list.items.len);
}

/// The returned value is borrowed from the list, so it is only valid while the
/// list holds it. Callers that outlive the list need `Zicl_IncrRefCount`.
export fn Zicl_ListGetItem(interp: *Interp, list: *Value, index: u32) callconv(.c) OptionalValue {
    const as_list = interp.getListInPlace(list) catch return .none;
    if (index >= as_list.items.len) return .none;
    return as_list.items[index].asOptional();
}

export fn Zicl_ListAppend(interp: *Interp, list: *Value, item: Value) callconv(.c) ReturnCode {
    var det: ErrorDetails = undefined;
    if (interp.wrapError(&det, list.asMutableInPlace(List, &det))) |maybe_mut| {
        if (maybe_mut) |list_mut| {
            list_mut.append(item) catch |err| return ReturnCode.fromError(narrowError(err));
        } else {
            const list_mut = interp.wrapError(&det, list.duplicateAsType(List, &det)) catch |err| {
                return ReturnCode.fromError(err);
            };
            list_mut.append(item) catch |err| {
                list_mut.asHead().release();
                return ReturnCode.fromError(narrowError(err));
            };
            // The copy is ours, so handing it to the caller's slot transfers
            // our reference along with it.
            list.swap(list_mut.asHead().asValue());
        }
    } else |err| return ReturnCode.fromError(err);
    return .ok;
}

// Dict functions.
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

// Source functions.
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

// Global init functions.
var global_threaded: std.Io.Threaded = undefined;

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

// Interpreter functions.
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

export fn Zicl_GetScriptBeingEvaluated(interp: *Interp) callconv(.c) Value {
    return interp.evalFrame().currently_evaluating;
}

export fn Zicl_EvalObject(interp: *Interp, script: Value) callconv(.c) ReturnCode {
    return ReturnCode.fromErrorUnion(interp.evalObject(script));
}

export fn Zicl_EvalFile(interp: *Interp, filename: [*:0]const u8) callconv(.c) ReturnCode {
    return ReturnCode.fromErrorUnion(interp.evalFile(std.mem.span(filename)));
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

export fn Zicl_SetVariable(interp: *Interp, name: *Value, value: Value) callconv(.c) ReturnCode {
    var name_shim: Shimmerable = .{ .original = name.* };
    errdefer name_shim.discardChanges();
    interp.setVariable(&name_shim, value) catch |err| return ReturnCode.fromError(err);
    name.* = name_shim.consume();
    return .ok;
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

// Object debugging functions.

export fn Zicl_RefCount(value: Value) callconv(.c) u32 {
    const obj = value.asPtr() orelse return 0;
    return obj.getRefCount();
}

export fn Zicl_RefCountPtr(value: Value) callconv(.c) ?*u32 {
    const obj = value.asPtr() orelse return null;
    return &obj.ref_count;
}

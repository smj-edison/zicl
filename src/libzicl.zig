const std = @import("std");

const Heap = @import("Heap.zig");
const Handle = Heap.Handle;
const OptionalHandle = Heap.OptionalHandle;
const objutil = @import("objutil.zig");
const Shimmerable = objutil.Shimmerable;
const Mutable = objutil.Mutable;
const Interp = @import("Interp.zig");
const narrowError = Interp.narrowError;
const ReturnCode = Interp.ReturnCode;
const commands = @import("commands.zig");
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
    const io = Heap.global_io;

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
            var file_writer = file.writerStreaming(Heap.global_io, &.{});
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
            std.Io.File.writeStreamingAll(file, Heap.global_io, "aborting due to recursive panic\n") catch {};
        },
        else => {},
    }
    std.process.abort();
}

fn errorToOptional(result: anyerror!Handle) OptionalHandle {
    if (result) |handle| {
        return handle.toOptional();
    } else |_| {
        return .none;
    }
}

// Basic object commands.
export fn Zicl_NewString(ptr: [*:0]const u8, len: c_int) callconv(.c) OptionalHandle {
    const bytes = if (len < 0) std.mem.span(ptr) else ptr[0..@intCast(len)];
    return errorToOptional(objutil.newString(bytes));
}

export fn Zicl_String(object: Handle) callconv(.c) ?[*:0]const u8 {
    return object.getString() catch return null;
}

export fn Zicl_GetString(object: Handle, len: *c_int) callconv(.c) ?[*:0]const u8 {
    const str = object.getString() catch return null;
    len.* = @intCast(str.len);
    return str;
}

export fn Zicl_DecrRefCount(handle: Handle) callconv(.c) void {
    handle.decrRefCount();
}

// List functions.
export fn Zicl_NewList(handles: ?[*]Handle, n_handles: c_int) callconv(.c) OptionalHandle {
    if (handles) |val| {
        const new_list = objutil.newList(val[0..@intCast(n_handles)]) catch return .none;
        return new_list.toOptional();
    } else {
        return (objutil.newList(&.{}) catch return .none).toOptional();
    }
}

export fn Zicl_ListGetItem(list: Handle, index: u32) callconv(.c) Handle {
    return objutil.listItem(list, index);
}

export fn Zicl_ListLength(interp: *Interp, list: *Handle) callconv(.c) c_int {
    const len = interp.getListLengthInPlace(list) catch return -1;
    return @intCast(len);
}

export fn Zicl_ListAppend(interp: *Interp, list: *Handle, item: Handle) callconv(.c) ReturnCode {
    _ = interp.listAppendInPlace(list, item) catch |err| return ReturnCode.fromError(err);
    return .ok;
}

// Dict functions.
export fn Zicl_NewDict(handles: ?[*]Handle, n_handles: c_int) callconv(.c) OptionalHandle {
    if (handles) |val| {
        const new_list = objutil.newDict(val[0..@intCast(n_handles)]) catch return .none;
        return new_list.toOptional();
    } else {
        return (objutil.newDict(&.{}) catch return .none).toOptional();
    }
}

export fn Zicl_DictPut(interp: *Interp, dict: *Handle, key: Handle, value: Handle) callconv(.c) ReturnCode {
    _ = interp.putDictValueInPlace(dict, key, value) catch |err| return ReturnCode.fromError(err);
    return .ok;
}

// Number functions.
export fn Zicl_GetLong(interp: *Interp, handle: *Handle, out: *c_long) callconv(.c) ReturnCode {
    out.* = interp.getIntegerInPlace(handle) catch |err| return ReturnCode.fromError(err);
    return .ok;
}

export fn Zicl_GetDouble(interp: *Interp, handle: *Handle, out: *f64) callconv(.c) ReturnCode {
    var wb: Shimmerable = .{ .original = handle.* };
    out.* = interp.getFloat(&wb) catch |err| return ReturnCode.fromError(err);
    handle.* = wb.consume();
    return .ok;
}

export fn Zicl_GetBoolean(interp: *Interp, handle: *Handle, out: *c_int) callconv(.c) ReturnCode {
    const result = interp.getBooleanInPlace(handle) catch |err| return ReturnCode.fromError(err);
    out.* = if (result) 1 else 0;
    return .ok;
}

// Source functions.
export fn Zicl_SourceGetFilename(source: Handle) callconv(.c) ?[*:0]const u8 {
    if (objutil.getSourceInfo(source)) |info| if (info.file_name.toHandle()) |name| {
        return name.getString() catch return null;
    };
    return null;
}

export fn Zicl_SourceGetLine(source: Handle) callconv(.c) c_int {
    if (objutil.getSourceInfo(source)) |info| {
        return @intCast(info.line_no);
    } else return -1;
}

/// Attaches source location to a handle so that evaluation errors report the
/// correct file and line. The `filename` string is heap-allocated and owned
/// by the source extra-data; `destroyExtraData` releases it.
export fn Zicl_SourceSetInfo(handle: Handle, filename: [*:0]const u8, line_no: c_int) callconv(.c) ReturnCode {
    const file_handle = objutil.newString(std.mem.span(filename)) catch return .oom;
    // `file_handle` starts at refcount 1. `setSourceInfo` borrows it without
    // incrementing, so that single count is owned by the extra-data. When the
    // extra-data is destroyed or replaced, it calls `decrOptional()` to release it.
    objutil.setSourceInfo(handle, .{
        .file_name = file_handle.toOptional(),
        .line_no = @intCast(line_no),
    }) catch {
        file_handle.decrRefCount();
        return .oom;
    };
    return .ok;
}

// Global init functions.
var global_threaded: std.Io.Threaded = undefined;
export fn Zicl_InitGlobals() ReturnCode {
    global_threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
    Heap.initGlobals(std.heap.c_allocator, global_threaded.io()) catch return ReturnCode.@"error";
    return .ok;
}

export fn Zicl_InitLocalHeap() ReturnCode {
    Heap.initLocalHeap() catch return ReturnCode.@"error";
    return .ok;
}

export fn Zicl_DeinitAll() callconv(.c) void {
    Heap.deinitAll();
}

export fn Zicl_LeakCheckAll() callconv(.c) void {
    Heap.leakCheckAll();
}

// Interpreter functions.
export fn Zicl_CreateInterp() callconv(.c) ?*Interp {
    // Store the interpreter on the heap, so it's an opaque pointer.
    const interp = Heap.global_gpa.create(Interp) catch return null;
    errdefer Heap.global_gpa.destroy(interp);
    interp.* = Interp.init() catch return null;
    errdefer interp.deinit();

    commands.registerCoreCommands(interp) catch return null;

    return interp;
}

export fn Zicl_InterpDestroy(interp: *Interp) callconv(.c) void {
    interp.deinit();
    Heap.global_gpa.destroy(interp);
}

export fn Zicl_RegisterNativeFn(name: [*:0]const u8, init_fn: Heap.NativeInitFn) callconv(.c) ReturnCode {
    Heap.nativefn_registry.register(Heap.global_gpa, std.mem.span(name), init_fn) catch |err| switch (err) {
        error.OutOfMemory => return .oom,
        error.DuplicateNativeFn => return .@"error",
    };
    return .ok;
}

export fn Zicl_CreateCommand(
    interp: *Interp,
    name: [*:0]const u8,
    command: *const Interp.CCommandFn,
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

export fn Zicl_GetScriptBeingEvaluated(interp: *Interp) callconv(.c) Handle {
    return interp.currentEvalFrame().currently_evaluating;
}

export fn Zicl_EvalObject(interp: *Interp, script: Handle) callconv(.c) Interp.ReturnCode {
    return Interp.ReturnCode.fromErrorUnion(interp.evalObject(script));
}

export fn Zicl_EvalFile(interp: *Interp, filename: [*:0]const u8) callconv(.c) Interp.ReturnCode {
    return Interp.ReturnCode.fromErrorUnion(interp.evalFile(std.mem.span(filename)));
}

export fn Zicl_GetResult(interp: *Interp) callconv(.c) Handle {
    return interp.result;
}

export fn Zicl_SetResult(interp: *Interp, handle: Handle) callconv(.c) void {
    interp.setResult(handle);
}

export fn Zicl_SetResultOwning(interp: *Interp, handle: Handle) callconv(.c) void {
    interp.setResultOwning(handle);
}

export fn Zicl_SetVariable(interp: *Interp, name: *Handle, handle: Handle) callconv(.c) ReturnCode {
    var name_wb: Shimmerable = .{ .original = name.* };
    interp.setVariableTo(&name_wb, handle) catch |err| return ReturnCode.fromError(err);
    name.* = name_wb.consume();
    return .ok;
}

export fn Zicl_SetResultString(interp: *Interp, str: [*:0]const u8, len: c_int) ReturnCode {
    const bytes = if (len < 0) std.mem.span(str) else str[0..@intCast(len)];
    interp.setResultString(bytes) catch |err| return ReturnCode.fromError(err);
    return .ok;
}

export fn Zicl_SetResultBool(interp: *Interp, value: c_int) ReturnCode {
    interp.setResultBoolean(value != 0) catch |err| return ReturnCode.fromError(err);
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
    const msg = Interp.makeErrorMessage(
        interp.result,
        interp.stack_trace.orEmpty(),
    ) catch |err| return ReturnCode.fromError(narrowError(err));
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

export fn Zicl_Tag(handle: Handle) callconv(.c) u8 {
    return @intFromEnum(handle.tag());
}

export fn Zicl_Peek(handle: Handle) callconv(.c) *Heap.Object {
    return handle.peek();
}

export fn Zicl_RefCount(handle: Handle) callconv(.c) u32 {
    const heap = handle.getHeap();
    const ptr = &heap.objects.items(.ref_count)[handle.index];
    if (heap.getLocalMetadata(handle.index).cross_thread) {
        return @atomicLoad(u32, ptr, .monotonic);
    } else {
        return ptr.*;
    }
}

export fn Zicl_RefCountPtr(handle: Handle) callconv(.c) *u32 {
    return &handle.getHeap().objects.items(.ref_count)[handle.index];
}

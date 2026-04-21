const std = @import("std");

const Heap = @import("Heap.zig");
const Handle = Heap.Handle;
const OptionalHandle = Heap.OptionalHandle;
const objutil = @import("objutil.zig");
const Interp = @import("Interp.zig");
const narrowError = Interp.narrowError;
const ReturnCode = Interp.ReturnCode;
const commands = @import("commands.zig");

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
    return objutil.listItemFollowRefs(list, index);
}

export fn Zicl_ListLength(interp: *Interp, list: *Handle) callconv(.c) c_int {
    const len = interp.getListLength(list) catch return -1;
    return @intCast(len);
}

export fn Zicl_ListAppend(interp: *Interp, list: *Handle, item: Handle) callconv(.c) ReturnCode {
    _ = interp.listAppend(list, item) catch |err| return ReturnCode.fromError(err);
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

// Number functions.
export fn Zicl_GetLong(interp: *Interp, handle: *Handle, out: *c_long) callconv(.c) ReturnCode {
    out.* = interp.getInteger(handle) catch |err| return ReturnCode.fromError(err);
    return .ok;
}

export fn Zicl_GetDouble(interp: *Interp, handle: *Handle, out: *f64) callconv(.c) ReturnCode {
    out.* = interp.getFloat(handle) catch |err| return ReturnCode.fromError(err);
    return .ok;
}

export fn Zicl_GetBoolean(interp: *Interp, handle: *Handle, out: *c_int) callconv(.c) ReturnCode {
    const result = interp.getBoolean(handle) catch |err| return ReturnCode.fromError(err);
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

// Global init functions.
var global_threaded: std.Io.Threaded = undefined;
export fn Zicl_InitGlobals() callconv(.c) c_int {
    global_threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
    Heap.initGlobals(std.heap.c_allocator, global_threaded.io()) catch return -1;
    return 0;
}

export fn Zicl_InitLocalHeap() callconv(.c) c_int {
    Heap.initLocalHeap() catch return -1;
    return 0;
}

export fn Zicl_DeinitAll() callconv(.c) void {
    Heap.deinitAll();
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

export fn Zicl_SetResultString(interp: *Interp, str: [*:0]const u8, len: c_int) ReturnCode {
    const bytes = if (len < 0) std.mem.span(str) else str[0..@intCast(len)];
    interp.setResultString(bytes) catch |err| return ReturnCode.fromError(err);
    return .ok;
}

export fn Zicl_SetResultBool(interp: *Interp, value: c_int) ReturnCode {
    interp.setResultBoolean(value != 0) catch |err| return ReturnCode.fromError(err);
    return .ok;
}

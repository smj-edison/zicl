const std = @import("std");

const Heap = @import("Heap.zig");
const Handle = Heap.Handle;
const OptionalHandle = Heap.OptionalHandle;
const objutil = @import("objutil.zig");
const Interp = @import("Interp.zig");
const commands = @import("commands.zig");

fn errorToOptional(result: anyerror!Handle) OptionalHandle {
    if (result) |handle| {
        return handle.toOptional();
    } else |_| {
        return .none;
    }
}

// Basic object commands.
export fn ziclNewString(ptr: [*:0]const u8, len: c_int) callconv(.c) OptionalHandle {
    const bytes = if (len < 0) std.mem.span(ptr) else ptr[0..@intCast(len)];
    return errorToOptional(objutil.newString(bytes));
}

export fn ziclString(object: Handle) callconv(.c) ?[*:0]const u8 {
    return object.getString() catch return null;
}

export fn ziclDecrRefCount(handle: Handle) callconv(.c) void {
    handle.decrRefCount();
}

// Global init functions.
var global_threaded: std.Io.Threaded = undefined;
export fn ziclInitGlobals() callconv(.c) c_int {
    global_threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
    Heap.initGlobals(std.heap.c_allocator, global_threaded.io()) catch return -1;
    return 0;
}

export fn ziclInitLocalHeap() callconv(.c) c_int {
    Heap.initLocalHeap() catch return -1;
    return 0;
}

export fn ziclDeinitAll() callconv(.c) void {
    Heap.deinitAll();
}

// Interpreter functions.
export fn ziclInterpCreate() callconv(.c) ?*Interp {
    // Store the interpreter on the heap, so it's an opaque pointer.
    const interp = Heap.global_gpa.create(Interp) catch return null;
    errdefer Heap.global_gpa.destroy(interp);
    interp.* = Interp.init() catch return null;
    errdefer interp.deinit();

    commands.registerCoreCommands(interp) catch return null;

    return interp;
}

export fn ziclInterpDestroy(interp: *Interp) callconv(.c) void {
    interp.deinit();
    Heap.global_gpa.destroy(interp);
}

export fn ziclEvalObject(interp: *Interp, script: Handle) callconv(.c) Interp.ReturnCode {
    return Interp.ReturnCode.fromError(interp.evalObject(script));
}

export fn ziclGetResult(interp: *Interp) callconv(.c) Handle {
    return interp.result;
}

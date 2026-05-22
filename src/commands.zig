const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

const Heap = @import("Heap.zig");
const Handle = Heap.Handle;
const OptionalHandle = Heap.OptionalHandle;
const objutil = @import("objutil.zig");
const Interp = @import("Interp.zig");

/// [fn]
pub fn fnCmd(args: []Handle) !void {
    assert(args.len == 4);
    const fn_name = &args[1];
    const arglist = &args[2];
    const body = args[3];

    // Capture the current scope.
    const scope = Interp.variables.borrow();

    const closure_obj = try Interp.createClosureObject(.{
        .args = arglist.*,
        .body = body,
        .name = fn_name.toOptional(),
        .scope = scope.toOptional(),
        .required_arity = 1,
        .cache_id = Heap.nextCacheId(),
    });
    defer closure_obj.decrRefCount();

    Interp.setVariableInner(fn_name.*, closure_obj.dupOrRef()) catch unreachable;
}

test "fn command" {
    _ = try Heap.testStart(testing.allocator, testing.io);
    try Interp.init();
    try Interp.registerCommand("fn");

    const fn_str = try objutil.newString(Heap.local_heap, "fn");
    const add_str = try objutil.newString(Heap.local_heap, "add");
    const a_b_str = try objutil.newString(Heap.local_heap, "a b");
    const fn1_body_str = try objutil.newString(Heap.local_heap, " + $a $b ");
    var fn1_args: [4]Handle = .{ fn_str, add_str, a_b_str, fn1_body_str };

    for (fn1_args) |arg| arg.incrRefCount();
    fnCmd(&fn1_args) catch unreachable;
    for (fn1_args) |arg| arg.decrRefCount();

    const addx_str = try objutil.newString(Heap.local_heap, "add");
    const a_str = try objutil.newString(Heap.local_heap, "a b");
    const fn2_body_str = try objutil.newString(Heap.local_heap, " + $a $x ");
    var fn2_args: [4]Handle = .{ fn_str, addx_str, a_str, fn2_body_str };

    for (fn2_args) |arg| arg.incrRefCount();
    fnCmd(&fn2_args) catch unreachable;
    for (fn2_args) |arg| arg.decrRefCount();
}

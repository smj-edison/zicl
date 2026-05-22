const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

const Heap = @import("Heap.zig");
const Handle = Heap.Handle;
const OptionalHandle = Heap.OptionalHandle;
const objutil = @import("objutil.zig");
const Interp = @import("Interp.zig");

/// [set]
pub fn setCmd(interp: *Interp, args: []const Handle) !void {
    var var_name = args[1].borrow();
    defer var_name.decrRefCount();

    try interp.setVariableTo(&var_name, args[2]);
}

/// [fn]
pub fn fnCmd(interp: *Interp, args: []Handle) Interp.Error!void {
    assert(args.len == 4);
    const fn_name = &args[1];
    const arglist = &args[2];
    const body = args[3];

    // Shimmer to list via the interp helper, which handles the case where
    // the handle can't be shimmered in place.
    Interp.shimmerToList(arglist);

    const parsed_args = Interp.parseClosureArgList(arglist.*) catch unreachable;
    defer parsed_args.deinit();

    // Capture the current scope.
    const frame = interp.currentCallFrame();
    const scope = frame.variables.borrow();

    // Build a non-owning closure descriptor. createClosureObject borrows
    // all fields, so we don't need to borrow here.
    const closure_obj = try Interp.createClosureObject(.{
        .args = arglist.*,
        .body = body,
        .name = fn_name.toOptional(),
        .scope = scope.toOptional(),
        .required_arity = parsed_args.required_arity,
        .cache_id = Heap.nextCacheId(),
    });
    defer closure_obj.decrRefCount();

    try interp.setVariableTo(fn_name, closure_obj);
}

pub fn registerCoreCommands(interp: *Interp) !void {
    try interp.registerCommand("fn", .{ .to_call = fnCmd, .description = "name argList body", .min_arity = 2, .max_arity = 3 });
    try interp.registerCommand("set", .{ .to_call = setCmd, .description = "varName ?newValue?", .min_arity = 1, .max_arity = 2 });
}

pub fn testStart(ta: std.mem.Allocator) !Interp {
    errdefer Heap.testFinish();
    _ = try Heap.testStart(ta, testing.io);
    var interp = try Interp.init();
    errdefer interp.deinit();
    try registerCoreCommands(&interp);
    return interp;
}

pub fn testFinish(interp: *Interp) void {
    interp.deinit();
    Heap.testFinish();
}

test "fn command" {
    var interp = try testStart(testing.allocator);
    defer testFinish(&interp);

    const fn_str = try objutil.newString(Heap.local_heap, "fn");
    const add_str = try objutil.newString(Heap.local_heap, "add");
    const a_b_str = try objutil.newString(Heap.local_heap, "a b");
    const fn1_body_str = try objutil.newString(Heap.local_heap, " + $a $b ");
    var fn1_args: [4]Handle = .{ fn_str, add_str, a_b_str, fn1_body_str };

    for (fn1_args) |arg| arg.incrRefCount();
    fnCmd(&interp, &fn1_args) catch unreachable;
    for (fn1_args) |arg| arg.decrRefCount();

    const addx_str = try objutil.newString(Heap.local_heap, "add");
    const a_str = try objutil.newString(Heap.local_heap, "a b");
    const fn2_body_str = try objutil.newString(Heap.local_heap, " + $a $x ");
    var fn2_args: [4]Handle = .{ fn_str, addx_str, a_str, fn2_body_str };

    for (fn2_args) |arg| arg.incrRefCount();
    fnCmd(&interp, &fn2_args) catch unreachable;
    for (fn2_args) |arg| arg.decrRefCount();
}

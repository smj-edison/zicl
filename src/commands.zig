const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

const Heap = @import("Heap.zig");
const Handle = Heap.Handle;
const OptionalHandle = Heap.OptionalHandle;
const objutil = @import("objutil.zig");
const Interp = @import("Interp.zig");

pub fn exprCmd(interp: *Interp, args: []const Handle) Interp.Error!void {
    var expr = args[1].borrow();
    defer expr.decrRefCount();
    const result = try (try interp.evalExpressionInPlace(&expr)).toObject();
    defer result.decrRefCount();
    interp.setResult(result);
}

/// [set]
pub fn setCmd(interp: *Interp, args: []const Handle) !void {
    var var_name = args[1].borrow();
    defer var_name.decrRefCount();

    if (args.len == 2) {
        // Return the value.
        interp.setResult(try interp.getVariableOrError(&var_name));
    } else {
        try interp.setVariableTo(&var_name, args[2]);
        // Return the stored value (may differ from args[2] after upvar follow).
        interp.setResult(try interp.getVariableOrError(&var_name));
    }
}

/// [fn] - creates a closure capturing the current scope and sets it as a
/// variable in the current scope.
pub fn fnCmd(interp: *Interp, args: []Handle) Interp.Error!void {
    assert(args.len == 4);
    const fn_name = &args[1];
    const arglist = &args[2];
    const body = args[3];

    // Shimmer to list via the interp helper, which handles the case where
    // the handle can't be shimmered in place.
    try interp.shimmerToList(arglist);

    var det: objutil.ErrorDetails = undefined;
    const parsed_args = try interp.wrapError(&det, Interp.parseClosureArgList(&det, arglist.*));
    defer parsed_args.deinit();

    // Capture the current scope.
    const scope = try interp.captureCurrentScope();
    defer scope.decrRefCount();

    // Build a non-owning closure descriptor. createClosureObject borrows
    // all fields, so we don't need to borrow here.
    const closure_obj = try Interp.createClosureObject(.{
        .args = arglist.*,
        .body = body,
        .name = fn_name.toOptional(),
        .scope = scope.toOptional(),
        .required_arity = parsed_args.required_arity,
        .optional_arity = parsed_args.optional_arity,
        .optional_values = parsed_args.optional_values,
        .has_args_parameter = parsed_args.has_args_parameter,
        .cache_id = Heap.nextCacheId(),
    });
    defer closure_obj.decrRefCount();

    try interp.setVariableTo(fn_name, closure_obj);
    interp.setResult(try interp.getVariableOrError(fn_name));
}

pub fn registerCoreCommands(interp: *Interp) !void {
    try interp.registerCommand("expr", .{ .to_call = exprCmd, .description = "expression", .min_arity = 1, .max_arity = 1 });
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

const std = @import("std");
pub const assert = std.debug.assert;

pub const heap = @import("../heap.zig");
pub const Value = heap.Value;

pub const objects = @import("../objects.zig");
pub const AlwaysCanBeType = objects.AlwaysCanBeType;
pub const ErrorDetails = objects.ErrorDetails;
pub const Shimmerable = objects.Shimmerable;

pub const Interp = @import("../Interp.zig");

const evaltypes = @import("../evaltypes.zig");
pub const Expression = evaltypes.Expression;

pub fn registerCommand(
    interp: *Interp,
    name: []const u8,
    to_call: evaltypes.CommandFn,
    description: []const u8,
    min_arity: usize,
    max_arity: ?usize,
    stride: ?usize,
) !void {
    try interp.registerCommand(name, .{
        .call_info = .{ .zig = to_call },
        .description = description,
        .min_arity = min_arity,
        .max_arity = max_arity,
        .multiple_of = stride,
    });
}

pub fn registerCoreCommands(interp: *Interp) !void {
    try @import("control_flow.zig").registerCommands(interp);
    try @import("variables.zig").registerCommands(interp);
    try @import("eval.zig").registerCommands(interp);
    try @import("strings.zig").registerCommands(interp);
    try @import("math.zig").registerCommands(interp);
    try @import("misc.zig").registerCommands(interp);
    try @import("dict.zig").registerCommands(interp);
    try @import("io.zig").registerCommands(interp);
    try @import("list.zig").registerCommands(interp);
    try @import("try_catch.zig").registerCommands(interp);
}

pub fn testStart(ta: std.mem.Allocator) !Interp {
    _ = try heap.testStart(ta, std.testing.io);
    errdefer heap.testFinish();
    var interp = try Interp.init(.{});
    errdefer interp.deinit();
    try registerCoreCommands(&interp);
    return interp;
}

pub fn testFinish(interp: *Interp) void {
    interp.deinit();
    heap.testFinish();
}

test {
    _ = @import("control_flow.zig");
    _ = @import("strings.zig");
    _ = @import("math.zig");
    _ = @import("eval.zig");
    _ = @import("variables.zig");
    _ = @import("io.zig");
    _ = @import("list.zig");
    _ = @import("try_catch.zig");
}

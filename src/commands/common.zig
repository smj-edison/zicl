pub const heap = @import("../heap.zig");
pub const Value = heap.Value;

pub const objects = @import("../objects.zig");
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

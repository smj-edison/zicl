const std = @import("std");
const testing = std.testing;

const Heap = @import("Heap.zig");
const object = @import("object.zig");
const Interp = @import("Interp.zig");

/// [puts]
pub fn puts(interp: *Interp, args: []const Heap.Handle) !void {
    if (args.len == 3) {
        const first_arg_str = try Heap.getString(args[1]);
        if (!std.mem.eql(u8, first_arg_str, "-nonewline")) {
            try interp.setResultString("The second argument must be -nonewline");
            return Interp.Error.EvalError;
        } else {
            const to_print = try Heap.getString(args[2]);
            std.debug.print("{s}", .{to_print});
        }
    } else {
        const to_print = try Heap.getString(args[1]);
        std.debug.print("{s}\n", .{to_print});
    }
}

pub fn registerCoreCommands(interp: *Interp) !void {
    try interp.registerCommand("puts", .{ .to_call = puts, .description = "?-nonewline? string", .min_arity = 1, .max_arity = 2, .multiple_of = null });
}

test "commands" {
    defer Heap.testFinish();
    var interp = try Interp.init(try Heap.createHeap(testing.allocator));
    defer interp.deinit();
    try registerCoreCommands(&interp);

    var script = try object.newString(interp.heap, "puts hello");
    defer script.release();
    try interp.evalObject(&script);
}

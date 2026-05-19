const std = @import("std");
const testing = std.testing;

const commands = @import("../commands.zig");
const testStart = commands.testStart;
const testFinish = commands.testFinish;

const ta = std.testing.allocator;

test "fn command" {
    var interp = try testStart(testing.allocator);
    defer testFinish(&interp);

    // Closure captures scope.
    try interp.testExpectScriptResult("15",
        \\ fn add {a b} { + $a $b }
        \\ set x 10
        \\ fn addx {a} { + $a $x }
    );
}

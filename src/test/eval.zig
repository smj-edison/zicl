const std = @import("std");

const commands = @import("../commands.zig");
const testStart = commands.testStart;
const testFinish = commands.testFinish;

const ta = std.testing.allocator;

test "apply named closure" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // Apply a named closure directly via its value.
    try interp.testExpectScriptResult("30",
        \\ fn add {a b} { + $a $b }
        \\ apply $add 10 20
    );
}

test "apply anonymous closure" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // Apply an inline closure without binding it to a name first.
    try interp.testExpectScriptResult("hello world",
        \\ apply [fn {a b} { append a " " $b }] hello world
    );
}

const std = @import("std");

const commands = @import("../commands.zig");
const testStart = commands.testStart;
const testFinish = commands.testFinish;

const ta = std.testing.allocator;

test "parsing" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // Make sure we handle "character after close brace" correctly. It's fine for
    // a bracket to be after a brace in a script context.
    try interp.testExpectScriptResult("2",
        \\ set x [expr {1 + 1}]
        \\ set x
    );

    // It should also work with argument expansion.
    try interp.testExpectScriptResult("3",
        \\ set items {1 2}
        \\ set x [+ {*}$items]
        \\ set x
    );
}

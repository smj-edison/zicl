const std = @import("std");

const commands = @import("../commands.zig");
const testStart = commands.testStart;
const testFinish = commands.testFinish;

const ta = std.testing.allocator;

test "lrepeat basic" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("a a a a a a a a a a", "lrepeat 10 a");
    try interp.testExpectScriptResult("a b c a b c a b c", "lrepeat 3 a b c");
    try interp.testExpectScriptResult("x", "lrepeat 1 x");
}

test "lrepeat zero count" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("", "lrepeat 0 a b c");
    try interp.testExpectScriptResult("", "lrepeat 0");
}

test "lrepeat no element args" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("", "lrepeat 5");
    try interp.testExpectScriptResult("", "lrepeat 1");
}

test "lrepeat nested" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("{0 0 0} {0 0 0} {0 0 0}", "lrepeat 3 [lrepeat 3 0]");
}

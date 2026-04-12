const std = @import("std");

const commands = @import("../commands.zig");
const testStart = commands.testStart;
const testFinish = commands.testFinish;

const ta = std.testing.allocator;

test "arithmetic addition" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("10", "+ 5 5");
    // Make sure it stays as an integer.
    try interp.testExpectScriptResult("9223372036854775807", "+ 9223372036854775807 0");
    // It should report integer overflow if the ints are too big.
    try interp.testExpectScriptError(error.EvalError, "integer overflow", "+ 9223372036854775807 9223372036854775807");
}

test "arithmetic division" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // Make sure it stays as an integer.
    try interp.testExpectScriptResult("2", "/ 12 5");
    try interp.testExpectScriptResult("0", "/ 2 2 2");
    try interp.testExpectScriptError(error.EvalError, "division by zero", "/ 5 0");
}

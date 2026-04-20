const std = @import("std");
const testing = std.testing;

const commands = @import("../commands.zig");
const testStart = commands.testStart;
const testFinish = commands.testFinish;

const Interp = @import("../Interp.zig");
const Heap = @import("../Heap.zig");
const objutil = @import("../objutil.zig");

const ta = std.testing.allocator;

test "variable unset" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("", "set x 5; unset x");
    try interp.testExpectScriptError(error.EvalError, "can't read \"x\": no such variable", "set x 5; unset x; unset x");
    try interp.testExpectScriptResult("", "set x 5; unset x; unset -nocomplain x");
}

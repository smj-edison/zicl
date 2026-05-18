const std = @import("std");

const commands = @import("../commands.zig");
const testStart = commands.testStart;
const testFinish = commands.testFinish;

const ta = std.testing.allocator;

test "subst basic" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("$x", "subst {\\$x}");
    try interp.testExpectScriptError(error.EvalError,
        \\wrong # args: should be "subst ?options? string"
    , "subst");
    try interp.testExpectScriptError(error.EvalError,
        \\bad option "a": must be -nocommands, -novariables, or -nobackslashes
    , "subst a b c");
}

const std = @import("std");

const commands = @import("../commands.zig");
const testStart = commands.testStart;
const testFinish = commands.testFinish;

const ta = std.testing.allocator;

test "append basic" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // Append a single value to a new variable.
    try interp.testExpectScriptResult("hello", "append x hello");
    // Appending again accumulates.
    try interp.testExpectScriptResult("hello world", "append x { world}");
}

test "append multiple values" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // All values are concatenated in order.
    try interp.testExpectScriptResult("abc", "append x a b c");
    try interp.testExpectScriptResult("abcdef", "append x d e f");
}

test "append to unset variable" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // Variable doesn't exist yet — should be created as empty then appended to.
    try interp.testExpectScriptResult("new", "append unset_var new");
    try interp.testExpectScriptResult("new", "set unset_var");
}

test "append no values" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // No values: returns current content without modifying it.
    try interp.testExpectScriptResult("hi",
        \\ set x hi
        \\ append x
    );
    // No values on an unset variable: creates it as empty string.
    try interp.testExpectScriptResult("",
        \\ append never_set
    );
}

test "append return value" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // The return value of append is the new variable contents.
    try interp.testExpectScriptResult("foobar",
        \\ set x foo
        \\ set y [append x bar]
        \\ set y
    );
}

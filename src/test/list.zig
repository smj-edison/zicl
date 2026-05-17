const std = @import("std");

const commands = @import("../commands.zig");
const testStart = commands.testStart;
const testFinish = commands.testFinish;

const ta = std.testing.allocator;

test "lassign basic" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("",
        \\ set x [lassign {a b c} v1 v2 v3]
        \\ set x
    );
    try interp.testExpectScriptResult("a", "set v1");
    try interp.testExpectScriptResult("b", "set v2");
    try interp.testExpectScriptResult("c", "set v3");
}

test "lassign remaining" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // Unassigned elements are returned.
    try interp.testExpectScriptResult("c d",
        \\ lassign {a b c d} v1 v2
    );
    try interp.testExpectScriptResult("a", "set v1");
    try interp.testExpectScriptResult("b", "set v2");
}

test "lassign not enough elements" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // When the list is shorter than the variable count, remaining vars get empty.
    try interp.testExpectScriptResult("",
        \\ lassign {a} v1 v2 v3
    );
    try interp.testExpectScriptResult("a", "set v1");
    try interp.testExpectScriptResult("", "set v2");
    try interp.testExpectScriptResult("", "set v3");
}

test "lassign no variables" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // With no variable names, the whole list is returned unchanged.
    try interp.testExpectScriptResult("a b c", "lassign {a b c}");
}

test "list command basic" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // No args returns empty list.
    try interp.testExpectScriptResult("", "list");

    // Single arg is returned as a one-element list.
    try interp.testExpectScriptResult("a", "list a");

    // Multiple args are combined into a list.
    try interp.testExpectScriptResult("a b c", "list a b c");
}

test "list command preserves strings" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // Strings with spaces are treated as single elements.
    try interp.testExpectScriptResult("{hello world} foo", "list {hello world} foo");

    // Empty string is a valid element.
    try interp.testExpectScriptResult("a {} b", "list a {} b");
}

test "list command nesting" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // Nested lists are preserved as elements.
    try interp.testExpectScriptResult("{a b} {c d}", "list {a b} {c d}");

    // llength verifies the structure.
    try interp.testExpectScriptResult("2", "llength [list {a b} {c d}]");
}

test "join basic" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // Default join string is a space.
    try interp.testExpectScriptResult("a b c", "join {a b c}");

    // Explicit join string.
    try interp.testExpectScriptResult("a,b,c", "join {a b c} ,");

    // Empty join string.
    try interp.testExpectScriptResult("abc", "join {a b c} {}");

    // Empty list returns empty string.
    try interp.testExpectScriptResult("", "join {}");

    // Single element.
    try interp.testExpectScriptResult("hello", "join {hello}");

    // Elements with spaces in them.
    try interp.testExpectScriptResult("hello world,foo bar", "join {{hello world} {foo bar}} ,");

    // Multi-character join string.
    try interp.testExpectScriptResult("a--b--c", "join {a b c} --");
}

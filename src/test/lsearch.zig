const std = @import("std");

const commands = @import("../commands.zig");
const testStart = commands.testStart;
const testFinish = commands.testFinish;

const ta = std.testing.allocator;

test "lsearch exact" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("2", "lsearch -exact {abcd bbcd 123 234 345} 123");
    try interp.testExpectScriptResult("-1", "lsearch -exact {abcd bbcd 123 234 345} 3456");
    try interp.testExpectScriptResult("-1", "lsearch -exact {foo bar cat} ba");
    try interp.testExpectScriptResult("1", "lsearch -exact {foo bar cat} bar");
    // Glob chars treated literally with -exact.
    try interp.testExpectScriptResult("2", "lsearch -exact {xyz bbcc *bc*} *bc*");
}

test "lsearch glob" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // Default mode is glob.
    try interp.testExpectScriptResult("4", "lsearch {abcd bbcd 123 234 345} *5");
    try interp.testExpectScriptResult("0", "lsearch {abcd bbcd 123 234 345} *bc*");
    try interp.testExpectScriptResult("1", "lsearch -glob {xyz bbcc *bc*} *bc*");
}

test "lsearch nocase" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("0", "lsearch -nocase {Foo bar} foo");
    try interp.testExpectScriptResult("1", "lsearch -nocase {foo BAR} bar");
}

test "lsearch not" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // -not returns first element that does NOT match the pattern.
    try interp.testExpectScriptResult("3", "lsearch -not {a a a b a a a} a");
    // All elements match "a", so no element fails to match -- return -1.
    try interp.testExpectScriptResult("-1", "lsearch -not {a a a} a");
    // "a" does not match "b", so index 0 is returned.
    try interp.testExpectScriptResult("0", "lsearch -not {a a a} b");
}

test "lsearch all" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("0 1 4", "lsearch -glob -all {a1 a2 b1 b2 a3 b3} a*");
    try interp.testExpectScriptResult("", "lsearch -glob -all {a1 a2 b1 b2 a3 b3} B*");
    try interp.testExpectScriptResult("2 3 5", "lsearch -glob -all -nocase {a1 a2 b1 b2 a3 b3} B*");
}

test "lsearch inline" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("b1", "lsearch -glob -inline {a1 a2 b1 b2 a3 b3} b*");
    try interp.testExpectScriptResult("", "lsearch -glob -inline {a1 a2 b1 b2 a3 b3} C*");
    try interp.testExpectScriptResult("b1 b2 b3", "lsearch -glob -inline -all {a1 a2 b1 b2 a3 b3} b*");
}

test "lsearch empty list" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("-1", "lsearch {} foo");
    try interp.testExpectScriptResult("", "lsearch -all {} foo");
}

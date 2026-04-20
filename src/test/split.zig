const std = @import("std");

const commands = @import("../commands.zig");
const testStart = commands.testStart;
const testFinish = commands.testFinish;

const ta = std.testing.allocator;

test "split on single char" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("12 3 45", "split 12,3,45 {,}");
    try interp.testExpectScriptResult("a b c", "split a.b.c .");
}

test "split trailing delimiter" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("12 34 56 {}", "split 12,34,56, {,}");
}

test "split empty string" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("", "split {}");
    try interp.testExpectScriptResult("", "split {} {}");
    try interp.testExpectScriptResult("", "split {} ,");
}

test "split into chars" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("1 2 3 4 5", "split 12345 {}");
    try interp.testExpectScriptResult("a b c", "split abc {}");
}

test "split default whitespace" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // Default split collapses whitespace runs (like Tcl's default " " separator).
    try interp.testExpectScriptResult("", "split {   }");
    try interp.testExpectScriptResult("a b", "split {a b}");
    try interp.testExpectScriptResult("hello world", "split {  hello   world  }");
}

test "split multiple delimiters" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // Each char in splitChars is an independent delimiter.
    try interp.testExpectScriptResult("{word 1} {} {} {word 2} {word 3}", "split {word 1xyzword 2zword 3} xyz");
}

test "split with leading delimiter" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("{} 12 {} {} 34 56 {}", "split ,12,,,34,56, {,}");
}

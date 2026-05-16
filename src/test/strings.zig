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

test "concat command" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // No args returns empty string.
    try interp.testExpectScriptResult("", "concat");

    // Single string arg is returned as-is (modulo whitespace trimming).
    try interp.testExpectScriptResult("hello", "concat hello");
    try interp.testExpectScriptResult("hello", "concat {  hello  }");

    // Multiple string args are trimmed and joined with a space.
    try interp.testExpectScriptResult("a b c", "concat a b c");
    try interp.testExpectScriptResult("a b c", "concat {  a  } {  b  } {  c  }");

    // Empty args are dropped.
    try interp.testExpectScriptResult("a b", "concat a {} b");

    // All-list path: result is the concatenated list.
    try interp.testExpectScriptResult("1 2 3 4", "concat {1 2} {3 4}");
    try interp.testExpectScriptResult("1 2 3", "concat {1 2 3} {}");
}

test "string map basic" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // Single-character replacement.
    try interp.testExpectScriptResult("bbbb", "string map {a b} abba");

    // Single-character replacement on single-char string.
    try interp.testExpectScriptResult("b", "string map {a b} a");

    // Multiple replacements with overlapping prefixes.
    // Longer keys are tried first, so "abc" matches before "ab" or "a".
    try interp.testExpectScriptResult("A321*A*321*", "string map {abc 321 ab * a A} aabcabaababcab");
}

test "string map -nocase" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // Case-insensitive single-character replacement.
    try interp.testExpectScriptResult("bbbb", "string map -nocase {a b} Abba");

    // Case-insensitive with overlapping prefixes.
    try interp.testExpectScriptResult("A321*A*321*", "string map -nocase {aBc 321 Ab * a A} aabcabaababcab");

    // One-pair case: longer key wins regardless of case.
    try interp.testExpectScriptResult("a32aBaAb32Ab", "string map -nocase {abc 32} aAbCaBaAbAbcAb");

    // One-pair case with shorter key.
    try interp.testExpectScriptResult("a4321C4321a43214321c4321", "string map -nocase {ab 4321} aAbCaBaAbAbcAb");
}

test "string map error cases" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // Odd number of elements in the mapping list is an error.
    try interp.testExpectScriptError(error.EvalError, "list must contain an even number of elements",
        "string map {a b c} abba");
}

test "string map empty keys" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // Empty key is skipped; the string is returned unchanged.
    try interp.testExpectScriptResult("foo", "string map -nocase {{} abc} foo");

    // Empty key followed by a real key still replaces the real key.
    try interp.testExpectScriptResult("baroo", "string map -nocase {{} abc f bar {} def} foo");
}

test "string map case sensitive" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // Case-sensitive: "Ab" only matches "Ab", not "ab" or "aB".
    try interp.testExpectScriptResult("a4321CaBa43214321c4321", "string map {Ab 4321} aAbCaBaAbAbcAb");
}

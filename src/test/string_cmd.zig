const std = @import("std");

const commands = @import("../commands.zig");
const testStart = commands.testStart;
const testFinish = commands.testFinish;

const ta = std.testing.allocator;

test "string length" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("15", "string length {a little string}");
    try interp.testExpectScriptResult("0", "string length {}");
    try interp.testExpectScriptResult("5", "string length hello");
}

test "string index" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("a", "string index abcde 0");
    try interp.testExpectScriptResult("e", "string index abcde 4");
    try interp.testExpectScriptResult("", "string index abcde 5");
    try interp.testExpectScriptResult("c", "string index abc end");
    try interp.testExpectScriptResult("b", "string index abc end-1");
    try interp.testExpectScriptResult("", "string index abcde -10");
}

test "string compare" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("-1", "string compare abcde abdef");
    try interp.testExpectScriptResult("0", "string compare abcde abcde");
    try interp.testExpectScriptResult("1", "string compare abc ABCDE");
    try interp.testExpectScriptResult("0", "string compare -nocase abcde ABCDE");
    try interp.testExpectScriptResult("-1", "string compare -nocase abcde Abdef");
    try interp.testExpectScriptResult("0", "string compare -length 2 abcde abxyz");
    try interp.testExpectScriptResult("0", "string compare {} {}");
    try interp.testExpectScriptResult("-1", "string compare {} foo");
}

test "string equal" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("0", "string equal abcde abdef");
    try interp.testExpectScriptResult("1", "string equal abcde abcde");
    try interp.testExpectScriptResult("1", "string equal -nocase abcde ABCDE");
    try interp.testExpectScriptResult("0", "string equal -nocase abcde Abdef");
    try interp.testExpectScriptResult("1", "string equal -length 2 abc abde");
    try interp.testExpectScriptResult("1", "string equal {} {}");
    try interp.testExpectScriptResult("0", "string equal {} foo");
}

test "string first" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("12", "string first bq abcdefgbcefgbqrs");
    try interp.testExpectScriptResult("1", "string first bcd abcdefgbcefgbqrs");
    try interp.testExpectScriptResult("-1", "string first a bcd");
    try interp.testExpectScriptResult("1", "string first b abcdefgbcefgbqrs");
    // With start index.
    try interp.testExpectScriptResult("7", "string first b abcdefgbcefgbqrs 2");
}

test "string last" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("7", "string last xx xxxx123xx345x678");
    try interp.testExpectScriptResult("12", "string last x xxxx123xx345x678");
    try interp.testExpectScriptResult("-1", "string last a bcd");
}

test "string range" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("cdefghijklmno", "string range abcdefghijklmnop 2 14");
    try interp.testExpectScriptResult("hijklmnop", "string range abcdefghijklmnop 7 1000");
    try interp.testExpectScriptResult("klmnop", "string range abcdefghijklmnop 10 end");
    try interp.testExpectScriptResult("", "string range abcdefghijklmnop 10 9");
    try interp.testExpectScriptResult("abc", "string range abcdefghijklmnop -3 2");
    try interp.testExpectScriptResult("", "string range abcdefghijklmnop -3 -2");
    try interp.testExpectScriptResult("", "string range abcdefghijklmnop 1000 1010");
    try interp.testExpectScriptResult("op", "string range abcdefghijklmnop end-1 end");
}

test "string tolower" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("abcdef", "string tolower ABCDeF");
    try interp.testExpectScriptResult("123", "string tolower 123");
    try interp.testExpectScriptResult("", "string tolower {}");
}

test "string toupper" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("ABCDEF", "string toupper abCDEf");
    try interp.testExpectScriptResult("123", "string toupper 123");
    try interp.testExpectScriptResult("", "string toupper {}");
}

test "string repeat" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("abcabcabc", "string repeat abc 3");
    try interp.testExpectScriptResult("def", "string repeat def 1");
    try interp.testExpectScriptResult("", "string repeat abc 0");
    try interp.testExpectScriptResult("", "string repeat {} 100");
    try interp.testExpectScriptResult("     ", "string repeat { } 5");
}

test "string trim" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("XYZ", "string trim {    XYZ      }");
    try interp.testExpectScriptResult("A XYZ A", "string trim {  A XYZ A    }");
    try interp.testExpectScriptResult("ABC ", "string trim {XXYYZZABC XXYYZZ} ZYX");
    try interp.testExpectScriptResult("", "string trim {}");
    try interp.testExpectScriptResult("abcdefg", "string trim abcdefg {}");
}

test "string trimleft" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("XYZ      ", "string trimleft {    XYZ      }");
    try interp.testExpectScriptResult("", "string trimleft {   }");
}

test "string trimright" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("    XYZ", "string trimright {    XYZ      }");
    try interp.testExpectScriptResult("", "string trimright {   }");
    try interp.testExpectScriptResult("", "string trimright {}");
}

test "string replace" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // Replace a range with a new value.
    try interp.testExpectScriptResult("aXYZde", "string replace abcde 1 2 XYZ");
    // Delete a range (no replacement).
    try interp.testExpectScriptResult("ade", "string replace abcde 1 2");
    // Replace at start.
    try interp.testExpectScriptResult("Xbcde", "string replace abcde 0 0 X");
    // Replace at end.
    try interp.testExpectScriptResult("abcdX", "string replace abcde end end X");
}

test "string cat" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("helloworld", "string cat hello world");
    try interp.testExpectScriptResult("abc", "string cat a b c");
    try interp.testExpectScriptResult("", "string cat");
}

test "string reverse" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("cba", "string reverse abc");
    try interp.testExpectScriptResult("a", "string reverse a");
    try interp.testExpectScriptResult("", "string reverse {}");
}

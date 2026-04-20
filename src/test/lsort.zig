const std = @import("std");

const commands = @import("../commands.zig");
const testStart = commands.testStart;
const testFinish = commands.testFinish;

const ta = std.testing.allocator;

test "lsort ascii" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("a b c d", "lsort {d c b a}");
    try interp.testExpectScriptResult("", "lsort {}");
    try interp.testExpectScriptResult("a", "lsort {a}");
}

test "lsort decreasing" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("e d c b a", "lsort -decreasing {d e c b a}");
    // Last flag wins.
    try interp.testExpectScriptResult("a b c d e", "lsort -decreasing -increasing {d e c b a}");
}

test "lsort integer" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("6 18 24 300", "lsort -integer {24 6 300 18}");
    try interp.testExpectScriptResult("300 24 18 6", "lsort -integer -decreasing {24 6 300 18}");
}

test "lsort real" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("150e-1 24.2 6e3", "lsort -real {24.2 6e3 150e-1}");
}

test "lsort nocase" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("aa aB ba ce", "lsort -nocase {ba aB aa ce}");
}

test "lsort dictionary" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // Dictionary order: numbers within strings sort numerically.
    try interp.testExpectScriptResult("0k 1k 10k", "lsort -dictionary {1k 0k 10k}");
}

test "lsort unique" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("1 2 3 4", "lsort -integer -unique {3 1 2 3 1 4 3}");
    try interp.testExpectScriptResult("a b c", "lsort -unique {c b a b c}");
}

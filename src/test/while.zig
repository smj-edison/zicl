const std = @import("std");

const commands = @import("../commands.zig");
const testStart = commands.testStart;
const testFinish = commands.testFinish;

const ta = std.testing.allocator;

test "while basic counter" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("10",
        \\ set count 0
        \\ while {$count < 10} { incr count }
        \\ set count
    );
}

test "while condition never true" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("xxx",
        \\ set value xxx
        \\ while {2 > 3} { set value yyy }
        \\ set value
    );
}

test "while returns empty string" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("",
        \\ set x 1
        \\ while {$x} { set x 0 }
    );
}

test "while break" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("6",
        \\ set value 1
        \\ while {1} {
        \\     incr value
        \\     if {$value > 5} { break }
        \\ }
        \\ set value
    );
}

test "while continue" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // Continue skips incrementing result for index 2.
    try interp.testExpectScriptResult("3",
        \\ set i 0
        \\ set sum 0
        \\ while {$i < 4} {
        \\     incr i
        \\     if {$i == 2} { continue }
        \\     incr sum
        \\ }
        \\ set sum
    );
}

test "while nested" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("6",
        \\ set sum 0
        \\ set i 0
        \\ while {$i < 3} {
        \\     set j 0
        \\     while {$j < 2} {
        \\         incr sum
        \\         incr j
        \\     }
        \\     incr i
        \\ }
        \\ set sum
    );
}

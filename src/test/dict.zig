const std = @import("std");
const testing = std.testing;

const commands = @import("../commands.zig");
const testStart = commands.testStart;
const testFinish = commands.testFinish;

const Interp = @import("../Interp.zig");
const Heap = @import("../Heap.zig");
const objutil = @import("../objutil.zig");

const ta = std.testing.allocator;

test "dict unset" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // Dictionaries can be created by unsetting.
    try interp.testExpectScriptResult("", "dict unset nonexistent alsononexistent");
    try interp.testExpectScriptResult("", "set nonexistent"); // Shouldn't error.
}

test "dict commands" {
    var interp = try testStart(testing.allocator);
    defer testFinish(&interp);

    try interp.testExpectScriptError(error.EvalError,
        \\Missing value to go with key when converting "10" to a dictionary.
    ,
        \\ dict set x a 10
        \\ puts [dict get $x a 5]
    );

    try interp.testExpectScriptResult("qux",
        \\ dict set foo bar baz qux
        \\ dict get $foo bar baz
    );
}

test "dict parent links" {
    var interp = try testStart(testing.allocator);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("value",
        \\ set a {key value}
        \\ set b "^parent [hash $a] key2 value2"
        \\ dict get $b key
    );
}

test "dict sugar" {
    var interp = try testStart(testing.allocator);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("a b y 10",
        \\ set x {a b}
        \\ set x::y 10
        \\ set x
    );
}

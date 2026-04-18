const std = @import("std");
const testing = std.testing;

const commands = @import("../commands.zig");
const testStart = commands.testStart;
const testFinish = commands.testFinish;

const Interp = @import("../Interp.zig");
const Heap = @import("../Heap.zig");
const objutil = @import("../objutil.zig");

const ta = std.testing.allocator;

test "catch and error" {
    var interp = try testStart(testing.allocator);
    defer testFinish(&interp);

    // Basic catch -- normal return gives code 0.
    try interp.testExpectScriptResult("0",
        \\ catch { set x 42 }
    );

    // Catch an error -- code 1.
    try interp.testExpectScriptResult("1",
        \\ catch { error "boom" }
    );

    // Capture result variable.
    try interp.testExpectScriptResult("boom",
        \\ catch { error "boom" } msg
        \\ set msg
    );

    // Capture opts variable and check -code.
    try interp.testExpectScriptResult("1",
        \\ catch { error "boom" } msg opts
        \\ dict get $opts -code
    );

    // [error] with a custom error code.
    try interp.testExpectScriptResult("MY CODE",
        \\ catch { error "boom" {MY CODE} } msg opts
        \\ dict get $opts -errorcode
    );
}

test "try command" {
    var interp = try testStart(testing.allocator);
    defer testFinish(&interp);

    // try with on handler matching error.
    try interp.testExpectScriptResult("caught: boom",
        \\ try {
        \\   error "boom"
        \\ } on error {msg} {
        \\   set msg "caught: $msg"
        \\ }
    );

    // try with finally.
    try interp.testExpectScriptResult("done",
        \\ set x "not done"
        \\ try { set x done } finally { set x done }
        \\ set x
    );

    // try with on ok handler.
    try interp.testExpectScriptResult("ok result",
        \\ try { set result "ok result" } on ok {val} { set val }
    );
}

test "return command" {
    var interp = try testStart(testing.allocator);
    defer testFinish(&interp);

    // Basic return from a function.
    try interp.testExpectScriptResult("42",
        \\ fn getval {} { return 42; set x 99 }
        \\ getval
    );
}

test "fn command" {
    var interp = try testStart(testing.allocator);
    defer testFinish(&interp);

    // Basic closure.
    try interp.testExpectScriptResult("30",
        \\ fn add {a b} { + $a $b }
        \\ add 10 20
    );

    // Closure captures scope.
    try interp.testExpectScriptResult("15",
        \\ set x 10
        \\ fn addx {a} { + $a $x }
        \\ addx 5
    );

    // Nested closure captures outer scope via parent_link chain.
    try interp.testExpectScriptResult("15",
        \\ set outer 5
        \\ fn foo {} {
        \\   set inner 10
        \\   fn bar {} { + $inner $outer }
        \\   set bar
        \\ }
        \\ set bar [foo]
        \\ bar
    );

    // Optional parameters.
    try interp.testExpectScriptResult("3",
        \\ fn greet {a {b 3}} { + $a $b }
        \\ greet 0
    );

    // Variadic args parameter.
    try interp.testExpectScriptResult("10 20 30",
        \\ fn collect {args} { set args }
        \\ collect 10 20 30
    );
}

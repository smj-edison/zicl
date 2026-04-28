const std = @import("std");
const testing = std.testing;

const commands = @import("../commands.zig");
const testStart = commands.testStart;
const testFinish = commands.testFinish;

const Interp = @import("../Interp.zig");
const Heap = @import("../Heap.zig");
const objutil = @import("../objutil.zig");

const ta = std.testing.allocator;

test "fn named" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("30",
        \\ fn add {a b} { + $a $b }
        \\ add 10 20
    );
}

test "fn anonymous" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("30",
        \\ apply [fn {a b} { + $a $b }] 10 20
    );
}

test "fn scope capture" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("15",
        \\ set x 10
        \\ fn addx {a} { + $a $x }
        \\ addx 5
    );
}

test "fn nested closure scope" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // `bar` is returned from `foo` and captures both `inner` and `outer`.
    try interp.testExpectScriptResult("15",
        \\ set outer 5
        \\ fn foo {} {
        \\   set inner 10
        \\   fn bar {} { + $inner $outer }
        \\   return $bar
        \\ }
        \\ set bar [foo]
        \\ bar
    );
}

test "fn optional args" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    _ = try interp.testRunScript("fn greet {a {b 3}} { + $a $b }");
    try interp.testExpectScriptResult("3", "greet 0");
    try interp.testExpectScriptResult("7", "greet 3 4");
}

test "fn varargs" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("10 20 30",
        \\ fn collect {args} { set args }
        \\ collect 10 20 30
    );
}

test "fn in dict" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // Exercises the path where a closure lives inside a dict and is retrieved
    // back as a .closure-tagged object, then dispatched.
    try interp.testExpectScriptResult("7",
        \\ fn add {a b} { + $a $b }
        \\ set ops::add $add
        \\ ops::add 3 4
    );
}

test "fn parsing" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // A manually-constructed fn string exercises parseClosure directly, since
    // there is no .closure tag to shortcut through.
    try interp.testExpectScriptResult("30",
        \\ set foo {fn impl {{a b} {+ $a $b}} scope {+ {nativefn +}}}
        \\ foo 10 20
    );
}

test "method as fn" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptError(error.EvalError,
        \\method "greet" cannot be invoked as function
    ,
        \\ method greet {self} { puts "hello" }
        \\ greet
    );
}

test "method anonymous via applymethod" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("{counter 8} 8",
        \\ set method [method {self x} {
        \\   incr self::counter $x
        \\   return $self::counter
        \\ }]
        \\ applymethod $method {counter 5} 3
    );
}

test "method arbitrary self name" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("fido",
        \\ set Dog {name fido}
        \\ method Dog::getName {this} { return $this::name }
        \\ Dog::getName
    );
}

test "method updates self" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("rex",
        \\ set doggo {name fido}
        \\ method doggo::rename {self newName} {
        \\   set self::name $newName
        \\ }
        \\ doggo::rename rex
        \\ dict get $doggo name
    );
}

test "method parseable by applymethod" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("{x 5} 10",
        \\ set method {method impl {{self y} {+ $self::x $y}} scope {+ {nativefn +}}}
        \\ applymethod $method {x 5} 5
    );
}

test "method lexical scope capture" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("55",
        \\ set multiplier 5
        \\ set scoreboard {base 5}
        \\ method scoreboard::score {self scored} { + $self::base [* $scored $multiplier] }
        \\ scoreboard::score 10
    );
}

test "method in nested object" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("15",
        \\ set inner {a 5}
        \\ set outer [dict create inner $inner b 10]
        \\ method outer::inner::frobnicate {self x} {
        \\   return [+ $self::a $x]
        \\ }
        \\ outer::inner::frobnicate 10
    );
}

test "method object copying" {
    // This test makes sure that duplicated objects remain immutable.

    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("fido",
        \\ set Dog::rename [method {self newName} {
        \\   dict set self name $newName
        \\ }]
        \\ set doggo [dict merge $Dog {name fido}]
        \\ set doggoClone $doggo
        \\ doggo::rename rex
        \\ dict get $doggoClone name
    );
}

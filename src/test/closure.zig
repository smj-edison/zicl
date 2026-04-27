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

    try interp.testExpectScriptResult("hello dave",
        \\ method greet {self prepend} { return "$prepend $self::name" }
        \\ greet {name dave} hello
    );
}

test "method anonymous via apply" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("8",
        \\ apply [method {self x} { + $self::current $x }] {current 5} 3
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

test "method reads and returns updated self" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // The method receives the dict as its first arg, modifies it, and returns
    // the updated copy. The caller decides whether to rebind.
    try interp.testExpectScriptResult("rex",
        \\ method rename {self newName} {
        \\   dict set self name $newName
        \\ }
        \\ set dog {name fido}
        \\ set dog [apply $rename $dog rex]
        \\ dict get $dog name
    );
}

test "method string form is parseable by apply" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // Same as the fn string form test, but for methods. Verifies that
    // parseClosure recognises the "method " prefix and sets is_method correctly.
    try interp.testExpectScriptResult("6",
        \\ apply {method impl {{self x} {+ $x 1}} scope {+ {nativefn +}}} {} 5
    );
}

test "method lexical scope capture" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("15",
        \\ set bonus 5
        \\ method score {self base} { + $base $bonus }
        \\ apply $score {} 10
    );
}

// --- dict sugar + method ---
//
// These tests cover methods stored as dict values and dispatched via the
// $dict::key substitution. The `obj::method` command form (which also writes
// the result back to `obj`) is not yet implemented; those cases are marked
// with TODO comments below.

test "method stored in dict, called via apply" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("woof",
        \\ set Dog::bark [method {self} { return woof }]
        \\ set doggo $Dog
        \\ apply $doggo::bark $doggo
    );
}

test "method retrieved via dict sugar reads self" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("fido",
        \\ set Dog::getName [method {self} { dict get $self name }]
        \\ set doggo [dict merge $Dog {name fido}]
        \\ apply $doggo::getName $doggo
    );
}

test "method returns updated self via apply" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    _ = try interp.testRunScript(
        \\ set Dog::rename [method {self newName} {
        \\   dict set self name $newName
        \\ }]
    );
    std.debug.print("Variables: {f}\n", .{interp.currentCallFrame().variables});

    // The method receives the dict, updates it, and returns the new state.
    // The caller rebinds -- this is the manual form of what `doggo::rename rex`
    // will do automatically once method dispatch is implemented.
    try interp.testExpectScriptResult("rex",
        \\ set Dog::rename [method {self newName} {
        \\   dict set self name $newName
        \\ }]
        \\ set doggo [dict merge $Dog {name fido}]
        \\ set doggo [apply $doggo::rename $doggo rex]
        \\ dict get $doggo name
    );
}

test "independent copies are unaffected by method dispatch" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // Value semantics: updating doggo via apply does not affect doggoClone,
    // which was assigned before the call.
    try interp.testExpectScriptResult("fido",
        \\ set Dog::rename [method {self newName} {
        \\   dict set self name $newName
        \\ }]
        \\ set doggo [dict merge $Dog {name fido}]
        \\ set doggoClone $doggo
        \\ set doggo [apply $doggo::rename $doggo rex]
        \\ dict get $doggoClone name
    );
}

// TODO: once `obj::method` command dispatch is implemented, the above tests
// should also work as:
//
//   doggo::rename rex
//   dict get $doggo name  ;# rex
//
//   set doggoClone $doggo
//   doggo::rename rex
//   dict get $doggoClone name  ;# fido -- clone unaffected

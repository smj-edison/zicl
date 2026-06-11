const std = @import("std");
const testing = std.testing;

const commands = @import("../commands.zig");
const testStart = commands.testStart;
const testFinish = commands.testFinish;

const Interp = @import("../Interp.zig");
const Heap = @import("../Heap.zig");
const OptionalHandle = Heap.OptionalHandle;
const objutil = @import("../objutil.zig");
const Mutable = objutil.Mutable;
const Shimmerable = objutil.Shimmerable;

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

test "dict link command" {
    var interp = try testStart(testing.allocator);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("value",
        \\ set a {key value}
        \\ set b {key2 value2}
        \\ set c [dict link $a $b]
        \\ dict get $c key
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

test "dict keys" {
    var interp = try testStart(testing.allocator);
    defer testFinish(&interp);

    // Basic dict keys.
    try interp.testExpectScriptResult("a b", "dict keys {a 1 b 2}");

    // Keys with pattern.
    try interp.testExpectScriptResult("a", "dict keys {a 1 b 2} a*");

    const foo_str = try objutil.newString("foo");
    defer foo_str.decrRefCount();
    const bar_str = try objutil.newString("bar");
    defer bar_str.decrRefCount();
    const baz_str = try objutil.newString("baz");
    defer baz_str.decrRefCount();
    const one_str = try objutil.newString("1");
    defer one_str.decrRefCount();
    const two_str = try objutil.newString("2");
    defer two_str.decrRefCount();
    const three_str = try objutil.newString("3");
    defer three_str.decrRefCount();
    const four_str = try objutil.newString("4");
    defer four_str.decrRefCount();

    // Parent links: parent keys first, then child keys not already present.
    const parent = try objutil.newDict(&.{ foo_str, one_str, bar_str, two_str });
    defer parent.decrRefCount();

    var child: Mutable = .{ .original = try objutil.newDict(&.{
        foo_str, three_str,
        baz_str, four_str,
    }) };
    defer child.deinit();

    const parent_key = Heap.local_heap.getInternedString(.@"^parent");
    _ = try objutil.dictPutObject(&child, parent_key, parent.hashReference());

    {
        var var_name: Shimmerable = .{ .original = try objutil.newString("d") };
        defer var_name.deinit();
        try interp.setVariableTo(&var_name, child.current());
    }

    // foo is in both parent and child; parent foo takes precedence in order.
    // bar is only in parent.
    // baz is only in child.
    // Order: parent keys first (foo, bar), then new child keys (baz).
    try interp.testExpectScriptResult("foo bar baz", "dict keys $d");
}

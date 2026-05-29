const std = @import("std");
const testing = std.testing;

const commands = @import("../commands.zig");
const testStart = commands.testStart;
const testFinish = commands.testFinish;

const Interp = @import("../Interp.zig");
const Heap = @import("../Heap.zig");
const OptionalHandle = Heap.OptionalHandle;
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

    // Parent links: parent keys first, then child keys not already present.
    const heap = Heap.local_heap;
    const parent = try objutil.newDictInner(heap, &.{
        try objutil.newStringInner(heap, "foo"), try objutil.newStringInner(heap, "1"),
        try objutil.newStringInner(heap, "bar"), try objutil.newStringInner(heap, "2"),
    });
    defer parent.decrRefCount();

    const child = try objutil.newDictInner(heap, &.{
        try objutil.newStringInner(heap, "foo"), try objutil.newStringInner(heap, "3"),
        try objutil.newStringInner(heap, "baz"), try objutil.newStringInner(heap, "4"),
    });
    defer child.decrRefCount();

    var new: OptionalHandle = .none;
    errdefer new.decrOptional();
    const parent_key = heap.getInternedString(.@"^parent");
    _ = try objutil.dictPutObject(child, &new, parent_key, parent.hashReference());
    new.swapWithNone();

    {
        var var_name = try objutil.newString("d");
        defer var_name.decrRefCount();
        try interp.setVariableTo(&var_name, child);
    }

    // foo is in both parent and child; parent foo takes precedence in order.
    // bar is only in parent.
    // baz is only in child.
    // Order: parent keys first (foo, bar), then new child keys (baz).
    try interp.testExpectScriptResult("foo bar baz", "dict keys $d");
}

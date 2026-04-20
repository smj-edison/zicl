const std = @import("std");
const testing = std.testing;

const commands = @import("../commands.zig");
const testStart = commands.testStart;
const testFinish = commands.testFinish;

const Interp = @import("../Interp.zig");
const Heap = @import("../Heap.zig");
const objutil = @import("../objutil.zig");

const ta = std.testing.allocator;

/// Get the full stack trace as a Tcl list string: {name file line args} repeated
/// once per call frame, innermost first.
fn traceString(interp: *Interp) ![]const u8 {
    const trace = interp.stack_trace.toHandle() orelse return error.NoStackTrace;
    return trace.getString();
}

test "apply named closure" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("30",
        \\ fn add {a b} { + $a $b }
        \\ apply $add 10 20
    );
}

test "apply anonymous closure" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult("hello world",
        \\ apply [fn {a b} { append a " " $b }] hello world
    );
}

test "stack trace in global frame" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    const script =
        \\ set x 1
        \\ set y 2
        \\ / 1 0
    ;
    try interp.testExpectScriptError(error.EvalError, "division by zero", script);
    try testing.expectEqualStrings("{} {} 3 {/ 1 0}", try traceString(&interp));
}

test "stack trace in nested closure" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    const script =
        \\ fn bad {} {
        \\   / 1 0
        \\ }
        \\ bad
    ;
    try interp.testExpectScriptError(error.EvalError, "division by zero", script);
    try testing.expectEqualStrings("bad {} 2 {/ 1 0} {} {} 4 {}", try traceString(&interp));
}

test "stack trace in command substitution" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // Both the command-substitution eval frame and the outer eval frame share the same call
    // frame (global), so dedup collapses them to one trace entry. That entry's line comes
    // from source_info on the [/ 1 0] token, which points to where the substitution appears
    // in the outer script — line 2 — even though / 1 0 is line 1 of the inner script.
    const script =
        \\ set x 1
        \\ puts [/ 1 0]
    ;
    try interp.testExpectScriptError(error.EvalError, "division by zero", script);
    try testing.expectEqualStrings("{} {} 2 {/ 1 0}", try traceString(&interp));
}

test "stack trace line number correct dedup" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    // foo and bar have identical body text. Each closure has a unique cache_id, so each
    // body gets its own parsed_scripts entry — no sharing. The absolute line for each
    // must be correct, coming from source_info.line_no on the body Handle.
    //
    // foo's { is on line 1 → / 1 0 at relative line 2 → absolute line 2.
    // bar's { is on line 4 → / 1 0 at relative line 2 → absolute line 5.
    const script_foo =
        \\ fn foo {} {
        \\   / 1 0
        \\ }
        \\ fn bar {} {
        \\   / 1 0
        \\ }
        \\ foo
    ;
    const count_before_foo = Heap.local_heap.parsed_scripts.mapping.count();
    try interp.testExpectScriptError(error.EvalError, "division by zero", script_foo);
    try testing.expectEqual(count_before_foo + 2, Heap.local_heap.parsed_scripts.mapping.count());
    try testing.expectEqualStrings("foo {} 2 {/ 1 0} {} {} 7 {}", try traceString(&interp));

    const script_bar =
        \\ fn foo {} {
        \\   / 1 0
        \\ }
        \\ fn bar {} {
        \\   / 1 0
        \\ }
        \\ bar
    ;
    const count_before_bar = Heap.local_heap.parsed_scripts.mapping.count();
    try interp.testExpectScriptError(error.EvalError, "division by zero", script_bar);
    // bar has a distinct cache_id from foo, so it gets its own parsed_scripts entry even
    // though the body text is identical — the ParsedScript is NOT shared.
    try testing.expectEqual(count_before_bar + 2, Heap.local_heap.parsed_scripts.mapping.count());
    try testing.expectEqualStrings("bar {} 5 {/ 1 0} {} {} 7 {}", try traceString(&interp));
}

test "unknown" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult(
        "foo bar",
        \\ fn unknown {args} { return $args }
        \\ badfunction foo bar
        ,
    );
}

test "arg expansion" {
    var interp = try testStart(ta);
    defer testFinish(&interp);

    try interp.testExpectScriptResult(
        "bar baz",
        \\ fn foo {args} { return $args }
        \\ foo bar baz
        ,
    );
}

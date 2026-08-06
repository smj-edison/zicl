const std = @import("std");

const control_flow = @import("control_flow.zig");

const common = @import("common.zig");
const heap = common.heap;
const objects = common.objects;
const String = objects.String;
const List = objects.List;
const ErrorDetails = common.ErrorDetails;
const Interp = common.Interp;
const Shimmerable = common.Shimmerable;
const registerCommand = common.registerCommand;
const memutil = common.memutil;

/// [lmap]
pub fn lmapCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    return control_flow.foreachMapHelper(interp, args, .map);
}

/// [llength]
pub fn llengthCmd(interp: *Interp, args: []Shimmerable) !void {
    const as_list = try interp.getList(&args[1]);
    try interp.setResultInteger(@intCast(as_list.items.len));
}

pub fn lappendCmd(interp: *Interp, args: []Shimmerable) !void {
    if ((try interp.getVariable(&args[1])).asValue()) |var_value| {
        var det: ErrorDetails = undefined;
        if (try interp.wrapError(&det, var_value.asMutableInPlace(List, &det))) |list_mut| {
            for (args[2..]) |item| try list_mut.append(item.current());
            // Mutated in place, so no writeback needed.
            interp.setResult(list_mut.asHead().asValue());
        } else {
            const list_mut: *List = try interp.wrapError(&det, var_value.duplicateAsType(List, &det));
            defer list_mut.asHead().release();
            for (args[2..]) |item| try list_mut.append(item.current());
            try interp.setVariable(&args[1], list_mut.asHead().asValue());
            interp.setResult(list_mut.asHead().asValue());
        }
    } else {
        const list = (try List.newFromShimmerables(args[2..])).asHead().asValue();
        defer list.release();
        try interp.setVariable(&args[1], list);
        interp.setResult(list);
    }
}

/// [lassign]
pub fn lassignCmd(interp: *Interp, args: []Shimmerable) !void {
    // args[0] = "lassign", args[1] = list, args[2..] = varNames

    // `args[1]` holds its own borrow of the list, which matters when one of the
    // target variables is the one the list came from:
    //
    // ```
    // set l {a b}
    // lassign $l l other
    // ```
    //
    // Assigning to `l` releases the list that `$l` substituted, so without that
    // borrow `as_list.items` would dangle before `other` is assigned.
    const as_list = try interp.getList(&args[1]);
    const list_len = as_list.items.len;
    const var_count = args.len - 2;

    // Assign each list element to the corresponding variable.
    for (0..var_count) |i| {
        const var_name = &args[i + 2];
        if (i < list_len) {
            try interp.setVariable(var_name, as_list.items[i]);
        } else {
            // If there's no more elements, it becomes the empty string.
            try interp.setVariable(var_name, heap.interned_empty_string);
        }
    }

    // If there's any remaining list elements, they're returned from [lassign].
    if (list_len > var_count) {
        const remaining = as_list.items[var_count..];
        const remaining_list = try List.new(remaining);
        interp.setResultOwning(remaining_list.asHead().asValue());
    } else {
        interp.setEmptyResult();
    }
}

/// [list]
pub fn listCmd(interp: *Interp, args: []Shimmerable) !void {
    interp.setResultOwning((try List.newFromShimmerables(args[1..])).asHead().asValue());
}

pub fn concatCmd(interp: *Interp, args: []Shimmerable) !void {
    const to_concat = args[1..];
    if (to_concat.len == 0) {
        interp.setEmptyResult();
        return;
    }

    // If every argument is already a list, concatenate them as lists. Checked
    // with `asType` rather than by shimmering, because shimmering would make the
    // check true of every argument and so retire the string path below:
    //
    // ```
    // concat {a  b}
    // ```
    //
    // The string path only trims the ends, giving `a  b`, while going through a
    // list re-renders it as `a b`.
    not_all_lists: {
        for (to_concat) |arg| {
            if (arg.current().asType(List) == null) break :not_all_lists;
        }

        var total: usize = 0;
        for (to_concat) |arg| total += arg.current().asType(List).?.items.len;

        const result = try List.newWithCapacity(&.{}, total);
        errdefer result.asHead().release();
        for (to_concat) |arg| {
            for (arg.current().asType(List).?.items) |item| result.appendAssumeCapacity(item);
        }

        interp.setResultOwning(result.asHead().asValue());
        return;
    }

    // String path: trim each arg and join with single spaces.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(heap.global_gpa);

    var first_nonempty = true;
    for (to_concat) |arg| {
        const raw = try arg.getString();
        const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        if (!first_nonempty) try buf.append(heap.global_gpa, ' ');
        try buf.appendSlice(heap.global_gpa, trimmed);
        first_nonempty = false;
    }

    try interp.setResultStringOwning(try buf.toOwnedSliceSentinel(heap.global_gpa, 0));
}

/// [join]
pub fn joinCmd(interp: *Interp, args: []Shimmerable) !void {
    // join list ?joinString?
    const as_list = try interp.getList(&args[1]);
    const join_string = if (args.len > 2) try args[2].getString() else " ";

    if (as_list.items.len == 0) {
        interp.setEmptyResult();
        return;
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(heap.global_gpa);

    for (as_list.items, 0..) |item, i| {
        if (i > 0) try buf.appendSlice(heap.global_gpa, join_string);
        try buf.appendSlice(heap.global_gpa, try item.getString());
    }

    try interp.setResultStringOwning(try buf.toOwnedSliceSentinel(heap.global_gpa, 0));
}

pub fn registerCommands(interp: *Interp) !void {
    try registerCommand(interp, "list", listCmd, "?arg ...?", 0, null);
    try registerCommand(interp, "llength", llengthCmd, "list", 1, 1);
    try registerCommand(interp, "lappend", lappendCmd, "varName ?value ...?", 1, null);
    try registerCommand(interp, "lassign", lassignCmd, "list ?varName ...?", 1, null);
    try registerCommand(interp, "lmap", lmapCmd, "varList list ?varList list ...? body", 3, null);
    try registerCommand(interp, "concat", concatCmd, "?arg ...?", 0, null);
    try registerCommand(interp, "join", joinCmd, "list ?joinString?", 1, 2);
}

const testing = std.testing;

fn testLassignBasic(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("", "lassign {a b c} v1 v2 v3");
    try interp.testExpectScriptResult("a", "set v1");
    try interp.testExpectScriptResult("b", "set v2");
    try interp.testExpectScriptResult("c", "set v3");
}

test "lassign basic" {
    try memutil.checkAllocationFailures(.exhaustive, testLassignBasic, .{});
}

fn testLassignRemaining(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Unassigned elements are returned.
    try interp.testExpectScriptResult("c d",
        \\ lassign {a b c d} v1 v2
    );
    try interp.testExpectScriptResult("a", "set v1");
    try interp.testExpectScriptResult("b", "set v2");
}

test "lassign remaining" {
    try memutil.checkAllocationFailures(.exhaustive, testLassignRemaining, .{});
}

fn testLassignNotEnoughElements(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // When the list is shorter than the variable count, remaining vars get empty.
    try interp.testExpectScriptResult("",
        \\ lassign {a} v1 v2 v3
    );
    try interp.testExpectScriptResult("a", "set v1");
    try interp.testExpectScriptResult("", "set v2");
    try interp.testExpectScriptResult("", "set v3");
}

test "lassign not enough elements" {
    try memutil.checkAllocationFailures(.exhaustive, testLassignNotEnoughElements, .{});
}

fn testLassignCanAssignBackOverTheVariableItsListCameFrom(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // `l` is reassigned partway through, which releases the list still being
    // read for the remaining variables.
    try interp.testExpectScriptResult("b",
        \\ set l {a b}
        \\ lassign $l l other
        \\ return $other
    );
    try interp.testExpectScriptResult("a", "return $l");
}

test "lassign can assign back over the variable its list came from" {
    try memutil.checkAllocationFailures(.exhaustive, testLassignCanAssignBackOverTheVariableItsListCameFrom, .{});
}

fn testLassignNoVariables(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // With no variable names, the whole list is returned unchanged.
    try interp.testExpectScriptResult("a b c", "lassign {a b c}");
}

test "lassign no variables" {
    try memutil.checkAllocationFailures(.exhaustive, testLassignNoVariables, .{});
}

fn testListCommandBasic(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // No args returns empty list.
    try interp.testExpectScriptResult("", "list");

    // Single arg is returned as a one-element list.
    try interp.testExpectScriptResult("a", "list a");

    // Multiple args are combined into a list.
    try interp.testExpectScriptResult("a b c", "list a b c");
}

test "list command basic" {
    try memutil.checkAllocationFailures(.exhaustive, testListCommandBasic, .{});
}

fn testListCommandPreservesStrings(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Strings with spaces are treated as single elements.
    try interp.testExpectScriptResult("{hello world} foo", "list {hello world} foo");

    // Empty string is a valid element.
    try interp.testExpectScriptResult("a {} b", "list a {} b");
}

test "list command preserves strings" {
    try memutil.checkAllocationFailures(.exhaustive, testListCommandPreservesStrings, .{});
}

fn testListCommandNesting(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Nested lists are preserved as elements.
    try interp.testExpectScriptResult("{a b} {c d}", "list {a b} {c d}");

    // llength verifies the structure.
    try interp.testExpectScriptResult("2", "llength [list {a b} {c d}]");
}

test "list command nesting" {
    try memutil.checkAllocationFailures(.exhaustive, testListCommandNesting, .{});
}

fn testJoinBasic(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Default join string is a space.
    try interp.testExpectScriptResult("a b c", "join {a b c}");

    // Explicit join string.
    try interp.testExpectScriptResult("a,b,c", "join {a b c} ,");

    // Empty join string.
    try interp.testExpectScriptResult("abc", "join {a b c} {}");

    // Empty list returns empty string.
    try interp.testExpectScriptResult("", "join {}");

    // Single element.
    try interp.testExpectScriptResult("hello", "join {hello}");

    // Elements with spaces in them.
    try interp.testExpectScriptResult("hello world,foo bar", "join {{hello world} {foo bar}} ,");

    // Multi-character join string.
    try interp.testExpectScriptResult("a--b--c", "join {a b c} --");
}

test "join basic" {
    try memutil.checkAllocationFailures(.exhaustive, testJoinBasic, .{});
}

fn testLappendAppendsToAVariable(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("a b c", "set l {a b}; lappend l c");
    try interp.testExpectScriptResult("a b c", "set l");

    // Several values in one call.
    try interp.testExpectScriptResult("a b c d", "set l {a b}; lappend l c d");

    // An undefined variable becomes a new list.
    try interp.testExpectScriptResult("x y", "lappend fresh x y");
    try interp.testExpectScriptResult("x y", "set fresh");

    // Appending nothing leaves the value alone.
    try interp.testExpectScriptResult("a b", "set l {a b}; lappend l");
}

test "lappend appends to a variable" {
    try memutil.checkAllocationFailures(.exhaustive, testLappendAppendsToAVariable, .{});
}

fn testLappendCopiesWhenTheListIsShared(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // `other` holds the same list, so appending to `l` must copy rather than
    // mutate in place, leaving `other` untouched.
    try interp.testExpectScriptResult("a b",
        \\ set l {a b}
        \\ set other $l
        \\ lappend l c
        \\ return $other
    );
    try interp.testExpectScriptResult("a b c", "return $l");
}

test "lappend copies when the list is shared" {
    try memutil.checkAllocationFailures(.exhaustive, testLappendCopiesWhenTheListIsShared, .{});
}

fn testConcatJoinsListsAndStrings(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Every argument is already a list here, which takes the list fast path.
    try interp.testExpectScriptResult("a b c d", "concat [list a b] [list c d]");
    try interp.testExpectScriptResult("2", "llength [concat [list a] [list b]]");

    // Bare words are strings, so this takes the trimming path instead. Both
    // paths have to agree on the result.
    try interp.testExpectScriptResult("a b c d", "concat {a b} {c d}");
    try interp.testExpectScriptResult("a b c d", "concat {  a b  } {  c d  }");

    // The string path only trims the ends, so interior spacing survives. Going
    // through a list would re-render this with single spaces instead, which is
    // why the fast path checks rather than shimmers.
    try interp.testExpectScriptResult("a  b", "concat {a  b}");

    // Empty arguments drop out rather than leaving stray separators.
    try interp.testExpectScriptResult("a b", "concat {a} {} {b}");
    try interp.testExpectScriptResult("", "concat");
    try interp.testExpectScriptResult("", "concat {} {}");

    // A single argument comes back as itself, trimmed.
    try interp.testExpectScriptResult("hello", "concat hello");
    try interp.testExpectScriptResult("hello", "concat {  hello  }");

    // More than two arguments, with and without padding.
    try interp.testExpectScriptResult("a b c", "concat a b c");
    try interp.testExpectScriptResult("a b c", "concat {  a  } {  b  } {  c  }");

    // Multi-element arguments flatten into one sequence.
    try interp.testExpectScriptResult("1 2 3 4", "concat {1 2} {3 4}");
    try interp.testExpectScriptResult("1 2 3", "concat {1 2 3} {}");
}

test "concat joins lists and strings" {
    try memutil.checkAllocationFailures(.exhaustive, testConcatJoinsListsAndStrings, .{});
}

fn testLmapMapsABodyOverAList(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("2 3 4", "lmap x {1 2 3} { + $x 1 }");
    try interp.testExpectScriptResult("", "lmap x {} { + $x 1 }");

    // The loop variable survives as the last element, matching [foreach].
    try interp.testExpectScriptResult("3", "lmap x {1 2 3} { + $x 1 }; return $x");
}

test "lmap maps a body over a list" {
    try memutil.checkAllocationFailures(.exhaustive, testLmapMapsABodyOverAList, .{});
}

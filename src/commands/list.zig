const std = @import("std");

const control_flow = @import("control_flow.zig");
const strutil = @import("../strutil.zig");
const regex = @import("../regex.zig");
const pcre2 = @import("pcre2");

const common = @import("common.zig");
const heap = common.heap;
const objects = common.objects;
const String = objects.String;
const List = objects.List;
const Value = common.Value;
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
    interp.setResultInteger(@intCast(as_list.items.len));
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

/// [lindex]
///
/// Each argument after `list` is one index level to drill through (matching
/// Jim's `Jim_ListIndices`, which does not treat a lone list-valued index
/// argument as sugar for multiple indices the way vanilla Tcl documents it).
/// The walk itself lives in `List.getRecursively`, mirroring
/// `Dictionary.getRecursively`.
pub fn lindexCmd(interp: *Interp, args: []Shimmerable) !void {
    const result = try interp.getListValueRecursively(&args[1], args[2..]);
    interp.setResult(result.orEmpty());
}

/// [lrange]
pub fn lrangeCmd(interp: *Interp, args: []Shimmerable) !void {
    const as_list = try interp.getList(&args[1]);

    var det: ErrorDetails = undefined;
    const range = try interp.wrapError(&det, objects.Index.getRange(&det, as_list.items.len, &args[2], &args[3]));

    const result = try List.new(as_list.items[range.start..range.end]);
    interp.setResultOwning(result.asHead().asValue());
}

/// [lreplace]
///
/// `Index.Range` isn't reused here: it always clamps to a valid start/end
/// pair for extraction (as [lrange] wants), but [lreplace] needs first and
/// the delete boundary tracked separately, since an inverted range still has
/// to insert at `first` rather than collapsing to an empty range.
pub fn lreplaceCmd(interp: *Interp, args: []Shimmerable) !void {
    const as_list = try interp.getList(&args[1]);
    const len = as_list.items.len;
    const len_i: i65 = @intCast(len);

    const first_index = try interp.getIndex(&args[2]);
    const last_index = try interp.getIndex(&args[3]);
    const first_abs = first_index.asAbsoluteIndex(len);
    const last_abs = last_index.asAbsoluteIndex(len);

    // `first` clamps into [0, len]. When `last` falls before `first`, nothing
    // is deleted and any new elements are inserted at `first` instead, which
    // is why `delete_end` is clamped to be no earlier than `first` itself.
    const first: usize = @intCast(std.math.clamp(first_abs, 0, len_i));
    const first_i: i65 = @intCast(first);
    const delete_end: usize = @intCast(std.math.clamp(@max(last_abs + 1, first_i), first_i, len_i));

    const new_elements = args[4..];
    const total = first + new_elements.len + (len - delete_end);
    const result = try List.newWithCapacity(&.{}, total);
    errdefer result.asHead().release();

    for (as_list.items[0..first]) |item| result.appendAssumeCapacity(item);
    for (new_elements) |elem| result.appendAssumeCapacity(elem.current());
    for (as_list.items[delete_end..]) |item| result.appendAssumeCapacity(item);

    interp.setResultOwning(result.asHead().asValue());
}

/// [linsert]
pub fn linsertCmd(interp: *Interp, args: []Shimmerable) !void {
    const as_list = try interp.getList(&args[1]);
    const len = as_list.items.len;

    const idx = try interp.getIndex(&args[2]);
    const idx_abs = idx.asAbsoluteIndex(len);

    // Tcl's semantics: idx >= len means append at end; idx < 0 means insert at
    // len + idx + 1 (clamped to 0). As with [lreplace], relative indices like
    // `end` are already resolved by asAbsoluteIndex, so only literal negatives
    // need the transform.
    const insert_at: usize = if (idx_abs >= len)
        len
    else if (idx_abs < 0)
        @intCast(std.math.clamp(len + idx_abs + 1, 0, len))
    else
        @intCast(idx_abs);

    const new_elements = args[3..];
    const total = len + new_elements.len;
    const result = try List.newWithCapacity(&.{}, total);
    errdefer result.asHead().release();

    for (as_list.items[0..insert_at]) |item| result.appendAssumeCapacity(item);
    for (new_elements) |elem| result.appendAssumeCapacity(elem.current());
    if (insert_at < len) for (as_list.items[insert_at..]) |item| result.appendAssumeCapacity(item);

    interp.setResultOwning(result.asHead().asValue());
}

/// [lrepeat]
pub fn lrepeatCmd(interp: *Interp, args: []Shimmerable) !void {
    const count_raw = try interp.getInteger(&args[1]);
    const count = std.math.cast(usize, count_raw) catch return interp.integerOverflowError(i64, count_raw);

    if (count == 0 or args.len == 2) {
        interp.setEmptyResult();
        return;
    }

    const elements = args[2..];

    const total_raw = std.math.mulWide(usize, count, elements.len);
    const total = std.math.cast(usize, total_raw) orelse return interp.integerOverflowError(u128, total_raw);
    const result = try List.newWithCapacity(&.{}, total);
    errdefer result.asHead().release();

    for (0..count) |_| {
        for (elements) |elem| result.appendAssumeCapacity(elem.current());
    }

    interp.setResultOwning(result.asHead().asValue());
}

/// [lsearch]
pub fn lsearchCmd(interp: *Interp, args: []Shimmerable) !void {
    const Mode = enum { exact, glob, regexp };
    var mode: Mode = .glob; // Tcl's default.
    var opt_nocase = false;

    var i: usize = 1;
    while (i < args.len - 2) : (i += 1) {
        if (try args[i].current().equalsString("-exact")) {
            mode = .exact;
        } else if (try args[i].current().equalsString("-glob")) {
            mode = .glob;
        } else if (try args[i].current().equalsString("-regexp")) {
            mode = .regexp;
        } else if (try args[i].current().equalsString("-nocase")) {
            opt_nocase = true;
        } else if (try args[i].current().equalsString("--")) {
            i += 1;
            break;
        } else {
            return error.WrongUsage;
        }
    }

    if (args.len - i != 2) return error.WrongUsage;

    const as_list = try interp.getList(&args[i]);
    const pattern_shim = &args[i + 1];
    const pattern_bytes = try pattern_shim.current().getString();

    var det: ErrorDetails = undefined;
    var compiled_regexp: ?*const regex.Regexp = null;
    if (mode == .regexp) {
        var compile_opts: u32 = pcre2.PCRE2_UTF | pcre2.PCRE2_UCP;
        if (opt_nocase) compile_opts |= pcre2.PCRE2_CASELESS;
        compiled_regexp = try interp.wrapError(&det, regex.Regexp.shimmerFrom(&det, pattern_shim, compile_opts));
    }

    for (as_list.items, 0..) |item, idx| {
        const item_bytes = try item.getString();

        const matched = switch (mode) {
            .exact => strutil.compare(item_bytes, pattern_bytes, null, opt_nocase) == .eq,
            .glob => strutil.globMatch(pattern_bytes, item_bytes, opt_nocase),
            .regexp => try interp.wrapError(&det, regex.doesStringMatch(&det, compiled_regexp.?.regexp, item_bytes)),
        };

        if (matched) {
            interp.setResultInteger(@intCast(idx));
            return;
        }
    }

    interp.setResultInteger(-1);
}

/// [lset]
///
/// Mirrors `dict set`'s own command body: prefer mutating the variable's list
/// in place, and only duplicate it when it's shared. The index-path walk
/// itself is `List.setRecursively`, mirroring `Dictionary.putRecursively`.
pub fn lsetCmd(interp: *Interp, args: []Shimmerable) !void {
    const var_name = &args[1];
    const new_value = args[args.len - 1].current();

    if (args.len == 3) {
        // No index: same as [set].
        try interp.setVariable(var_name, new_value);
        interp.setResult(new_value);
        return;
    }

    var det: ErrorDetails = undefined;
    const current = try interp.getVariableOrError(var_name);

    if (try interp.wrapError(&det, current.asMutableInPlace(List, &det))) |list_mut| {
        try interp.setListValueRecursively(list_mut, args[2..(args.len - 1)], new_value);
        interp.setResult(list_mut.asHead().asValue());
    } else {
        const duped = try interp.wrapError(&det, current.duplicateAsType(List, &det));
        defer duped.asHead().release();
        try interp.setListValueRecursively(duped, args[2..(args.len - 1)], new_value);
        try interp.setVariable(var_name, duped.asHead().asValue());
        interp.setResult(duped.asHead().asValue());
    }
}

const LsortMode = enum { ascii, integer, real };
fn getValueOrder(mode: LsortMode, a: Value, b: Value) !std.math.Order {
    switch (mode) {
        .ascii => {
            const a_bytes = try a.getString();
            const b_bytes = try b.getString();
            return strutil.compare(a_bytes, b_bytes, null, false);
        },
        .integer, .real => {
            var a_shim: Shimmerable = .{ .original = a };
            defer a_shim.discardChanges();
            var b_shim: Shimmerable = .{ .original = b };
            defer b_shim.discardChanges();

            const a_num = try objects.Number.getAsIntOrFloat(null, &a_shim);
            const b_num = try objects.Number.getAsIntOrFloat(null, &b_shim);
            return std.math.order(a_num.asFloat(), b_num.asFloat());
        },
    }
}

const LsortContext = struct {
    pub const Command = struct {
        interp: *Interp,
        command: Interp.CommandVariant,
        command_name: Value,
    };

    mode: LsortMode,
    decreasing: bool,
    /// Used to exfiltrate an error if it occured, since sort functions
    /// can't directly return an error.
    err: *?Interp.Error,
    command: ?Command = null,

    fn callCommand(interp: *Interp, command: *const Interp.CommandVariant, command_name: Value, a: Value, b: Value) !std.math.Order {
        var call_args: [3]Shimmerable = .{
            .{ .original = command_name },
            .{ .original = a },
            .{ .original = b },
        };
        defer for (&call_args) |*shim| shim.discardChanges();

        try interp.invokeCommand(command, &call_args);

        const num = try interp.getIntOrFloatInPlace(&interp.result);
        return std.math.order(num.asFloat(), 0.0);
    }

    fn lessThan(self: @This(), a: Value, b: Value) bool {
        if (self.err.* != null) return false;

        if (self.command) |cmd| {
            const order = callCommand(cmd.interp, &cmd.command, cmd.command_name, a, b) catch |err| {
                self.err.* = err;
                return false;
            };
            return if (self.decreasing) order == .gt else order == .lt;
        } else {
            const order = getValueOrder(self.mode, a, b) catch |err| {
                self.err.* = Interp.narrowError(err);
                return false;
            };
            return if (self.decreasing) order == .gt else order == .lt;
        }
    }
};

/// [lsort]
pub fn lsortCmd(interp: *Interp, args: []Shimmerable) !void {
    var mode: LsortMode = .ascii;
    var decreasing = false;
    var command_ctx: ?LsortContext.Command = null;
    defer if (command_ctx) |*ctx| ctx.command.deinit();

    var i: usize = 1;
    while (i < args.len - 1) : (i += 1) {
        if (try args[i].current().equalsString("-ascii")) {
            mode = .ascii;
        } else if (try args[i].current().equalsString("-integer") or
            try args[i].current().equalsString("-real"))
        {
            mode = .integer;
        } else if (try args[i].current().equalsString("-increasing")) {
            decreasing = false;
        } else if (try args[i].current().equalsString("-decreasing")) {
            decreasing = true;
        } else if (try args[i].current().equalsString("-command")) {
            i += 1;
            if (i >= args.len - 1) return error.WrongUsage;
            const command = interp.getCommandFromValue(&args[i], false) catch |err| switch (err) {
                error.CommandNotFound => return error.EvalError, // Message already set.
                else => return Interp.narrowError(err),
            };
            command_ctx = .{
                .interp = interp,
                .command = command,
                .command_name = args[i].current(),
            };
        } else {
            return error.WrongUsage;
        }
    }

    const as_list = try interp.getList(&args[i]);
    const items = try heap.local_arena.dupe(Value, as_list.items);

    var error_out: ?Interp.Error = null;
    const ctx: LsortContext = .{
        .mode = mode,
        .decreasing = decreasing,
        .command = command_ctx,
        .err = &error_out,
    };
    std.mem.sort(Value, items, ctx, LsortContext.lessThan);

    if (error_out) |err| return Interp.narrowError(err);

    const result = try List.new(items);
    interp.setResultOwning(result.asHead().asValue());
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
    try registerCommand(interp, "lindex", lindexCmd, "list ?index ...?", 1, null);
    try registerCommand(interp, "lrange", lrangeCmd, "list first last", 3, 3);
    try registerCommand(interp, "lreplace", lreplaceCmd, "list first last ?element ...?", 3, null);
    try registerCommand(interp, "lsearch", lsearchCmd, "?options? list pattern", 2, null);
    try registerCommand(interp, "lset", lsetCmd, "varName ?index ...? newValue", 2, null);
    try registerCommand(interp, "lsort", lsortCmd, "?options? list", 1, null);
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

fn testLindexBasic(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // No index returns the list itself.
    try interp.testExpectScriptResult("a b c", "lindex {a b c}");

    // A single index.
    try interp.testExpectScriptResult("b", "lindex {a b c} 1");
    try interp.testExpectScriptResult("c", "lindex {a b c} end");
    try interp.testExpectScriptResult("b", "lindex {a b c} end-1");

    // Out of range comes back empty, not an error.
    try interp.testExpectScriptResult("", "lindex {a b c} 10");
    try interp.testExpectScriptResult("", "lindex {a b c} -1");

    // Each argument drills one level deeper (no single-list-of-indices sugar):
    // braces are just Tcl quoting, so `{0}` is the same argument as `0`, not
    // a nested one-element list to flatten.
    try interp.testExpectScriptResult("d", "lindex {{a b} {c d}} 1 1");
    try interp.testExpectScriptResult("a", "lindex {a b c} {0}");

    // Malformed index syntax is a real error, unlike a well-formed index
    // that's merely out of range (matching Jim's `Jim_ListIndices`, which
    // only treats a genuinely out-of-range numeric index as "return empty").
    try interp.testExpectScriptError(error.EvalError,
        \\bad index "abc": must be intexpr or end?[+-]intexpr?
    , "lindex {a b c} abc");
}

test "lindex basic" {
    try memutil.checkAllocationFailures(.exhaustive, testLindexBasic, .{});
}

fn testLrangeBasic(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("b c", "lrange {a b c d} 1 2");
    try interp.testExpectScriptResult("c d", "lrange {a b c d} end-1 end");
    try interp.testExpectScriptResult("a b c d", "lrange {a b c d} 0 end");

    // Start past the list length used to panic (invalid slice); now clamps empty.
    try interp.testExpectScriptResult("", "lrange {a b c} 10 20");

    // Inverted range returns nothing.
    try interp.testExpectScriptResult("", "lrange {a b c d} 3 1");
}

test "lrange basic" {
    try memutil.checkAllocationFailures(.exhaustive, testLrangeBasic, .{});
}

fn testLreplaceBasic(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Replace a middle range.
    try interp.testExpectScriptResult("a X Y d", "lreplace {a b c d} 1 2 X Y");

    // Deleting with no replacement elements.
    try interp.testExpectScriptResult("a d", "lreplace {a b c d} 1 2");

    // last < first inserts without deleting anything.
    try interp.testExpectScriptResult("a X b c", "lreplace {a b c} 1 0 X");

    // Appending past the end.
    try interp.testExpectScriptResult("a b c X", "lreplace {a b c} 10 20 X");
}

test "lreplace basic" {
    try memutil.checkAllocationFailures(.exhaustive, testLreplaceBasic, .{});
}

fn testLsearchBasic(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Default mode is glob.
    try interp.testExpectScriptResult("1", "lsearch {foo ba* baz} ba*");
    try interp.testExpectScriptResult("2", "lsearch {foo bar baz} b*z");
    try interp.testExpectScriptResult("-1", "lsearch {foo bar baz} nope");

    try interp.testExpectScriptResult("1", "lsearch -exact {foo bar baz} bar");
    try interp.testExpectScriptResult("2", "lsearch -regexp {foo bar baz} {z$}");
}

test "lsearch basic" {
    try memutil.checkAllocationFailures(.exhaustive, testLsearchBasic, .{});
}

fn testLsetBasic(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("a X c",
        \\ set l {a b c}
        \\ lset l 1 X
    );
    try interp.testExpectScriptResult("a X c", "return $l");

    // Nested index path.
    try interp.testExpectScriptResult("{a b} {c X}",
        \\ set l {{a b} {c d}}
        \\ lset l 1 1 X
    );

    // No index at all just sets the variable, like [set].
    try interp.testExpectScriptResult("Y",
        \\ set l {a b c}
        \\ lset l Y
    );
}

test "lset basic" {
    try memutil.checkAllocationFailures(.exhaustive, testLsetBasic, .{});
}

fn testLsortBasic(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("a b c", "lsort {c a b}");
    try interp.testExpectScriptResult("c b a", "lsort -decreasing {c a b}");
    try interp.testExpectScriptResult("2 10 30", "lsort -integer {10 2 30}");
}

test "lsort basic" {
    try memutil.checkAllocationFailures(.exhaustive, testLsortBasic, .{});
}

fn testLsortCommand(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult(
        "a b c",
        "lsort -command [fn {a b} {string compare $a $b}] {c a b}",
    );
    try interp.testExpectScriptResult(
        "30 10 2",
        "lsort -command [fn {a b} {expr {$b - $a}}] {10 2 30}",
    );
    try interp.testExpectScriptError(
        error.EvalError,
        "not a valid function: \"notACommand\"",
        "lsort -command notACommand {c a b}",
    );
}

test "lsort -command sorts using a closure comparator" {
    try memutil.checkAllocationFailures(.exhaustive, testLsortCommand, .{});
}

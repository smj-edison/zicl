const std = @import("std");

const common = @import("common.zig");
const heap = common.heap;
const ErrorDetails = common.ErrorDetails;
const Value = common.Value;
const objects = common.objects;
const List = objects.List;
const Interp = common.Interp;
const Shimmerable = common.Shimmerable;
const registerCommand = common.registerCommand;
const memutil = common.memutil;

/// [incr]
pub fn incrCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    var increment_by: i64 = 1;

    if (args.len == 3) {
        // There's an amount provided to increment by.
        increment_by = try interp.getInteger(&args[2]);
    }

    const var_name = &args[1];

    if ((try interp.getVariableTakingReference(var_name)).asValue()) |val| {
        defer val.dropReference();
        var val_shim: Shimmerable = .{ .original = val };
        defer val_shim.discardChanges();
        var det: ErrorDetails = undefined;
        const contents = try interp.wrapError(&det, objects.Integer.shimmerFrom(&det, &val_shim));
        const new_contents = std.math.add(i64, contents, increment_by) catch {
            return interp.wrapError(&det, objects.Integer.overflowError(i65, &det, @as(i65, contents) + @as(i65, increment_by)));
        };

        const new_int = Value.newInt(new_contents);
        try interp.setVariable(var_name, new_int);
        interp.setResult(new_int);
    } else {
        const new_int = objects.Integer.new(increment_by);
        try interp.setVariable(var_name, new_int);
        interp.setResult(new_int);
    }
}

/// [set]
pub fn setCmd(interp: *Interp, args: []Shimmerable) !void {
    const var_name = &args[1];

    if (args.len == 2) {
        // Return the value.
        interp.setResultOwning(try interp.getVariableTakingReferenceOrError(var_name));
    } else {
        try interp.setVariable(var_name, args[2].current());
        // Return the stored value (may differ from args[2] after upvar follow).
        interp.setResultOwning(try interp.getVariableTakingReferenceOrError(var_name));
    }
}

/// [unset]
pub fn unsetCmd(interp: *Interp, args: []Shimmerable) !void {
    var should_complain = true;

    var i: usize = 1;
    while (i < args.len) {
        if (try args[i].current().equalsString("--")) {
            i += 1;
            break;
        } else if (try args[i].current().equalsString("-nocomplain")) {
            should_complain = false;
            i += 1;
            continue;
        } else break;
    }

    if (should_complain) {
        while (i < args.len) : (i += 1) {
            try interp.unsetVariable(&args[i]);
        }
    } else {
        while (i < args.len) : (i += 1) {
            interp.unsetVariableSilent(&args[i]) catch |err| switch (err) {
                error.VariableNotFound,
                error.LookupFailed,
                error.BadVariableName,
                error.BadDict,
                => {},
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
    }
}

/// [upvar] - link a local variable to a variable in an upper scope.
/// Syntax: `upvar ?level? otherVar myVar ?otherVar myVar ...?`.
pub fn upvarCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    var upvar_names_start: usize = 1;
    var levels_up: u32 = 1;

    if (args.len > 3 and @mod(args.len, 2) == 0) {
        if (interp.getInteger(&args[1])) |level| {
            if (level >= 0 and level <= std.math.maxInt(u32)) {
                levels_up = @intCast(level);
                upvar_names_start = 2;
            } else {
                try interp.setResultString("bad level");
                return error.EvalError;
            }
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try interp.setResultString("bad level");
                return error.EvalError;
            },
        }
    }

    if (args.len - upvar_names_start < 2) return error.WrongUsage;

    const current_frame = interp.callFrameIdx();
    const target_frame = interp.getRelativeCallFrame(current_frame, levels_up) orelse {
        try interp.setResultString("bad level");
        return error.EvalError;
    };

    var j = upvar_names_start;
    while (j + 1 < args.len) : (j += 2) {
        try args[j].ensureShimmerable();
        try args[j + 1].ensureShimmerable();

        try interp.setVariableUpvar(&args[j + 1], target_frame, args[j].current());
    }
}

pub fn registerCommands(interp: *Interp) !void {
    try registerCommand(interp, "incr", incrCmd, "varName ?increment?", 1, 2);
    try registerCommand(interp, "set", setCmd, "varName ?newValue?", 1, 2);
    try registerCommand(interp, "unset", unsetCmd, "?-nocomplain? ?--? ?varName ...?", 0, null);
    try registerCommand(interp, "upvar", upvarCmd, "?level? otherVar myVar ?otherVar myVar ...?", 2, null);
}

const testing = std.testing;

fn testUnsetRemovesAVariable(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("", "set x 5; unset x");
    try interp.testExpectScriptError(error.EvalError, "can't unset \"x\": no such variable", "set x 5; unset x; unset x");
    try interp.testExpectScriptResult("", "set x 5; unset x; unset -nocomplain x");
}

test "unset removes a variable" {
    try memutil.checkAllocationFailures(.exhaustive, testUnsetRemovesAVariable, .{});
}

fn testUnsetOfAShadowingLocalExposesTheLexicalItShadowed(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Removing the local has to expose the captured scope underneath rather than
    // leaving the name unresolvable, so the lexical chain must survive the unset.
    try interp.testExpectScriptResult("outer",
        \\ set x outer
        \\ fn peel {} { set x inner; unset x; return $x }
        \\ peel
    );

    // The caller's variable is untouched by the local's whole lifecycle.
    try interp.testExpectScriptResult("outer",
        \\ set x outer
        \\ fn peel {} { set x inner; unset x; return $x }
        \\ peel
        \\ return $x
    );
}

test "unset of a shadowing local exposes the lexical it shadowed" {
    try memutil.checkAllocationFailures(.exhaustive, testUnsetOfAShadowingLocalExposesTheLexicalItShadowed, .{});
}

fn testDictSugarReadsAndWritesThroughAVariable(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Each assertion uses a fresh variable, since they share one interpreter and
    // a leftover dict would be descended into by the next path.

    // `one::b` names key `b` of the dict in variable `one`.
    try interp.testExpectScriptResult("b value", "set one::b value; set one");
    try interp.testExpectScriptResult("value", "set two::b value; set two::b");

    // A second key joins the same dict rather than replacing it.
    try interp.testExpectScriptResult("b 1 c 2", "set three::b 1; set three::c 2; set three");

    // Nested paths build nested dicts.
    try interp.testExpectScriptResult("deep", "set four::b::c deep; set four::b::c");
    try interp.testExpectScriptResult("c deep", "set five::b::c deep; set five::b");
}

test "dict sugar reads and writes through a variable" {
    try memutil.checkAllocationFailures(.exhaustive, testDictSugarReadsAndWritesThroughAVariable, .{});
}

fn testDictSugarCopiesWhenTheDictIsShared(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // `other` holds the same dict, so writing through sugar must copy rather
    // than mutate in place, leaving `other` alone.
    try interp.testExpectScriptResult("b 1",
        \\ set a {b 1}
        \\ set other $a
        \\ set a::b 2
        \\ return $other
    );
    try interp.testExpectScriptResult("b 2", "return $a");
}

test "dict sugar copies when the dict is shared" {
    try memutil.checkAllocationFailures(.exhaustive, testDictSugarCopiesWhenTheDictIsShared, .{});
}

fn testUnsetRemovesADictSugarElement(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Only the named key goes; the rest of the dict stays.
    try interp.testExpectScriptResult("c 2", "set a::b 1; set a::c 2; unset a::b; set a");

    // Removing a key that was never there is an error.
    try interp.testExpectScriptError(
        error.EvalError,
        "can't unset \"a::missing\": no such element in dictionary",
        "set a::b 1; unset a::missing",
    );
}

test "unset removes a dict sugar element" {
    try memutil.checkAllocationFailures(.exhaustive, testUnsetRemovesADictSugarElement, .{});
}

fn testUnsetOfASharedDictElementCopiesRatherThanMutating(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Same copy-on-write requirement as writing, on the removal path.
    try interp.testExpectScriptResult("b 1 c 2",
        \\ set a {b 1 c 2}
        \\ set other $a
        \\ unset a::b
        \\ return $other
    );
    try interp.testExpectScriptResult("c 2", "return $a");
}

test "unset of a shared dict element copies rather than mutating" {
    try memutil.checkAllocationFailures(.exhaustive, testUnsetOfASharedDictElementCopiesRatherThanMutating, .{});
}

fn testUpvarReadsAndWritesThroughALink(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Reading through a link.
    try interp.testExpectScriptResult("5",
        \\ set outer 5
        \\ fn peek {} { upvar 1 outer inner; return $inner }
        \\ peek
    );

    // Writing through a link reaches the caller's variable.
    try interp.testExpectScriptResult("changed",
        \\ set outer original
        \\ fn poke {} { upvar 1 outer inner; set inner changed }
        \\ poke
        \\ return $outer
    );

    // Unsetting through a link removes the caller's variable, not the link.
    try interp.testExpectScriptError(error.EvalError, "can't read \"outer\": no such variable",
        \\ set outer 5
        \\ fn drop {} { upvar 1 outer inner; unset inner }
        \\ drop
        \\ return $outer
    );
}

test "upvar reads and writes through a link" {
    try memutil.checkAllocationFailures(.exhaustive, testUpvarReadsAndWritesThroughALink, .{});
}

fn testUpvarAtLevel0RejectsCyclesAndRedefinition(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptError(error.EvalError, "can't upvar from variable to itself", "upvar 0 x x");
    try interp.testExpectScriptError(error.EvalError, "can't upvar from variable to itself", "upvar 0 x y; upvar 0 y x");
    try interp.testExpectScriptError(error.EvalError, "variable \"y\" already exists", "set y 1; upvar 0 x y");
}

test "upvar at level 0 rejects cycles and redefinition" {
    try memutil.checkAllocationFailures(.exhaustive, testUpvarAtLevel0RejectsCyclesAndRedefinition, .{});
}

fn testUpvarResolvesToAValueWhenItsScopeIsCaptured(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // `make` holds `linked` only as an upvar into its caller. The closure it
    // returns outlives that frame, so the capture has to resolve the link to a
    // value rather than storing it.
    try interp.testExpectScriptResult("7",
        \\ set outer 7
        \\ fn make {} {
        \\   upvar 1 outer linked
        \\   fn grab {} { return $linked }
        \\   return $grab
        \\ }
        \\ set grab [make]
        \\ grab
    );
}

test "upvar resolves to a value when its scope is captured" {
    try memutil.checkAllocationFailures(.exhaustive, testUpvarResolvesToAValueWhenItsScopeIsCaptured, .{});
}

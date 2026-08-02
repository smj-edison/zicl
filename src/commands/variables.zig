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

/// [incr]
pub fn incrCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    var increment_by: i64 = 1;

    if (args.len == 3) {
        // There's an amount provided to increment by.
        increment_by = try interp.getInteger(&args[2]);
    }

    const var_name = &args[1];

    if ((try interp.getVariable(var_name)).asValue()) |val| {
        var val_shim: Shimmerable = .{ .original = val };
        defer val_shim.discardChanges();
        var det: ErrorDetails = undefined;
        const contents = try interp.wrapError(&det, objects.Integer.shimmerFrom(&det, &val_shim));
        const new_contents = std.math.add(i64, contents, increment_by) catch {
            return interp.wrapError(&det, objects.Integer.overflowError(i65, &det, @as(i65, contents) + @as(i65, increment_by)));
        };

        const new_int = objects.Integer.new(new_contents);
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
        interp.setResult(try interp.getVariableOrError(var_name));
    } else {
        try interp.setVariable(var_name, args[2].current());
        // Return the stored value (may differ from args[2] after upvar follow).
        interp.setResult(try interp.getVariableOrError(var_name));
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
    if (levels_up > current_frame) {
        try interp.setResultString("bad level");
        return error.EvalError;
    }
    const target_frame = current_frame - levels_up;

    var j = upvar_names_start;
    while (j + 1 < args.len) : (j += 2) {
        try args[j].ensureShimmerable();
        try args[j + 1].ensureShimmerable();

        try interp.setVariableUpvar(&args[j + 1], target_frame, args[j].current());
    }
}

pub fn registerCommands(interp: *Interp) !void {
    try registerCommand(interp, "incr", incrCmd, "varName ?increment?", 1, 2, null);
    try registerCommand(interp, "set", setCmd, "varName ?newValue?", 1, 2, null);
    try registerCommand(interp, "unset", unsetCmd, "?-nocomplain? ?--? ?varName ...?", 0, null, null);
    try registerCommand(interp, "upvar", upvarCmd, "?level? otherVar myVar ?otherVar myVar ...?", 2, null, null);
}

const testing = std.testing;

test "unset removes a variable" {
    var interp = try common.testStart(testing.allocator);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("", "set x 5; unset x");
    try interp.testExpectScriptError(error.EvalError, "can't unset \"x\": no such variable", "set x 5; unset x; unset x");
    try interp.testExpectScriptResult("", "set x 5; unset x; unset -nocomplain x");
}

test "unset of a shadowing local exposes the lexical it shadowed" {
    var interp = try common.testStart(testing.allocator);
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

test "upvar reads and writes through a link" {
    var interp = try common.testStart(testing.allocator);
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

test "upvar at level 0 rejects cycles and redefinition" {
    var interp = try common.testStart(testing.allocator);
    defer common.testFinish(&interp);

    try interp.testExpectScriptError(error.EvalError, "can't upvar from variable to itself", "upvar 0 x x");
    try interp.testExpectScriptError(error.EvalError, "can't upvar from variable to itself", "upvar 0 x y; upvar 0 y x");
    try interp.testExpectScriptError(error.EvalError, "variable \"y\" already exists", "set y 1; upvar 0 x y");
}

test "upvar resolves to a value when its scope is captured" {
    var interp = try common.testStart(testing.allocator);
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

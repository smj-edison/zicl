const std = @import("std");

const common = @import("common.zig");
const heap = common.heap;
const ErrorDetails = common.ErrorDetails;
const Value = common.Value;
const objects = common.objects;
const List = objects.List;
const Interp = common.Interp;
const Shimmerable = common.Shimmerable;

pub fn propagateLoopControl(interp: *Interp, result: Interp.Error!void) Interp.Error!enum { @"continue", @"break", none } {
    if (result) |_| {
        return .none;
    } else |err| switch (err) {
        error.Continue, error.Break => {
            if (interp.loop_propagate > 1) {
                interp.loop_propagate -= 1;
                return err;
            } else {
                return switch (err) {
                    error.Continue => .@"continue",
                    error.Break => .@"break",
                    inline else => unreachable,
                };
            }
        },
        else => return err,
    }

    return .none;
}

pub fn forCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    // Do the initialization.
    try interp.evalObject(args[1].current());

    // Check condition.
    while (try interp.getBoolFromExpression(args[2].current())) {
        // Evaluate body.
        switch (try propagateLoopControl(interp, interp.evalObject(args[4].current()))) {
            .@"break" => {
                break;
            },
            .@"continue" => {
                // No need to do anything, because as the called body
                // returned `error.Continue` early, it skipped running
                // the rest of the commands.
            },
            .none => {},
        }

        // Run increment.
        try interp.evalObject(args[3].current());
    }

    interp.setEmptyResult();
}

/// Shared implementation of [foreach] and [lmap].
fn foreachMapHelper(interp: *Interp, args: []Shimmerable, mode: enum { foreach, map }) Interp.Error!void {
    const body = &args[args.len - 1];

    // [foreach] can simultaneously loop over multiple lists, so it's easiest to think of it as zipped.
    // It's not quite a normal zip though, since the stride over each list depends on how many variables
    // it captures.

    const list_count = (args.len - 2) / 2;

    // Track per-list iteration state.
    var iter_state: std.ArrayList(struct {
        stride: u32,
        length: u32,
        current_index: u32,
    }) = try .initCapacity(heap.global_gpa, list_count);
    defer iter_state.deinit(heap.global_gpa);

    for (0..list_count) |i| {
        const as_list = try interp.getList(&args[i * 2 + 1]);
        const stride = as_list.items.len;
        if (stride == 0) {
            try interp.setResultString("foreach varlist is empty");
            return error.EvalError;
        }
        iter_state.appendAssumeCapacity(.{
            .stride = stride,
            .length = try interp.getListLength(&args[i * 2 + 2]),
            .current_index = 0,
        });
    }

    var result_list: Mutable = .{ .original = Heap.local_heap.emptyHandle() };
    errdefer result_list.discardChanges();

    while (true) {
        // Continue only if any list still has unconsumed elements.
        keep_going: for (0..list_count) |i| {
            const list_state = iter_state.get(i);
            if (list_state.current_index < list_state.length) break :keep_going;
        } else break;

        // Go through all the lists and assign their variables.
        for (0..list_count) |list_index| {
            var var_list = &args[list_index * 2 + 1];
            const value_list = &args[list_index * 2 + 2];

            const stride = iter_state.items(.stride)[list_index];
            const length = iter_state.items(.length)[list_index];
            const current_index = &iter_state.items(.current_index)[list_index];

            // Assign variables for this specific list.
            for (0..stride) |v| {
                var var_name = objutil.listItem(var_list.current(), @intCast(v));

                // Ensure the name can shimmer before passing to `setVariableInner`.
                var name_new: OptionalHandle = .none;
                try Heap.ensureShimmerableOrDup(var_name, &name_new);
                if (name_new.toHandle()) |new| {
                    // Write the duplicated handle back to the variable list.
                    try objutil.listSetInner(var_list.asMutable(), @intCast(v), new.referenceOwning());
                    var_name = objutil.listItem(var_list.current(), @intCast(v));
                }

                const value = if (current_index.* < length) blk: {
                    const item = objutil.listItem(value_list.current(), current_index.*);
                    current_index.* += 1;
                    break :blk item;
                } else Heap.local_heap.emptyHandle();

                var det: objutil.ErrorDetails = undefined;
                try interp.wrapError(&det, interp.setVariableInner(&det, interp.callFrameIdx(), var_name, value.dupOrRef()));
            }
        }

        // Evaluate body and handle break/continue.
        switch (try propagateLoopControl(interp, interp.evalObject(body.current()))) {
            .@"break" => break,
            .@"continue" => continue,
            .none => {
                if (mode == .map) _ = try interp.listAppend(&result_list, interp.result);
            },
        }
    }

    interp.setResultOwning(result_list.consume());
}

/// [foreach]
pub fn foreachCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    return foreachMapHelper(interp, args, .foreach);
}

test "loop commands" {
    var interp = try testStart(testing.allocator);
    defer testFinish(&interp);

    // Basic loop.
    try interp.testExpectScriptResult("5",
        \\ for {set i 0} {$i < 5} {incr i} { }
        \\ set i
    );

    // [continue]
    try interp.testExpectScriptResult("5",
        \\ for {set i 0} {$i < 5} {incr i} { continue }
        \\ set i
    );

    try interp.testExpectScriptResult("0",
        \\ for {set i 0} {$i < 5} {incr i} {
        \\   for {set j 0} {$j < 5} {incr j} {
        \\     continue 2
        \\   }
        \\ }
        \\ set j
    );

    // [foreach] basic iteration.
    try interp.testExpectScriptResult("6",
        \\ set sum 0
        \\ foreach i {1 2 3} { set sum [expr {$sum + $i}] }
        \\ set sum
    );

    // [foreach] with multiple list pairs.
    try interp.testExpectScriptResult("1 2 x y|3 4 z |",
        \\ set r ""
        \\ foreach {a b} {1 2 3 4} {c d} {x y z} {
        \\   append r "$a $b $c $d|"
        \\ }
        \\ set r
    );

    // [foreach] shorter valuelist than varlist (pad with empty strings).
    try interp.testExpectScriptResult("1 2|3 |",
        \\ set r ""
        \\ foreach {a b} {1 2 3} { append r "$a $b|" }
        \\ set r
    );

    // [foreach] empty valuelist (body never runs).
    try interp.testExpectScriptResult("0",
        \\ set sum 0
        \\ foreach i {} { set sum [expr {$sum + $i}] }
        \\ set sum
    );

    // [foreach] break inside foreach.
    try interp.testExpectScriptResult("6",
        \\ set sum 0
        \\ foreach i {1 2 3 4 5} {
        \\   if {$i > 3} { break }
        \\   set sum [expr {$sum + $i}]
        \\ }
        \\ set sum
    );

    // [foreach] continue inside foreach.
    try interp.testExpectScriptResult("12",
        \\ set sum 0
        \\ foreach i {1 2 3 4 5} {
        \\   if {$i == 3} { continue }
        \\   set sum [expr {$sum + $i}]
        \\ }
        \\ set sum
    );

    // [foreach] empty varlist error.
    try interp.testExpectScriptError(error.EvalError, "foreach varlist is empty",
        \\ foreach {} {1 2} { puts hi }
    );

    // [lmap] basic iteration.
    try interp.testExpectScriptResult("2 4 6",
        \\ lmap x {1 2 3} { expr {$x * 2} }
    );

    // [lmap] with multiple list pairs.
    try interp.testExpectScriptResult("{1 x} {2 y}",
        \\ lmap a {1 2} b {x y} { list $a $b }
    );

    // [lmap] continue skips the result.
    try interp.testExpectScriptResult("2 6",
        \\ lmap x {1 2 3} { if {$x == 2} { continue } ; expr {$x * 2} }
    );

    // [lmap] break stops early.
    try interp.testExpectScriptResult("2",
        \\ lmap x {1 2 3} { if {$x == 2} { break } ; expr {$x * 2} }
    );

    // [lmap] empty input list returns empty list.
    try interp.testExpectScriptResult("",
        \\ lmap x {} { expr {$x * 2} }
    );

    // [lmap] empty varlist error.
    try interp.testExpectScriptError(error.EvalError, "foreach varlist is empty",
        \\ lmap {} {1 2} { puts hi }
    );
}

/// [if]
pub fn ifCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    var remaining_args = args[1..];
    while (true) {
        // Need a condition and a body after.
        if (remaining_args.len < 2) return error.WrongUsage;

        // Check condition.
        if (try interp.getBoolFromExpression(remaining_args[0].current())) {
            // Evaluate true branch.
            try interp.evalObject(remaining_args[1].current());
            return;
        }

        // False branch, is there an else or elseif condition?
        remaining_args = remaining_args[2..];

        if (remaining_args.len == 0) {
            // `if` doesn't return anything if there's no else branch, and
            // the condition returned false.
            interp.setEmptyResult();
            return;
        }

        if (try remaining_args[0].current().equalsString("else")) {
            // There should only be one more argument, since there shouldn't
            // be anything after "else".
            if (remaining_args.len > 2) return error.WrongUsage;
            try interp.evalObject(remaining_args[1].current());
            return;
        }

        if (try remaining_args[0].current().equalsString("elseif")) {
            // Keep going.
            remaining_args = remaining_args[1..];
            continue;
        }

        // tcl doesn't require "else" for the last condition, but I think that's
        // too lax. We're more strict.
        return error.WrongUsage;
    }
}

/// [switch]
pub fn switchCmd(interp: *Interp, args: []Shimmerable) !void {
    const MatchType = enum { exact, glob, regex, command };
    var match_type: MatchType = .exact;

    var command_to_match: ?Handle = null;

    var arg_index: usize = 1;
    while (arg_index < args.len) : (arg_index += 1) {
        // Make sure we have something after, since we look ahead for some
        // of the flags.
        if (args.len - arg_index < 2) return error.WrongUsage;

        const bytes = try args[arg_index].getString();

        if (bytes[0] != '-') break; // Not a flag.
        if (try args[arg_index].current().equalsString("--")) {
            arg_index += 1;
            break;
        }
        if (try args[arg_index].current().equalsString("-exact")) {
            match_type = .exact;
        } else if (try args[arg_index].current().equalsString("-glob")) {
            match_type = .glob;
        } else if (try args[arg_index].current().equalsString("-regexp")) {
            match_type = .regex;
        } else if (try args[arg_index].current().equalsString("-command")) {
            match_type = .command;
            arg_index += 1;
            command_to_match = args[arg_index].current();
        } else {
            try interp.setResultFormatted(
                "bad option \"{f}\": must be -exact, -glob, -regexp, -command procname or --",
                .{args[arg_index].current()},
            );
            return error.EvalError;
        }
    }

    // Value we're switching on.
    const to_match_on = args[arg_index].current().borrow();
    defer to_match_on.decrRefCount();
    arg_index += 1;
    const to_match_on_bytes = try to_match_on.getString();

    const switch_body, var to_free_after = blk: {
        if (args.len - arg_index == 1) {
            try interp.shimmerToList(&args[arg_index]);
            const handles = try objutil.listToShimmerables(Heap.global_gpa, args[arg_index].current());
            break :blk .{ handles.items, handles };
        } else {
            if (@mod(args.len - arg_index, 2) != 0) return error.WrongUsage;
            break :blk .{ args[arg_index..], null };
        }
    };
    defer if (to_free_after) |*val| {
        for (switch_body) |*wb| wb.discardChanges();
        val.deinit(Heap.global_gpa);
    };

    // We need to borrow `body_to_run`, since it may mutate under us otherwise when `commandMatch` is called.
    var body_to_run: ?Handle = null;
    defer if (body_to_run) |val| val.decrRefCount();

    // Go through each switch arm until we find one that matches.
    var arm_idx: usize = 0;
    while (arm_idx < switch_body.len) : (arm_idx += 2) {
        const is_default = try switch_body[arm_idx].current().equalsString("default");
        // If `default` isn't the last arm in the switch body, we treat it
        // as a normal string to check against.
        if (!is_default or arm_idx < switch_body.len - 2) {
            switch (match_type) {
                .exact => {
                    if (try Heap.checkIfEqual(to_match_on, switch_body[arm_idx].current())) {
                        body_to_run = switch_body[arm_idx + 1].current().borrow();
                        break;
                    }
                },
                .glob => {
                    const matches = strutil.globMatch(try switch_body[arm_idx].getString(), to_match_on_bytes, false);
                    if (matches) {
                        body_to_run = switch_body[arm_idx + 1].current().borrow();
                        break;
                    }
                },
                .regex => {
                    var det: objutil.ErrorDetails = undefined;
                    const opts = pcre2.PCRE2_UTF | pcre2.PCRE2_UCP | pcre2.PCRE2_DOTALL;
                    try Interp.wrapError(interp, &det, objutil.shimmerToRegexp(&det, &switch_body[arm_idx], opts));
                    const regexp_handle = switch_body[arm_idx].current();

                    const re = regexp_handle.getRegexpExtraData();

                    const matches = try interp.wrapError(&det, regex.doesStringMatch(&det, re, to_match_on_bytes));
                    if (matches) {
                        body_to_run = switch_body[arm_idx + 1].current().borrow();
                        break; // Match!
                    } else continue;
                },
                .command => {
                    const matches = try commandMatch(interp, command_to_match.?, switch_body[arm_idx].current(), to_match_on);
                    if (matches) {
                        body_to_run = switch_body[arm_idx + 1].current().borrow();
                        break; // Match!
                    } else continue;
                },
            }
        } else {
            // Truly the default.
            body_to_run = switch_body[arm_idx + 1].current().borrow();
        }
    }

    interp.setEmptyResult();
    if (body_to_run) |to_run| {
        const to_run_fallthrough = if (try to_run.equalsString("-")) blk: {
            // Fall through if the body is `-`.
            var true_body_idx = arm_idx + 1;
            while (true_body_idx < switch_body.len) : (true_body_idx += 2) {
                if (!(try switch_body[true_body_idx].current().equalsString("-"))) break;
            } else {
                try interp.setResultFormatted("no body specified for pattern \"{f}\"", .{switch_body[arm_idx].current()});
            }
            break :blk switch_body[true_body_idx].current();
        } else to_run;

        try interp.evalObject(to_run_fallthrough);
    }
}

/// [error message ?errorCode?]
pub fn errorCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    interp.setResult(args[1].current());

    if (args.len >= 3) {
        // Store the error code so [catch]/[try] can pick it up.
        try interp.shimmerToList(&args[2]);
        interp.pending_error_code.swap(args[2].current().borrow());
    }

    return error.EvalError;
}

/// [return ?-option value ...? ?result?]
///
/// Supported options: -code, -level, -errorcode.
pub fn returnCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    var code: Interp.ReturnCode = .@"return";
    var level: u32 = 1;

    const Flags = objutil.TclEnum(enum { @"-code", @"-level", @"-errorcode" }, "[return] flags", false);

    var i: usize = 1;
    while (i + 1 < args.len) {
        const flag = &args[i];
        const value = &args[i + 1];

        const flag_value = Flags.get(null, flag) catch null;

        if (flag_value) |val| switch (val) {
            .@"-code" => {
                var det: objutil.ErrorDetails = undefined;
                code = try interp.wrapError(&det, Interp.ReturnCodeEnum.get(&det, value));
                i += 2;
            },
            .@"-level" => {
                const level_i64 = try interp.getInteger(value);
                if (level_i64 < 0 or level_i64 > std.math.maxInt(u32)) {
                    try interp.setResultFormatted("bad -level value \"{}\"", .{level_i64});
                    return error.EvalError;
                }
                level = @intCast(level_i64);
                i += 2;
            },
            .@"-errorcode" => {
                interp.pending_error_code.swapWithNone();
                interp.pending_error_code = value.current().borrow().toOptional();
                i += 2;
            },
        } else {
            // Remaining arg has the return value.
            break;
        }
    }

    // If there's a trailing result value, set it; otherwise keep current result.
    if (i < args.len) {
        interp.setResult(args[i].current());
    }

    // -level 0 means "don't propagate, just set the result."
    if (level == 0) return;

    // `evalObjectInner` decrements `left_to_go` each time PropagateResult bubbles up
    // one eval level. Starting at `level` means it lands exactly `level` frames up.
    interp.return_propagate = .{
        .left_to_go = level,
        .return_at_end = null,
    };

    return code.toError();
}

pub fn breakCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    if (args.len == 2) {
        const level = try interp.getInteger(&args[1]);
        if (level < 1) {
            try interp.setResultFormatted("break level \"{}\" lower than 1", .{level});
        } else if (level > std.math.maxInt(u32)) {
            try interp.setResultFormatted("break level \"{}\" too high", .{level});
        }

        interp.loop_propagate = @intCast(level);
    }

    return error.Break;
}

pub fn continueCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    if (args.len == 2) {
        const level = try interp.getInteger(&args[1]);
        if (level < 1) {
            try interp.setResultFormatted("continue level \"{}\" lower than 1", .{level});
        } else if (level > std.math.maxInt(u32)) {
            try interp.setResultFormatted("continue level \"{}\" too high", .{level});
        }

        interp.loop_propagate = @intCast(level);
    } else {
        interp.loop_propagate = 1;
    }

    return error.Continue;
}

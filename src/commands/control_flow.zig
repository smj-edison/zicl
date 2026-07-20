const std = @import("std");

const pcre2 = @import("pcre2");

const strutil = @import("../strutil.zig");
const regex = @import("../regex.zig");
const common = @import("common.zig");
const heap = common.heap;
const ErrorDetails = common.ErrorDetails;
const Value = common.Value;
const objects = common.objects;
const List = objects.List;
const Interp = common.Interp;
const Shimmerable = common.Shimmerable;
const registerCommand = common.registerCommand;

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

/// [for]
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

    // [foreach] can simultaneously loop over multiple lists, so it's easiest to
    // think of it as a zipping iteratoe. It's not quite a normal zip though,
    // since the stride over each list depends on how many variables it
    // captures.

    const list_count = (args.len - 2) / 2;

    // Track per-list iteration state.
    var iter_state: std.ArrayList(struct {
        stride: usize,
        length: usize,
        current_index: usize,
    }) = try .initCapacity(heap.local_arena, list_count);

    for (0..list_count) |i| {
        const list_variable_names = try interp.getList(&args[i * 2 + 1]);
        const list_values = try interp.getList(&args[i * 2 + 2]);
        const stride = list_variable_names.items.len;
        if (stride == 0) {
            try interp.setResultString("foreach varlist is empty");
            return error.EvalError;
        }
        iter_state.appendAssumeCapacity(.{
            .stride = stride,
            .length = list_values.items.len,
            .current_index = 0,
        });
    }

    const result_list = if (mode == .map) try List.new(&.{}) else null;
    errdefer if (result_list) |list| list.asHead().release();

    outer: while (true) {
        // Continue only if any list still has unconsumed elements.
        inner: for (0..list_count) |i| {
            if (iter_state.items[i].current_index < iter_state.items[i].length) break :inner;
        } else {
            // All lists have consumed their elements, so we're done.
            break :outer;
        }

        // Go through all the lists and assign their variables.
        for (0..list_count) |list_index| {
            const var_list = try interp.getList(&args[list_index * 2 + 1]);
            const value_list = try interp.getList(&args[list_index * 2 + 2]);

            const state = &iter_state.items[list_index];

            // Assign variables for this specific list.
            for (0..state.stride) |var_name_index| {
                var var_name: Shimmerable = .{ .original = var_list.items[var_name_index] };
                defer var_name.discardChanges();

                const value = if (state.current_index < state.length) blk: {
                    const item = value_list.items[state.current_index];
                    state.current_index += 1;
                    break :blk item;
                } else heap.interned_empty_string.get();

                try interp.setVariable(&var_name, value);
            }
        }

        // Evaluate body and handle break/continue.
        switch (try propagateLoopControl(interp, interp.evalObject(body.current()))) {
            .@"break" => break,
            .@"continue" => continue,
            .none => {
                if (result_list) |val| try val.append(interp.result);
            },
        }
    }

    if (result_list) |list| {
        interp.setResultOwning(list.asHead().asValue());
    } else {
        interp.setEmptyResult();
    }
}

/// [foreach]
pub fn foreachCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    return foreachMapHelper(interp, args, .foreach);
}

test "loop commands" {
    var interp = try common.testStart(std.testing.allocator);
    defer common.testFinish(&interp);

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

fn commandMatch(interp: *Interp, command: Value, pattern: Value, string: Value) !bool {
    const script = try objects.List.new(&.{ command, pattern, string });
    defer script.asHead().release();
    try interp.evalObject(script.asHead().asValue());
    return try interp.getBooleanInPlace(&interp.result);
}

/// [switch]
pub fn switchCmd(interp: *Interp, args: []Shimmerable) !void {
    const MatchType = enum { exact, glob, regex, command };
    var match_type: MatchType = .exact;

    var command_to_match: ?Value = null;

    var arg_index: usize = 1;
    while (arg_index < args.len) : (arg_index += 1) {
        // Make sure we have something after, since we look ahead for some
        // of the flags.
        if (args.len - arg_index < 2) return error.WrongUsage;

        const bytes = try args[arg_index].current().getString();

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
                "bad option \"{s}\": must be -exact, -glob, -regexp, -command procname or --",
                .{try args[arg_index].current().getString()},
            );
            return error.EvalError;
        }
    }

    // Value we're switching on.
    const to_match_on = args[arg_index].current().borrow();
    defer to_match_on.release();
    arg_index += 1;
    const to_match_on_bytes = try to_match_on.getString();

    const switch_body, const should_discard_changes = blk: {
        if (args.len - arg_index == 1) {
            const as_list = try interp.getList(&args[arg_index]);
            const handles = try objects.valuesToShimmerables(heap.local_arena, as_list.items);
            break :blk .{ handles, true };
        } else {
            if (@mod(args.len - arg_index, 2) != 0) return error.WrongUsage;
            break :blk .{ args[arg_index..], false };
        }
    };
    defer if (should_discard_changes) for (switch_body) |*wb| wb.discardChanges();

    // We need to borrow `body_to_run`, since it may mutate under us when `commandMatch` is called.
    var body_to_run: ?Value = null;
    defer if (body_to_run) |val| val.release();

    // Go through each switch arm until we find one that matches.
    var arm_idx: usize = 0;
    while (arm_idx < switch_body.len) : (arm_idx += 2) {
        const is_default = try switch_body[arm_idx].current().equalsString("default");
        // If `default` isn't the last arm in the switch body, we treat it
        // as a normal string to check against.
        if (!is_default or arm_idx < switch_body.len - 2) {
            switch (match_type) {
                .exact => {
                    if (try to_match_on.equals(switch_body[arm_idx].current())) {
                        body_to_run = switch_body[arm_idx + 1].current().borrow();
                        break;
                    }
                },
                .glob => {
                    const matches = strutil.globMatch(try switch_body[arm_idx].current().getString(), to_match_on_bytes, false);
                    if (matches) {
                        body_to_run = switch_body[arm_idx + 1].current().borrow();
                        break;
                    }
                },
                .regex => {
                    var det: ErrorDetails = undefined;
                    const opts = pcre2.PCRE2_UTF | pcre2.PCRE2_UCP | pcre2.PCRE2_DOTALL;
                    const regexp = try interp.wrapError(&det, regex.Regexp.shimmerFrom(&det, &switch_body[arm_idx], opts));

                    const matches = try interp.wrapError(&det, regex.doesStringMatch(&det, regexp.regexp, to_match_on_bytes));
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
                try interp.setResultFormatted(
                    "no body specified for pattern \"{s}\"",
                    .{try switch_body[arm_idx].current().getString()},
                );
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

    const Flags = objects.EnumConstructor(enum { @"-code", @"-level", @"-errorcode" }, false);

    var i: usize = 1;
    while (i + 1 < args.len) {
        const flag = &args[i];
        const value = &args[i + 1];

        const flag_value = Flags.get(null, flag) catch null;

        if (flag_value) |val| switch (val) {
            .@"-code" => {
                var det: ErrorDetails = undefined;
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
                interp.pending_error_code.swap(value.current().borrow());
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

/// [break]
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

/// [continue]
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

pub fn registerCommands(interp: *Interp) !void {
    try registerCommand(interp, "break", breakCmd, "?level?", 0, 1, null);
    try registerCommand(interp, "continue", continueCmd, "?level?", 0, 1, null);
    try registerCommand(interp, "error", errorCmd, "message ?errorCode?", 1, 2, null);
    try registerCommand(interp, "for", forCmd, "start test next body", 4, 4, null);
    try registerCommand(interp, "foreach", foreachCmd, "varList list ?varList list ...? body", 3, null, 2);
    try registerCommand(interp, "if", ifCmd, "condition trueBody ?elseif ...? ?else falseBody?", 2, null, null);
    try registerCommand(interp, "return", returnCmd, "?-option value ...? ?result?", 0, null, null);
    try registerCommand(interp, "switch", switchCmd, "?options? string pattern body ... ?default body? or pattern body ?pattern body ...?", 2, null, null);
}

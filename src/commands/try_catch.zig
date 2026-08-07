const std = @import("std");
const assert = std.debug.assert;

const common = @import("common.zig");
const heap = common.heap;
const objects = common.objects;
const Value = common.Value;
const OptionalValue = heap.OptionalValue;
const Dictionary = objects.Dictionary;
const Interp = common.Interp;
const Shimmerable = common.Shimmerable;
const registerCommand = common.registerCommand;
const memutil = common.memutil;

const interned_code = heap.InternedString.newValue("-code");
const interned_level = heap.InternedString.newValue("-level");
const interned_errorstack = heap.InternedString.newValue("-errorstack");
const interned_errorcode = heap.InternedString.newValue("-errorcode");
const interned_during = heap.InternedString.newValue("-during");

fn buildErrorOptions(
    interp: *Interp,
    exit_code: Interp.ReturnCode,
    stack_trace: OptionalValue,
    error_code: OptionalValue,
    during: OptionalValue,
) error{OutOfMemory}!Value {
    const options = try Dictionary.newWithCapacity(&.{}, 10);
    errdefer options.asHead().release();

    // The return code surfaced to the caller. `.return` is an internal code, and
    // a return still travelling outward is on its way to completing normally, so
    // what the caller sees for it is ok.
    const visible_code: i64 = if (exit_code == .@"return")
        @intFromEnum(@as(Interp.ReturnCode, .ok))
    else
        @intFromEnum(exit_code);

    try options.put(interned_code, objects.Integer.new(visible_code));
    try options.put(interned_level, objects.Integer.new(interp.return_propagate.left_to_go));

    if (exit_code == .@"error") {
        if (stack_trace.asValue()) |val| try options.put(interned_errorstack, val);
        if (error_code.asValue()) |val| try options.put(interned_errorcode, val);
    }

    if (during.asValue()) |val| try options.put(interned_during, val);

    return options.asHead().asValue();
}

fn buildErrorOptionsBestEffort(
    interp: *Interp,
    exit_code: Interp.ReturnCode,
    stack_trace: OptionalValue,
    error_code: OptionalValue,
    during: OptionalValue,
) Value {
    return buildErrorOptions(interp, exit_code, stack_trace, error_code, during) catch {
        return heap.oom_error_options_dict.?.borrow();
    };
}

/// Implements both [catch] and [try].
fn catchTryHelper(
    interp: *Interp,
    mode: enum { @"catch", @"try" },
    args: []Shimmerable,
) Interp.Error!void {
    // Make sure to clear the last pending error code, if it exists.
    interp.pending_error_code.swapWithNone();
    interp.pending_error_during.swapWithNone();

    // If we catch an return code and it's in this set, we propagate it up instead of returning it.
    var to_propagate = std.EnumSet(Interp.ReturnCode).initEmpty();
    // By default these return codes are ignored, e.g. propagated.
    to_propagate.insert(.exit);
    // Out of memory belongs to the allocator's caller, not the script: catching it
    // would report code 7 as an ordinary result and hide that anything failed.
    to_propagate.insert(.oom);

    // The caller may have specified a different set of codes to propagate/catch. The
    // format is -no"code", or -"code". For example, -nobreak would propagate break.
    // This loop sorts out all these flags.
    var arg_index: usize = 1;
    while (arg_index < args.len) : (arg_index += 1) {
        const str_value = try args[arg_index].getString();

        if (std.mem.eql(u8, str_value, "--")) {
            arg_index += 1; // Advance to just after `--`.
            break;
        }

        if (str_value[0] != '-') break; // Not a flag.

        if (str_value.len >= 3 and std.mem.eql(u8, str_value[0..3], "-no")) {
            if (Interp.ReturnCodeEnum.map.get(str_value[3..])) |val| {
                to_propagate.insert(val);
            } else return error.WrongUsage;
        } else {
            if (Interp.ReturnCodeEnum.map.get(str_value[1..])) |val| {
                to_propagate.remove(val);
            } else return error.WrongUsage;
        }
    }
    to_propagate.remove(.ok); // Not a valid code to deal with.

    // Make sure there's at least another argument after the flags.
    if (args.len - arg_index < 1) return error.WrongUsage;

    const script = args[arg_index];
    arg_index += 1;
    const exit_code: Interp.ReturnCode = blk: {
        if (interp.evalValue(script.current())) {
            // Evaluated just fine.
            break :blk .ok;
        } else |err| {
            break :blk Interp.ReturnCode.fromError(err);
        }
    };
    var error_code = interp.pending_error_code;
    interp.pending_error_code = .none;
    defer error_code.release();
    const stack_trace = interp.stack_trace;
    interp.stack_trace = .none;
    defer stack_trace.release();

    // In this next section, we need to find if there's a script that we need to run
    // to handle the associated error. The following logic determines what branch
    // (if any) applies, and whether there's a `finally` branch.

    // You may ask: why do we have `branch_matched` and `handler_script`? Well, we support
    // Tcl's fall-through logic, where you can have `-` as the body of your script, and
    // it'll fall through until it hits an actual implementation.
    //
    // If `branch_matched` is true, but `handler_script` is null, it means we've hit a
    // branch but haven't found its script yet.
    var branch_matched = false;
    var handler_script: ?Value = null;
    defer if (handler_script) |val| val.release();
    var finally_script: ?Value = null;
    defer if (finally_script) |val| val.release();
    var message_var_name: ?Value = null;
    defer if (message_var_name) |val| val.release();
    var options_var_name: ?Value = null;
    defer if (options_var_name) |val| val.release();

    if (mode == .@"try") {
        // For [try], we need to find either a matching `on` or a matching `trap`.
        // We also need to see if there's a `finally`. If we find a matching branch,
        // we set `handler_script`, as well as `message_var_name` and `options_var_name`
        // if present. We also set `finally_script` if there's a `finally` branch.
        const TryOptions = objects.EnumConstructor(enum { on, trap, finally }, false);

        outer: while (arg_index < args.len) {
            const option = TryOptions.get(null, &args[arg_index]) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.BadEnumVariant => return error.WrongUsage,
            };
            switch (option) {
                .on => {
                    if (args.len - arg_index < 4) return error.WrongUsage;
                    const on_params = args[arg_index..][0..4];
                    arg_index += 4;

                    // Already found a match, so skip this branch.
                    if (handler_script != null) continue;

                    if (branch_matched) {
                        // Fall through logic.
                    } else {
                        const match_against = Interp.ReturnCodeEnum.get(null, &on_params[1]) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.BadEnumVariant => return error.WrongUsage,
                        };
                        if (exit_code != match_against) {
                            // Didn't match what we're looking for.
                            continue;
                        }
                    }

                    // If we got here, it means we either matched, or are falling through.
                    if (try on_params[3].current().equalsString("-")) {
                        // If the script is `-`, it means fall through.
                        branch_matched = true;
                        continue;
                    }

                    handler_script = on_params[3].current().borrow();

                    const vars_to_bind = try interp.getList(&on_params[2]);
                    if (vars_to_bind.items.len > 0) message_var_name = vars_to_bind.items[0].borrow();
                    if (vars_to_bind.items.len > 1) options_var_name = vars_to_bind.items[1].borrow();
                },
                .trap => {
                    if (args.len - arg_index < 4) return error.WrongUsage;
                    const trap_params = args[arg_index..][0..4];
                    arg_index += 4;

                    // Already found a match, so skip this branch.
                    if (handler_script != null) continue;

                    if (branch_matched) {
                        // Fall through logic.
                    } else {
                        // Don't check the trap if no error was reported.
                        if (exit_code != .@"error") continue;

                        if (error_code.asValue()) |code| {
                            var code_shim: Shimmerable = .{ .original = code };
                            defer code_shim.discardChanges();
                            const code_list = try interp.getList(&code_shim);
                            const match_code = &trap_params[1]; // Error code to match against.
                            const match_list = try interp.getList(match_code);

                            // If the code we're wanting to check is longer than the returned
                            // error code, it obviously doesn't match.
                            if (match_list.items.len > code_list.items.len) continue;

                            for (match_list.items, code_list.items[0..match_list.items.len]) |match_item, code_item| {
                                if (!try code_item.equals(match_item)) {
                                    // Not the same, since this item wasn't the same.
                                    continue :outer;
                                }
                            }
                        }
                    }

                    // If we got here, it means we either matched, or are falling through.
                    if (try trap_params[3].current().equalsString("-")) {
                        // If the script is `-`, it means fall through.
                        branch_matched = true;
                        continue;
                    }

                    handler_script = trap_params[3].current().borrow();

                    const vars_to_bind = try interp.getList(&trap_params[2]);
                    if (vars_to_bind.items.len > 0) message_var_name = vars_to_bind.items[0].borrow();
                    if (vars_to_bind.items.len > 1) options_var_name = vars_to_bind.items[1].borrow();
                },
                .finally => {
                    if (args.len - arg_index != 2) return error.WrongUsage;
                    const finally_params = args[arg_index..][0..2];
                    arg_index += 2;

                    finally_script = finally_params[1].current().borrow();
                    if (try finally_script.?.equalsString("-")) return error.WrongUsage;
                },
            }
        }
    } else {
        if (args.len - arg_index > 0) {
            message_var_name = args[arg_index].current().borrow();
            arg_index += 1;
        }
        if (args.len - arg_index > 0) {
            options_var_name = args[arg_index].current().borrow();
            arg_index += 1;
        }
    }

    if (to_propagate.contains(exit_code)) {
        // Not caught, so we'll propagate it.
        if (finally_script) |val| {
            // Use `try` here, since according to Tcl, an error in `finally` should
            // replace the original error.
            try interp.evalValue(val);
        }
        return exit_code.toError();
    }

    if (message_var_name) |var_name| if ((try var_name.getString()).len > 0) {
        var var_name_shim: Shimmerable = .{ .original = var_name };
        defer var_name_shim.discardChanges();

        const current_error = interp.result;
        try interp.setVariable(&var_name_shim, current_error);
    };

    var options_dict: OptionalValue = .none;
    defer options_dict.release();

    if (options_var_name) |var_name| if ((try var_name.getString()).len > 0) {
        var var_name_shim: Shimmerable = .{ .original = var_name };
        defer var_name_shim.discardChanges();

        if (options_dict.isNone()) {
            options_dict.swap(buildErrorOptionsBestEffort(interp, exit_code, stack_trace, error_code, .none));
        }

        try interp.setVariable(&var_name_shim, options_dict.asValue().?);
    };

    var script_result: Interp.Error!void = exit_code.toError();
    if (handler_script) |handler| {
        // Now that we've set up the message and options variables,
        // the handler will have the variables it needs to run.
        if (interp.evalValue(handler)) {
            script_result = {};
        } else |err| {
            // We still need to run the finally block, which is why
            // we can't use `try` in this scenario.
            script_result = err;

            if (options_dict.isNone()) {
                options_dict.swap(buildErrorOptionsBestEffort(interp, exit_code, stack_trace, error_code, .none));
            }

            interp.pending_error_during.swap(options_dict.asValue().?.borrow());
            options_dict.swap(buildErrorOptionsBestEffort(
                interp,
                Interp.ReturnCode.fromError(err),
                interp.stack_trace,
                interp.pending_error_code,
                options_dict,
            ));
        }
    }

    if (finally_script) |finally| {
        // Save the previous result, so if the `finally` runs successfully,
        // we restore the previous result.
        const previous_result = interp.result.borrow();
        defer previous_result.release();

        if (interp.evalValue(finally)) {
            interp.setResult(previous_result);
        } else |err| {
            script_result = err;

            if (options_dict.isNone()) {
                options_dict.swap(buildErrorOptionsBestEffort(interp, exit_code, stack_trace, error_code, .none));
            }

            interp.pending_error_during.swap(options_dict.asValue().?.borrow());
        }
    }

    // The handler and finally scripts run past the `to_propagate` check above, so an
    // OOM in either still has to escape.
    script_result catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };

    switch (mode) {
        .@"catch" => {
            try interp.setResultInteger(@intFromEnum(Interp.ReturnCode.fromErrorUnion(script_result)));
            return;
        },
        .@"try" => {
            return script_result;
        },
    }
}

/// [catch script ?resultVar? ?optsVar?]
pub fn catchCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    return catchTryHelper(interp, .@"catch", args);
}

/// [try script ?handler ...? ?finally body?]
pub fn tryCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    return catchTryHelper(interp, .@"try", args);
}

pub fn registerCommands(interp: *Interp) !void {
    try registerCommand(interp, "catch", catchCmd, "?options? script ?resultVar? ?optionsVar?", 1, null);
    try registerCommand(interp, "try", tryCmd, "?options? body ?handler ...? ?finally script?", 1, null);
}

const testing = std.testing;

fn testCatchAndError(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Basic catch -- normal return gives code 0.
    try interp.testExpectScriptResult("0",
        \\ catch { set x 42 }
    );

    // Catch an error -- code 1.
    try interp.testExpectScriptResult("1",
        \\ catch { error "boom" }
    );

    // Capture result variable.
    try interp.testExpectScriptResult("boom",
        \\ catch { error "boom" } msg
        \\ set msg
    );

    // Capture opts variable and check -code.
    try interp.testExpectScriptResult("1",
        \\ catch { error "boom" } msg opts
        \\ dict get $opts -code
    );

    // [error] with a custom error code.
    try interp.testExpectScriptResult("MY CODE",
        \\ catch { error "boom" {MY CODE} } msg opts
        \\ dict get $opts -errorcode
    );
}

test "catch and error" {
    try memutil.checkAllocationFailures(
        .{ .unsupported = "reading the options dict goes through `buildErrorOptionsBestEffort`, which answers a failed allocation with the preallocated fallback dict, so an injected failure changes what the script reads instead of raising" },
        testCatchAndError,
        .{},
    );
}

fn testTryCommand(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // try with on handler matching error.
    try interp.testExpectScriptResult("caught: boom",
        \\ try {
        \\   error "boom"
        \\ } on error {msg} {
        \\   set msg "caught: $msg"
        \\ }
    );

    // try with finally. The two bodies write distinguishable values, so this
    // fails if either one is skipped or if they run in the wrong order.
    try interp.testExpectScriptResult("body",
        \\ set marker none
        \\ try { set marker body } finally { set marker "$marker,finally" }
    );
    // The body's result survives the finally, but the finally still ran.
    try interp.testExpectScriptResult("body,finally", "set marker");

    // try with on ok handler.
    try interp.testExpectScriptResult("ok result",
        \\ try { set result "ok result" } on ok {val} { set val }
    );
}

test "try command" {
    try memutil.checkAllocationFailures(.exhaustive, testTryCommand, .{});
}

fn testTryTrapMatchesAnErrorCodePrefix(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // A trap pattern matches when it is a prefix of the raised -errorcode.
    try interp.testExpectScriptResult("trapped: boom",
        \\ try {
        \\   error "boom" {ARITH DIVZERO}
        \\ } trap {ARITH} {msg} {
        \\   set msg "trapped: $msg"
        \\ }
    );

    // An exact match works too.
    try interp.testExpectScriptResult("trapped",
        \\ try { error "boom" {ARITH DIVZERO} } trap {ARITH DIVZERO} {msg} { return trapped }
    );

    // A pattern longer than the code cannot match, so this falls to [on error].
    try interp.testExpectScriptResult("fell through",
        \\ try {
        \\   error "boom" {ARITH}
        \\ } trap {ARITH DIVZERO} {msg} {
        \\   return trapped
        \\ } on error {msg} {
        \\   return "fell through"
        \\ }
    );

    // A pattern that differs on an element does not match either.
    try interp.testExpectScriptResult("fell through",
        \\ try {
        \\   error "boom" {ARITH DIVZERO}
        \\ } trap {POSIX ENOENT} {msg} {
        \\   return trapped
        \\ } on error {msg} {
        \\   return "fell through"
        \\ }
    );
}

test "try trap matches an error code prefix" {
    try memutil.checkAllocationFailures(
        .{ .unsupported = "the handler's [return] goes through `buildErrorOptionsBestEffort`, which absorbs a failed allocation into the preallocated fallback dict, so the test still passes and the injection never reaches the harness" },
        testTryTrapMatchesAnErrorCodePrefix,
        .{},
    );
}

fn testTryFallsThroughAHandlerWhoseBodyIsADash(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // `-` means "use the next handler's body", which is how Tcl shares one
    // implementation across several codes.
    try interp.testExpectScriptResult("shared",
        \\ try {
        \\   error "boom"
        \\ } on error {msg} - on break {msg} {
        \\   return shared
        \\ }
    );
}

test "try falls through a handler whose body is a dash" {
    try memutil.checkAllocationFailures(
        .{ .unsupported = "the handler's [return] goes through `buildErrorOptionsBestEffort`, which absorbs a failed allocation into the preallocated fallback dict, so the test still passes and the injection never reaches the harness" },
        testTryFallsThroughAHandlerWhoseBodyIsADash,
        .{},
    );
}

fn testTryRunsFinallyOnBothSuccessAndFailure(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // The finally body runs even when a handler caught an error, and the
    // handler's result survives it.
    try interp.testExpectScriptResult("handled",
        \\ set marker none
        \\ try { error "boom" } on error {msg} { return handled } finally { set marker ran }
    );
    try interp.testExpectScriptResult("ran", "set marker");

    // An error inside finally replaces the original result.
    try interp.testExpectScriptError(error.EvalError, "from finally",
        \\ try { set x fine } finally { error "from finally" }
    );
}

test "try runs finally on both success and failure" {
    try memutil.checkAllocationFailures(
        .{ .unsupported = "the handler's [return] goes through `buildErrorOptionsBestEffort`, which absorbs a failed allocation into the preallocated fallback dict, so the test still passes and the injection never reaches the harness" },
        testTryRunsFinallyOnBothSuccessAndFailure,
        .{},
    );
}

fn testThePreallocatedOOMFallbackIsAUsableOptionsDict(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // `buildErrorOptionsBestEffort` hands this out when it cannot allocate, and
    // the [try] logic reads codes straight out of it, so it has to already be a
    // dictionary rather than a string that would need shimmering to become one.
    const fallback = heap.oom_error_options_dict.?;
    try testing.expect(fallback.asType(Dictionary) != null);

    var name: Shimmerable = .{ .original = try objects.String.newValue("opts") };
    defer name.deinit();
    try interp.setVariable(&name, fallback);

    try interp.testExpectScriptResult("1", "dict get $opts -code");
    try interp.testExpectScriptResult("0", "dict get $opts -level");
    // `ZICL OOM` rather than Tcl's `NONE`, so a script can tell this fallback
    // apart from a genuine error that simply carried no code.
    try interp.testExpectScriptResult("ZICL OOM", "dict get $opts -errorcode");
}

test "the preallocated OOM fallback is a usable options dict" {
    try memutil.checkAllocationFailures(.exhaustive, testThePreallocatedOOMFallbackIsAUsableOptionsDict, .{});
}

fn testCatchReportsTheCodeOfNonErrorOutcomes(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // 3 is `return`. [catch] observes it because a body is not a closure call,
    // so nothing consumed the level before it got here.
    try interp.testExpectScriptResult("3", "catch { return foo }");
    // The caught result is still readable.
    try interp.testExpectScriptResult("foo", "catch { return foo } msg; set msg");

    // The options describe the return rather than the catch: a `[return]` is on
    // its way to completing normally, so its own code is 0, and one level is
    // still outstanding because nothing has consumed it yet.
    try interp.testExpectScriptResult("0", "catch { return foo } msg opts; dict get $opts -code");
    try interp.testExpectScriptResult("1", "catch { return foo } msg opts; dict get $opts -level");
    // 4 is `break`, 5 is `continue`.
    try interp.testExpectScriptResult("4", "catch { break }");
    try interp.testExpectScriptResult("5", "catch { continue }");
}

test "catch reports the code of non-error outcomes" {
    try memutil.checkAllocationFailures(
        .{ .unsupported = "reading the options dict goes through `buildErrorOptionsBestEffort`, which answers a failed allocation with the preallocated fallback dict, so an injected failure changes what the script reads instead of raising" },
        testCatchReportsTheCodeOfNonErrorOutcomes,
        .{},
    );
}

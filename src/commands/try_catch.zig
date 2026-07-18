fn buildErrorOptions(
    interp: *Interp,
    exit_code: Interp.ReturnCode,
    stack_trace: OptionalHandle,
    error_code: OptionalHandle,
    during: OptionalHandle,
) error{OutOfMemory}!Handle {
    const options = try objutil.newDictWithCapacity(10);

    // The return code surfaced to the caller.
    const visible_code: i64 = code: {
        // .return is an internal return type, so it should never be surfaced to the callee.
        if (exit_code == .@"return") {
            if (interp.return_propagate.return_at_end) |to_return| {
                break :code @intFromEnum(Interp.ReturnCode.fromErrorUnion(to_return));
            } else {
                break :code @intFromEnum(@as(Interp.ReturnCode, .ok));
            }
        } else {
            break :code @intFromEnum(exit_code);
        }
    };

    objutil.dictPutAssumeCapacity(options, Heap.local_heap.getInternedString(.@"-code"), objutil.integerObject(visible_code));
    objutil.dictPutAssumeCapacity(
        options,
        Heap.local_heap.getInternedString(.@"-level"),
        objutil.integerObject(interp.return_propagate.left_to_go),
    );

    if (exit_code == .@"error") {
        if (stack_trace.toHandle()) |val| {
            objutil.dictPutAssumeCapacity(options, Heap.local_heap.getInternedString(.@"-errorstack"), val.reference());
        }

        if (error_code.toHandle()) |val| {
            objutil.dictPutAssumeCapacity(options, Heap.local_heap.getInternedString(.@"-errorcode"), val.reference());
        }
    }

    if (during.toHandle()) |val| {
        objutil.dictPutAssumeCapacity(options, Heap.local_heap.getInternedString(.@"-during"), val.reference());
    }

    return options;
}

fn buildErrorOptionsBestEffort(
    interp: *Interp,
    exit_code: Interp.ReturnCode,
    stack_trace: OptionalHandle,
    error_code: OptionalHandle,
    during: OptionalHandle,
) Handle {
    return buildErrorOptions(interp, exit_code, stack_trace, error_code, during) catch {
        return Heap.local_heap.oom_error_options_dict.?.borrow();
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
    to_propagate.insert(.signal);

    // The caller may have specified a different set of codes to propagate/catch. The
    // format is -no"code", or -"code". For example, -nobreak would propagate break,
    // while -signal would catch a signal return code. This loop sorts out all these flags.
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
                to_propagate.insert(val);
            } else return error.WrongUsage;
        }
    }
    to_propagate.remove(.ok); // Not a valid code to deal with.

    // Make sure there's at least another argument after the flags.
    if (args.len - arg_index < 1) return error.WrongUsage;

    const script = args[arg_index];
    arg_index += 1;
    const exit_code: Interp.ReturnCode = blk: {
        if (!to_propagate.contains(.signal)) interp.signal_depth += 1;
        defer {
            if (!to_propagate.contains(.signal)) interp.signal_depth -= 1;
        }

        if (interp.checkSignal()) {
            // If a signal was set, don't evaluate the code, just
            // set the return code to .signal.
            break :blk .signal;
        } else {
            if (interp.evalObject(script.current())) {
                // Evaluated just fine.
                break :blk .ok;
            } else |err| {
                break :blk Interp.ReturnCode.fromErrorUnion(err);
            }
        }
    };
    var error_code = interp.pending_error_code;
    interp.pending_error_code = .none;
    defer error_code.decrOptional();
    const stack_trace = interp.stack_trace;
    interp.stack_trace = .none;
    defer stack_trace.decrOptional();

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
    var handler_script: ?Handle = null;
    defer if (handler_script) |val| val.decrRefCount();
    var finally_script: ?Handle = null;
    defer if (finally_script) |val| val.decrRefCount();
    var message_var_name: ?Handle = null;
    defer if (message_var_name) |val| val.decrRefCount();
    var options_var_name: ?Handle = null;
    defer if (options_var_name) |val| val.decrRefCount();

    if (mode == .@"try") {
        // For [try], we need to find either a matching `on` or a matching `trap`.
        // We also need to see if there's a `finally`. If we find a matching branch,
        // we set `handler_script`, as well as `message_var_name` and `options_var_name`
        // if present. We also set `finally_script` if there's a `finally` branch.
        const TryOptions = objutil.TclEnum(enum { on, trap, finally }, "try options", false);

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

                    const vars_to_bind_len = try interp.getListLength(&on_params[2]);
                    if (vars_to_bind_len > 0) message_var_name = objutil.listItem(on_params[2].current(), 0).borrow();
                    if (vars_to_bind_len > 1) options_var_name = objutil.listItem(on_params[2].current(), 1).borrow();
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

                        if (error_code.toHandleRef()) |code| {
                            const code_len = try interp.getListLengthInPlace(code);
                            const match_code = &trap_params[1]; // Error code to match against.
                            const match_code_len = try interp.getListLength(match_code);

                            // If the code we're wanting to check is longer than the returned
                            // error code, it obviously doesn't match.
                            if (match_code_len > code_len) continue;

                            for (0..match_code_len) |i| {
                                const code_item = objutil.listItem(code.*, @intCast(i));
                                const match_item = objutil.listItem(match_code.current(), @intCast(i));
                                if (!try Heap.checkIfEqual(code_item, match_item)) {
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

                    const vars_to_bind_len = try interp.getListLength(&trap_params[2]);
                    if (vars_to_bind_len > 0) message_var_name = objutil.listItem(trap_params[2].current(), 0).borrow();
                    if (vars_to_bind_len > 1) options_var_name = objutil.listItem(trap_params[2].current(), 1).borrow();
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
            try interp.evalObject(val);
        }
        return exit_code.toError();
    }

    if (!to_propagate.contains(.signal) and exit_code == .signal) {
        // Construct the signal result here, instead of wherever the signal
        // originated from.
        assert(interp.signal != 0);
        const signal_list = try Interp.signalMaskToList(interp.signal);
        interp.setResultOwning(signal_list);
        interp.signal = 0;
    }

    if (message_var_name) |var_name| if ((try var_name.getString()).len > 0) {
        var var_name_wb: Shimmerable = .{ .original = var_name };
        defer var_name_wb.discardChanges();

        const current_error = interp.result;
        try interp.setVariableTo(&var_name_wb, current_error);
    };

    var options_dict: OptionalHandle = .none;
    defer options_dict.decrOptional();

    if (options_var_name) |var_name| if ((try var_name.getString()).len > 0) {
        var var_name_wb: Shimmerable = .{ .original = var_name };
        defer var_name_wb.discardChanges();

        if (options_dict == .none) {
            const options = buildErrorOptionsBestEffort(interp, exit_code, stack_trace, error_code, .none);
            options_dict = options.toOptional();
        }

        try interp.setVariableTo(&var_name_wb, options_dict.toHandle().?);
    };

    var script_result: Interp.Error!void = exit_code.toError();
    if (handler_script) |handler| {
        // Now that we've set up the message and options variables,
        // the handler will have the variables it needs to run.
        if (interp.evalObject(handler)) {
            script_result = {};
        } else |err| {
            // We still need to run the finally block, which is why
            // we can't use `try` in this scenario.
            script_result = err;

            if (options_dict == .none) {
                const options = buildErrorOptionsBestEffort(interp, exit_code, stack_trace, error_code, .none);
                options_dict = options.toOptional();
            }

            interp.pending_error_during.swap(options_dict.toHandle().?.borrow());
            options_dict.swap(buildErrorOptionsBestEffort(
                interp,
                Interp.ReturnCode.fromErrorUnion(err),
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
        defer previous_result.decrRefCount();

        if (interp.evalObject(finally)) {
            interp.setResult(previous_result);
        } else |err| {
            script_result = err;

            if (options_dict == .none) {
                const options = buildErrorOptionsBestEffort(interp, exit_code, stack_trace, error_code, .none);
                options_dict = options.toOptional();
            }

            interp.pending_error_during.swap(options_dict.toHandle().?.borrow());
        }
    }

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

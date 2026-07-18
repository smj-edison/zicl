pub fn exprCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const result = try (try interp.evalExpression(args[1].current())).toObject();
    defer result.decrRefCount();
    interp.setResult(result);
}

pub fn substCmd(interp: *Interp, args: []Shimmerable) !void {
    var flags: Tokenizer.SubstFlags = .{
        .command_subst = true,
        .variable_subst = true,
        .escape_subst = true,
    };

    for (1..(args.len - 1)) |arg_index| {
        if (try args[arg_index].current().equalsString("-nocommands")) {
            flags.command_subst = false;
        } else if (try args[arg_index].current().equalsString("-novariables")) {
            flags.variable_subst = false;
        } else if (try args[arg_index].current().equalsString("-nobackslashes")) {
            flags.escape_subst = false;
        }

        try interp.setResultFormatted(
            "bad option \"{f}\": must be -nocommands, -novariables, or -nobackslashes",
            .{args[arg_index].current()},
        );
        return error.EvalError;
    }

    const to_substitute = &args[args.len - 1];
    interp.setResultOwning(try interp.evalSubstitution(to_substitute.current(), flags));
}

/// [uplevel] - evaluate a script in an upper scope.
/// Syntax: uplevel ?level? script ?arg ...?
pub fn uplevelCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    if (args.len < 2) return error.WrongUsage;

    var script_start: usize = 1;
    var levels_up: u32 = 1;

    const first_str = try args[1].getString();
    if (first_str.len > 0 and (first_str[0] >= '0' and first_str[0] <= '9')) {
        if (interp.getInteger(&args[1])) |level| {
            if (level >= 0) {
                levels_up = @intCast(level);
                script_start = 2;
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

    if (args.len - script_start < 1) return error.WrongUsage;

    const current_frame = interp.callFrameIdx();
    if (current_frame < levels_up) {
        try interp.setResultString("bad level");
        return error.EvalError;
    }
    const target_frame = current_frame - levels_up;

    const script, const is_new_script = blk: {
        if (args.len - script_start == 1) {
            break :blk .{ args[script_start].current(), false };
        }
        const list = try objutil.newListFromShimmerables(args[script_start..]);
        break :blk .{ list, true };
    };
    defer if (is_new_script) script.decrRefCount();

    const cache_key = @as(u256, interp.call_frames.items[target_frame].signature.cache_id) ^ try script.getHashNoRegister();
    return interp.evalObjectInner(target_frame, script, cache_key);
}

pub fn evalCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    if (args.len == 2) {
        try interp.evalObject(args[1].current());
    } else {
        try interp.evalObject(try objutil.newListFromShimmerables(args[1..]));
    }
}

/// [apply]
pub fn applyCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    var det: objutil.ErrorDetails = undefined;
    const closure_and_key = try interp.wrapError(&det, interp.getClosure(&det, args[1].current(), false));

    // args[1..] puts the lambda in the name slot (index 0) that callClosure
    // expects, with the actual arguments starting at index 1.
    try Interp.narrowToEvalError(interp.callClosure(
        closure_and_key.closure,
        closure_and_key.cache_key,
        args[1..],
    ));
}

pub fn applymethodCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    var det: objutil.ErrorDetails = undefined;
    const closure_and_key = try interp.wrapError(&det, interp.getClosure(&det, args[1].current(), true));

    if (!closure_and_key.closure.is_method) {
        try interp.setResultString("[applymethod] called with a function");
        return error.EvalError;
    }

    try Interp.narrowToEvalError(interp.callClosure(
        closure_and_key.closure,
        closure_and_key.cache_key,
        args[1..],
    ));

    const new_self = args[2].shimmered.toHandle().?;
    args[2].shimmered = .none; // It's bad practice to leave a `Shimmerable` as mutated.
    defer new_self.decrRefCount();
    const method_result = interp.result;

    interp.setResultOwning(try objutil.newList(&.{ new_self, method_result }));
}

pub fn tallcallCommand(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    if (interp.callFrameIdx() == 0) {
        try interp.setResultString("tailcall can only be called from a proc or lambda");
        return error.EvalError;
    } else if (args.len >= 2) {
        // Make sure that if the command doesn't exist, we throw the error here, so
        // it doesn't mysteriously show up at a untracable spot up the call stack.
        _ = interp.getCommand(interp.callFrameIdx() - 1, &args[1], false) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.EvalError,
        };

        const tailcall_args = try Heap.global_gpa.dupe(Shimmerable, args[1..]);
        errdefer Heap.global_gpa.free(tailcall_args);

        // `args[1..]` includes the name of the command to run.
        assert(interp.callFrame().tailcall == null);
        interp.callFrame().tailcall = .{
            .args = tailcall_args,
        };
        return error.Tailcall;
    } else {
        try interp.setResultString("no function provided");
        return error.EvalError;
    }
}

/// `closureHelper` is a helper function that implements [fn] and [method] logic. This function
/// parses the closure, captures the scope, and (if provided) sets the function name in the local
/// scope.
fn closureHelper(interp: *Interp, args: []Shimmerable, mode: enum { function, method }) Interp.Error!void {
    const fn_name: ?*Shimmerable, const arglist, const body = blk: {
        if (args.len == 4) {
            break :blk .{ &args[1], &args[2], args[3] };
        } else {
            break :blk .{ null, &args[1], args[2] };
        }
    };

    // Shimmer to list via the interp helper, which handles the case where
    // the handle can't be shimmered in place.
    try interp.shimmerToList(arglist);

    var det: objutil.ErrorDetails = undefined;
    const parsed_args = try interp.wrapError(&det, Interp.parseClosureArgList(&det, arglist.current()));
    defer parsed_args.deinit();

    // Capture the current scope.
    const scope = try interp.captureCurrentScope();
    defer scope.decrRefCount();

    // Build a non-owning closure descriptor. createClosureObject borrows
    // all fields, so we don't need to borrow here.
    const closure_obj = try Interp.createClosureObject(.{
        .args = parsed_args.arg_names,
        .body = body.current(),
        .name = if (fn_name) |val| val.current().toOptional() else .none,
        .scope_hash_ref = scope.toOptional(),
        .required_arity = parsed_args.required_arity,
        .optional_arity = parsed_args.optional_arity,
        .optional_values = parsed_args.optional_values,
        .has_args_parameter = parsed_args.has_args_parameter,
        .is_method = mode == .method,
        .cache_id = Heap.nextCacheId(),
    });
    defer closure_obj.decrRefCount();

    if (fn_name) |val| {
        try interp.setVariableTo(val, closure_obj);
        interp.setResult(try interp.getVariableOrError(val));
    } else {
        interp.setResult(closure_obj);
    }
}

pub fn fnCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    return closureHelper(interp, args, .function);
}

pub fn methodCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    return closureHelper(interp, args, .method);
}

pub fn sourceCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    try interp.evalFile(try args[1].getString());
}

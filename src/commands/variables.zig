/// [incr]
pub fn incrCmd(interp: *Interp, args: []Shimmerable) !void {
    var increment_by: i64 = 1;

    if (args.len == 3) {
        // There's an amount provided to increment by.
        increment_by = try interp.getInteger(&args[2]);
    }

    const var_name = &args[1];

    if ((try interp.getVariable(var_name)).toHandle()) |val| {
        const contents = try interp.getIntegerNoShimmer(val);
        const new_contents = std.math.add(i64, contents, increment_by) catch {
            var det: objutil.ErrorDetails = undefined;
            return interp.wrapError(&det, objutil.integerOverflowErrorWithWide(&det, @as(i65, contents) + increment_by));
        };

        if (val.canMutate()) {
            // Can modify directly.
            val.invalidateBoth();
            val.peek().* = objutil.integerObject(new_contents);
            interp.setResult(val);
        } else {
            try interp.setVariableToObject(var_name, objutil.integerObject(new_contents));
            interp.setResult((interp.getVariable(var_name) catch unreachable).toHandle().?);
        }
    } else {
        try interp.setVariableToObject(var_name, objutil.integerObject(increment_by));
        interp.setResult((try interp.getVariable(var_name)).toHandle().?);
    }
}

/// [set]
pub fn setCmd(interp: *Interp, args: []Shimmerable) !void {
    const var_name = &args[1];

    if (args.len == 2) {
        // Return the value.
        interp.setResult(try interp.getVariableOrError(var_name));
    } else {
        try interp.setVariableTo(var_name, args[2].current());
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
                error.HashLookupFailed,
                error.LookupFailed,
                error.NotHashReference,
                error.BadVariableName,
                error.BadDict,
                => {},
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
    }
}

/// [upvar] - link a local variable to a variable in an upper scope.
/// Syntax: upvar ?level? otherVar myVar ?otherVar myVar ...?
pub fn upvarCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    var upvar_names_start: usize = 1;
    var levels_up: u32 = 1;

    if (args.len > 3 and @mod(args.len, 2) == 0) {
        if (interp.getInteger(&args[1])) |level| {
            if (level >= 0) {
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
    if (current_frame < levels_up) {
        try interp.setResultString("bad level");
        return error.EvalError;
    }
    const target_frame = current_frame - levels_up;

    var j = upvar_names_start;
    while (j + 1 < args.len) : (j += 2) {
        try args[j].ensureShimmerable();
        try args[j + 1].ensureShimmerable();

        var det: objutil.ErrorDetails = undefined;
        try interp.wrapError(
            &det,
            interp.setVariableUpvarInner(&det, current_frame, args[j + 1].current(), target_frame, args[j].current()),
        );
    }
}

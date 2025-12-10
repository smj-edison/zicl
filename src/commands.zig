const std = @import("std");
const testing = std.testing;

const Heap = @import("Heap.zig");
const Handle = Heap.Handle;
const object = @import("object.zig");
const Interp = @import("Interp.zig");

fn integerOverflowError(interp: *Interp) !void {
    try interp.setResultString("integer overflow");
    return error.IntegerOverflow;
}

fn addMulHelper(interp: *Interp, args: []Heap.Handle, comptime operator: enum { add, mul }) !void {
    // This will break out of the block early if not all arguments are ints.
    not_all_ints: {
        var result: i64 = 0;

        for (1..args.len) |i| {
            const operand = blk: {
                if (args[i].peek().tag == .integer) {
                    break :blk args[i].peek().body.integer;
                } else if (args[i].peek().tag == .float) {
                    break :not_all_ints;
                } else {
                    // Try to shimmer it to an integer.
                    break :blk interp.getInteger(&args[i]) catch |err| switch (err) {
                        error.IntegerOverflow, error.BadInteger => {
                            break :not_all_ints;
                        },
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                }
            };

            result = switch (operator) {
                .add => std.math.add(i64, result, operand) catch return integerOverflowError(interp),
                .mul => std.math.mul(i64, result, operand) catch return integerOverflowError(interp),
            };
        }

        try interp.setResultInteger(result);
    }

    var result: f64 = 0;

    for (1..args.len) |i| {
        const operand: f64 = blk: {
            if (args[i].peek().tag == .integer) {
                break :blk @floatFromInt(args[i].peek().body.integer);
            } else if (args[i].peek().tag == .float) {
                break :blk args[i].peek().body.float;
            } else {
                // Try to shimmer it to a float.
                break :blk try interp.getFloat(&args[i]);
            }
        };

        result = switch (operator) {
            .add => result + operand,
            .mul => result * operand,
        };
    }

    interp.setResultOwning(try object.floatNew(result));
}

pub fn add(interp: *Interp, args: []Heap.Handle) !void {
    return addMulHelper(interp, args, .add);
}

pub fn mul(interp: *Interp, args: []Heap.Handle) !void {
    return addMulHelper(interp, args, .mul);
}

/// [puts]
pub fn puts(interp: *Interp, args: []Heap.Handle) !void {
    if (args.len == 3) {
        const first_arg_str = try Heap.getString(args[1]);
        if (!std.mem.eql(u8, first_arg_str, "-nonewline")) {
            try interp.setResultString("The second argument must be -nonewline");
            return Interp.Error.EvalError;
        } else {
            const to_print = try Heap.getString(args[2]);
            std.debug.print("{s}", .{to_print});
        }
    } else {
        const to_print = try Heap.getString(args[1]);
        std.debug.print("{s}\n", .{to_print});
    }
}

pub fn incr(interp: *Interp, args: []Heap.Handle) !void {
    var increment_by: i64 = 1;

    if (args.len == 3) {
        // There's an amount provided to increment by.
        increment_by = try interp.getInteger(&args[2]);
    }

    if (interp.getVariableNoDetails(&args[1])) |val| {
        const contents = try interp.getIntegerNoShimmer(val);
        const new_contents = std.math.add(i64, contents, increment_by) catch return integerOverflowError(interp);

        if (val.canModify()) {
            // Can modify directly.
            val.invalidateBoth();
            val.peek().tag = .integer;
            val.peek().body = .{ .integer = new_contents };
        } else {
            try interp.setVariableToObject(&args[1], .{
                .str = Heap.Object.null_string,
                .tag = .integer,
                .body = .{ .integer = new_contents },
            });
        }

        try interp.setResult(val);
    } else |err| {
        switch (err) {
            error.VariableNotFound => {
                try interp.setVariableToObject(&args[1], .{
                    .str = Heap.Object.null_string,
                    .tag = .integer,
                    .body = .{ .integer = increment_by },
                });
                try interp.setResult(try interp.getVariable(&args[1]));
            },
            else => return err,
        }
    }
}

fn namespaceSplit(full_name: []const u8) struct { namespace: []const u8, command_name: []const u8 } {
    // Skip any leading colons.
    var trimmed = full_name;
    while (trimmed.len > 0 and trimmed[0] == ':') trimmed = trimmed[1..];

    // Look for the last colon pair, as that's where the command name starts.
    var command_name = trimmed;
    if (std.mem.lastIndexOf(u8, trimmed, "::")) |last_pair| {
        trimmed = trimmed[0..last_pair];
        command_name = trimmed[(last_pair + 2)..];
    } else {
        trimmed = full_name[0..0];
    }

    return .{
        .namespace = trimmed,
        .command_name = command_name,
    };
}

pub fn createProcedureCommand(
    interp: *Interp,
    arg_list: *Handle,
    statics_list: ?*Handle,
    body: *Handle,
    namespace: Handle,
) !Interp.Command {
    const arg_list_len = try interp.getListLength(arg_list);

    const statics: ?Handle = blk: {
        if (statics_list) |list| {
            try Heap.ensureSameHeap(list);
            const statics_count = try interp.getListLength(list);

            const statics_dict = try object.dictUninitializedNew(statics_count * 2);
            const dict_items = object.dictItems(statics_dict);
            errdefer statics_dict.release();

            for (0..statics_count) |i| {
                const static_name = object.listItem(list.*, @intCast(i));
                if (interp.getVariableImpl(null, static_name)) |static_value| {
                    const dict_name_str = try Heap.duplicateObjString(Heap.local_heap, static_name);
                    errdefer dict_name_str.deinit(Heap.local_heap);
                    const dict_value = try Heap.referenceOrDuplicate(Heap.local_heap, static_value);

                    dict_items[i * 2] = .{
                        .str = dict_name_str,
                        .tag = .none,
                        .body = undefined,
                    };
                    dict_items[i * 2 + 1] = dict_value;
                } else |err| switch (err) {
                    error.VariableNotFound => {
                        try interp.setResultFormatted("variable for initialization of static \"{f}\" not found in the local context", .{static_name});
                        return error.VariableNotFound;
                    },
                    else => return err,
                }
            }

            try object.dictReindex(statics_dict, null);

            break :blk statics_dict;
        } else {
            break :blk null;
        }
    };

    const new_arg_list = try object.listUninitializedNew(arg_list_len);
    errdefer new_arg_list.release();

    // We'll set this to a list if we encounter any optional values.
    var optional_values: ?Handle = null;
    errdefer if (optional_values) |val| val.release();
    // Set to true if we find args.
    var args_parameter_found = false;
    // Keep track of how many arguments there are.
    var required_arity: u32 = 0;
    var optional_arity: u32 = 0;

    // Now we'll make the new args list, validating as we go along.
    for (0..arg_list_len) |i| {
        if (args_parameter_found) {
            try interp.setResultString("parameter after 'args' not allowed");
            return error.ParameterAfterArgs;
        }

        var arg = try object.listItem(arg_list.*, @intCast(i)).borrow();
        defer arg.release();
        const arg_len = try interp.getListLength(&arg);

        if (arg_len == 0) {
            try interp.setResultString("argument with no name");
            return error.ArgumentWithNoName;
        } else if (arg_len > 2) {
            try interp.setResultFormatted("too many fields in argument specifier \"{f}\"", .{arg});
            return error.TooManyFieldsInArgument;
        } else if (arg_len == 2) {
            // Optional parameter.
            if (optional_values == null) {
                optional_values = try object.listNew(&.{});
            }

            const arg_name = try Heap.getString(object.listItem(arg, 0));
            if (std.mem.eql(u8, arg_name, "args")) {
                try interp.setResultString("'args' must be a required parameter");
                return error.ArgsWasOptional;
            }

            const arg_str_duped = try Heap.duplicateObjString(Heap.local_heap, object.listItem(arg, 0));
            errdefer arg_str_duped.deinit(Heap.local_heap);
            // Append value to optional values.
            _ = try interp.listAppend(&(optional_values.?), object.listItem(arg, 1));
            // And put the variable name onto the new arg list.
            object.listItem(new_arg_list, @intCast(i)).peek().* = .{
                .str = arg_str_duped,
                .tag = .none,
                .body = undefined,
            };

            optional_arity += 1;
        } else {
            if (optional_values != null) {
                // This breaks tcl behavior, but really, it shouldn't just silently convert required
                // values to optional values.
                try interp.setResultString("required parameter after optional parameter not allowed");
                return error.RequiredParameterAfterOptionalParameter;
            }

            const arg_name = try Heap.getString(object.listItem(arg, 0));
            if (std.mem.eql(u8, arg_name, "args")) args_parameter_found = true;

            // Required parameter.
            object.listItem(new_arg_list, @intCast(i)).peek().* = .{
                .str = try Heap.duplicateObjString(Heap.local_heap, object.listItem(arg, 0)),
                .tag = .none,
                .body = undefined,
            };

            required_arity += 1;
        }
    }

    return .{
        .namespace = try namespace.borrow(),
        .call_info = .{ .tcl = .{
            .signature = .{
                .args = new_arg_list,
                .body = try body.borrow(),
                .statics = statics,
                .has_args_parameter = args_parameter_found,
                .required_arity = required_arity,
                .optional_arity = optional_arity,
                .optional_values = optional_values,
            },
        } },
    };
}

pub fn proc(interp: *Interp, args: []Heap.Handle) !void {
    const proc_name = try Heap.getString(args[1]);
    const arg_list = &args[2];
    const statics = if (args.len == 5) &args[3] else null;
    const body = if (args.len == 5) &args[4] else &args[3];

    const qualified = try Interp.qualifyName(interp.gpa, interp.namespace, proc_name);
    defer if (qualified) |val| interp.gpa.free(val);
    const qualified_name = qualified orelse proc_name;

    const name_parts = namespaceSplit(qualified_name);

    // The procedure's namespace may not be the same as the current namespace.
    const proc_namespace = try object.newString(name_parts.namespace);
    defer proc_namespace.release();

    var command = createProcedureCommand(interp, arg_list, statics, body, proc_namespace) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.EvalError,
    };
    errdefer command.deinit();
    try interp.createCommand(try interp.gpa.dupe(u8, proc_name), command);
}

pub fn registerCoreCommands(interp: *Interp) !void {
    try interp.registerCommand("+", .{ .to_call = add, .description = "?number ...?", .min_arity = 1, .max_arity = null, .multiple_of = null });
    try interp.registerCommand("*", .{ .to_call = mul, .description = "?number ...?", .min_arity = 1, .max_arity = null, .multiple_of = null });
    try interp.registerCommand("proc", .{ .to_call = proc, .description = "name arglist ?statics? body", .min_arity = 3, .max_arity = 4, .multiple_of = null });
    try interp.registerCommand("puts", .{ .to_call = puts, .description = "?-nonewline? string", .min_arity = 1, .max_arity = 2, .multiple_of = null });
    try interp.registerCommand("incr", .{ .to_call = incr, .description = "varName key ?increment?", .min_arity = 1, .max_arity = 2, .multiple_of = null });
}

test "commands" {
    defer Heap.testFinish();
    _ = try Heap.testStart(testing.allocator);
    var interp = try Interp.init();
    defer interp.deinit();
    try registerCoreCommands(&interp);

    var script = try object.newString(
        \\ proc foo {x} { puts $x }
        \\ foo 10
    );
    defer script.release();
    try interp.evalObject(&script);
}

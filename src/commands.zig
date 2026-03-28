const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

const Heap = @import("Heap.zig");
const Handle = Heap.Handle;
const OptionalHandle = Heap.OptionalHandle;
const objutil = @import("objutil.zig");
const Interp = @import("Interp.zig");

fn addMulHelper(interp: *Interp, args: []Handle, comptime operator: enum { add, mul }) Interp.Error!void {
    // This will break out of the block early if not all arguments are ints.
    not_all_ints: {
        var result: i64 = 0;

        for (1..args.len) |i| {
            const operand = blk: {
                if (args[i].tag() == .integer) {
                    break :blk args[i].peek().body.integer;
                } else if (args[i].tag() == .float) {
                    break :not_all_ints;
                } else {
                    // Try to shimmer it to an integer.
                    var new_ref: OptionalHandle = .none;
                    const res = objutil.integerGet(null, args[i], &new_ref) catch |err| switch (err) {
                        error.IntegerOverflow, error.BadInteger => {
                            break :not_all_ints;
                        },
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                    args[i].swapIfNew(new_ref);
                    break :blk res;
                }
            };

            result = switch (operator) {
                .add => std.math.add(i64, result, operand),
                .mul => std.math.mul(i64, result, operand),
            } catch {
                interp.integerOverflowError(null) catch return error.EvalError;
            };
        }

        try interp.setResultInteger(result);
    }

    var result: f64 = 0;

    for (1..args.len) |i| {
        const operand: f64 = blk: {
            if (args[i].tag() == .integer) {
                break :blk @floatFromInt(args[i].peek().body.integer);
            } else if (args[i].tag() == .float) {
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

    interp.setResultOwning(try objutil.newFloat(interp.heap, result));
}

pub fn addCmd(interp: *Interp, args: []Handle) Interp.Error!void {
    try addMulHelper(interp, args, .add);
}

pub fn mulCmd(interp: *Interp, args: []Handle) Interp.Error!void {
    try addMulHelper(interp, args, .mul);
}

pub fn applyCmd(interp: *Interp, args: []Handle) Interp.Error!void {
    const lambda_len = try interp.getListLength(&args[1]);
    if (lambda_len < 2 or lambda_len > 3) {
        try interp.setResultFormatted("can't interpret \"{f}\" as a lambda expression", .{args[1]});
        return error.EvalError;
    }

    var namespace: Heap.OptionalHandle = .none;
    if (lambda_len == 3) {
        namespace = objutil.listItemFollowRefs(args[1], 2).toOptional();
    }

    const arg_list = objutil.listItemFollowRefs(args[1], 0);
    const body = objutil.listItemFollowRefs(args[1], 1);

    var new_arg_list = arg_list.borrow();
    defer new_arg_list.decrRefCount();
    var new_body = body.borrow();
    defer new_body.decrRefCount();
    var command = createProcedureCommand(interp, &new_arg_list, null, &new_body, namespace) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.EvalError,
    };
    defer command.deinit();

    // Create a new arg array with a dummy arg[0] for error messages (as the command name
    // is the first argument).
    var sf = std.heap.stackFallback(32, Heap.global_gpa);
    const stack_alloc = sf.get();

    // 1 (the first argument, "apply lambdaProc") + args.len - 2 (skip "apply" and the lambda).
    const lambda_args = try stack_alloc.alloc(Heap.Handle, 1 + args.len - 2);
    defer stack_alloc.free(lambda_args);

    lambda_args[0] = interp.heap.getInternedString(.lambda_apply_expr);
    for (args[2..], lambda_args[1..]) |provided_arg, *lambda_arg| {
        lambda_arg.* = provided_arg.borrow();
    }
    defer for (lambda_args[1..]) |lambda_arg| lambda_arg.decrRefCount();

    try interp.callProcedure(&command, lambda_args);
}

pub fn breakCmd(interp: *Interp, args: []Handle) Interp.Error!void {
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

pub fn continueCmd(interp: *Interp, args: []Handle) Interp.Error!void {
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

/// [dict]
pub fn dictCmd(interp: *Interp, args: []Handle) Interp.Error!void {
    const SubcommandName = enum {
        create,
        get,
        getdef,
        set,
        unset,
        exists,
        keys,
        size,
        info,
        merge,
        with,
        append,
        lappend,
        incr,
        remove,
        values,
        @"for",
        replace,
        update,
    };
    const SubcommandEnum = objutil.TclEnum(SubcommandName, "dict_subcommand");

    var det: objutil.ErrorDetails = undefined;
    var new_enum: OptionalHandle = .none;
    const subcommand: SubcommandName = try interp.wrapError(&det, SubcommandEnum.get(&det, args[1], &new_enum));
    args[1].swapIfNew(new_enum);

    switch (subcommand) {
        .get => {
            interp.setResult(try interp.getDictValueRecursivelyOrError(&args[2], args[3..]));
        },
        .getdef => {
            if ((try interp.getDictValueRecursively(&args[2], args[3..(args.len - 1)])).toHandle()) |val| {
                interp.setResult(val);
            } else {
                interp.setResult(args[args.len - 1]);
            }
        },
        .set => {
            const dict = blk: {
                if ((try interp.getVariable(&args[2])).toHandle()) |val| {
                    break :blk val;
                } else {
                    const new_variable_dict = try objutil.newDictWithCapacity(2);
                    defer new_variable_dict.decrRefCount();
                    try interp.setVariableTo(&args[2], new_variable_dict);
                    break :blk (try interp.getVariable(&args[2])).toHandle().?;
                }
            };

            const new_value = try interp.heap.dupOrReference(args[args.len - 1]);
            const put_result = try interp.wrapError(
                &det,
                objutil.dictPutRecursively(&det, dict, args[3..(args.len - 1)], new_value),
            );

            if (put_result.new_dict.toHandle()) |new_dict| {
                defer new_dict.decrRefCount();
                try interp.setVariableTo(&args[2], new_dict);
                // TODO probably can do this faster than looking back up every time.
                interp.setResult((try interp.getVariable(&args[2])).toHandle().?);
            } else {
                interp.setResult(dict);
            }
        },
        .unset => {},
        else => unreachable,
    }
}

test "dict commands" {
    var interp = try testStart(testing.allocator);
    defer testFinish(&interp);

    try testing.expectError(error.EvalError, testRunScript(&interp,
        \\ dict set x a 10
        \\ puts [dict get $x a 5]
    ));
    try testing.expectEqualStrings(
        \\Missing value to go with key when converting "10" to a dictionary.
    , try interp.result.getString());

    try testExpectScriptResult(&interp, "qux",
        \\ dict set foo bar baz qux
        \\ dict get $foo bar baz
    );
}

pub fn exprCmd(interp: *Interp, args: []Handle) Interp.Error!void {
    const result = try (try interp.evalExpressionInPlace(&args[1])).toObject(interp);
    defer result.decrRefCount();
    interp.setResult(result);
}

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

pub fn forCmd(interp: *Interp, args: []Handle) Interp.Error!void {
    // Do the initialization.
    try interp.evalObjectInPlace(&args[1]);

    // Check condition.
    while (try interp.getBoolFromExpression(&args[2])) {
        // Evaluate body.
        switch (try propagateLoopControl(interp, interp.evalObjectInPlace(&args[4]))) {
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
        try interp.evalObjectInPlace(&args[3]);
    }

    interp.setEmptyResult();
}

test "loop commands" {
    var interp = try testStart(testing.allocator);
    defer testFinish(&interp);

    // Basic loop.
    try testExpectScriptResult(&interp, "5",
        \\ for {set i 0} {$i < 5} {incr i} {}
        \\ set i
    );

    // [continue]
    try testExpectScriptResult(&interp, "5",
        \\ for {set i 0} {$i < 5} {incr i} { continue }
        \\ set i
    );

    try testExpectScriptResult(&interp, "0",
        \\ for {set i 0} {$i < 5} {incr i} {
        \\   for {set j 0} {$j < 5} {incr j} {
        \\     continue 2
        \\   }
        \\ }
        \\ set j
    );
}

/// [puts]
pub fn putsCmd(interp: *Interp, args: []Handle) !void {
    if (args.len == 3) {
        const first_arg_str = try args[1].getString();
        if (!std.mem.eql(u8, first_arg_str, "-nonewline")) {
            try interp.setResultString("The second argument must be -nonewline");
            return Interp.Error.EvalError;
        } else {
            const to_print = try args[2].getString();
            std.debug.print("{s}", .{to_print});
        }
    } else {
        const to_print = try args[1].getString();
        std.debug.print("{s}\n", .{to_print});
    }
}

/// [if]
pub fn ifCmd(interp: *Interp, args: []Handle) Interp.Error!void {
    var remaining_args = args[1..];
    while (true) {
        // Need a condition and a body after.
        if (remaining_args.len < 2) return error.WrongUsage;

        // Check condition.
        if (try interp.getBoolFromExpression(&remaining_args[0])) {
            // Evaluate true branch.
            try interp.evalObjectInPlace(&remaining_args[1]);
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

        if (try Heap.stringEquals(remaining_args[0], "else")) {
            // There should only be one more argument, since there shouldn't
            // be anything after "else".
            if (remaining_args.len > 2) return error.WrongUsage;
            try interp.evalObjectInPlace(&remaining_args[1]);
            return;
        }

        if (try Heap.stringEquals(remaining_args[0], "elseif")) {
            // Keep going.
            remaining_args = remaining_args[1..];
            continue;
        }

        // tcl doesn't require "else" for the last condition, but I think that's
        // too lax. We're more strict.
        return error.WrongUsage;
    }
}

/// [incr]
pub fn incrCmd(interp: *Interp, args: []Handle) !void {
    var increment_by: i64 = 1;

    if (args.len == 3) {
        // There's an amount provided to increment by.
        increment_by = try interp.getInteger(&args[2]);
    }

    if ((try interp.getVariable(&args[1])).toHandle()) |val| {
        const contents = try interp.getIntegerNoShimmer(val);
        const new_contents = std.math.add(i64, contents, increment_by) catch {
            var det: objutil.ErrorDetails = undefined;
            return interp.wrapError(&det, objutil.integerOverflowErrorWithWide(&det, @as(i65, contents) + increment_by));
        };

        if (val.canMutate()) {
            // Can modify directly.
            val.invalidateBoth();
            val.peek().head.tag = .integer;
            val.peek().body = .{ .integer = new_contents };
            interp.setResult(val);
        } else {
            try interp.setVariableToObject(&args[1], .{
                .str = Heap.Object.null_string,
                .tag = .integer,
                .body = .{ .integer = new_contents },
            });
            interp.setResult((interp.getVariable(&args[1]) catch unreachable).toHandle().?);
        }
    } else {
        try interp.setVariableToObject(&args[1], .{
            .str = Heap.Object.null_string,
            .tag = .integer,
            .body = .{ .integer = increment_by },
        });
        interp.setResult((try interp.getVariable(&args[1])).toHandle().?);
    }
}

/// [set]
pub fn setCmd(interp: *Interp, args: []Handle) !void {
    if (args.len == 2) {
        // Return the value.
        interp.setResult(try interp.getVariableOrError(&args[1]));
    } else {
        try interp.setVariableTo(&args[1], args[2]);
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

/// Modifies arg_list to only contain names of variables (optional values
/// are stored elsewhere).
pub fn createProcedureCommand(
    interp: *Interp,
    arg_list: *Handle,
    statics_names: ?*Handle,
    body: *Handle,
    namespace: Heap.OptionalHandle,
) !Interp.Command {
    const statics: ?Handle = blk: {
        if (statics_names) |names| {
            try interp.ensureShimmerable(names);
            const statics_count = try interp.getListLength(names);

            const statics_dict = try objutil.newDictWithCapacity(statics_count * 2);
            statics_dict.peek().body.dict.len = statics_count * 2;
            const dict_items = objutil.dictItems(statics_dict);
            errdefer statics_dict.decrRefCount();

            for (0..statics_count) |i| {
                const static_name = objutil.listItem(names.*, @intCast(i));
                if (interp.getVariableImpl(null, static_name)) |static_value| {
                    const dict_name_str = try Heap.duplicateObjString(Heap.local_heap, static_name);
                    errdefer dict_name_str.deinit(Heap.local_heap);
                    const dict_value = try Heap.local_heap.dupOrReference(static_value);

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

            break :blk statics_dict;
        } else {
            break :blk null;
        }
    };

    const arg_list_len = try interp.getListLength(arg_list);

    // We'll set this to a list if we encounter any optional values.
    var optional_values: ?Handle = null;
    errdefer if (optional_values) |val| val.decrRefCount();
    // Set to true if we find args.
    var args_parameter_found = false;
    // Keep track of how many arguments there are.
    var required_arity: u32 = 0;
    var optional_arity: u32 = 0;

    // Validate the args as we go along, replacing any optional arguments with just
    // their variables' name.
    for (0..arg_list_len) |i| {
        if (args_parameter_found) {
            try interp.setResultString("parameter after 'args' not allowed");
            return error.ParameterAfterArgs;
        }

        var arg = objutil.listItem(arg_list.*, @intCast(i)).borrow();
        defer arg.decrRefCount();
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
                // Init the optional_values list.
                optional_values = try objutil.newList(&.{});
            }

            if (try Heap.stringEquals(objutil.listItem(arg, 0), "args")) {
                try interp.setResultString("'args' must be a required parameter");
                return error.ArgsWasOptional;
            }

            // Append value to optional values.
            _ = try interp.listAppend(&(optional_values.?), objutil.listItem(arg, 1));
            // And replace the `arg_list`'s parameter/value with just the parameter name.
            var det: objutil.ErrorDetails = undefined;
            const new_item = try Heap.local_heap.dupOrReference(objutil.listItem(arg, 0));
            var new_arg_list: OptionalHandle = .none;
            try objutil.listSetObject(&det, arg_list.*, &new_arg_list, @intCast(i), new_item);
            arg_list.swapIfNew(new_arg_list);

            optional_arity += 1;
        } else {
            if (optional_values != null) {
                // This breaks tcl behavior, but really, it shouldn't just silently convert required
                // values to optional values.
                try interp.setResultString("required parameter after optional parameter not allowed");
                return error.RequiredParameterAfterOptionalParameter;
            }

            const arg_name = try objutil.listItem(arg, 0).getString();
            if (std.mem.eql(u8, arg_name, "args")) args_parameter_found = true;

            // Required parameter.
            required_arity += 1;
        }
    }

    return .{
        .namespace = namespace.borrowOptional(),
        .call_info = .{ .tcl = .{
            .signature = .{
                .args = arg_list.borrow(),
                .body = body.borrow(),
                .statics = statics,
                .has_args_parameter = args_parameter_found,
                .required_arity = required_arity,
                .optional_arity = optional_arity,
                .optional_values = optional_values,
            },
        } },
    };
}

/// [proc]
pub fn procCmd(interp: *Interp, args: []Handle) !void {
    const proc_name = try args[1].getString();
    const arg_list = &args[2];
    const statics = if (args.len == 5) &args[3] else null;
    const body = if (args.len == 5) &args[4] else &args[3];

    const qualified = try Interp.qualifyName(Heap.global_gpa, interp.namespace, proc_name);
    defer if (qualified) |val| Heap.global_gpa.free(val);
    const qualified_name = qualified orelse proc_name;

    const name_parts = namespaceSplit(qualified_name);

    // The procedure's namespace may not be the same as the current namespace.
    const proc_namespace = try objutil.newString(interp.heap, name_parts.namespace);
    defer proc_namespace.decrRefCount();

    var command = createProcedureCommand(interp, arg_list, statics, body, proc_namespace.toOptional()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.EvalError,
    };
    errdefer command.deinit();
    try interp.createCommand(try Heap.global_gpa.dupe(u8, proc_name), command);
}

pub fn registerCoreCommands(interp: *Interp) !void {
    try interp.registerCommand("+", .{ .to_call = addCmd, .description = "?number ...?", .min_arity = 1 });
    try interp.registerCommand("*", .{ .to_call = mulCmd, .description = "?number ...?", .min_arity = 1 });
    try interp.registerCommand("apply", .{ .to_call = applyCmd, .description = "lambdaExpr ?arg ...?", .min_arity = 1 });
    try interp.registerCommand("break", .{ .to_call = breakCmd, .description = "?level?", .min_arity = 0, .max_arity = 1 });
    try interp.registerCommand("continue", .{ .to_call = continueCmd, .description = "?level?", .min_arity = 0, .max_arity = 1 });
    try interp.registerCommand("dict", .{ .to_call = dictCmd, .description = "subcommand ?arg ...?", .min_arity = 1 });
    try interp.registerCommand("expr", .{ .to_call = exprCmd, .description = "expression", .min_arity = 1, .max_arity = 1 });
    try interp.registerCommand("for", .{ .to_call = forCmd, .description = "start test next body", .min_arity = 4, .max_arity = 4 });
    try interp.registerCommand("if", .{ .to_call = ifCmd, .description = "condition trueBody ?elseif ...? ?else falseBody?", .min_arity = 2 });
    try interp.registerCommand("incr", .{ .to_call = incrCmd, .description = "varName key ?increment?", .min_arity = 1, .max_arity = 2 });
    try interp.registerCommand("proc", .{ .to_call = procCmd, .description = "name arglist ?statics? body", .min_arity = 3, .max_arity = 4 });
    try interp.registerCommand("puts", .{ .to_call = putsCmd, .description = "?-nonewline? string", .min_arity = 1, .max_arity = 2 });
    try interp.registerCommand("set", .{ .to_call = setCmd, .description = "varName ?newValue?", .min_arity = 1, .max_arity = 2 });
}

pub fn testStart(ta: std.mem.Allocator) !Interp {
    errdefer Heap.testFinish();
    _ = try Heap.testStart(ta);
    var interp = try Interp.init();
    errdefer interp.deinit();
    try registerCoreCommands(&interp);
    return interp;
}

pub fn testFinish(interp: *Interp) void {
    interp.deinit();
    Heap.testFinish();
}

fn testRunScript(interp: *Interp, script: []const u8) !Handle {
    var script_handle = try objutil.newString(interp.heap, script);
    defer script_handle.decrRefCount();
    try interp.evalObjectInPlace(&script_handle);
    return interp.result;
}

fn testExpectScriptResult(interp: *Interp, expected: []const u8, script: []const u8) !void {
    try testing.expectEqualStrings(expected, try try testRunScript(interp, script).getString());
}

test "commands" {
    var interp = try testStart(testing.allocator);
    defer testFinish(&interp);

    var script = try objutil.newString(interp.heap,
        \\ dict set x a 10
        \\ puts [dict get $x a 5]
    );
    defer script.decrRefCount();
    interp.evalObjectInPlace(&script) catch {};
}

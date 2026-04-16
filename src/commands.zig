const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

const Heap = @import("Heap.zig");
const Handle = Heap.Handle;
const OptionalHandle = Heap.OptionalHandle;
const objutil = @import("objutil.zig");
const Interp = @import("Interp.zig");

fn addMulHelper(interp: *Interp, args: []const Handle, comptime operator: enum { add, mul }) Interp.Error!void {
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
                    var new_handle: OptionalHandle = .none;
                    defer new_handle.decrOptional();
                    const res = objutil.integerGet(null, args[i], &new_handle) catch |err| switch (err) {
                        error.IntegerOverflow, error.BadInteger => {
                            break :not_all_ints;
                        },
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                    break :blk res;
                }
            };

            result = switch (operator) {
                .add => std.math.add(i64, result, operand),
                .mul => std.math.mul(i64, result, operand),
            } catch {
                return interp.integerOverflowError(null);
            };
        }

        try interp.setResultInteger(result);
        return;
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
                var arg = args[i].borrow();
                defer arg.decrRefCount();
                break :blk try interp.getFloat(&arg);
            }
        };

        result = switch (operator) {
            .add => result + operand,
            .mul => result * operand,
        };
    }

    interp.setResultOwning(try objutil.newFloat(result));
}

const IntegerOrFloat = union(enum) {
    int: i64,
    float: f64,
};
fn subDivHelper(interp: *Interp, args: []const Handle, comptime operator: enum { sub, div }) Interp.Error!void {
    if (args.len == 2) {
        // The arity = 2 case is different. For [- x] returns -x,
        // while [/ x] returns 1/x.
        const value: IntegerOrFloat = blk: {
            if (args[1].tag() == .integer) {
                break :blk .{ .int = args[1].peek().body.integer };
            } else if (args[1].tag() == .float) {
                break :blk .{ .float = args[1].peek().body.float };
            }

            var new_handle: OptionalHandle = .none;
            defer new_handle.decrOptional();
            const as_int = objutil.integerGet(null, args[1], &new_handle) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.IntegerOverflow, error.BadInteger => {
                    // Try parsing it as a float if it's not an integer.
                    var arg = args[1].borrow();
                    defer arg.decrRefCount();
                    break :blk .{ .float = try interp.getFloat(&arg) };
                },
            };

            break :blk .{ .int = as_int };
        };

        switch (operator) {
            .sub => {
                switch (value) {
                    .int => |int| {
                        const result = std.math.sub(i64, 0, int) catch {
                            // The only case an integer can overflow is when negating the
                            // lowest possible integer (for example, with i8, going from
                            // -128 to 128).
                            var buf: [std.fmt.count("{}", .{std.math.minInt(i65)})]u8 = undefined;
                            const as_str = std.fmt.bufPrint(&buf, "{}", .{-@as(i65, int)}) catch unreachable;
                            return interp.integerOverflowError(as_str);
                        };
                        try interp.setResultInteger(result);
                    },
                    .float => |float| {
                        interp.setResult(try objutil.newFloat(-float));
                    },
                }
            },
            .div => {
                const as_float: f64 = switch (value) {
                    .float => |float| float,
                    .int => |int| @floatFromInt(int),
                };
                if (as_float == 0.0) {
                    interp.setResultInterned(.@"division by zero");
                    return error.EvalError;
                }
                interp.setResult(try objutil.newFloat(1.0 / as_float));
            },
        }

        return;
    }

    // 3+ arguments, so we'll apply them in a row.

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
                    var new_handle: OptionalHandle = .none;
                    defer new_handle.decrOptional();
                    const res = objutil.integerGet(null, args[i], &new_handle) catch |err| switch (err) {
                        error.IntegerOverflow, error.BadInteger => {
                            break :not_all_ints;
                        },
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                    break :blk res;
                }
            };

            if (i == 1) {
                result = operand;
            } else {
                result = switch (operator) {
                    .sub => std.math.sub(i64, result, operand) catch {
                        return interp.integerOverflowError(null);
                    },
                    .div => std.math.divFloor(i64, result, operand) catch |err| switch (err) {
                        error.Overflow => return interp.integerOverflowError(null),
                        error.DivisionByZero => {
                            interp.setResultInterned(.@"division by zero");
                            return error.EvalError;
                        },
                    },
                };
            }
        }

        try interp.setResultInteger(result);
        return;
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
                var arg = args[i].borrow();
                defer arg.decrRefCount();
                break :blk try interp.getFloat(&arg);
            }
        };

        result = switch (operator) {
            .sub => result - operand,
            .div => blk: {
                if (operand == 0.0) {
                    interp.setResultInterned(.@"division by zero");
                    return error.EvalError;
                }
                break :blk result / operand;
            },
        };
    }

    interp.setResultOwning(try objutil.newFloat(result));
}

pub fn addCmd(interp: *Interp, args: []const Handle) Interp.Error!void {
    try addMulHelper(interp, args, .add);
}

pub fn mulCmd(interp: *Interp, args: []const Handle) Interp.Error!void {
    try addMulHelper(interp, args, .mul);
}

pub fn subCmd(interp: *Interp, args: []const Handle) Interp.Error!void {
    try subDivHelper(interp, args, .sub);
}

pub fn divCmd(interp: *Interp, args: []const Handle) Interp.Error!void {
    try subDivHelper(interp, args, .div);
}

pub fn breakCmd(interp: *Interp, args: []const Handle) Interp.Error!void {
    if (args.len == 2) {
        var level_arg = args[1].borrow();
        defer level_arg.decrRefCount();
        const level = try interp.getInteger(&level_arg);
        if (level < 1) {
            try interp.setResultFormatted("break level \"{}\" lower than 1", .{level});
        } else if (level > std.math.maxInt(u32)) {
            try interp.setResultFormatted("break level \"{}\" too high", .{level});
        }

        interp.loop_propagate = @intCast(level);
    }

    return error.Break;
}

pub fn continueCmd(interp: *Interp, args: []const Handle) Interp.Error!void {
    if (args.len == 2) {
        var level_arg = args[1].borrow();
        defer level_arg.decrRefCount();
        const level = try interp.getInteger(&level_arg);
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
pub fn dictCmd(interp: *Interp, args: []const Handle) Interp.Error!void {
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
    defer new_enum.decrOptional();
    const subcommand: SubcommandName = try interp.wrapError(&det, SubcommandEnum.get(&det, args[1], &new_enum));

    switch (subcommand) {
        .get => {
            var dict = args[2].borrow();
            defer dict.decrRefCount();
            var new_dict: OptionalHandle = .none;
            defer new_dict.swapWithNone();
            interp.setResult(try interp.getDictValueRecursivelyOrError(&dict, &new_dict, args[3..]));
        },
        .getdef => {
            if ((try interp.testGetDictValueRecursively(args[2], args[3..(args.len - 1)])).toHandle()) |val| {
                defer val.decrRefCount();
                interp.setResult(val);
            } else {
                interp.setResult(args[args.len - 1]);
            }
        },
        .set => {
            var var_name = args[2].borrow();
            defer var_name.decrRefCount();

            const dict = blk: {
                if ((try interp.getVariable(&var_name)).toHandle()) |val| {
                    break :blk val;
                } else {
                    const new_variable_dict = try objutil.newDictWithCapacity(2);
                    defer new_variable_dict.decrRefCount();
                    try interp.setVariableTo(&var_name, new_variable_dict);
                    break :blk (try interp.getVariable(&var_name)).toHandle().?;
                }
            };

            const new_value = try Heap.local_heap.dupOrReference(args[args.len - 1]);
            var new_dict: OptionalHandle = .none;
            _ = try interp.wrapError(
                &det,
                objutil.dictPutRecursively(&det, dict, &new_dict, args[3..(args.len - 1)], new_value),
            );

            if (new_dict.toHandle()) |new| {
                defer new.decrRefCount();
                try interp.setVariableTo(&var_name, new);
                // TODO probably can do this faster than looking back up every time.
                interp.setResult((try interp.getVariable(&var_name)).toHandle().?);
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

    try interp.testExpectScriptError(error.EvalError,
        \\Missing value to go with key when converting "10" to a dictionary.
    ,
        \\ dict set x a 10
        \\ puts [dict get $x a 5]
    );

    try interp.testExpectScriptResult("qux",
        \\ dict set foo bar baz qux
        \\ dict get $foo bar baz
    );
}

pub fn exprCmd(interp: *Interp, args: []const Handle) Interp.Error!void {
    var expr = args[1].borrow();
    defer expr.decrRefCount();
    const result = try (try interp.evalExpressionInPlace(&expr)).toObject();
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

pub fn forCmd(interp: *Interp, args: []const Handle) Interp.Error!void {
    // Do the initialization.
    try interp.evalObject(args[1]);

    // Check condition.
    var expr = args[2].borrow();
    defer expr.decrRefCount();
    while (try interp.getBoolFromExpression(&expr)) {
        // Evaluate body.
        switch (try propagateLoopControl(interp, interp.evalObject(args[4]))) {
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
        try interp.evalObject(args[3]);
    }

    interp.setEmptyResult();
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
}

/// [puts]
pub fn putsCmd(interp: *Interp, args: []const Handle) !void {
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
pub fn ifCmd(interp: *Interp, args: []const Handle) Interp.Error!void {
    var remaining_args = args[1..];
    while (true) {
        // Need a condition and a body after.
        if (remaining_args.len < 2) return error.WrongUsage;

        // Check condition.
        var cond = remaining_args[0].borrow();
        defer cond.decrRefCount();
        if (try interp.getBoolFromExpression(&cond)) {
            // Evaluate true branch.
            try interp.evalObject(remaining_args[1]);
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
            try interp.evalObject(remaining_args[1]);
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
pub fn incrCmd(interp: *Interp, args: []const Handle) !void {
    var increment_by: i64 = 1;

    if (args.len == 3) {
        // There's an amount provided to increment by.
        var increment_handle = args[2].borrow();
        defer increment_handle.decrRefCount();
        increment_by = try interp.getInteger(&increment_handle);
    }

    var var_name = args[1].borrow();
    defer var_name.decrRefCount();

    if ((try interp.getVariable(&var_name)).toHandle()) |val| {
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
            try interp.setVariableToObject(&var_name, .{
                .head = .{ .str = Heap.Object.null_string, .tag = .integer },
                .body = .{ .integer = new_contents },
            });
            interp.setResult((interp.getVariable(&var_name) catch unreachable).toHandle().?);
        }
    } else {
        try interp.setVariableToObject(&var_name, .{
            .head = .{ .str = Heap.Object.null_string, .tag = .integer },
            .body = .{ .integer = increment_by },
        });
        interp.setResult((try interp.getVariable(&var_name)).toHandle().?);
    }
}

/// [append]
pub fn appendCmd(interp: *Interp, args: []const Handle) !void {
    // Get the variable's value if it exists, or else use an empty string.
    var var_name = args[1].borrow();
    defer var_name.decrRefCount();
    const var_value: []const u8 = blk: {
        if ((try interp.getVariable(&var_name)).toHandle()) |val| {
            break :blk try val.getString();
        } else {
            break :blk "";
        }
    };

    // Fast path: no values to append, just ensure the variable exists and return it.
    if (args.len == 2) {
        if ((try interp.getVariable(&var_name)).toHandle()) |val| {
            interp.setResult(val);
        } else {
            try interp.setVariableTo(&var_name, Heap.local_heap.emptyHandle());
            interp.setEmptyResult();
        }
        return;
    }

    // Compute total length so we can allocate a single string.
    var total_len: usize = var_value.len;
    for (args[2..]) |arg| {
        total_len += (try arg.getString()).len;
    }

    const result_str = try objutil.newStringToFill(Heap.local_heap, total_len);
    defer result_str.decrRefCount();

    if (total_len > 0) {
        const buf = Heap.getStringMut(result_str) catch unreachable;
        var pos: usize = 0;
        @memcpy(buf[pos..(pos + var_value.len)], var_value);
        pos += var_value.len;
        for (args[2..]) |arg| {
            const s = try arg.getString();
            @memcpy(buf[pos..(pos + s.len)], s);
            pos += s.len;
        }
    }

    try interp.setVariableTo(&var_name, result_str);
    interp.setResult((try interp.getVariable(&var_name)).toHandle().?);
}

/// [set]
pub fn setCmd(interp: *Interp, args: []const Handle) !void {
    var var_name = args[1].borrow();
    defer var_name.decrRefCount();

    if (args.len == 2) {
        // Return the value.
        interp.setResult(try interp.getVariableOrError(&var_name));
    } else {
        try interp.setVariableTo(&var_name, args[2]);
    }
}

/// [apply] - invoke a closure value directly without binding it to a name.
/// Unlike Tcl's [apply], the lambda must be a Zicl closure object or its
/// serialized string form, a raw {argList body} list is not supported.
pub fn applyCmd(interp: *Interp, args: []const Handle) Interp.Error!void {
    const closure_and_key = try interp.getClosure(args[1]);
    // args[1..] puts the lambda in the name slot (index 0) that callClosure
    // expects, with the actual arguments starting at index 1.
    try interp.callClosure(closure_and_key.closure, closure_and_key.cache_key, args[1..]);
}

/// [fn] - creates a closure capturing the current scope and sets it as a
/// variable in the current scope.
pub fn fnCmd(interp: *Interp, args: []const Handle) Interp.Error!void {
    var fn_name: ?Handle, var arglist, const body = blk: {
        if (args.len == 4) {
            break :blk .{ args[1].borrow(), args[2].borrow(), args[3] };
        } else {
            break :blk .{ @as(?Handle, null), args[1].borrow(), args[2] };
        }
    };
    defer if (fn_name) |val| val.decrRefCount();
    defer arglist.decrRefCount();

    // Shimmer to list via the interp helper, which handles the case where
    // the handle can't be shimmered in place.
    try interp.shimmerToList(&arglist);

    var det: objutil.ErrorDetails = undefined;
    const parsed_args = try interp.wrapError(&det, Interp.parseClosureArgList(&det, arglist));
    defer parsed_args.deinit();

    // Capture the current scope.
    const scope = try interp.captureCurrentScope();
    defer scope.decrRefCount();

    // Build a non-owning closure descriptor. createClosureObject borrows
    // all fields, so we don't need to borrow here.
    const closure_obj = try Interp.createClosureObject(.{
        .args = arglist,
        .body = body,
        .name = if (fn_name) |val| val.toOptional() else .none,
        .scope = scope.toOptional(),
        .required_arity = parsed_args.required_arity,
        .optional_arity = parsed_args.optional_arity,
        .optional_values = parsed_args.optional_values,
        .has_args_parameter = parsed_args.has_args_parameter,
        .cache_id = Heap.nextCacheId(),
    });
    defer closure_obj.decrRefCount();

    if (fn_name) |*val| {
        try interp.setVariableTo(val, closure_obj);
        interp.setResult(try interp.getVariableOrError(val));
    } else {
        interp.setResult(closure_obj);
    }
}

pub fn registerCoreCommands(interp: *Interp) !void {
    try interp.registerCommand("*", .{ .to_call = mulCmd, .description = "?number ...?", .min_arity = 1 });
    try interp.registerCommand("+", .{ .to_call = addCmd, .description = "?number ...?", .min_arity = 1 });
    try interp.registerCommand("-", .{ .to_call = subCmd, .description = "?number ...?", .min_arity = 1 });
    try interp.registerCommand("/", .{ .to_call = divCmd, .description = "?number ...?", .min_arity = 1 });
    try interp.registerCommand("append", .{ .to_call = appendCmd, .description = "varName ?value ...?", .min_arity = 1 });
    try interp.registerCommand("apply", .{ .to_call = applyCmd, .description = "lambda ?arg ...?", .min_arity = 1 });
    try interp.registerCommand("break", .{ .to_call = breakCmd, .description = "?level?", .min_arity = 0, .max_arity = 1 });
    try interp.registerCommand("continue", .{ .to_call = continueCmd, .description = "?level?", .min_arity = 0, .max_arity = 1 });
    try interp.registerCommand("dict", .{ .to_call = dictCmd, .description = "subcommand ?arg ...?", .min_arity = 1 });
    try interp.registerCommand("expr", .{ .to_call = exprCmd, .description = "expression", .min_arity = 1, .max_arity = 1 });
    try interp.registerCommand("fn", .{ .to_call = fnCmd, .description = "name argList body", .min_arity = 2, .max_arity = 3 });
    try interp.registerCommand("for", .{ .to_call = forCmd, .description = "start test next body", .min_arity = 4, .max_arity = 4 });
    try interp.registerCommand("if", .{ .to_call = ifCmd, .description = "condition trueBody ?elseif ...? ?else falseBody?", .min_arity = 2 });
    try interp.registerCommand("incr", .{ .to_call = incrCmd, .description = "varName key ?increment?", .min_arity = 1, .max_arity = 2 });
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

test "fn command" {
    var interp = try testStart(testing.allocator);
    defer testFinish(&interp);

    // Basic closure.
    try interp.testExpectScriptResult("30",
        \\ fn add {a b} { + $a $b }
        \\ add 10 20
    );

    // Closure captures scope.
    try interp.testExpectScriptResult("15",
        \\ set x 10
        \\ fn addx {a} { + $a $x }
        \\ addx 5
    );

    // Nested closure captures outer scope via parent_link chain.
    try interp.testExpectScriptResult("15",
        \\ set outer 5
        \\ fn foo {} {
        \\   set inner 10
        \\   fn bar {} { + $inner $outer }
        \\   set bar
        \\ }
        \\ set bar [foo]
        \\ bar
    );

    // Optional parameters.
    try interp.testExpectScriptResult("3",
        \\ fn greet {a {b 3}} { + $a $b }
        \\ greet 0
    );

    // Variadic args parameter.
    try interp.testExpectScriptResult("10 20 30",
        \\ fn collect {args} { set args }
        \\ collect 10 20 30
    );
}

test "commands" {
    var interp = try testStart(testing.allocator);
    defer testFinish(&interp);

    var script = try objutil.newString(Heap.local_heap,
        \\ dict set x a 10
        \\ puts [dict get $x a 5]
    );
    defer script.decrRefCount();
    interp.evalObject(script) catch {};
}

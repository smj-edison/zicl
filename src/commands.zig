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

    interp.setResultOwning(try objutil.newFloat(Heap.local_heap, result));
}

pub fn addCmd(interp: *Interp, args: []Handle) Interp.Error!void {
    try addMulHelper(interp, args, .add);
}

pub fn mulCmd(interp: *Interp, args: []Handle) Interp.Error!void {
    try addMulHelper(interp, args, .mul);
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

            const new_value = try Heap.local_heap.dupOrReference(args[args.len - 1]);
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
    const result = try (try interp.evalExpressionInPlace(&args[1])).toObject();
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
    try interp.evalObject(args[1]);

    // Check condition.
    while (try interp.getBoolFromExpression(&args[2])) {
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
    try testExpectScriptResult(&interp, "5",
        \\ for {set i 0} {$i < 5} {incr i} { }
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
                .head = .{ .str = Heap.Object.null_string, .tag = .integer },
                .body = .{ .integer = new_contents },
            });
            interp.setResult((interp.getVariable(&args[1]) catch unreachable).toHandle().?);
        }
    } else {
        try interp.setVariableToObject(&args[1], .{
            .head = .{ .str = Heap.Object.null_string, .tag = .integer },
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

/// [fn] - creates a closure capturing the current scope and sets it as a
/// variable in the current scope.
pub fn fnCmd(interp: *Interp, args: []Handle) Interp.Error!void {
    const fn_name = args[1];
    const body = args[3];

    // Shimmer to list via the interp helper, which handles the case where
    // the handle can't be shimmered in place.
    try interp.shimmerToList(&args[2]);

    var det: objutil.ErrorDetails = undefined;
    const parsed_args = try interp.wrapError(&det, Interp.parseClosureArgList(&det, args[2]));
    defer parsed_args.deinit();

    // Capture the current scope.
    const scope = try interp.captureCurrentScope();
    defer scope.decrRefCount();

    // Build a non-owning closure descriptor. createClosureObject borrows
    // all fields, so we don't need to borrow here.
    const closure_obj = try Interp.createClosureObject(.{
        .args = args[2],
        .body = body,
        .name = fn_name.toOptional(),
        .scope = scope.toOptional(),
        .required_arity = parsed_args.required_arity,
        .optional_arity = parsed_args.optional_arity,
        .optional_values = parsed_args.optional_values,
        .has_args_parameter = parsed_args.has_args_parameter,
        .cache_id = Heap.nextCacheId(),
    });
    defer closure_obj.decrRefCount();

    try interp.setVariableTo(&args[1], closure_obj);
    interp.setResult(try interp.getVariableOrError(&args[1]));
}

pub fn registerCoreCommands(interp: *Interp) !void {
    try interp.registerCommand("+", .{ .to_call = addCmd, .description = "?number ...?", .min_arity = 1 });
    try interp.registerCommand("*", .{ .to_call = mulCmd, .description = "?number ...?", .min_arity = 1 });
    try interp.registerCommand("break", .{ .to_call = breakCmd, .description = "?level?", .min_arity = 0, .max_arity = 1 });
    try interp.registerCommand("continue", .{ .to_call = continueCmd, .description = "?level?", .min_arity = 0, .max_arity = 1 });
    try interp.registerCommand("dict", .{ .to_call = dictCmd, .description = "subcommand ?arg ...?", .min_arity = 1 });
    try interp.registerCommand("expr", .{ .to_call = exprCmd, .description = "expression", .min_arity = 1, .max_arity = 1 });
    try interp.registerCommand("fn", .{ .to_call = fnCmd, .description = "name argList body", .min_arity = 3, .max_arity = 3 });
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

fn testRunScript(interp: *Interp, script: []const u8) !Handle {
    var script_handle = try objutil.newString(Heap.local_heap, script);
    defer script_handle.decrRefCount();
    try interp.evalObject(script_handle);
    return interp.result;
}

fn testExpectScriptResult(interp: *Interp, expected: []const u8, script: []const u8) !void {
    try testing.expectEqualStrings(expected, try (try testRunScript(interp, script)).getString());
}

test "fn command" {
    var interp = try testStart(testing.allocator);
    defer testFinish(&interp);

    // Basic closure.
    try testExpectScriptResult(&interp, "30",
        \\ fn add {a b} { + $a $b }
        \\ add 10 20
    );

    // Closure captures scope.
    try testExpectScriptResult(&interp, "15",
        \\ set x 10
        \\ fn addx {a} { + $a $x }
        \\ addx 5
    );

    // Nested closure captures outer scope via parent_link chain.
    testExpectScriptResult(&interp, "15",
        \\ set outer 5
        \\ fn foo {} {
        \\   set inner 10
        \\   fn bar {} { + $inner $outer }
        \\   set bar
        \\ }
        \\ set bar [foo]
        \\ bar
    ) catch {
        std.debug.print("Error result: {f}\n", .{interp.result});
        return error.TestFailed;
    };

    // Optional parameters.
    try testExpectScriptResult(&interp, "3",
        \\ fn greet {a {b 3}} { + $a $b }
        \\ greet 0
    );

    // Variadic args parameter.
    try testExpectScriptResult(&interp, "10 20 30",
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

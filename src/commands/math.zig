const std = @import("std");

const common = @import("common.zig");
const ErrorDetails = common.ErrorDetails;
const Value = common.Value;
const objects = common.objects;
const Number = objects.Number;
const Integer = objects.Integer;
const Float = objects.Float;
const Interp = common.Interp;
const Shimmerable = common.Shimmerable;
const registerCommand = common.registerCommand;
const memutil = common.memutil;

fn addMulHelper(interp: *Interp, args: []Shimmerable, comptime operator: enum { add, mul }) Interp.Error!void {
    // This will break out of the block early if not all arguments are ints.
    not_all_ints: {
        var result: i64 = if (operator == .add) 0 else 1;

        for (1..args.len) |i| {
            const operand = Integer.shimmerFrom(null, &args[i]) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.BadInteger => break :not_all_ints,
                error.IntegerOverflow => {
                    // Capture the error.
                    var det: ErrorDetails = undefined;
                    _ = try interp.wrapError(&det, Integer.shimmerFrom(&det, &args[i]));
                    unreachable;
                },
            };

            switch (operator) {
                .add => {
                    result = std.math.add(i64, result, operand) catch {
                        return interp.integerOverflowError(i65, @as(i65, result) + operand);
                    };
                },
                .mul => {
                    result = std.math.mul(i64, result, operand) catch {
                        return interp.integerOverflowError(i128, std.math.mulWide(i64, result, operand));
                    };
                },
            }
        }

        try interp.setResultInteger(result);
        return;
    }

    var result: f64 = 0;

    for (1..args.len) |i| {
        var det: ErrorDetails = undefined;
        const operand: f64 = (try interp.wrapError(&det, Number.getAsIntOrFloat(&det, &args[i]))).asFloat();

        result = switch (operator) {
            .add => result + operand,
            .mul => result * operand,
        };
    }

    interp.setResultFloat(result);
}

fn subDivHelper(interp: *Interp, args: []Shimmerable, comptime operator: enum { sub, div }) Interp.Error!void {
    if (args.len == 2) {
        // The arity = 2 case is different. For `[- x]` it returns `-x`,
        // while `[/ x]` returns `1/x`.
        var det: ErrorDetails = undefined;
        const value = try interp.wrapError(&det, objects.Number.getAsIntOrFloat(&det, &args[1]));

        switch (operator) {
            .sub => {
                switch (value) {
                    .integer => |int| {
                        const result = std.math.sub(i64, 0, int) catch {
                            // The only case an integer can overflow is when negating the
                            // lowest possible integer (for example, with i8, going from
                            // -128 to 128).
                            return interp.integerOverflowError(i65, -@as(i65, int));
                        };
                        try interp.setResultInteger(result);
                    },
                    .float => |float| {
                        interp.setResultOwning(Value.newFloat(-float));
                    },
                }
            },
            .div => {
                const as_float: f64 = switch (value) {
                    .float => |float| float,
                    .integer => |int| @floatFromInt(int),
                };
                if (as_float == 0.0) {
                    interp.setResultOwning(Number.division_by_zero_message);
                    return error.EvalError;
                }
                interp.setResult(Value.newFloat(1.0 / as_float));
            },
        }

        return;
    }

    // 3+ arguments, so we'll apply them in a row.

    // This will break out of the block early if not all arguments are ints.
    not_all_ints: {
        var result: i64 = 0;

        for (1..args.len) |i| {
            const operand = Integer.shimmerFrom(null, &args[i]) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.BadInteger => break :not_all_ints,
                error.IntegerOverflow => {
                    // Capture the error.
                    var det: ErrorDetails = undefined;
                    _ = try interp.wrapError(&det, Integer.shimmerFrom(&det, &args[i]));
                    unreachable;
                },
            };

            if (i == 1) {
                result = operand;
            } else {
                result = switch (operator) {
                    .sub => std.math.sub(i64, result, operand) catch {
                        return interp.integerOverflowError(i65, @as(i65, result) - @as(i65, operand));
                    },
                    .div => std.math.divFloor(i64, result, operand) catch |err| switch (err) {
                        error.Overflow => return interp.integerOverflowError(i65, @divFloor(@as(i65, result), @as(i65, operand))),
                        error.DivisionByZero => {
                            interp.setResultOwning(Number.division_by_zero_message);
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
        var det: ErrorDetails = undefined;
        const operand: f64 = (try interp.wrapError(&det, Number.getAsIntOrFloat(&det, &args[i]))).asFloat();

        result = switch (operator) {
            .sub => result - operand,
            .div => blk: {
                if (operand == 0.0) {
                    interp.setResultOwning(Number.division_by_zero_message);
                    return error.EvalError;
                }
                break :blk result / operand;
            },
        };
    }

    interp.setResultFloat(result);
}

pub fn addCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    try addMulHelper(interp, args, .add);
}

pub fn mulCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    try addMulHelper(interp, args, .mul);
}

pub fn subCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    try subDivHelper(interp, args, .sub);
}

pub fn divCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    try subDivHelper(interp, args, .div);
}

pub fn registerCommands(interp: *Interp) !void {
    try registerCommand(interp, "*", mulCmd, "?number ...?", 1, null);
    try registerCommand(interp, "+", addCmd, "?number ...?", 1, null);
    try registerCommand(interp, "-", subCmd, "?number ...?", 1, null);
    try registerCommand(interp, "/", divCmd, "?number ...?", 1, null);
}

fn testArithmeticAddition(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("10", "+ 5 5");
    // Make sure it stays as an integer.
    try interp.testExpectScriptResult("9223372036854775807", "+ 9223372036854775807 0");
    // It should report integer overflow if the ints are too big.
    try interp.testExpectScriptError(error.EvalError,
        \\integer value "18446744073709551614" too big to be represented
    , "+ 9223372036854775807 9223372036854775807");
}

test "arithmetic addition" {
    try memutil.checkAllocationFailures(.exhaustive, testArithmeticAddition, .{});
}

fn testArithmeticDivision(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Make sure it stays as an integer.
    try interp.testExpectScriptResult("2", "/ 12 5");
    try interp.testExpectScriptResult("0", "/ 2 2 2");
    try interp.testExpectScriptError(error.EvalError, "division by zero", "/ 5 0");
}

test "arithmetic division" {
    try memutil.checkAllocationFailures(.exhaustive, testArithmeticDivision, .{});
}

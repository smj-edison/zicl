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

fn addMulHelper(interp: *Interp, args: []Shimmerable, comptime operator: enum { add, mul }) Interp.Error!void {
    // This will break out of the block early if not all arguments are ints.
    not_all_ints: {
        var result: i64 = if (operator == .add) 0 else 1;

        for (1..args.len) |i| {
            const operand = blk: {
                if (args[i].tag() == .integer) {
                    break :blk args[i].peek().body.integer;
                } else if (args[i].tag() == .float) {
                    break :not_all_ints;
                } else {
                    // Try to shimmer it to an integer.
                    const res = objects.Integer.parse(null, try args[i].current().getString()) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.IntegerOverflow, error.BadInteger => {
                            break :not_all_ints;
                        },
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
                break :blk try interp.getFloat(&args[i]);
            }
        };

        result = switch (operator) {
            .add => result + operand,
            .mul => result * operand,
        };
    }

    try interp.setResultFloat(result);
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
                    .int => |int| {
                        const result = std.math.sub(i64, 0, int) catch {
                            // The only case an integer can overflow is when negating the
                            // lowest possible integer (for example, with i8, going from
                            // -128 to 128).
                            return interp.integerOverflowError(i65, -@as(i65, int));
                        };
                        try interp.setResultInteger(result);
                    },
                    .float => |float| {
                        interp.setResult(try Value.newFloat(-float));
                    },
                }
            },
            .div => {
                const as_float: f64 = switch (value) {
                    .float => |float| float,
                    .int => |int| @floatFromInt(int),
                };
                if (as_float == 0.0) {
                    interp.setResultOwning(common.Expression.division_by_zero_message.get());
                    return error.EvalError;
                }
                interp.setResult(try Value.newFloat(1.0 / as_float));
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
                if (Integer.asInt(args[i].current())) |int| break :blk int;
                if (Float.asFloat(args[i].current())) |_| break :not_all_ints;

                // Try to shimmer it to an integer.
                const res = objects.Integer.parse(null, try args[i].current().getString()) catch |err| switch (err) {
                    error.IntegerOverflow, error.BadInteger => {
                        break :not_all_ints;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                };
                break :blk res;
            };

            if (i == 1) {
                result = operand;
            } else {
                result = switch (operator) {
                    .sub => std.math.sub(i64, result, operand) catch {
                        return interp.integerOverflowError(i65, @as(i65, result) - @as(i65, operand));
                    },
                    .div => std.math.divFloor(i64, result, operand) catch |err| switch (err) {
                        error.Overflow => return interp.integerOverflowError(i65, @as(i65, result) / @as(i65, operand)),
                        error.DivisionByZero => {
                            interp.setResultOwning(Number.division_by_zero_message.get());
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
            if (Integer.asInt(args[i].current())) |int| break :blk @floatFromInt(int);
            if (Float.asFloat(args[i].current())) |float| break :blk float;

            // Try to shimmer it to a float.
            break :blk try interp.getFloat(&args[i]);
        };

        result = switch (operator) {
            .sub => result - operand,
            .div => blk: {
                if (operand == 0.0) {
                    interp.setResultOwning(Number.division_by_zero_message.get());
                    return error.EvalError;
                }
                break :blk result / operand;
            },
        };
    }

    try interp.setResultFloat(result);
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

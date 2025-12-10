const std = @import("std");
const testing = std.testing;

const Heap = @import("Heap.zig");
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

    interp.setResultOwning(try object.floatNew(interp.heap, result));
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

pub fn registerCoreCommands(interp: *Interp) !void {
    try interp.registerCommand("+", .{ .to_call = add, .description = "?number ...?", .min_arity = 1, .max_arity = null, .multiple_of = null });
    try interp.registerCommand("*", .{ .to_call = mul, .description = "?number ...?", .min_arity = 1, .max_arity = null, .multiple_of = null });
    try interp.registerCommand("puts", .{ .to_call = puts, .description = "?-nonewline? string", .min_arity = 1, .max_arity = 2, .multiple_of = null });
    try interp.registerCommand("incr", .{ .to_call = incr, .description = "varName key ?increment?", .min_arity = 1, .max_arity = 2, .multiple_of = null });
}

test "commands" {
    defer Heap.testFinish();
    var interp = try Interp.init(try Heap.createHeap(testing.allocator));
    defer interp.deinit();
    try registerCoreCommands(&interp);

    var script = try object.newString(interp.heap,
        \\ puts hello
        \\ incr x
        \\ puts $x
        \\ incr x
        \\ puts [incr x]
        \\ puts [+ 5 5 10 20.5]
    );
    defer script.release();
    try interp.evalObject(&script);
}

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const assert = std.debug.assert;

const Tokenizer = @import("Tokenizer.zig");
const strutil = @import("strutil.zig");
const Heap = @import("Heap.zig");
const Handle = Heap.Handle;
const OptionalHandle = Heap.OptionalHandle;
const objutil = @import("objutil.zig");
const Shimmerable = objutil.Shimmerable;
const Mutable = objutil.Mutable;
const Interp = @import("Interp.zig");
const ioutil = @import("ioutil.zig");
const pcre2 = @import("pcre2");
const regex = @import("regex.zig");

fn commandMatch(interp: *Interp, command: Handle, pattern: Handle, string: Handle) !bool {
    const script = try objutil.newList(&.{ command, pattern, string });
    defer script.decrRefCount();
    try interp.evalObject(script);
    return try interp.getBooleanInPlace(&interp.result);
}

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
                    const res = objutil.integerGet(null, &args[i]) catch |err| switch (err) {
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
        // The arity = 2 case is different. For [- x] returns -x,
        // while [/ x] returns 1/x.
        const value = try interp.getIntegerOrFloat(&args[1]);

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
                    const res = objutil.integerGet(null, &args[i]) catch |err| switch (err) {
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
                break :blk try interp.getFloat(&args[i]);
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

pub fn breakCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
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

pub fn continueCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
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

pub fn hashCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    interp.setResultOwning(try objutil.createHashReference(args[1].current()));
}

pub fn hashlookupCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    interp.setResult(try interp.resolveHash(&args[1]));
}

/// [dict]
pub fn dictCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const Subcommands = enum {
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
        link,
    };
    const Parser = objutil.SubcommandParser(Subcommands, &.{
        .{ .variant = .create, .usage = "?key value ...?", .stride = 2 },
        .{ .variant = .get, .usage = "dictionary ?key ...?", .min_args = 1 },
        .{ .variant = .getdef, .usage = "dictionary ?key ...? key default", .min_args = 3 },
        .{ .variant = .set, .usage = "varName key ?key ...? value", .min_args = 3 },
        .{ .variant = .unset, .usage = "varName key ?key ...?", .min_args = 2 },
        .{ .variant = .exists, .usage = "dictionary key ?key ...?", .min_args = 2 },
        .{ .variant = .keys, .usage = "dictionary ?pattern?", .min_args = 1, .max_args = 2 },
        .{ .variant = .size, .usage = "dictionary", .min_args = 1, .max_args = 1 },
        .{ .variant = .info, .usage = "dictionary", .min_args = 1, .max_args = 1 },
        .{ .variant = .merge, .usage = "?...?" },
        .{ .variant = .with, .usage = "dictVar ?key ...? script", .min_args = 2 },
        .{ .variant = .append, .usage = "varName key ?value ...?", .min_args = 2 },
        .{ .variant = .lappend, .usage = "varName key ?value ...?", .min_args = 2 },
        .{ .variant = .incr, .usage = "varName key ?increment?", .min_args = 2, .max_args = 3 },
        .{ .variant = .remove, .usage = "dictionary ?key ...?", .min_args = 1 },
        .{ .variant = .values, .usage = "dictionary ?pattern?", .min_args = 1, .max_args = 2 },
        .{ .variant = .@"for", .usage = "vars dictionary script", .min_args = 3, .max_args = 3 },
        .{ .variant = .replace, .usage = "dictionary ?key value ...?", .min_args = 1 },
        .{ .variant = .update, .usage = "varName ?arg ...? script", .min_args = 2 },
        .{ .variant = .link, .usage = "linkTo dict", .min_args = 2, .max_args = 2 },
    });

    var det: objutil.ErrorDetails = undefined;
    const subcommand: Subcommands = try interp.wrapError(&det, Parser.parse(&det, args));

    switch (subcommand) {
        .create => {
            const pairs = args[2..];
            if (@mod(pairs.len, 2) != 0) {
                return error.WrongUsage;
            }
            const new_dict = try objutil.newDictWithCapacity(@intCast(pairs.len));
            var arg_i: usize = 2;
            while (arg_i < args.len) : (arg_i += 2) {
                objutil.dictPutAssumeCapacity(new_dict, args[arg_i].current(), args[arg_i + 1].current().dupOrRef());
            }
            interp.setResultOwning(new_dict);
        },
        .get => {
            const dict = &args[2];
            const path = args[3..];
            interp.setResult(try interp.getDictValueRecursivelyOrError(dict, objutil.ShimmerableSliceContext{ .items = path }));
        },
        .getdef => {
            const getdef_ctx = objutil.ShimmerableSliceContext{ .items = args[3..(args.len - 1)] };
            if ((try interp.getDictValueRecursively(&args[2], getdef_ctx)).toHandle()) |val| {
                interp.setResult(val);
            } else {
                interp.setResult(args[args.len - 1].current());
            }
        },
        .set => {
            const var_name = &args[2];
            const keys = args[3..(args.len - 1)];

            var dict: Mutable = blk: {
                if ((try interp.getVariable(var_name)).toHandle()) |val| {
                    break :blk .{ .original = val };
                } else {
                    const new_variable_dict = try objutil.newDictWithCapacity(2);
                    defer new_variable_dict.decrRefCount();
                    try interp.setVariableTo(var_name, new_variable_dict);
                    break :blk .{ .original = (try interp.getVariable(var_name)).toHandle().? };
                }
            };
            defer dict.discardChanges();

            if (keys.len == 0) {
                interp.setResult(dict.current());
                return;
            }

            const new_value = args[args.len - 1].current().dupOrRef();
            const set_ctx = objutil.ShimmerableSliceContext{ .items = keys };
            _ = try interp.wrapError(&det, objutil.dictPutRecursively(&det, &dict, set_ctx, new_value));

            if (dict.takeMutated().toHandle()) |new| {
                {
                    defer new.decrRefCount();
                    try interp.setVariableTo(var_name, new);
                }
                // TODO probably can do this faster than looking back up every time.
                interp.setResult((try interp.getVariable(var_name)).toHandle().?);
            } else {
                interp.setResult(dict.current());
            }
        },
        .unset => {
            const var_name = &args[2];
            if (args.len < 4) return error.WrongUsage;

            var dict: Mutable = blk: {
                if ((try interp.getVariable(var_name)).toHandle()) |val| {
                    break :blk .{ .original = val };
                } else {
                    const new_variable_dict = try objutil.newDictWithCapacity(2);
                    defer new_variable_dict.decrRefCount();
                    try interp.setVariableTo(var_name, new_variable_dict);
                    break :blk .{ .original = (try interp.getVariable(var_name)).toHandle().? };
                }
            };
            defer dict.discardChanges();

            const unset_ctx = objutil.ShimmerableSliceContext{ .items = args[3..args.len] };
            _ = try interp.wrapError(&det, objutil.dictRemoveRecursively(&det, &dict, unset_ctx));
            if (dict.takeMutated().toHandle()) |new| {
                defer new.decrRefCount();
                try interp.setVariableToObject(var_name, new.reference());
            }
        },
        .exists => {
            const dict = &args[2];
            const exists_ctx = objutil.ShimmerableSliceContext{ .items = args[3..] };
            try interp.setResultBoolean((try interp.getDictValueRecursively(dict, exists_ctx)) != .none);
        },
        .keys, .values => {
            var new_dict: OptionalHandle = .none;
            errdefer new_dict.decrOptional();
            var kv_map: objutil.DictKvResult = try interp.wrapError(&det, objutil.dictGetKvPairs(&det, Heap.global_gpa, &args[2]));
            defer {
                var iter = kv_map.iterator();
                while (iter.next()) |val| {
                    val.key_ptr.decrRefCount();
                    val.value_ptr.decrRefCount();
                }
                kv_map.deinit(Heap.global_gpa);
            }

            if (args.len == 4) {
                const pattern = &args[3];
                var filtered = try objutil.newListWithCapacity(@intCast(kv_map.count()));
                errdefer filtered.decrRefCount();
                for (kv_map.keys(), kv_map.values()) |key, value| {
                    const used = if (subcommand == .keys) key else value;
                    if (try objutil.globMatch(pattern.current(), used, false)) {
                        objutil.listAppendAssumeCapacity(filtered, used.dupOrRef());
                    }
                }
                interp.setResultOwning(filtered);
            } else {
                interp.setResultOwning(try objutil.newList(if (subcommand == .keys) kv_map.keys() else kv_map.values()));
            }
        },
        .merge => {
            const dicts = args[2..];

            if (dicts.len == 0) {
                interp.setResultOwning(try objutil.newDictWithCapacity(0));
                return;
            }

            // Make sure everything is a dict.
            for (dicts) |*d| try interp.shimmerToDict(d);

            if (dicts.len == 1) {
                interp.setResult(dicts[0].current());
                return;
            }

            var result = try objutil.newDictWithCapacity(0);
            errdefer result.decrRefCount();

            for (dicts) |dict| {
                const pair_count = dict.peek().body.dict.len / 2;
                var pair_i: u32 = 0;
                while (pair_i < pair_count) : (pair_i += 1) {
                    const k = objutil.dictItem(dict.current(), pair_i * 2);
                    const v = objutil.dictItem(dict.current(), pair_i * 2 + 1);
                    _ = try interp.putDictValueInPlace(&result, k, v);
                }
            }

            interp.setResultOwning(result);
        },
        .link => {
            const link_to = &args[2];
            const dict = &args[3];

            var mutable_dict = try dict.duplicateForMutable();
            errdefer mutable_dict.decrRefCount();

            const hash_ref = try objutil.createHashReference(link_to.current());
            defer hash_ref.decrRefCount();
            _ = try interp.putDictValueInPlace(&mutable_dict, Heap.local_heap.getInternedString(.@"^parent"), hash_ref);
            interp.setResultOwning(mutable_dict);
        },
        else => std.debug.panic("unimplemented: {}", .{subcommand}),
    }
}

pub fn exprCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const result = try (try interp.evalExpression(args[1].current())).toObject();
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

pub fn forCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    // Do the initialization.
    try interp.evalObject(args[1].current());

    // Check condition.
    while (try interp.getBoolFromExpression(args[2].current())) {
        // Evaluate body.
        switch (try propagateLoopControl(interp, interp.evalObject(args[4].current()))) {
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
        try interp.evalObject(args[3].current());
    }

    interp.setEmptyResult();
}

/// Shared implementation of [foreach] and [lmap].
fn foreachMapHelper(interp: *Interp, args: []Shimmerable, mode: enum { foreach, map }) Interp.Error!void {
    const body = &args[args.len - 1];

    // [foreach] can simultaneously loop over multiple lists, so it's easiest to think of it as zipped.
    // It's not quite a normal zip though, since the stride over each list depends on how many variables
    // it captures.

    const list_count = (args.len - 2) / 2;

    // Track per-list iteration state.
    var iter_state: std.MultiArrayList(struct {
        stride: u32,
        length: u32,
        current_index: u32,
    }) = try .initCapacity(Heap.global_gpa, list_count);
    defer iter_state.deinit(Heap.global_gpa);

    for (0..list_count) |i| {
        const stride = try interp.getListLength(&args[i * 2 + 1]);
        if (stride == 0) {
            try interp.setResultString("foreach varlist is empty");
            return error.EvalError;
        }
        iter_state.appendAssumeCapacity(.{
            .stride = stride,
            .length = try interp.getListLength(&args[i * 2 + 2]),
            .current_index = 0,
        });
    }

    var result_list: Mutable = .{ .original = Heap.local_heap.emptyHandle() };
    errdefer result_list.discardChanges();

    while (true) {
        // Continue only if any list still has unconsumed elements.
        keep_going: for (0..list_count) |i| {
            const list_state = iter_state.get(i);
            if (list_state.current_index < list_state.length) break :keep_going;
        } else break;

        // Go through all the lists and assign their variables.
        for (0..list_count) |list_index| {
            var var_list = &args[list_index * 2 + 1];
            const value_list = &args[list_index * 2 + 2];

            const stride = iter_state.items(.stride)[list_index];
            const length = iter_state.items(.length)[list_index];
            const current_index = &iter_state.items(.current_index)[list_index];

            // Assign variables for this specific list.
            for (0..stride) |v| {
                var var_name = objutil.listItem(var_list.current(), @intCast(v));

                // Ensure the name can shimmer before passing to `setVariableInner`.
                var name_new: OptionalHandle = .none;
                try Heap.ensureShimmerableOrDup(var_name, &name_new);
                if (name_new.toHandle()) |new| {
                    // Write the duplicated handle back to the variable list.
                    try objutil.listSetInner(var_list.asMutable(), @intCast(v), new.referenceOwning());
                    var_name = objutil.listItem(var_list.current(), @intCast(v));
                }

                const value = if (current_index.* < length) blk: {
                    const item = objutil.listItem(value_list.current(), current_index.*);
                    current_index.* += 1;
                    break :blk item;
                } else Heap.local_heap.emptyHandle();

                var det: objutil.ErrorDetails = undefined;
                try interp.wrapError(&det, interp.setVariableInner(&det, interp.callFrameIdx(), var_name, value.dupOrRef()));
            }
        }

        // Evaluate body and handle break/continue.
        switch (try propagateLoopControl(interp, interp.evalObject(body.current()))) {
            .@"break" => break,
            .@"continue" => continue,
            .none => {
                if (mode == .map) _ = try interp.listAppend(&result_list, interp.result);
            },
        }
    }

    interp.setResultOwning(result_list.consume());
}

/// [foreach]
pub fn foreachCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    return foreachMapHelper(interp, args, .foreach);
}

/// [lmap]
pub fn lmapCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    return foreachMapHelper(interp, args, .map);
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

    // [foreach] basic iteration.
    try interp.testExpectScriptResult("6",
        \\ set sum 0
        \\ foreach i {1 2 3} { set sum [expr {$sum + $i}] }
        \\ set sum
    );

    // [foreach] with multiple list pairs.
    try interp.testExpectScriptResult("1 2 x y|3 4 z |",
        \\ set r ""
        \\ foreach {a b} {1 2 3 4} {c d} {x y z} {
        \\   append r "$a $b $c $d|"
        \\ }
        \\ set r
    );

    // [foreach] shorter valuelist than varlist (pad with empty strings).
    try interp.testExpectScriptResult("1 2|3 |",
        \\ set r ""
        \\ foreach {a b} {1 2 3} { append r "$a $b|" }
        \\ set r
    );

    // [foreach] empty valuelist (body never runs).
    try interp.testExpectScriptResult("0",
        \\ set sum 0
        \\ foreach i {} { set sum [expr {$sum + $i}] }
        \\ set sum
    );

    // [foreach] break inside foreach.
    try interp.testExpectScriptResult("6",
        \\ set sum 0
        \\ foreach i {1 2 3 4 5} {
        \\   if {$i > 3} { break }
        \\   set sum [expr {$sum + $i}]
        \\ }
        \\ set sum
    );

    // [foreach] continue inside foreach.
    try interp.testExpectScriptResult("12",
        \\ set sum 0
        \\ foreach i {1 2 3 4 5} {
        \\   if {$i == 3} { continue }
        \\   set sum [expr {$sum + $i}]
        \\ }
        \\ set sum
    );

    // [foreach] empty varlist error.
    try interp.testExpectScriptError(error.EvalError, "foreach varlist is empty",
        \\ foreach {} {1 2} { puts hi }
    );

    // [lmap] basic iteration.
    try interp.testExpectScriptResult("2 4 6",
        \\ lmap x {1 2 3} { expr {$x * 2} }
    );

    // [lmap] with multiple list pairs.
    try interp.testExpectScriptResult("{1 x} {2 y}",
        \\ lmap a {1 2} b {x y} { list $a $b }
    );

    // [lmap] continue skips the result.
    try interp.testExpectScriptResult("2 6",
        \\ lmap x {1 2 3} { if {$x == 2} { continue } ; expr {$x * 2} }
    );

    // [lmap] break stops early.
    try interp.testExpectScriptResult("2",
        \\ lmap x {1 2 3} { if {$x == 2} { break } ; expr {$x * 2} }
    );

    // [lmap] empty input list returns empty list.
    try interp.testExpectScriptResult("",
        \\ lmap x {} { expr {$x * 2} }
    );

    // [lmap] empty varlist error.
    try interp.testExpectScriptError(error.EvalError, "foreach varlist is empty",
        \\ lmap {} {1 2} { puts hi }
    );
}

/// [puts]
pub fn putsCmd(interp: *Interp, args: []Shimmerable) !void {
    const to_print, const print_newline = blk: {
        if (args.len == 3) {
            const first_arg_str = try args[1].getString();
            if (!std.mem.eql(u8, first_arg_str, "-nonewline")) {
                try interp.setResultString("The second argument must be -nonewline");
                return error.EvalError;
            } else {
                break :blk .{ try args[2].getString(), false };
            }
        } else {
            break :blk .{ try args[1].getString(), true };
        }
    };

    const stdout = ioutil.lockStdout();
    defer ioutil.unlockStdout();
    var buf: [64]u8 = undefined;
    var writer = stdout.writer(Heap.global_io, &buf);
    writer.interface.print("{s}", .{to_print}) catch {
        try interp.setResultFormatted("failed to print: {}", .{writer.err.?});
        return error.EvalError;
    };
    if (print_newline) {
        writer.interface.writeAll("\n") catch {
            try interp.setResultFormatted("failed to print: {}", .{writer.err.?});
            return error.EvalError;
        };
    }
    writer.flush() catch {
        try interp.setResultFormatted("failed to print: {}", .{writer.err.?});
        return error.EvalError;
    };
}

/// [pid]
pub fn pidCmd(interp: *Interp, args: []Shimmerable) !void {
    if (args.len != 1) {
        try interp.setResultString("wrong # args: should be \"pid\"");
        return error.EvalError;
    }
    try interp.setResultInteger(@intCast(std.os.linux.getpid()));
}

/// [if]
pub fn ifCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    var remaining_args = args[1..];
    while (true) {
        // Need a condition and a body after.
        if (remaining_args.len < 2) return error.WrongUsage;

        // Check condition.
        if (try interp.getBoolFromExpression(remaining_args[0].current())) {
            // Evaluate true branch.
            try interp.evalObject(remaining_args[1].current());
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

        if (try remaining_args[0].current().equalsString("else")) {
            // There should only be one more argument, since there shouldn't
            // be anything after "else".
            if (remaining_args.len > 2) return error.WrongUsage;
            try interp.evalObject(remaining_args[1].current());
            return;
        }

        if (try remaining_args[0].current().equalsString("elseif")) {
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

/// [append]
pub fn appendCmd(interp: *Interp, args: []Shimmerable) !void {
    // Get the variable's value if it exists, or else use an empty string.
    const var_name = &args[1];

    const var_value: []const u8 = blk: {
        if ((try interp.getVariable(var_name)).toHandle()) |val| {
            break :blk try val.getString();
        } else {
            break :blk "";
        }
    };

    // Fast path: no values to append, just ensure the variable exists and return it.
    if (args.len == 2) {
        if ((try interp.getVariable(var_name)).toHandle()) |val| {
            interp.setResult(val);
        } else {
            try interp.setVariableTo(var_name, Heap.local_heap.emptyHandle());
            interp.setEmptyResult();
        }
        return;
    }

    // Compute total length so we can allocate a single string.
    var total_len: usize = var_value.len;
    for (args[2..]) |arg| {
        total_len += (try arg.getString()).len;
    }

    var new_bytes = try Heap.global_gpa.alloc(u8, total_len);
    defer Heap.global_gpa.free(new_bytes);

    if (total_len > 0) {
        var pos: usize = 0;
        @memcpy(new_bytes[pos..(pos + var_value.len)], var_value);
        pos += var_value.len;
        for (args[2..]) |arg| {
            const s = try arg.getString();
            @memcpy(new_bytes[pos..(pos + s.len)], s);
            pos += s.len;
        }
    }

    const result = try objutil.newString(new_bytes);
    defer result.decrRefCount();
    try interp.setVariableTo(var_name, result);
    interp.setResult((try interp.getVariable(var_name)).toHandle().?);
}

pub fn stringCmd(interp: *Interp, args: []Shimmerable) !void {
    const Subcommands = enum {
        bytelength,
        byterange,
        cat,
        compare,
        equal,
        first,
        index,
        is,
        last,
        length,
        map,
        match,
        range,
        repeat,
        replace,
        reverse,
        tolower,
        totitle,
        toupper,
        trim,
        trimleft,
        trimright,
    };
    const Parser = objutil.SubcommandParser(Subcommands, &.{
        .{ .variant = .bytelength, .usage = "string", .min_args = 1, .max_args = 1 },
        .{ .variant = .byterange, .usage = "string first last", .min_args = 3, .max_args = 3 },
        .{ .variant = .cat, .usage = "?string ...?", .min_args = 0, .max_args = null },
        .{ .variant = .compare, .usage = "?-nocase? ?-length int? string1 string2", .min_args = 2, .max_args = 5 },
        .{ .variant = .equal, .usage = "?-nocase? ?-length int? string1 string2", .min_args = 2, .max_args = 5 },
        .{ .variant = .first, .usage = "subString string ?index?", .min_args = 2, .max_args = 3 },
        .{ .variant = .index, .usage = "string index", .min_args = 2, .max_args = 2 },
        .{ .variant = .is, .usage = "class ?-strict? str", .min_args = 2, .max_args = 3 },
        .{ .variant = .last, .usage = "subString string ?index?", .min_args = 2, .max_args = 3 },
        .{ .variant = .length, .usage = "string", .min_args = 1, .max_args = 1 },
        .{ .variant = .map, .usage = "?-nocase? mapList string", .min_args = 2, .max_args = 3 },
        .{ .variant = .match, .usage = "?-nocase? pattern string", .min_args = 2, .max_args = 3 },
        .{ .variant = .range, .usage = "string first last", .min_args = 3, .max_args = 3 },
        .{ .variant = .repeat, .usage = "string count", .min_args = 2, .max_args = 2 },
        .{ .variant = .replace, .usage = "string first last ?string?", .min_args = 3, .max_args = 4 },
        .{ .variant = .reverse, .usage = "string", .min_args = 1, .max_args = 1 },
        .{ .variant = .tolower, .usage = "string", .min_args = 1, .max_args = 1 },
        .{ .variant = .totitle, .usage = "string", .min_args = 1, .max_args = 1 },
        .{ .variant = .toupper, .usage = "string", .min_args = 1, .max_args = 1 },
        .{ .variant = .trim, .usage = "string ?trimchars?", .min_args = 1, .max_args = 2 },
        .{ .variant = .trimleft, .usage = "string ?trimchars?", .min_args = 1, .max_args = 2 },
        .{ .variant = .trimright, .usage = "string ?trimchars?", .min_args = 1, .max_args = 2 },
    });

    var det: objutil.ErrorDetails = undefined;
    const subcommand: Subcommands = try interp.wrapError(&det, Parser.parse(&det, args));

    const sub_args = args[2..];
    const was_wrong_usage = wrong_usage: {
        switch (subcommand) {
            .bytelength => {
                const bytes = try sub_args[0].getString();
                try interp.setResultInteger(@intCast(bytes.len));
            },
            .byterange => {
                const bytes = try sub_args[0].getString();
                const range = try interp.wrapError(&det, objutil.getRange(
                    &det,
                    @intCast(bytes.len),
                    &sub_args[1],
                    &sub_args[2],
                ));
                try interp.setResultString(bytes[range.start..range.end]);
            },
            .cat => {
                var new_str: std.ArrayList(u8) = .empty;
                defer new_str.deinit(Heap.global_gpa);
                for (sub_args[0..]) |handle| {
                    const str = try handle.getString();
                    try new_str.appendSlice(Heap.global_gpa, str);
                }

                try interp.setResultString(new_str.items);
            },
            .compare, .equal => {
                var opt_case_insensitive = false;
                var opt_length: ?usize = null;

                // The last two arguments are the strings to compare. Everything
                // before is a flag.
                var i: usize = 0;
                while (i < sub_args.len - 2) : (i += 1) {
                    if (try sub_args[i].current().equalsString("-nocase")) {
                        opt_case_insensitive = true;
                    } else if (try sub_args[i].current().equalsString("-length")) {
                        if (i + 1 >= sub_args.len - 2) break :wrong_usage true; // There needs to be a value after `-length`.
                        opt_length = std.math.lossyCast(usize, try interp.getInteger(&sub_args[i + 1]));
                        i += 1;
                    } else break :wrong_usage true;
                }

                const bytes_a = try sub_args[i].getString();
                const bytes_b = try sub_args[i + 1].getString();

                // Fast case: [string equal], case sensitive, no max length.
                if (subcommand == .equal and !opt_case_insensitive and opt_length == null) {
                    try interp.setResultBoolean(std.mem.eql(u8, bytes_a, bytes_b));
                } else {
                    const order = strutil.compare(bytes_a, bytes_b, opt_length, opt_case_insensitive);
                    if (subcommand == .equal) {
                        try interp.setResultBoolean(order == .eq);
                    } else switch (order) {
                        .lt => try interp.setResultInteger(-1),
                        .eq => try interp.setResultInteger(0),
                        .gt => try interp.setResultInteger(1),
                    }
                }
            },
            .length => {
                try interp.setResultInteger(@intCast(try interp.getCodepointLength(&sub_args[0])));
            },
            .range => {
                const ranged_str = try interp.wrapError(
                    &det,
                    objutil.stringRange(&det, &sub_args[0], &sub_args[1], &sub_args[2]),
                );

                interp.setResultOwning(ranged_str);
            },
            .map => {
                var opt_case_insensitive = false;
                if (sub_args.len == 3) {
                    if (!try sub_args[0].current().equalsString("-nocase")) break :wrong_usage true;
                    opt_case_insensitive = true;
                }

                const map_list = &sub_args[sub_args.len - 2];
                const str_handle = &sub_args[sub_args.len - 1];

                const map_len = try interp.getListLength(map_list);
                if (@mod(map_len, 2) != 0) {
                    try interp.setResultString("list must contain an even number of elements");
                    return error.EvalError;
                }

                const pair_count = map_len / 2;
                const Pair = struct {
                    key: []const u8,
                    value: []const u8,
                    key_codepoint_len: usize,
                };

                // Precompute keys and values since the search loop is pretty hot.
                var pairs = try std.ArrayList(Pair).initCapacity(Heap.global_gpa, pair_count);
                defer pairs.deinit(Heap.global_gpa);

                // Go through and make sure every key has type .string so we can get its codepoint length.
                var key_i: u32 = 0;
                while (key_i < map_len) : (key_i += 2) {
                    var key_wb: Shimmerable = .{ .original = objutil.listItem(map_list.current(), key_i) };
                    defer key_wb.discardChanges();
                    try objutil.shimmerToString(&key_wb);
                    if (key_wb.takeShimmered().toHandle()) |new_key| {
                        // Be sure to write back the new object to the list.
                        try objutil.listSetInner(map_list.asMutable(), key_i, new_key.steal());
                    }
                }

                key_i = 0;
                while (key_i < map_len) : (key_i += 2) {
                    const key_handle = objutil.listItem(map_list.current(), key_i);
                    const value_handle = objutil.listItem(map_list.current(), key_i + 1);

                    var key_wb: Shimmerable = .{ .original = key_handle };
                    const key_codepoint_len = try objutil.getCodepointLength(&key_wb);
                    assert(key_wb.shimmered == .none);

                    pairs.appendAssumeCapacity(.{
                        .key = try key_handle.getString(),
                        .value = try value_handle.getString(),
                        .key_codepoint_len = key_codepoint_len,
                    });
                }

                const str = try str_handle.getString();

                var result: std.ArrayList(u8) = .empty;
                defer result.deinit(Heap.global_gpa);

                var str_iter = strutil.Iterator.init(str);

                // no_match_start tracks the first byte of a contiguous run of characters
                // that did not match any key. When a match is found, everything from
                // this byte index up to the current position is copied verbatim into
                // the result. It is null when we are not in the middle of an unmatched
                // run (e.g. right after a replacement, or at the start of the string).
                var no_match_start: ?usize = null;

                while (str_iter.peek()) |_| : (_ = str_iter.next()) {
                    var matched = false;
                    for (pairs.items) |pair| {
                        if (pair.key.len == 0) continue;
                        const remaining = str[str_iter.i..];
                        if (remaining.len < pair.key.len) continue;

                        // Limit the comparison to the key's codepoint count so that a
                        // longer remaining string still matches when the prefix is
                        // identical. Without the limit, compare would return .gt.
                        const order = strutil.compare(remaining, pair.key, pair.key_codepoint_len, opt_case_insensitive);
                        if (order != .eq) continue;

                        // A key matched. First, flush any preceding unmatched characters.
                        if (no_match_start) |start| {
                            try result.appendSlice(Heap.global_gpa, str[start..str_iter.i]);
                            no_match_start = null;
                        }
                        try result.appendSlice(Heap.global_gpa, pair.value);

                        // The outer loop already peeked at 1 codepoint but did not consume it.
                        // We need to advance past the rest of the matched key so the next
                        // iteration resumes at the first character after the replacement.
                        for (1..pair.key_codepoint_len) |_| {
                            _ = str_iter.next() orelse break;
                        }
                        matched = true;
                        break;
                    }

                    if (!matched) {
                        // This codepoint is not the start of any key. If we are not
                        // already tracking an unmatched run, mark the start here.
                        if (no_match_start == null) no_match_start = str_iter.i;
                    }
                }

                // If the string ended while we were still in an unmatched run, copy the
                // trailing characters into the result.
                if (no_match_start) |start| {
                    try result.appendSlice(Heap.global_gpa, str[start..str_iter.i]);
                }

                try interp.setResultString(result.items);
            },
            .index => {
                const codepoint_len = try interp.getCodepointLength(&sub_args[0]);
                const bytes = try sub_args[0].getString();
                const index = try interp.getIndex(&sub_args[1]);

                const abs_index = index.asAbsoluteIndex(@intCast(codepoint_len));
                if (abs_index < 0 or abs_index >= codepoint_len) {
                    interp.setEmptyResult();
                    return;
                } else if (bytes.len == codepoint_len) {
                    // ASCII optimization.
                    try interp.setResultString(&.{bytes[@intCast(abs_index)]});
                } else {
                    const byte_index = strutil.cpIndex(bytes, @intCast(abs_index)).?;
                    const len = std.unicode.utf8ByteSequenceLength(bytes[byte_index]) catch {
                        interp.setEmptyResult();
                        return;
                    };
                    try interp.setResultString(bytes[byte_index..][0..len]);
                }
            },
            else => std.debug.panic("unimplemented: {}", .{subcommand}),
        }
        break :wrong_usage false;
    };

    if (was_wrong_usage) {
        try interp.setResultFormatted(
            "wrong # args: should be \"{f} {f} {s}\"",
            .{ args[0].current(), args[1].current(), Parser.EnumToSubcommand.get(subcommand).usage },
        );
        return error.EvalError;
    }
}

pub fn llengthCmd(interp: *Interp, args: []Shimmerable) !void {
    try interp.setResultInteger(try interp.getListLength(&args[1]));
}

pub fn lappendCmd(interp: *Interp, args: []Shimmerable) !void {
    var list: Mutable = blk: {
        if ((try interp.getVariable(&args[1])).toHandle()) |val| {
            break :blk .{ .original = val.borrow() };
        } else {
            break :blk .{ .original = try objutil.newListWithCapacity(0) };
        }
    };
    defer list.deinit();

    for (args[2..]) |item| {
        _ = try interp.listAppend(&list, item.current());
    }

    try interp.setVariableTo(&args[1], list.current());
    interp.setResult(list.current());
}

pub fn lassignCmd(interp: *Interp, args: []Shimmerable) !void {
    // args[0] = "lassign", args[1] = list, args[2..] = varNames
    const list = &args[1];
    const list_len = try interp.getListLength(list);
    const var_count = args.len - 2;

    // Assign each list element to the corresponding variable.
    for (0..var_count) |i| {
        const var_name = &args[i + 2];
        if (i < list_len) {
            try interp.setVariableTo(var_name, objutil.listItem(list.current(), @intCast(i)));
        } else {
            // If there's no more elements, it becomes the empty string.
            try interp.setVariableTo(var_name, Heap.local_heap.emptyHandle());
        }
    }

    // If there's any remaining list elements, they're returned from [lassign].
    if (list_len > var_count) {
        const remaining_count = list_len - var_count;
        var remaining_list = try objutil.newListWithCapacity(@intCast(remaining_count));
        errdefer remaining_list.decrRefCount();
        for (var_count..list_len) |i| {
            objutil.listAppendAssumeCapacity(remaining_list, objutil.listItem(list.current(), @intCast(i)).dupOrRef());
        }
        interp.setResultOwning(remaining_list);
    } else {
        interp.setEmptyResult();
    }
}

/// [list]
pub fn listCmd(interp: *Interp, args: []Shimmerable) !void {
    interp.setResultOwning(try objutil.newListFromShimmerables(args[1..]));
}

pub fn concatCmd(interp: *Interp, args: []Shimmerable) !void {
    const to_concat = args[1..];
    if (to_concat.len == 0) {
        interp.setEmptyResult();
        return;
    }

    // If all the objects are lists, we can do a fast path.
    not_all_lists: {
        for (to_concat) |arg| {
            if (arg.tag() != .list) break :not_all_lists;
        }

        var total: u32 = 0;
        for (to_concat) |arg| total += objutil.listLength(arg.current());

        const result = try objutil.newListWithCapacity(total);
        errdefer result.decrRefCount();
        for (to_concat) |arg| {
            for (0..objutil.listLength(arg.current())) |i| {
                objutil.listAppendAssumeCapacity(result, objutil.listItem(arg.current(), @intCast(i)).dupOrRef());
            }
        }

        interp.setResultOwning(result);
        return;
    }

    // String path: trim each arg and join with single spaces.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(Heap.global_gpa);

    var first_nonempty = true;
    for (to_concat) |arg| {
        const raw = try arg.getString();
        const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        if (!first_nonempty) try buf.append(Heap.global_gpa, ' ');
        try buf.appendSlice(Heap.global_gpa, trimmed);
        first_nonempty = false;
    }

    try interp.setResultString(buf.items);
}

pub fn joinCmd(interp: *Interp, args: []Shimmerable) !void {
    // join list ?joinString?
    const list_len = try interp.getListLength(&args[1]);
    const join_string = if (args.len > 2) try args[2].getString() else " ";

    if (list_len == 0) {
        interp.setEmptyResult();
        return;
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(Heap.global_gpa);

    for (0..list_len) |i| {
        if (i > 0) try buf.appendSlice(Heap.global_gpa, join_string);
        const item = objutil.listItem(args[1].current(), @intCast(i));
        const item_str = try item.getString();
        try buf.appendSlice(Heap.global_gpa, item_str);
    }

    try interp.setResultString(buf.items);
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

pub fn launderCmd(interp: *Interp, args: []Shimmerable) !void {
    const str = try args[1].getString();
    try interp.setResultString(str);
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

/// [switch]
pub fn switchCmd(interp: *Interp, args: []Shimmerable) !void {
    const MatchType = enum { exact, glob, regex, command };
    var match_type: MatchType = .exact;

    var command_to_match: ?Handle = null;

    var arg_index: usize = 1;
    while (arg_index < args.len) : (arg_index += 1) {
        // Make sure we have something after, since we look ahead for some
        // of the flags.
        if (args.len - arg_index < 2) return error.WrongUsage;

        const bytes = try args[arg_index].getString();

        if (bytes[0] != '-') break; // Not a flag.
        if (try args[arg_index].current().equalsString("--")) {
            arg_index += 1;
            break;
        }
        if (try args[arg_index].current().equalsString("-exact")) {
            match_type = .exact;
        } else if (try args[arg_index].current().equalsString("-glob")) {
            match_type = .glob;
        } else if (try args[arg_index].current().equalsString("-regexp")) {
            match_type = .regex;
        } else if (try args[arg_index].current().equalsString("-command")) {
            match_type = .command;
            arg_index += 1;
            command_to_match = args[arg_index].current();
        } else {
            try interp.setResultFormatted(
                "bad option \"{f}\": must be -exact, -glob, -regexp, -command procname or --",
                .{args[arg_index].current()},
            );
            return error.EvalError;
        }
    }

    // Value we're switching on.
    const to_match_on = args[arg_index].current().borrow();
    defer to_match_on.decrRefCount();
    arg_index += 1;
    const to_match_on_bytes = try to_match_on.getString();

    const switch_body, var to_free_after = blk: {
        if (args.len - arg_index == 1) {
            try interp.shimmerToList(&args[arg_index]);
            const handles = try objutil.listToShimmerables(Heap.global_gpa, args[arg_index].current());
            break :blk .{ handles.items, handles };
        } else {
            if (@mod(args.len - arg_index, 2) != 0) return error.WrongUsage;
            break :blk .{ args[arg_index..], null };
        }
    };
    defer if (to_free_after) |*val| {
        for (switch_body) |*wb| wb.discardChanges();
        val.deinit(Heap.global_gpa);
    };

    // We need to borrow `body_to_run`, since it may mutate under us otherwise when `commandMatch` is called.
    var body_to_run: ?Handle = null;
    defer if (body_to_run) |val| val.decrRefCount();

    // Go through each switch arm until we find one that matches.
    var arm_idx: usize = 0;
    while (arm_idx < switch_body.len) : (arm_idx += 2) {
        const is_default = try switch_body[arm_idx].current().equalsString("default");
        // If `default` isn't the last arm in the switch body, we treat it
        // as a normal string to check against.
        if (!is_default or arm_idx < switch_body.len - 2) {
            switch (match_type) {
                .exact => {
                    if (try Heap.checkIfEqual(to_match_on, switch_body[arm_idx].current())) {
                        body_to_run = switch_body[arm_idx + 1].current().borrow();
                        break;
                    }
                },
                .glob => {
                    const matches = strutil.globMatch(try switch_body[arm_idx].getString(), to_match_on_bytes, false);
                    if (matches) {
                        body_to_run = switch_body[arm_idx + 1].current().borrow();
                        break;
                    }
                },
                .regex => {
                    var det: objutil.ErrorDetails = undefined;
                    const opts = pcre2.PCRE2_UTF | pcre2.PCRE2_UCP | pcre2.PCRE2_DOTALL;
                    try Interp.wrapError(interp, &det, objutil.shimmerToRegexp(&det, &switch_body[arm_idx], opts));
                    const regexp_handle = switch_body[arm_idx].current();

                    const re = regexp_handle.getRegexpExtraData();

                    const matches = try interp.wrapError(&det, regex.doesStringMatch(&det, re, to_match_on_bytes));
                    if (matches) {
                        body_to_run = switch_body[arm_idx + 1].current().borrow();
                        break; // Match!
                    } else continue;
                },
                .command => {
                    const matches = try commandMatch(interp, command_to_match.?, switch_body[arm_idx].current(), to_match_on);
                    if (matches) {
                        body_to_run = switch_body[arm_idx + 1].current().borrow();
                        break; // Match!
                    } else continue;
                },
            }
        } else {
            // Truly the default.
            body_to_run = switch_body[arm_idx + 1].current().borrow();
        }
    }

    interp.setEmptyResult();
    if (body_to_run) |to_run| {
        const to_run_fallthrough = if (try to_run.equalsString("-")) blk: {
            // Fall through if the body is `-`.
            var true_body_idx = arm_idx + 1;
            while (true_body_idx < switch_body.len) : (true_body_idx += 2) {
                if (!(try switch_body[true_body_idx].current().equalsString("-"))) break;
            } else {
                try interp.setResultFormatted("no body specified for pattern \"{f}\"", .{switch_body[arm_idx].current()});
            }
            break :blk switch_body[true_body_idx].current();
        } else to_run;

        try interp.evalObject(to_run_fallthrough);
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
                error.LinkLookupFailed,
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

pub fn breakpointCmd(_: *Interp, _: []Shimmerable) Interp.Error!void {
    @breakpoint();
}

/// [error message ?errorCode?]
pub fn errorCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    interp.setResult(args[1].current());

    if (args.len >= 3) {
        // Store the error code so [catch]/[try] can pick it up.
        try interp.shimmerToList(&args[2]);
        interp.pending_error_code.swap(args[2].current().borrow());
    }

    return error.EvalError;
}

/// [return ?-option value ...? ?result?]
///
/// Supported options: -code, -level, -errorcode.
pub fn returnCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    var code: Interp.ReturnCode = .@"return";
    var level: u32 = 1;

    const Flags = objutil.TclEnum(enum { @"-code", @"-level", @"-errorcode" }, "[return] flags", false);

    var i: usize = 1;
    while (i + 1 < args.len) {
        const flag = &args[i];
        const value = &args[i + 1];

        const flag_value = Flags.get(null, flag) catch null;

        if (flag_value) |val| switch (val) {
            .@"-code" => {
                var det: objutil.ErrorDetails = undefined;
                code = try interp.wrapError(&det, Interp.ReturnCodeEnum.get(&det, value));
                i += 2;
            },
            .@"-level" => {
                const level_i64 = try interp.getInteger(value);
                if (level_i64 < 0 or level_i64 > std.math.maxInt(u32)) {
                    try interp.setResultFormatted("bad -level value \"{}\"", .{level_i64});
                    return error.EvalError;
                }
                level = @intCast(level_i64);
                i += 2;
            },
            .@"-errorcode" => {
                interp.pending_error_code.swapWithNone();
                interp.pending_error_code = value.current().borrow().toOptional();
                i += 2;
            },
        } else {
            // Remaining arg has the return value.
            break;
        }
    }

    // If there's a trailing result value, set it; otherwise keep current result.
    if (i < args.len) {
        interp.setResult(args[i].current());
    }

    // -level 0 means "don't propagate, just set the result."
    if (level == 0) return;

    // `evalObjectInner` decrements `left_to_go` each time PropagateResult bubbles up
    // one eval level. Starting at `level` means it lands exactly `level` frames up.
    interp.return_propagate = .{
        .left_to_go = level,
        .return_at_end = null,
    };

    return code.toError();
}

pub fn fileCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const Subcommands = enum {
        exists,
        dirname,
        tail,
        rootname,
        join,
        mkdir,
        size,
        readable,
        isdirectory,
        mtime,
        readlink,
        tempfile,
    };
    const Parser = objutil.SubcommandParser(Subcommands, &.{
        .{ .variant = .exists, .usage = "name", .min_args = 1, .max_args = 1 },
        .{ .variant = .dirname, .usage = "name", .min_args = 1, .max_args = 1 },
        .{ .variant = .tail, .usage = "name", .min_args = 1, .max_args = 1 },
        .{ .variant = .rootname, .usage = "name", .min_args = 1, .max_args = 1 },
        .{ .variant = .join, .usage = "name ?name ...?", .min_args = 1, .max_args = null },
        .{ .variant = .mkdir, .usage = "dir", .min_args = 1, .max_args = 1 },
        .{ .variant = .size, .usage = "name", .min_args = 1, .max_args = 1 },
        .{ .variant = .readable, .usage = "name", .min_args = 1, .max_args = 1 },
        .{ .variant = .isdirectory, .usage = "name", .min_args = 1, .max_args = 1 },
        .{ .variant = .mtime, .usage = "name", .min_args = 1, .max_args = 1 },
        .{ .variant = .readlink, .usage = "name", .min_args = 1, .max_args = 1 },
        .{ .variant = .tempfile, .usage = "?name?", .min_args = 0, .max_args = 1 },
    });

    var det: objutil.ErrorDetails = undefined;
    const subcommand: Subcommands = try interp.wrapError(&det, Parser.parse(&det, args));

    switch (subcommand) {
        .exists => {
            const path = try args[2].getString();
            const exists = blk: {
                std.Io.Dir.accessAbsolute(Heap.global_io, path, .{}) catch |err| switch (err) {
                    error.FileNotFound => break :blk false,
                    else => {
                        try interp.setResultFormatted("could not access file: {s}", .{@errorName(err)});
                        return error.EvalError;
                    },
                };
                break :blk true;
            };
            try interp.setResultBoolean(exists);
        },
        .dirname => {
            const path = try args[2].getString();
            const dir = std.Io.Dir.path.dirname(path) orelse ".";
            try interp.setResultString(dir);
        },
        .tail => {
            const path = try args[2].getString();
            const base = std.Io.Dir.path.basename(path);
            try interp.setResultString(base);
        },
        .rootname => {
            const path = try args[2].getString();
            const ext = std.Io.Dir.path.extension(path);
            const root = if (ext.len > 0) path[0 .. path.len - ext.len] else path;
            try interp.setResultString(root);
        },
        .join => {
            var path_parts: std.ArrayList([]const u8) = .empty;
            defer path_parts.deinit(Heap.global_gpa);
            for (args[2..]) |arg| {
                try path_parts.append(Heap.global_gpa, try arg.getString());
            }
            const joined = try std.Io.Dir.path.join(Heap.global_gpa, path_parts.items);
            defer Heap.global_gpa.free(joined);
            try interp.setResultString(joined);
        },
        .mkdir => {
            const path = try args[2].getString();
            std.Io.Dir.cwd().createDir(Heap.global_io, path, .default_dir) catch |err| {
                try interp.setResultFormatted("could not create directory: {s}", .{@errorName(err)});
                return error.EvalError;
            };
            interp.setEmptyResult();
        },
        .size => {
            const path = try args[2].getString();
            const stat = std.Io.Dir.cwd().statFile(Heap.global_io, path, .{}) catch |err| {
                try interp.setResultFormatted("could not stat file: {s}", .{@errorName(err)});
                return error.EvalError;
            };
            try interp.setResultInteger(@intCast(stat.size));
        },
        .readable => {
            const path = try args[2].getString();
            const readable = blk: {
                std.Io.Dir.accessAbsolute(Heap.global_io, path, .{ .read = true }) catch |err| switch (err) {
                    error.FileNotFound => break :blk false,
                    else => {
                        try interp.setResultFormatted("could not access file: {s}", .{@errorName(err)});
                        return error.EvalError;
                    },
                };
                break :blk true;
            };
            try interp.setResultBoolean(readable);
        },
        .isdirectory => {
            const path = try args[2].getString();
            const is_dir = blk: {
                const stat = std.Io.Dir.cwd().statFile(Heap.global_io, path, .{}) catch |err| switch (err) {
                    error.FileNotFound => break :blk false,
                    else => {
                        try interp.setResultFormatted("could not stat file: {s}", .{@errorName(err)});
                        return error.EvalError;
                    },
                };
                break :blk stat.kind == .directory;
            };
            try interp.setResultBoolean(is_dir);
        },
        .mtime => {
            const path = try args[2].getString();
            const stat = std.Io.Dir.cwd().statFile(Heap.global_io, path, .{}) catch |err| {
                try interp.setResultFormatted("could not stat file: {s}", .{@errorName(err)});
                return error.EvalError;
            };
            // Convert to millseconds first so we should fit within the f64's mantissa pretty well.
            const mtime_ms: f64 = @floatFromInt(stat.mtime.toMilliseconds());
            try interp.setResultFloat(mtime_ms / 1000.0);
        },
        .readlink => {
            const path = try args[2].getString();
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const len = std.Io.Dir.cwd().readLink(Heap.global_io, path, &buf) catch |err| {
                try interp.setResultFormatted("could not read link: {s}", .{@errorName(err)});
                return error.EvalError;
            };
            try interp.setResultString(buf[0..len]);
        },
        .tempfile => {
            const template = if (args.len > 2) try args[2].getString() else null;

            var path_buf: std.ArrayList(u8) = .empty;
            defer path_buf.deinit(Heap.global_gpa);

            if (template) |t| {
                try path_buf.appendSlice(Heap.global_gpa, t);
            } else {
                const tmpdir = switch (builtin.os.tag) {
                    .windows => blk: {
                        const env_vars = &[_][]const u8{ "TMP", "TEMP", "LOCALAPPDATA", "USERPROFILE" };
                        for (env_vars) |name| {
                            if (std.c.getenv(name.ptr)) |val| {
                                const slice = std.mem.span(val);
                                if (slice.len > 0) break :blk slice;
                            }
                        }
                        break :blk "C:\\Windows\\Temp";
                    },
                    else => blk: {
                        if (std.c.getenv("TMPDIR")) |val| {
                            const slice = std.mem.span(val);
                            if (slice.len > 0) break :blk slice;
                        }
                        break :blk "/tmp";
                    },
                };
                try path_buf.appendSlice(Heap.global_gpa, tmpdir);
                if (!std.mem.endsWith(u8, path_buf.items, std.fs.path.sep_str)) {
                    try path_buf.append(Heap.global_gpa, std.fs.path.sep);
                }
                try path_buf.appendSlice(Heap.global_gpa, "tcl.tmp.");
            }

            const base_len = path_buf.items.len;
            const has_template = if (template) |val| std.mem.endsWith(u8, val, "XXXXXX") else false;
            const suffix_start = if (has_template) base_len - 6 else base_len;
            const suffix_len: usize = if (has_template) 6 else 8;

            if (!has_template) {
                try path_buf.resize(Heap.global_gpa, base_len + suffix_len);
            }

            const alnum = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
            var random_bytes: [8]u8 = undefined;

            var retries: u32 = 0;
            const max_retries = 100;
            while (retries < max_retries) : (retries += 1) {
                Heap.global_io.random(&random_bytes);

                for (0..suffix_len) |i| {
                    path_buf.items[suffix_start + i] = alnum[random_bytes[i] % alnum.len];
                }

                const file = std.Io.Dir.createFileAbsolute(Heap.global_io, path_buf.items, .{
                    .read = true,
                    .truncate = false,
                    .exclusive = true,
                }) catch |err| switch (err) {
                    error.PathAlreadyExists => continue,
                    else => {
                        try interp.setResultFormatted("could not create temp file: {s}", .{@errorName(err)});
                        return error.EvalError;
                    },
                };
                defer file.close(Heap.global_io);

                try interp.setResultString(path_buf.items);
                return;
            }

            try interp.setResultString("could not create a unique temporary file");
            return error.EvalError;
        },
    }
}

/// [errorinfo optsDict]
pub fn infoCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const Subcommands = enum {
        exists,
        source,
        frame,
        hostname,
        type,
    };
    const Parser = objutil.SubcommandParser(Subcommands, &.{
        .{ .variant = .exists, .usage = "varName", .min_args = 1, .max_args = 1 },
        .{ .variant = .source, .usage = "script ?fileName lineNo?", .min_args = 1, .max_args = 3 },
        .{ .variant = .frame, .usage = "?level?", .min_args = 0, .max_args = 1 },
        .{ .variant = .hostname, .usage = "", .min_args = 0, .max_args = 0 },
        .{ .variant = .type, .usage = "object", .min_args = 1, .max_args = 1 },
    });

    var det: objutil.ErrorDetails = undefined;
    const subcommand: Subcommands = try interp.wrapError(&det, Parser.parse(&det, args));

    switch (subcommand) {
        .exists => {
            const val = try interp.getVariable(&args[2]);
            try interp.setResultInteger(if (val.toHandle() != null) 1 else 0);
        },
        .source => {
            const script = &args[2];
            if (args.len == 3) {
                if (objutil.getSourceInfo(script.current())) |info| {
                    const file_name = info.file_name.orEmpty();
                    const line_no = try objutil.newInteger(info.line_no);
                    defer line_no.decrRefCount();
                    const list = try objutil.newList(&.{ file_name, line_no });
                    interp.setResultOwning(list);
                } else {
                    const line_no = try objutil.newInteger(1);
                    defer line_no.decrRefCount();
                    const list = try objutil.newList(&.{ Heap.local_heap.emptyHandle(), line_no });
                    interp.setResultOwning(list);
                }
            } else {
                const file_name = try objutil.newString(try args[3].getString());
                defer file_name.decrRefCount();
                const line_no = try interp.getInteger(&args[4]);
                try script.ensureShimmerable();
                try objutil.setSourceInfo(script.current(), .{ .file_name = file_name.toOptional(), .line_no = @intCast(line_no) });
            }
        },
        .frame => {
            const current = interp.callFrameIdx();

            if (args.len == 2) {
                try interp.setResultInteger(@intCast(current + 1));
                return;
            }

            const level = try interp.getInteger(&args[2]);
            const signed_current: i64 = @intCast(current);
            const signed_level: i64 = @intCast(level);
            const target: u32 = blk: {
                if (level < 0) {
                    const t = signed_current + signed_level;
                    if (t < 0) {
                        try interp.setResultString("bad level");
                        return error.EvalError;
                    }
                    break :blk @intCast(t);
                } else {
                    if (signed_level >= signed_current + 1) {
                        try interp.setResultString("bad level");
                        return error.EvalError;
                    }
                    break :blk @intCast(level);
                }
            };

            // Find the topmost eval frame for the target call frame.
            var target_eval_frame: ?*Interp.EvalFrame = null;
            var i = interp.eval_frames.items.len;
            while (i > 0) {
                i -= 1;
                const eval_frame = &interp.eval_frames.items[i];
                if (eval_frame.call_frame == target) {
                    target_eval_frame = eval_frame;
                    break;
                }
            }

            if (target_eval_frame == null) {
                try interp.setResultString("bad level");
                return error.EvalError;
            }

            const eval_frame = target_eval_frame.?;
            const body = eval_frame.currently_evaluating;
            const source_info = objutil.getSourceInfo(body);
            const file_name, const base_line = if (source_info) |info| blk: {
                break :blk .{ info.file_name.orEmpty(), info.line_no };
            } else blk: {
                break :blk .{ Heap.local_heap.emptyHandle(), 1 };
            };
            const abs_line = base_line + (eval_frame.current_line -| 1);

            const call_frame = &interp.call_frames.items[eval_frame.call_frame];
            const type_val = if (call_frame.signature.name.toHandle() != null) "fn" else "source";
            const type_handle = try objutil.newString(type_val);
            defer type_handle.decrRefCount();
            const file_name_str = if (file_name.tag() == .string) try file_name.getString() else "";
            const file_handle = try objutil.newString(file_name_str);
            defer file_handle.decrRefCount();
            const line_handle = try objutil.newInteger(@intCast(abs_line));
            defer line_handle.decrRefCount();

            var dict = try objutil.newDictWithCapacity(8);
            defer dict.decrRefCount();

            objutil.dictPutAssumeCapacity(dict, Heap.local_heap.getInternedString(.type), type_handle.steal());
            objutil.dictPutAssumeCapacity(dict, Heap.local_heap.getInternedString(.file), file_handle.steal());
            objutil.dictPutAssumeCapacity(dict, Heap.local_heap.getInternedString(.line), objutil.integerObject(@intCast(abs_line)));

            const rel_level = current - target;
            objutil.dictPutAssumeCapacity(dict, Heap.local_heap.getInternedString(.level), objutil.integerObject(@intCast(rel_level)));

            interp.setResult(dict.borrow());
        },
        .hostname => {
            var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
            const name = std.posix.gethostname(&buf) catch |err| {
                try interp.setResultFormatted("could not get hostname: {s}", .{@errorName(err)});
                return error.EvalError;
            };
            try interp.setResultString(name);
        },
        .type => {
            try interp.setResultString(@tagName(args[1].tag()));
        },
    }
}

pub fn errorinfoCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const message = args[1];
    const stack_trace = if (args.len == 3) args[2].current() else if (args.len == 2) interp.stack_trace.orEmpty() else unreachable;

    // The stack is a flat list: {name file line args ...} repeated.
    var stack_list = stack_trace.borrow();
    errdefer stack_list.decrRefCount();
    try interp.shimmerToListInPlace(&stack_list);

    const error_message = Interp.makeErrorMessage(message.current(), stack_list) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WrongSize => return,
    };
    interp.setResultOwning(error_message);
}

fn registerCommand(
    interp: *Interp,
    name: []const u8,
    to_call: Interp.CommandFn,
    description: []const u8,
    min_arity: usize,
    max_arity: ?usize,
    stride: ?usize,
) !void {
    try interp.registerCommand(name, .{
        .call_info = .{ .zig = to_call },
        .description = description,
        .min_arity = min_arity,
        .max_arity = max_arity,
        .multiple_of = stride,
    });
}

pub fn registerCoreCommands(interp: *Interp) !void {
    try registerCommand(interp, "*", mulCmd, "?number ...?", 1, null, null);
    try registerCommand(interp, "+", addCmd, "?number ...?", 1, null, null);
    try registerCommand(interp, "-", subCmd, "?number ...?", 1, null, null);
    try registerCommand(interp, "/", divCmd, "?number ...?", 1, null, null);
    try registerCommand(interp, "append", appendCmd, "varName ?value ...?", 1, null, null);
    try registerCommand(interp, "apply", applyCmd, "fn ?arg ...?", 1, null, null);
    try registerCommand(interp, "applymethod", applymethodCmd, "self method ?arg ...?", 1, null, null);
    try registerCommand(interp, "break", breakCmd, "?level?", 0, 1, null);
    try registerCommand(interp, "breakpoint", breakpointCmd, "", 0, 0, null);
    try registerCommand(interp, "catch", catchCmd, "script ?resultVar? ?optsVar?", 1, 3, null);
    try registerCommand(interp, "concat", concatCmd, "?arg ...?", 0, null, null);
    try registerCommand(interp, "continue", continueCmd, "?level?", 0, 1, null);
    try registerCommand(interp, "dict", dictCmd, "subcommand ?arg ...?", 1, null, null);
    try registerCommand(interp, "error", errorCmd, "message ?errorCode?", 1, 2, null);
    try registerCommand(interp, "errorinfo", errorinfoCmd, "optsDict", 1, 1, null);
    try registerCommand(interp, "eval", evalCmd, "arg ?arg ...?", 1, null, null);
    try registerCommand(interp, "expr", exprCmd, "expression", 1, 1, null);
    try registerCommand(interp, "file", fileCmd, "subcommand ?arg ...?", 1, null, null);
    try registerCommand(interp, "fn", fnCmd, "?name? argList body", 2, 3, null);
    try registerCommand(interp, "hash", hashCmd, "string", 1, 1, null);
    try registerCommand(interp, "hashlookup", hashlookupCmd, "hash", 1, 1, null);
    try registerCommand(interp, "method", methodCmd, "?name? argList body", 2, 3, null);
    try registerCommand(interp, "for", forCmd, "start test next body", 4, 4, null);
    try registerCommand(interp, "foreach", foreachCmd, "varList list ?varList list ...? body", 3, null, 2);
    try registerCommand(interp, "lmap", lmapCmd, "varList list ?varList list ...? body", 3, null, 2);
    try registerCommand(interp, "if", ifCmd, "condition trueBody ?elseif ...? ?else falseBody?", 2, null, null);
    try registerCommand(interp, "incr", incrCmd, "varName ?increment?", 1, 2, null);
    try registerCommand(interp, "info", infoCmd, "subcommand ?arg ...?", 1, null, null);
    try registerCommand(interp, "lappend", lappendCmd, "varName ?value value ...?", 1, null, null);
    try registerCommand(interp, "lassign", lassignCmd, "list ?varName ...?", 1, null, null);
    try registerCommand(interp, "launder", launderCmd, "string", 1, 1, null);
    try registerCommand(interp, "list", listCmd, "?arg ...?", 0, null, null);
    try registerCommand(interp, "join", joinCmd, "list ?joinString?", 1, 2, null);
    try registerCommand(interp, "llength", llengthCmd, "list", 1, 1, null);
    try registerCommand(interp, "pid", pidCmd, "", 0, 0, null);
    try registerCommand(interp, "puts", putsCmd, "?-nonewline? string", 1, 2, null);
    try registerCommand(interp, "regexp", regex.regexpCmd, "?switches? exp string ?matchVar ...?", 2, null, null);
    try registerCommand(interp, "regsub", regex.regsubCmd, "?switches? exp string subSpec ?varName?", 3, null, null);
    try registerCommand(interp, "return", returnCmd, "?-option value ...? ?result?", 0, null, null);
    try registerCommand(interp, "set", setCmd, "varName ?newValue?", 1, 2, null);
    try registerCommand(interp, "string", stringCmd, "subcommand ?arg ...?", 1, null, null);
    try registerCommand(interp, "source", sourceCmd, "fileName", 1, 1, null);
    try registerCommand(interp, "subst", substCmd, "?options? string", 1, 4, null);
    try registerCommand(interp, "switch", switchCmd, "?options? string pattern body ... ?default body? or pattern body ?pattern body ...?", 2, null, null);
    try registerCommand(interp, "tailcall", tallcallCommand, "command ?arg ...?", 1, null, null);
    try registerCommand(interp, "try", tryCmd, "script ?handler ...? ?finally body?", 1, null, null);
    try registerCommand(interp, "unset", unsetCmd, "?-nocomplain? ?--? ?varName ...?", 0, null, null);
    try registerCommand(interp, "uplevel", uplevelCmd, "?level? script ?arg ...?", 1, null, null);
    try registerCommand(interp, "upvar", upvarCmd, "?level? otherVar myVar ?otherVar myVar ...?", 2, null, null);
}

pub fn testStart(ta: std.mem.Allocator) !Interp {
    errdefer Heap.testFinish();
    _ = try Heap.testStart(ta, testing.io);
    var interp = try Interp.init();
    errdefer interp.deinit();
    try registerCoreCommands(&interp);
    return interp;
}

pub fn testFinish(interp: *Interp) void {
    interp.deinit();
    Heap.testFinish();
}

test "commands" {
    var interp = try testStart(testing.allocator);
    defer testFinish(&interp);

    var script = try objutil.newString(
        \\ dict set x a 10
        \\ puts [dict get $x a 5]
    );
    defer script.decrRefCount();
    interp.evalObject(script) catch {};
}

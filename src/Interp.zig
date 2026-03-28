const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const Tokenizer = @import("Tokenizer.zig");
const Heap = @import("Heap.zig");
const Handle = Heap.Handle;
const OptionalHandle = Heap.OptionalHandle;
const objutil = @import("objutil.zig");
const memutil = @import("memutil.zig");
const expr_parse = @import("expr_parse.zig");

const Interp = @This();
/// The result from a procedure or eval call
result: Handle,
/// Eval frames are separate from call frames, as eval calls can be
/// nested while staying in the same scope. For example,
/// `puts [+ 2 2]` has one call frame (the global scope), and two
/// eval frames (one for puts, and while puts is running, another
/// for +).
eval_frames: std.ArrayList(EvalFrame),
/// All call frames. Note, index is _not_ stack depth. Why? Because
/// when you run `uplevel`, it creates a new call frame, it doesn't
/// jump back.
call_frames: std.ArrayList(CallFrame),
/// Used to invalidate cached variable lookups. Will overflow, but
/// when it overflows the interpreter will scan through the heap and
/// invalidate all variables.
current_call_epoch: u32,
/// Used to invalidate cached procedures.
global_procedure_epoch: u32,
global_commands: CommandHashTable,

eval_depth: usize,
max_eval_depth: usize,
max_call_depth: usize,
/// Stack trace from a function error.
stack_trace: ?Handle,

/// Used to propagate `error.Continue` or `error.Break` up multiple
/// loop levels.
loop_propagate: u32 = 0,
/// Used for propagating a return code up multiple eval levels.
return_propagate: struct {
    left_to_go: u32 = 0,
    return_at_end: ?Error = null,
} = .{},

prng: std.Random.DefaultPrng,

pub const CommandHashTable = std.StringArrayHashMapUnmanaged(NativeCommand);
pub const CommandFn = fn (interp: *Interp, args: []Handle) Error!void;
pub const CCommandFn = fn (interp: *Interp, argc: c_int, argv: [*]Handle) callconv(.c) c_int;

pub const Error = std.mem.Allocator.Error || error{
    EvalError,
    Break,
    Continue,
    Signal,
    PropagateResult,
    VariableNotFound,
    VariableAlreadyExists,
    DictSugarInUpvarName,
    CircularUpvar,
    CommandNotFound,
    InfiniteRecursion,
    WrongUsage,
};

const Tailcall = struct {
    args: []Handle,
};

fn wrapErrorDetailsReturnType(ResultType: type) type {
    if (comptime std.meta.activeTag(@typeInfo(ResultType)) == .error_set) {
        return error{ OutOfMemory, EvalError };
    } else {
        return error{ OutOfMemory, EvalError }!@typeInfo(ResultType).error_union.payload;
    }
}
/// Used to convert from an object error to an interpreter error (e.g. putting
/// it in the interpreter result, instead of det)
pub fn wrapError(interp: *Interp, det: *objutil.ErrorDetails, result: anytype) wrapErrorDetailsReturnType(@TypeOf(result)) {
    if (comptime std.meta.activeTag(@typeInfo(@TypeOf(result))) == .error_set) {
        if (result == error.OutOfMemory) {
            return error.OutOfMemory;
        } else {
            return error.EvalError;
        }
    }

    if (result) |val| {
        return val;
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            // This error should have error details, if it's not OOM.
            interp.setResultOwning(det.message);
            return error.EvalError;
        },
    }
}

fn variableNotFoundError(det: ?*objutil.ErrorDetails, var_name: []const u8) !void {
    if (det) |details| details.* = .{
        .message = try objutil.newStringFmt(Heap.local_heap, "can't read \"{s}\": no such variable", .{var_name}),
    };

    return error.VariableNotFound;
}

/// Resolves to the variable's value, if any.
fn resolveVariable(interp: *Interp, var_call_frame: u32, var_name: Handle) !?Heap.VariableValue {
    const var_dict = interp.call_frames.items[var_call_frame].variables;
    const scope = interp.call_frames.items[var_call_frame].signature.scope;

    // Check the variables dictionary. Don't follow refs here so the
    // cached index points at the dict slot, not the ref target.
    const in_local_variables = try objutil.dictLookupInner(var_dict, var_name);
    if (in_local_variables.toHandle()) |local_var| {
        return .{ .local_variable = .{
            .target = local_var,
        } };
    }

    // Wasn't in the variables, maybe it's in a parent scope instead?
    if (scope.toHandle()) |dict| {
        const in_linked_scope = try objutil.dictLookupFollowLinks(dict, var_name);
        if (in_linked_scope.toHandle()) |val| {
            return .{ .lexical_variable = .{
                .target = val,
            } };
        }
    }

    return null;
}

/// This always recalculates .variable. You probably should be using `ensureValidVariableType`.
/// Must be called with a heap-native variable name, so it can shimmer in place.
fn reshimmerToVariable(interp: *Interp, det: ?*objutil.ErrorDetails, var_call_frame: u32, name: Handle) !void {
    name.assert(name.getHeap() == Heap.local_heap);
    name.assert(name.canShimmer());

    const var_name = try name.getString();
    const call_frame = &interp.call_frames.items[var_call_frame];

    if (try interp.resolveVariable(var_call_frame, name)) |var_value| {
        switch (var_value) {
            .local_variable => |local_var| {
                try name.prepareToShimmer();
                name.peek().head.tag = .cached_local_var;
                name.peek().body.cached_local_var = .{
                    .call_epoch = call_frame.call_epoch,
                    .cached_index = local_var.target.index,
                };
            },
            .lexical_variable => |lexical_var| {
                const extra_data = try Heap.local_heap.createExtraData();
                errdefer Heap.local_heap.destroyExtraData(extra_data);
                Heap.local_heap.getExtraData(extra_data).* = .{ .lexical_variable = .{
                    .ref = lexical_var.target.borrow(),
                } };

                try name.prepareToShimmer();
                name.peek().head.tag = .cached_lexical_var;
                name.peek().body.cached_lexical_var = .{
                    .call_epoch = call_frame.call_epoch,
                    .extra_data = extra_data,
                };
            },
        }
    } else {
        return variableNotFoundError(det, var_name);
    }
}

/// Ensures that this is a valid variable, dict sugar, or upvar. If not, it'll shimmer it to whichever one applies.
/// Must be called with a heap-native variable name.
fn ensureValidVariableType(interp: *Interp, det: ?*objutil.ErrorDetails, var_call_frame: u32, name: Handle) !void {
    assert(name.getHeap() == Heap.local_heap);

    const call_frame = interp.call_frames.items[var_call_frame];

    switch (name.tag()) {
        .cached_local_var => {
            // Fast case: if we're in the same epoch as last time, so we don't
            // need to do anything.
            if (name.peek().body.cached_local_var.call_epoch == call_frame.call_epoch) {
                return;
            } else {
                // Need to re-resolve the variable in the current call frame.
                // `name` will be valid after this function completes.
                try interp.reshimmerToVariable(det, var_call_frame, name);
                return;
            }
        },
        .cached_lexical_var => {
            // Fast case: if we're in the same epoch as last time, we don't need
            // to do anything.
            if (name.peek().body.cached_lexical_var.call_epoch == call_frame.call_epoch) {
                return;
            } else {
                // Since this is a lexical value lookup, and the lexical scopes are immutable,
                // the only case where this lookup becomes invalid is if it were shadowed by
                // a local variable.
                if ((try objutil.dictLookupFollowRefs(call_frame.variables, name)).toHandle()) |_| {
                    // Shadowed, so we need to look up again.
                    try interp.reshimmerToVariable(det, var_call_frame, name);
                    return;
                } else {
                    // Wasn't shadowed, so be sure to update its epoch so we don't do
                    // this expensive lookup again.
                    name.peek().body.cached_lexical_var.call_epoch = call_frame.call_epoch;
                    return;
                }
            }
        },
        .dict_sugar => {
            @panic("Dict sugar not implemented yet");
        },
        else => {
            // Fall through.
        },
    }

    // We don't know whether this is a normal variable or dict sugar yet.
    const var_name = try name.getString();

    // Does it end with ')' and have '(' at some point in the name?
    if (var_name.len >= 2 and var_name[var_name.len - 1] == ')' and std.mem.indexOfScalar(u8, var_name, '(') != null) {
        @panic("Dict sugar not implemented yet");
        // name_obj.tag = .dict_subst;
    } else {
        try interp.reshimmerToVariable(det, var_call_frame, name);
    }
}

// Must be called with a heap-native variable name.
fn createVariable(interp: *Interp, call_frame_idx: u32, name: Handle, value: Heap.Object) !void {
    name.assert(name.getHeap() == Heap.local_heap);
    name.assert(name.canShimmer());

    const call_frame = &interp.call_frames.items[call_frame_idx];
    call_frame.call_epoch = interp.nextCallEpoch();

    // Add variable.
    const put_result = try objutil.dictPutInner(call_frame.variables, name, value);
    call_frame.variables.swapIfNew(put_result.new_dict);

    try name.prepareToShimmer();
    name.peek().head.tag = .cached_local_var;
    name.peek().body.cached_local_var = .{
        .call_epoch = call_frame.call_epoch,
        .cached_index = put_result.new_value.index,
    };
}

/// Must be called with a heap-native name. Always takes ownership of `value`, even in error cases.
pub fn setVariableImpl(interp: *Interp, call_frame_idx: u32, name: Handle, value: Heap.Object) !void {
    name.assert(name.getHeap() == Heap.local_heap);
    name.assert(name.canShimmer());

    if (interp.ensureValidVariableType(null, call_frame_idx, name)) {
        switch (name.tag()) {
            .dict_sugar => @panic("Dict sugar not implemented"),
            .cached_local_var => {
                const cached_var = &name.peek().body.cached_local_var;
                const var_value = Heap.local_heap.getHandle(cached_var.cached_index);
                if (var_value.tag() == .upvar_link) {
                    const upvar_link = var_value.peek().body.upvar_link;
                    // Set the value through the linked name in the linked frame.
                    try interp.setVariableImpl(upvar_link.call_frame, Heap.local_heap.getHandle(upvar_link.linked_name), value);
                    return;
                }

                const var_call_frame = &interp.call_frames.items[call_frame_idx];

                const put_result = try objutil.dictPutInner(var_call_frame.variables, name, value);
                if (put_result.new_dict.toHandle()) |new_dict| {
                    // Did the dict change locations? If so, all cached lookups are now invalid.
                    var_call_frame.variables.swap(new_dict);
                    var_call_frame.call_epoch = interp.nextCallEpoch();
                }

                cached_var.* = .{
                    .call_epoch = var_call_frame.call_epoch,
                    .cached_index = put_result.new_value.index,
                };
            },
            .cached_lexical_var => {
                // We can't mutate a lexical var, so we instead shadow it in the local scope.
                try createVariable(interp, call_frame_idx, name, value);
            },
            else => unreachable,
        }
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.VariableNotFound => try createVariable(interp, call_frame_idx, name, value),
    }
}

pub fn setVariableLinkImpl(
    interp: *Interp,
    det: ?*objutil.ErrorDetails,
    call_frame_idx: u32,
    name: Handle,
    target_call_frame_idx: u32,
    target_name: Handle,
) !void {
    name.assert(name.getHeap() == Heap.local_heap);
    name.assert(name.canShimmer());

    const name_bytes = try name.getString();
    const target_name_bytes = try target_name.getString();

    if (interp.ensureValidVariableType(null, call_frame_idx, name)) |_| {
        // Variable already exists.
        if (det) |details| details.* = .{
            .message = try objutil.newStringFmt(Heap.local_heap, "variable \"{s}\" already exists", .{name_bytes}),
        };

        return error.VariableAlreadyExists;
    } else |err| switch (err) {
        error.VariableNotFound => {
            // Fall through.
        },
        error.OutOfMemory => return error.OutOfMemory,
    }

    if (name.tag() == .dict_sugar) {
        if (det) |details| details.* = .{
            .message = try objutil.newString(Heap.local_heap, "cannot create an upvar name that has dict sugar"),
        };
        return error.DictSugarInUpvarName;
    }

    // Check for cycles (only possible with `upvar 0`).
    if (call_frame_idx == target_call_frame_idx) {
        // Traverse the upvar chain until either we reach the end of the chain
        // or we find ourselves.
        var obj_currently_checking = target_name;
        while (true) {
            if (try Heap.checkIfEqual(name, obj_currently_checking)) {
                // We'd create a circular reference at this point, since
                // we managed to find ourselves when traversing the upvar
                // chain. Obviously, we can't let this happen.
                if (det) |details| details.* = .{
                    .message = try objutil.newString(Heap.local_heap, "can't upvar from variable to itself"),
                };
                return error.CircularUpvar;
            }

            const var_exists = interp.ensureValidVariableType(null, target_call_frame_idx, obj_currently_checking);
            if (var_exists) |_| {
                // Can't use `getVariableImpl` here, as it follows upvars.
                if (obj_currently_checking.tag() == .cached_local_var) {
                    const index = obj_currently_checking.peek().body.cached_local_var.cached_index;
                    const var_val = obj_currently_checking.getHeap().getHandle(index);
                    // Need to check the next link in this upvar chain to see if
                    // it has a cycle.
                    if (var_val.peek().body.upvar_link.call_frame != call_frame_idx) {
                        // Next upvar is higher than the current call frame, so it's
                        // impossible that it loops back here.
                        break;
                    } else {
                        const upvar_link = var_val.peek().body.upvar_link;
                        obj_currently_checking = var_val.getHeap().getHandle(upvar_link.linked_name);
                    }
                } else {
                    break;
                }
            } else |err| switch (err) {
                error.VariableNotFound => {
                    // If the target var doesn't exist, then of course the var name != nothing,
                    // so it's not equal to itself.
                    break;
                },
                error.OutOfMemory => return error.OutOfMemory,
            }
        }

        const target_name_duped = try objutil.newString(Heap.local_heap, target_name_bytes);

        try interp.setVariableImpl(call_frame_idx, name, .{
            .head = .{ .str = Heap.Object.null_string, .tag = .upvar_link },
            .body = .{ .upvar_link = .{
                .call_frame = target_call_frame_idx,
                .linked_name = target_name_duped.index,
            } },
        });
    }
}

/// Resolves to the variable's value. Must be called with a heap-native name.
pub fn getVariableInner(
    interp: *Interp,
    det: ?*objutil.ErrorDetails,
    call_frame: u32,
    name: Handle,
) error{ OutOfMemory, VariableNotFound }!Handle {
    try interp.ensureValidVariableType(det, call_frame, name);

    const name_obj = name.peek();
    const name_heap = name.getHeap();

    switch (name.tag()) {
        .cached_local_var => {
            const resolved = name_heap.getHandle(name_obj.body.cached_local_var.cached_index);
            if (resolved.tag() == .upvar_link) {
                // Recursively follow upvar.
                const upvar_link = resolved.peek().body.upvar_link;
                const linked_name = resolved.getHeap().getHandle(upvar_link.linked_name);
                return try interp.getVariableInner(det, upvar_link.call_frame, linked_name);
            }
            // The cached index points at the dict slot, which may
            // hold a reference to the actual value.
            return objutil.followIfRef(resolved);
        },
        .cached_lexical_var => {
            const extra_data = name_heap.getExtraData(name_obj.body.cached_lexical_var.extra_data);
            return extra_data.lexical_variable.ref;
        },
        .dict_sugar => {
            @panic("Dict sugar not implemented");
        },
        else => unreachable,
    }
}

fn testVariables(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    const heap = try Heap.testStart(ta);
    var interp = try Interp.init();
    defer interp.deinit();

    var str_foo = try objutil.newString(heap, "foo");
    defer str_foo.decrRefCount();

    // Make sure it doesn't resolve to anything.
    try testing.expectEqual(null, interp.resolveVariable(0, str_foo));

    const str_value = try objutil.newString(heap, "value");
    defer str_value.decrRefCount();
    try interp.setVariableTo(&str_foo, str_value);

    const cached_lookup_value = (try interp.resolveVariable(0, str_foo)).?.local_variable.target;
    try testing.expectEqualStrings("value", try cached_lookup_value.getString());
    // Also try resolving the value from a new string.
    var str2_foo = try objutil.newString(heap, "foo");
    defer str2_foo.decrRefCount();
    const lookup_value = (try interp.resolveVariable(0, str2_foo)).?.local_variable.target;
    try testing.expectEqualStrings("value", try lookup_value.getString());
}

test "variables" {
    try testing.checkAllAllocationFailures(testing.allocator, testVariables, .{});
}

fn testVariableLink(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    const heap = try Heap.testStart(ta);
    var interp = try Interp.init();
    defer interp.deinit();

    // Create a variable `foo` containing `value`, then upvar `bar` to `foo`.
    var str_foo = try objutil.newString(heap, "foo");
    defer str_foo.decrRefCount();

    try testing.expectEqual(null, interp.resolveVariable(0, str_foo));
    const str_value = try objutil.newString(heap, "value");
    defer str_value.decrRefCount();
    try interp.setVariableTo(&str_foo, str_value);

    var str_bar = try objutil.newString(heap, "bar");
    defer str_bar.decrRefCount();
    try interp.setVariableLinkImpl(null, 0, str_bar, 0, str_foo);

    // Make sure we can get the value of `foo` through `bar`.
    var lookup_value = try interp.getVariableInner(null, 0, str_bar);
    try testing.expectEqualStrings("value", try lookup_value.getString());

    // Modify `foo` through `bar`.
    const str_new_value = try objutil.newString(heap, "new value");
    defer str_new_value.decrRefCount();
    try interp.setVariableImpl(0, str_bar, str_new_value.reference());
    lookup_value = try interp.getVariableInner(null, 0, str_foo);
    try testing.expectEqualStrings("new value", try lookup_value.getString());
}

test "variable link" {
    try testing.checkAllAllocationFailures(testing.allocator, testVariableLink, .{});
}

pub const NativeCommand = struct {
    pub const ZigCommand = struct {
        to_call: *const CommandFn,
        description: ?[]const u8 = "",
        min_arity: usize = 0,
        max_arity: ?usize = null,
        /// If the command argument length needs to be a multiple of some
        /// amount, set this. A good example is `dict create`, as it needs
        /// an even number of arguments.
        multiple_of: ?usize = null,
    };

    pub const CCommand = extern struct {
        to_call: *const CCommandFn,
        description: ?[*:0]u8,
        min_arity: c_int = 0,
        max_arity: c_int = -1,
        multiple_of: c_int = -1,
    };

    call_info: union(enum) {
        zig: ZigCommand,
        c: CCommand,
    },

    /// Returns a string containing all the usage information. Allocates the string
    /// onto `gpa`. Produces something like `cmd ...`, or `cmd arg1 arg2 ?arg3?`
    pub fn getUsageInfo(command: *NativeCommand, gpa: std.mem.Allocator, command_name: []const u8) ![]const u8 {
        var aw = std.Io.Writer.Allocating.init(gpa);
        defer aw.deinit();

        // Write command name.
        aw.writer.writeAll(command_name) catch return error.OutOfMemory;

        switch (command.call_info) {
            .zig => |call_info| {
                if (call_info.description) |description| {
                    aw.writer.print(" {s}", .{description}) catch return error.OutOfMemory;
                } else {
                    aw.writer.writeAll(" ...") catch return error.OutOfMemory;
                }
            },
            .c => |call_info| {
                if (call_info.description) |description| {
                    aw.writer.print(" {s}", .{description}) catch return error.OutOfMemory;
                } else {
                    aw.writer.writeAll(" ...") catch return error.OutOfMemory;
                }
            },
        }

        return try aw.toOwnedSlice();
    }
};

fn wrongArgumentCountError(det: ?*objutil.ErrorDetails, command_usage: []const u8) !void {
    if (det) |details| details.* = .{
        .message = try objutil.newStringFmt(Heap.local_heap, "wrong # args: should be \"{s}\"", .{command_usage}),
    };

    return Error.WrongUsage;
}

/// `name` should be a static variable guaranteed to exist as long as the
/// interpreter exists.
pub fn registerCommand(interp: *Interp, name: []const u8, call_info: NativeCommand.ZigCommand) !void {
    try interp.global_commands.put(Heap.global_gpa, name, .{
        .call_info = .{ .zig = call_info },
    });

    var var_name = try objutil.newString(Heap.local_heap, name);
    defer var_name.decrRefCount();

    const var_name_escaped = try objutil.newList(&.{var_name});
    defer var_name_escaped.decrRefCount();
    var combined = std.ArrayList(u8).empty;
    defer combined.deinit(Heap.global_gpa);
    try combined.appendSlice(Heap.global_gpa, "nativefn ");
    try combined.appendSlice(Heap.global_gpa, try var_name_escaped.getString());
    const var_value = try objutil.newString(Heap.local_heap, combined.items);

    try interp.setVariableToObject(&var_name, var_value.referenceTakeOwnership());

    // FIXME need to handle this if it wraps around.
    interp.global_procedure_epoch += 1;
}

pub fn parseClosure(det: ?*objutil.ErrorDetails, bytes: []const u8) !Heap.Closure {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], "closure ")) {
        if (det) |details| details.* = .{
            .message = try objutil.newStringFmt(Heap.local_heap, "not a valid closure: \"{s}\"", .{bytes}),
        };
        return error.BadClosure;
    }

    const closure_value = try objutil.newString(Heap.local_heap, bytes[8..]);
    defer closure_value.decrRefCount();

    var new_handle: OptionalHandle = .none;
    objutil.shimmerToDict(null, closure_value, &new_handle) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (det) |details| details.* = .{
                .message = try objutil.newStringFmt(Heap.local_heap, "not a valid closure: \"{s}\"", .{bytes}),
            };
            return error.BadClosure;
        },
    };
    assert(new_handle == .none);

    const name = try objutil.dictLookupFollowLinks(closure_value, Heap.local_heap.getInternedString(.name));
    const impl_raw = try objutil.dictLookupFollowLinks(closure_value, Heap.local_heap.getInternedString(.impl));
    const scope = try objutil.dictLookupFollowLinks(closure_value, Heap.local_heap.getInternedString(.scope));

    const args, const body = blk: {
        if (impl_raw.toHandle()) |impl| {
            objutil.shimmerToList(null, impl, &new_handle) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    if (det) |details| details.* = .{
                        .message = try objutil.newStringFmt(Heap.local_heap, "not a valid closure implementation: \"{s}\"", .{bytes}),
                    };
                    return error.BadClosure;
                },
            };
            assert(new_handle == .none);

            if (objutil.listLengthRaw(impl) != 2) {
                if (det) |details| details.* = .{
                    .message = try objutil.newStringFmt(Heap.local_heap, "not a valid closure implementation: \"{s}\"", .{bytes}),
                };
                return error.BadClosure;
            }

            break :blk .{ objutil.listItem(impl, 0), objutil.listItem(impl, 1) };
        } else {
            if (det) |details| details.* = .{
                .message = try objutil.newStringFmt(Heap.local_heap, "closure missing implementation: \"{s}\"", .{bytes}),
            };
            return error.BadClosure;
        }
    };

    // We've got everything into the right data types, so now we can
    // start parsing the args list.
    objutil.shimmerToList(null, args, &new_handle) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (det) |details| details.* = .{
                .message = try objutil.newStringFmt(Heap.local_heap, "closure args is not a valid list: \"{f}\"", .{args}),
            };
            return error.BadClosure;
        },
    };
    assert(new_handle == .none);

    const arg_list_len = objutil.listLengthRaw(args);

    var optional_values: ?Handle = null;
    errdefer if (optional_values) |val| val.decrRefCount();
    var args_parameter_found = false;
    var required_arity: u32 = 0;
    var optional_arity: u32 = 0;

    for (0..arg_list_len) |i| {
        if (args_parameter_found) {
            if (det) |details| details.* = .{
                .message = try objutil.newString(Heap.local_heap, "parameter after 'args' not allowed"),
            };
            return error.BadClosure;
        }

        const arg = objutil.listItem(args, @intCast(i));
        objutil.shimmerToList(null, arg, &new_handle) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                if (det) |details| details.* = .{
                    .message = try objutil.newStringFmt(Heap.local_heap, "too many fields in argument specifier \"{f}\"", .{arg}),
                };
                return error.BadClosure;
            },
        };
        assert(new_handle == .none);
        const arg_len = objutil.listLengthRaw(arg);

        if (arg_len == 0) {
            if (det) |details| details.* = .{
                .message = try objutil.newString(Heap.local_heap, "argument with no name"),
            };
            return error.BadClosure;
        } else if (arg_len > 2) {
            if (det) |details| details.* = .{
                .message = try objutil.newStringFmt(Heap.local_heap, "too many fields in argument specifier \"{f}\"", .{arg}),
            };
            return error.BadClosure;
        } else if (arg_len == 2) {
            // Optional parameter.
            if (optional_values == null) {
                optional_values = try objutil.newList(&.{});
            }

            if (try Heap.stringEquals(objutil.listItem(arg, 0), "args")) {
                if (det) |details| details.* = .{
                    .message = try objutil.newString(Heap.local_heap, "'args' must be a required parameter"),
                };
                return error.BadClosure;
            }

            _ = try objutil.listAppend(null, optional_values.?, &new_handle, objutil.listItem(arg, 1));
            assert(new_handle == .none);

            // Replace {name default} with just the name.
            const new_item = try Heap.local_heap.dupOrReference(objutil.listItem(arg, 0));
            try objutil.listSetObject(null, args, &new_handle, @intCast(i), new_item);
            assert(new_handle == .none);

            optional_arity += 1;
        } else {
            if (optional_values != null) {
                if (det) |details| details.* = .{
                    .message = try objutil.newString(Heap.local_heap, "required parameter after optional parameter not allowed"),
                };
                return error.BadClosure;
            }

            const arg_name = try objutil.listItem(arg, 0).getString();
            if (std.mem.eql(u8, arg_name, "args")) args_parameter_found = true;

            required_arity += 1;
        }
    }

    return .{
        .args = args.borrow(),
        .body = body.borrow(),
        .name = name.borrowOptional(),
        .scope = scope.borrowOptional(),
        .required_arity = required_arity,
        .optional_arity = optional_arity,
        .optional_values = if (optional_values) |val| val.toOptional() else .none,
        .has_args_parameter = args_parameter_found,
        .cache_id = Heap.nextCacheId(),
    };
}

const ClosureAndCacheKey = struct {
    closure: Heap.Closure,
    cache_key: u256,
};
/// Caller is responsible for borrowing the returned closure
/// if they intend to use it beyond temporarily.
pub fn getClosure(interp: *Interp, handle: Handle) !ClosureAndCacheKey {
    if (handle.tag() == .closure) {
        const closure = handle.getClosureExtraData().*;
        return .{ .closure = closure, .cache_key = @as(u256, closure.cache_id) };
    }

    const cache_key = try handle.getHash();

    if (Heap.local_heap.parsed_closures.get(cache_key)) |cached| {
        return .{ .closure = cached.closure, .cache_key = cache_key };
    } else {
        // We need to parse the closure.
        var det: objutil.ErrorDetails = undefined;
        const closure: Heap.Closure = try interp.wrapError(&det, parseClosure(&det, try handle.getString()));
        if (Heap.local_heap.parsed_closures.put(cache_key, .{ .closure = closure })) |old_value| {
            var old = old_value;
            old.closure.deinit();
        }
        const cached = Heap.local_heap.parsed_closures.get(cache_key).?;
        return .{ .closure = cached.closure, .cache_key = cache_key };
    }
}

pub fn callClosure(interp: *Interp, closure: Heap.Closure, cache_key: u256, args: []Handle) !void {
    const arg_count = args.len - 1; // - 1 to skip command name as first argument.

    // Check arity.
    const too_few_arguments: bool = arg_count < closure.required_arity;
    const has_args: bool = closure.has_args_parameter;
    const too_many_arguments: bool = !has_args and arg_count > closure.required_arity + closure.optional_arity;
    if (too_few_arguments or too_many_arguments) {
        // Wrong argument count, error accordingly.
        var det: objutil.ErrorDetails = undefined;
        return interp.wrapError(&det, wrongArgumentCountError(&det, "FIXME"));
    }

    // Check for infinite recursion.
    if (interp.currentCallFrame().level >= interp.max_call_depth) {
        try interp.setResultString("Too many nested calls. Infinite recursion?");
        return error.InfiniteRecursion;
    }

    const parent_idx = interp.currentCallFrameIndex();
    const call_frame_idx = try interp.pushCallFrame(parent_idx, args, closure);
    defer {
        var frame = interp.call_frames.pop().?;
        frame.deinit();
    }

    // Next, we'll populate the call frame.

    // Where we are in the arguments that this was called with.
    var called_idx: usize = 1;
    // Where we are in the signature.
    var signature_idx: u32 = 0;
    const signature_len = objutil.listLengthRaw(closure.args);

    while (signature_idx < signature_len) : (signature_idx += 1) {
        const var_name = objutil.listItem(closure.args, signature_idx);

        // Are we at the last argument? If so, is it `args`?
        if (signature_idx == signature_len - 1 and closure.has_args_parameter) {
            // Assign remaining arguments to `args`.
            const list = try objutil.newList(args[called_idx..]);
            defer list.decrRefCount();
            try interp.setVariableImpl(call_frame_idx, var_name, list.reference());
        } else if (signature_idx > closure.required_arity) {
            // This is an optional argument.

            // Are there any remaining unassigned arguments?
            if (called_idx < args.len) {
                try interp.setVariableImpl(call_frame_idx, var_name, try Heap.local_heap.dupOrReference(args[called_idx]));
                called_idx += 1;
            } else {
                // Else populate it with its default value.
                const default_value = objutil.listItem(closure.optional_values.toHandle().?, signature_idx - closure.required_arity);
                try interp.setVariableImpl(call_frame_idx, var_name, try Heap.local_heap.dupOrReference(default_value));
            }
        } else {
            try interp.setVariableImpl(call_frame_idx, var_name, try Heap.local_heap.dupOrReference(args[called_idx]));
            called_idx += 1;
        }
    }

    try interp.evalObjectInner(closure.body, cache_key);
}

fn callNative(interp: *Interp, command: *NativeCommand, args: []Handle) !void {
    const signature = command.call_info.zig;

    const arg_count = args.len - 1;
    wrong_arg_count: {
        // Check arg count.
        if (arg_count < signature.min_arity) break :wrong_arg_count;
        if (signature.max_arity) |max_arity| {
            if (arg_count > max_arity) break :wrong_arg_count;
        }
        if (signature.multiple_of) |multiple_of| {
            if (@mod(arg_count, multiple_of) != 0) break :wrong_arg_count;
        }

        try command.call_info.zig.to_call(interp, args);
        return;
    }

    var sf = std.heap.stackFallback(64, Heap.global_gpa);
    const scratch = sf.get();
    const command_name = try args[0].getString();
    const command_usage = try command.getUsageInfo(scratch, command_name);
    defer scratch.free(command_usage);
    var det: objutil.ErrorDetails = undefined;
    return interp.wrapError(&det, wrongArgumentCountError(&det, command_usage));
}

fn freeLastResult(interp: *Interp) void {
    interp.result.decrRefCount();
    interp.result = Heap.local_heap.emptyObject();
}

pub fn setResult(interp: *Interp, handle: Handle) void {
    interp.freeLastResult();
    interp.result = handle.borrow();
}

pub fn setResultOwning(interp: *Interp, handle: Handle) void {
    interp.freeLastResult();
    interp.result = handle;
}

pub fn setResultInteger(interp: *Interp, value: i64) !void {
    interp.setResultOwning(try objutil.newInteger(Heap.local_heap, value));
}

pub fn setResultString(interp: *Interp, bytes: []const u8) !void {
    interp.freeLastResult();
    const bytes_handle = try objutil.newString(Heap.local_heap, bytes);

    setResult(interp, bytes_handle);
}

pub fn setResultFormatted(interp: *Interp, comptime fmt: []const u8, args: anytype) !void {
    interp.freeLastResult();
    const fmt_handle = try objutil.newStringFmt(Heap.local_heap, fmt, args);

    setResult(interp, fmt_handle);
}

pub fn setEmptyResult(interp: *Interp) void {
    interp.freeLastResult();
    interp.result = Heap.local_heap.emptyObject();
}

/// Call frame.
const CallFrame = struct {
    /// Parent index.
    parent: ?u32,
    /// Level of the call frame. 0 = global.
    level: u32,
    /// Dictionary containing the frame's variables.
    variables: Handle,
    /// Arguments of this procedure call. Lifetime managed by creator.
    args: []Handle,
    /// Signature of this procedure.
    signature: Heap.Closure,
    /// Call epoch. Used to invalidate previous variable lookups. Can overflow,
    /// but when it overflows it'll scan the heap and reset all cached lookups.
    call_epoch: u32,
    /// Set this during evaluation to trigger a tailcall.
    tailcall: ?Tailcall,

    pub fn deinit(frame: *CallFrame) void {
        // Args are managed externally, so we don't free them.
        frame.variables.decrRefCount();
        frame.signature.deinit();
    }

    /// Returns a dict containing this call frame's variables.
    pub fn captureScope(frame: *CallFrame, interp: *Interp) !Handle {
        const pairs = objutil.dictPairLengthRaw(frame.variables);

        // Make sure there's no upvars.
        for (0..pairs) |i| {
            const value = objutil.dictItem(frame.variables, i * 2 + 1);
            if (value.tag() == .upvar_link) break;
        } else {
            // No upvars found, so we can just borrow the variables.
            return frame.variables.borrow();
        }

        // Found upvars if we made it to this point, so we need
        // to duplicate everything, and follow any upvars.
        const new_dict = try objutil.newDictWithCapacity(pairs * 2);
        for (0..pairs) |i| {
            const key = objutil.dictItem(frame.variables, i * 2);
            const value = objutil.dictItem(frame.variables, i * 2 + 1);

            if (value.tag() == .upvar_link) {
                const upvar_link = value.peek().body.upvar_link;
                if (interp.getVariableInner(null, upvar_link.call_frame, upvar_link.linked_name)) |upvar_val| {
                    try objutil.dictPut(new_dict, key, upvar_val);
                } else |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.VariableNotFound => {
                        // Don't put anything in the dictionary if the upvar
                        // doesn't point at anything.
                    },
                }
            } else {
                try objutil.dictPut(new_dict, key, value);
            }
        }
    }
};

fn currentCallFrameIndex(interp: *Interp) u32 {
    return @intCast(interp.call_frames.items.len - 1);
}

fn currentCallFrame(interp: *Interp) *CallFrame {
    return &interp.call_frames.items[interp.currentCallFrameIndex()];
}

fn nextCallEpoch(interp: *Interp) u32 {
    const epoch = interp.current_call_epoch;
    interp.current_call_epoch = std.math.add(u32, interp.current_call_epoch, 1) catch @panic("TODO handle overflow properly");
    return epoch;
}

/// Evaluation frame.
const EvalFrame = struct {
    /// Pointer to the corrisponding call frame.
    call_frame: u32,
    /// Arguments of this eval frame.
    args: ?[]Handle,
};

fn currentEvalFrameIndex(interp: *Interp) u32 {
    return @intCast(interp.eval_frames.items.len - 1);
}

fn currentEvalFrame(interp: *Interp) *EvalFrame {
    return &interp.eval_frames.items[interp.currentCallFrameIndex()];
}

fn pushCallFrame(interp: *Interp, parent: ?u32, args: []Handle, signature: Heap.Closure) !u32 {
    const vars_handle = try objutil.newDict(Heap.local_heap, &.{});
    errdefer vars_handle.decrRefCount();
    const borrowed_signature = signature.borrow();
    errdefer borrowed_signature.deinit();

    const level = if (parent) |val| interp.call_frames.items[val].level + 1 else 0;
    const new_call_frame_idx = interp.call_frames.items.len;
    try interp.call_frames.append(Heap.global_gpa, .{
        .parent = parent,
        .args = args,
        .call_epoch = interp.nextCallEpoch(),
        .level = level,
        .signature = borrowed_signature,
        // TODO PERF recycle variable hash table if possible.
        .variables = vars_handle,
        .tailcall = null,
    });

    return @intCast(new_call_frame_idx);
}

fn pushEvalFrame(interp: *Interp) !u32 {
    try interp.eval_frames.append(Heap.global_gpa, .{
        .call_frame = interp.currentCallFrameIndex(),
        .args = null,
    });
    return interp.currentEvalFrameIndex();
}

fn popEvalFrame(interp: *Interp) void {
    _ = interp.eval_frames.pop() orelse unreachable;
}

/// Caller should release return value when they're done.
fn substituteOneToken(interp: *Interp, tag: Tokenizer.Token.Tag, value: Handle) !Handle {
    switch (tag) {
        .simple_string => {
            return value.borrow();
        },
        .variable_subst => {
            var det: objutil.ErrorDetails = undefined;
            const var_target: Handle = try interp.wrapError(
                &det,
                interp.getVariableInner(&det, interp.currentCallFrame().level, value),
            );
            return var_target.borrow();
        },
        .dict_sugar => {
            @panic("Dict sugar unimplemented");
        },
        .expression_sugar => {
            @panic("Expression sugar unimplemented");
        },
        .command_subst => {
            const nested_cache_key = @as(u256, interp.currentCallFrame().signature.cache_id) ^ try value.getHash();
            try interp.evalObjectInner(value, nested_cache_key);
            return interp.result.borrow();
        },
        else => {
            std.debug.panic("Tried to substitute token {}", .{tag});
        },
    }
}

fn interpolateTokens(
    interp: *Interp,
    tags: []const Tokenizer.Token.Tag,
    value_list: Handle,
    value_start: u32,
    value_len: u32,
    substitution_only: bool,
) !Handle {
    var sf = std.heap.stackFallback(@sizeOf(Handle) * 8, Heap.global_gpa);
    const tokens_alloc = sf.get();

    const new_values = try tokens_alloc.alloc(Handle, value_len);
    defer tokens_alloc.free(new_values);

    // Substitute all the tokens, placing them in `new_values`.
    for (tags, value_start..(value_start + value_len), 0..) |tag, value_index, i| {
        if (interp.substituteOneToken(tag, objutil.dictItemFollowRefs(value_list, @intCast(value_index)))) |new_value| {
            new_values[i] = new_value;
        } else |err| {
            // Due to the error, we're actually going to return early, after we take care
            // of giving a useful error to the user.
            var new_err = err;

            if (substitution_only) {
                switch (err) {
                    Error.Break => {
                        // Stop here.
                        break;
                    },
                    Error.Continue => {
                        new_values[i] = Heap.local_heap.emptyObject();
                        continue;
                    },
                    else => {},
                }
            } else {
                switch (err) {
                    Error.Break => {
                        try interp.setResultString("invoked \"break\" outside of a loop");
                        new_err = Error.EvalError;
                    },
                    Error.Continue => {
                        try interp.setResultString("invoked \"continue\" outside of a loop");
                        new_err = Error.EvalError;
                    },
                    else => {},
                }
            }

            // Clean everything up before we return.
            for (0..i) |cleanup_idx| {
                new_values[cleanup_idx].decrRefCount();
            }

            return new_err;
        }
    }

    var new_str_len: usize = 0;
    for (new_values) |new_value| {
        new_str_len += (try new_value.getString()).len;
    }

    const new_str = try objutil.newStringToFill(Heap.local_heap, new_str_len);
    errdefer new_str.decrRefCount();
    if (Heap.getStringMut(new_str)) |new_str_mut| {
        var written: usize = 0;
        for (new_values) |new_value| {
            const value_str = try new_value.getString();
            @memcpy(new_str_mut[written..][0..value_str.len], value_str);
            written += value_str.len;
        }
    } else |err| switch (err) {
        error.NotMutable => unreachable,
    }

    return new_str;
}

const CommandOrClosure = union(enum) {
    closure: ClosureAndCacheKey,
    command: *NativeCommand,
};

/// `name` must be from the threadlocal heap.
fn getCommandInner(interp: *Interp, det: ?*objutil.ErrorDetails, call_frame: u32, name: Handle) !CommandOrClosure {
    if (interp.getVariableInner(null, call_frame, name)) |var_val| {
        if (var_val.tag() == .closure) {
            return .{ .closure = try interp.getClosure(var_val) };
        }

        // TODO PERF figure out whether caching nativefn lookup would be beneficial.
        const bytes = try var_val.getString();
        if (bytes.len > 9 and std.mem.eql(u8, bytes[0..9], "nativefn ")) {
            // TODO `bytes[9..]` doesn't account for a nativefn name in braces or with escapes.
            const command = interp.global_commands.getPtr(bytes[9..]) orelse {
                if (det) |details| details.* = .{
                    .message = try objutil.newStringFmt(Heap.local_heap, "invalid native command name \"{s}\"", .{bytes[9..]}),
                };
                return error.CommandNotFound;
            };
            return .{ .command = command };
        } else {
            const closure = try interp.getClosure(var_val);
            return .{ .closure = closure };
        }
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.VariableNotFound => {
            if (det) |details| details.* = .{
                .message = try objutil.newStringFmt(Heap.local_heap, "invalid command name \"{f}\"", .{name}),
            };
            return error.CommandNotFound;
        },
    }
}

pub fn getCommand(
    interp: *Interp,
    det: ?*objutil.ErrorDetails,
    call_frame_idx: u32,
    provided_handle: Handle,
    new_handle: *OptionalHandle,
) !CommandOrClosure {
    errdefer new_handle.swapWithNone();
    try Heap.ensureShimmerableOrDup(provided_handle, new_handle);

    return interp.getCommandInner(det, call_frame_idx, new_handle.orElse(provided_handle));
}

fn invokeCommand(interp: *Interp, call_frame_idx: u32, args: []Handle) !void {
    var new_command: OptionalHandle = .none;
    var det: objutil.ErrorDetails = undefined;
    const command_or_closure = interp.getCommand(&det, call_frame_idx, args[0], &new_command) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EvalError => return error.EvalError,
        error.CommandNotFound => {
            // TODO invoke jim unknown
            std.debug.print("Tried to call command: {s}\n", .{args[0].getString() catch "<oom>"});
            @panic("unimplemented");
        },
    };
    args[0].swapIfNew(new_command);

    if (interp.eval_depth >= interp.max_eval_depth) {
        try interp.setResultString("Infinite eval recursion");
        return error.InfiniteRecursion;
    }

    interp.eval_depth += 1;
    defer interp.eval_depth -= 1;

    // Loop the calling section, as there may be a tailcall.
    var current_args = args;
    var tailcall_info: ?Tailcall = null;
    while (true) {
        interp.currentEvalFrame().args = current_args;
        // TODO implement tracing.

        // Be sure to clear the previous result.
        interp.setEmptyResult();

        const result = blk: {
            switch (command_or_closure) {
                .command => |command| {
                    break :blk interp.callNative(command, current_args);
                },
                .closure => |closure| {
                    break :blk interp.callClosure(closure.closure, closure.cache_key, current_args);
                },
            }
        };

        if (result) {
            if (interp.currentCallFrame().tailcall) |tailcall| {
                // Be sure to free the previous tailcall.
                if (tailcall_info) |prev_tailcall| {
                    for (prev_tailcall.args) |arg| arg.decrRefCount();
                    Heap.global_gpa.free(prev_tailcall.args);
                }

                tailcall_info = tailcall;
                current_args = tailcall.args;
                interp.currentCallFrame().tailcall = null;
            } else {
                tailcall_info = null;
            }
        } else |err| {
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    // TODO set stack trace
                    return err;
                },
            }
        }

        if (tailcall_info == null) break;
    }
}

fn exprResultAsBool(interp: *Interp, result: *ExprResult) !bool {
    switch (result.*) {
        .int => |int| return int != 0,
        .float => |float| {
            try interp.setResultFormatted("expected boolean but got \"{}\"", .{float});
            return error.BadBoolean;
        },
        .owned_handle => |string| {
            string.incrRefCount();
            var new_handle: OptionalHandle = .none;
            const bool_result = objutil.getBoolean(null, string.*, &new_handle) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    try interp.setResultFormatted("expected boolean but got \"{f}\"", .{string.*});
                    return error.BadBoolean;
                },
            };
            string.swapIfNew(new_handle);
            return bool_result;
        },
        .stack_handle => |*string| {
            var new_handle: OptionalHandle = .none;
            const bool_result = objutil.getBoolean(null, string.*, &new_handle) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    try interp.setResultFormatted("expected boolean but got \"{f}\"", .{string});
                    return error.BadBoolean;
                },
            };
            string.swapIfNew(new_handle);
            return bool_result;
        },
    }
}

fn boolToExprResult(value: bool) ExprResult {
    return .{ .int = @intFromBool(value) };
}

fn exprResultAsNumber(interp: *Interp, result: *ExprResult) !ExprResult {
    switch (result.*) {
        .int, .float => return result.*,
        .owned_handle => |string| {
            var new_handle: OptionalHandle = .none;
            const int_result = objutil.integerGet(null, string.*, &new_handle) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    // Try parsing it as a float.
                    return .{ .float = try interp.getFloat(string) };
                },
            };
            string.swapIfNew(new_handle);
            return .{ .int = int_result };
        },
        .stack_handle => |*string| {
            var new_handle: OptionalHandle = .none;
            const int_result = objutil.integerGet(null, string.*, &new_handle) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    // Try parsing it as a float.
                    return .{ .float = try interp.getFloat(string) };
                },
            };
            string.swapIfNew(new_handle);
            return .{ .int = int_result };
        },
    }
}

const division_by_zero_message = "division by zero";
const negative_denom_message = "negative denominator";
fn exprBinaryOperatorInteger(interp: *Interp, oper: expr_parse.Node.Tag, lhs: i64, rhs: i64) !i64 {
    var det: objutil.ErrorDetails = undefined;
    return switch (oper) {
        .mul => blk: {
            break :blk std.math.mul(i64, lhs, rhs) catch {
                const rendered = std.math.mulWide(i64, lhs, rhs);
                return interp.wrapError(&det, objutil.integerOverflowErrorWithWide(&det, rendered));
            };
        },
        .div => std.math.divFloor(i64, lhs, rhs) catch |err| switch (err) {
            error.Overflow => {
                return interp.wrapError(&det, objutil.integerOverflowError(&det, null));
            },
            error.DivisionByZero => {
                try interp.setResultString(division_by_zero_message);
                return error.DivisionByZero;
            },
        },
        .mod => std.math.mod(i64, lhs, rhs) catch |err| switch (err) {
            error.NegativeDenominator => {
                try interp.setResultString(negative_denom_message);
                return error.NegativeDenominator;
            },
            error.DivisionByZero => {
                try interp.setResultString(division_by_zero_message);
                return error.DivisionByZero;
            },
        },
        .sub => std.math.sub(i64, lhs, rhs) catch return interp.wrapError(&det, objutil.integerOverflowError(&det, null)),
        .add => std.math.add(i64, lhs, rhs) catch return interp.wrapError(&det, objutil.integerOverflowError(&det, null)),
        .shiftl => blk: {
            const rhs_constrained: u6 = @intCast(std.math.clamp(rhs, 0, 64));
            break :blk @as(i64, @bitCast(@as(u64, @bitCast(lhs)) << rhs_constrained));
        },
        .shiftr => blk: {
            const rhs_constrained: u6 = @intCast(std.math.clamp(rhs, 0, 64));
            break :blk @as(i64, @bitCast(@as(u64, @bitCast(lhs)) >> rhs_constrained));
        },
        .rotl => blk: {
            const rhs_constrained: u6 = @intCast(std.math.clamp(rhs, 0, 64));
            break :blk @as(i64, @bitCast(std.math.rotl(u64, @bitCast(lhs), rhs_constrained)));
        },
        .rotr => blk: {
            const rhs_constrained: u6 = @intCast(std.math.clamp(rhs, 0, 64));
            break :blk @as(i64, @bitCast(std.math.rotr(u64, @bitCast(lhs), rhs_constrained)));
        },
        .less_than => @intFromBool(lhs < rhs),
        .greater_than => @intFromBool(lhs > rhs),
        .less_or_equal => @intFromBool(lhs <= rhs),
        .greater_or_equal => @intFromBool(lhs >= rhs),
        .equal => @intFromBool(lhs == rhs),
        .not_equal => @intFromBool(lhs != rhs),
        .bit_and => lhs & rhs,
        .bit_xor => lhs ^ rhs,
        .bit_or => lhs | rhs,
        .bool_and => @intFromBool((lhs != 0) and (rhs != 0)),
        .bool_or => @intFromBool((lhs != 0) or (rhs != 0)),
        .pow => std.math.powi(i64, lhs, rhs) catch {
            // Report overflow for both underflow and overflow. Maybe I should report both?
            return interp.wrapError(&det, objutil.integerOverflowError(&det, null));
        },
        else => unreachable,
    };
}

fn exprBinaryOperatorFloat(interp: *Interp, oper: expr_parse.Node.Tag, lhs: f64, rhs: f64) !ExprResult {
    return switch (oper) {
        .mul => .{ .float = lhs * rhs },
        .div => blk: {
            if (rhs == 0.0) {
                try interp.setResultString(division_by_zero_message);
                return error.DivisionByZero;
            } else {
                break :blk .{ .float = lhs / rhs };
            }
        },
        .mod => .{
            .float = std.math.mod(f64, lhs, rhs) catch |err| switch (err) {
                error.DivisionByZero => {
                    try interp.setResultString(division_by_zero_message);
                    return error.DivisionByZero;
                },
                error.NegativeDenominator => {
                    try interp.setResultString(negative_denom_message);
                    return error.NegativeDenominator;
                },
            },
        },
        .sub => .{ .float = lhs - rhs },
        .add => .{ .float = lhs + rhs },
        .shiftl, .shiftr, .rotl, .rotr => {
            try interp.setResultFormatted("cannot bit shift on floats {} and {}", .{ lhs, rhs });
            return error.BadInteger;
        },
        .less_than => boolToExprResult(lhs < rhs),
        .greater_than => boolToExprResult(lhs > rhs),
        .less_or_equal => boolToExprResult(lhs <= rhs),
        .greater_or_equal => boolToExprResult(lhs >= rhs),
        .equal => boolToExprResult(lhs == rhs),
        .not_equal => boolToExprResult(lhs != rhs),
        .bit_and, .bit_xor, .bit_or, .bool_and, .bool_or => {
            try interp.setResultFormatted("cannot do bitwise operations on floats {} and {}", .{ lhs, rhs });
            return error.BadInteger;
        },
        .pow => .{ .float = std.math.pow(f64, lhs, rhs) },
        else => unreachable,
    };
}

const ExprResult = union(enum) {
    int: i64,
    float: f64,
    /// An owned handle is owned by the expression. It can be shimmered, replaced, etc.
    owned_handle: *Handle,
    /// A temp handle is on the stack, so it needs to be referenced every time.
    stack_handle: Handle,

    pub fn release(result: ExprResult) void {
        switch (result) {
            .stack_handle => |handle| handle.decrRefCount(),
            .owned_handle => {
                // Owned by the expr, so no need to decr ref count.
            },
            .int, .float => {},
        }
    }

    pub fn toObject(result: ExprResult) !Handle {
        switch (result) {
            .int => |int| return try objutil.newInteger(Heap.local_heap, int),
            .float => |float| return try objutil.newFloat(Heap.local_heap, float),
            .owned_handle => |handle| return handle.borrow(),
            .stack_handle => |handle| return handle,
        }
    }
};
fn evalExpressionNode(interp: *Interp, nodes: std.MultiArrayList(expr_parse.Node), node_index: expr_parse.Node.Index) !ExprResult {
    const node_tag = nodes.items(.tag)[@intFromEnum(node_index)];
    const node_data: *expr_parse.Node.Data = &nodes.items(.data)[@intFromEnum(node_index)];
    switch (node_tag) {
        .mul,
        .div,
        .mod,
        .sub,
        .add,
        .shiftl,
        .shiftr,
        .rotl,
        .rotr,
        .less_than,
        .greater_than,
        .less_or_equal,
        .greater_or_equal,
        .equal,
        .not_equal,
        .bit_and,
        .bit_xor,
        .bit_or,
        .bool_and,
        .bool_or,
        .pow,
        => {
            const children = node_data.binary;
            var lhs_value = try interp.evalExpressionNode(nodes, children.@"0");
            defer lhs_value.release();
            var rhs_value = try interp.evalExpressionNode(nodes, children.@"1");
            defer rhs_value.release();
            const lhs_tag = std.meta.activeTag(lhs_value);
            const rhs_tag = std.meta.activeTag(rhs_value);

            // Fast case, both integers, or both floats.
            if (lhs_tag == .int and rhs_tag == .int) {
                return .{
                    .int = try interp.exprBinaryOperatorInteger(node_tag, lhs_value.int, rhs_value.int),
                };
            } else if (lhs_tag == .float and rhs_tag == .float) {
                return try interp.exprBinaryOperatorFloat(node_tag, lhs_value.float, rhs_value.float);
            }

            // Slow case: 1. try to get both as integers, 2. try getting both as floats, 3. error.
            const lhs_converted: ExprResult = try interp.exprResultAsNumber(&lhs_value);
            const rhs_converted: ExprResult = try interp.exprResultAsNumber(&rhs_value);

            if (std.meta.activeTag(lhs_converted) == .int and std.meta.activeTag(rhs_converted) == .int) {
                return .{
                    .int = try interp.exprBinaryOperatorInteger(node_tag, lhs_converted.int, rhs_converted.int),
                };
            } else {
                const lhs_as_float: f64 = switch (lhs_converted) {
                    .int => |int| @floatFromInt(int),
                    .float => |float| float,
                    .owned_handle, .stack_handle => unreachable,
                };
                const rhs_as_float: f64 = switch (rhs_converted) {
                    .int => |int| @floatFromInt(int),
                    .float => |float| float,
                    .owned_handle, .stack_handle => unreachable,
                };
                return try interp.exprBinaryOperatorFloat(node_tag, lhs_as_float, rhs_as_float);
            }
        },
        .string_equal,
        .string_not_equal,
        .string_in,
        .string_not_in,
        .string_less_than,
        .string_greater_than,
        .string_less_than_or_equal,
        .string_greater_than_or_equal,
        => {
            const children = node_data.binary;
            const lhs_value = try interp.evalExpressionNode(nodes, children.@"0");
            const rhs_value = try interp.evalExpressionNode(nodes, children.@"1");
            defer lhs_value.release();
            defer rhs_value.release();

            var lhs_buffer: [50]u8 = @splat(0);
            var lhs_alloc = std.heap.FixedBufferAllocator.init(lhs_buffer[0..]);
            const lhs_string = switch (lhs_value) {
                .float => |val| std.fmt.allocPrint(lhs_alloc.allocator(), "{}", .{val}) catch unreachable,
                .int => |val| std.fmt.allocPrint(lhs_alloc.allocator(), "{}", .{val}) catch unreachable,
                .owned_handle => |val| (try val.*.getString())[0..],
                .stack_handle => |val| (try val.getString())[0..],
            };
            var rhs_buffer: [50]u8 = @splat(0);
            var rhs_alloc = std.heap.FixedBufferAllocator.init(rhs_buffer[0..]);
            const rhs_string = switch (lhs_value) {
                .float => |val| std.fmt.allocPrint(rhs_alloc.allocator(), "{}", .{val}) catch unreachable,
                .int => |val| std.fmt.allocPrint(rhs_alloc.allocator(), "{}", .{val}) catch unreachable,
                .owned_handle => |val| (try val.*.getString())[0..],
                .stack_handle => |val| (try val.getString())[0..],
            };

            const result = switch (node_tag) {
                .string_equal => std.mem.eql(u8, lhs_string, rhs_string),
                .string_not_equal => !std.mem.eql(u8, lhs_string, rhs_string),
                .string_in => std.mem.indexOf(u8, rhs_string, lhs_string) != null,
                .string_not_in => std.mem.indexOf(u8, rhs_string, lhs_string) == null,
                .string_less_than => std.mem.order(u8, rhs_string, lhs_string).compare(.lt),
                .string_greater_than => std.mem.order(u8, rhs_string, lhs_string).compare(.gt),
                .string_less_than_or_equal => std.mem.order(u8, rhs_string, lhs_string).compare(.lte),
                .string_greater_than_or_equal => std.mem.order(u8, rhs_string, lhs_string).compare(.gte),
                inline else => unreachable,
            };

            return if (result) .{ .int = 1 } else .{ .int = 0 };
        },
        .ternary_conditional => {
            const children = node_data.ternary;
            var condition = try interp.evalExpressionNode(nodes, children.@"0");

            if (try exprResultAsBool(interp, &condition)) {
                return interp.evalExpressionNode(nodes, children.@"1");
            } else {
                return interp.evalExpressionNode(nodes, children.@"2");
            }
        },
        .string => {
            const obj = &node_data.object;
            obj.incrRefCount();
            return .{ .owned_handle = obj };
        },
        .integer => return .{ .int = node_data.integer },
        .float => return .{ .float = node_data.float },
        .command_subst => {
            const nested_cache_key = @as(u256, interp.currentCallFrame().signature.cache_id) ^ try node_data.object.getHash();
            const result = interp.evalObjectInner(node_data.object, nested_cache_key);

            if (result) {
                return .{ .stack_handle = interp.result.borrow() };
            } else |err| {
                return err;
            }
        },
        .variable_subst => {
            // This should not change, since it should be a local heap object.
            var det: objutil.ErrorDetails = undefined;
            const var_value = try interp.wrapError(&det, interp.getVariableInner(&det, interp.currentCallFrameIndex(), node_data.object));

            return .{ .stack_handle = var_value.borrow() };
        },
        .dict_sugar => @panic("dict sugar not implemented"),
        .value_false => return .{ .int = 0 },
        .value_true => return .{ .int = 1 },
        .bool_not => {
            var result = try interp.evalExpressionNode(nodes, node_data.unary);
            defer result.release();
            const result_bool = try interp.exprResultAsBool(&result);
            return .{ .int = if (result_bool) 0 else 1 };
        },
        .bit_not => {
            var result = try interp.evalExpressionNode(nodes, node_data.unary);
            const value = switch (result) {
                .int => |val| val,
                .float => |val| {
                    try interp.setResultFormatted("cannot bit invert on float {}", .{val});
                    return error.BadInteger;
                },
                .owned_handle => |val| blk: {
                    break :blk try interp.getInteger(val);
                },
                .stack_handle => |*val| blk: {
                    break :blk try interp.getInteger(val);
                },
            };

            return .{ .int = ~value };
        },
        .identity => {
            var result = try interp.evalExpressionNode(nodes, node_data.unary);
            defer result.release();
            return try interp.exprResultAsNumber(&result);
        },
        .negation => {
            var result = try interp.evalExpressionNode(nodes, node_data.unary);
            defer result.release();
            const value = try interp.exprResultAsNumber(&result);
            switch (value) {
                .int => |int| return .{ .int = -int },
                .float => |float| return .{ .float = -float },
                .owned_handle, .stack_handle => unreachable,
            }
        },
        .to_int, .to_wide => {
            var result = try interp.evalExpressionNode(nodes, node_data.unary);
            defer result.release();
            const value = try interp.exprResultAsNumber(&result);
            switch (value) {
                .int => |int| return .{ .int = int },
                .float => |float| {
                    bad_int: {
                        if (float > @as(f64, @floatFromInt(std.math.maxInt(i64)))) break :bad_int;
                        if (float < @as(f64, @floatFromInt(std.math.minInt(i64)))) break :bad_int;
                        if (std.math.isNan(float)) break :bad_int;
                        return .{ .int = @intFromFloat(float) };
                    }
                    try interp.setResultFormatted("could not convert float \"{}\" to integer", .{float});
                    return error.BadInteger;
                },
                .owned_handle, .stack_handle => unreachable,
            }
        },
        .abs => {
            var result = try interp.evalExpressionNode(nodes, node_data.unary);
            defer result.release();
            const value = try interp.exprResultAsNumber(&result);
            switch (value) {
                .int => |int| {
                    if (@abs(int) > std.math.maxInt(i64)) {
                        var det: objutil.ErrorDetails = undefined;
                        return interp.wrapError(&det, objutil.integerOverflowErrorWithWide(&det, @abs(int)));
                    } else {
                        return .{ .int = @intCast(@abs(int)) };
                    }
                },
                .float => |float| return .{ .float = @abs(float) },
                .owned_handle, .stack_handle => unreachable,
            }
        },
        .to_double => {
            var result = try interp.evalExpressionNode(nodes, node_data.unary);
            defer result.release();
            const value = try interp.exprResultAsNumber(&result);
            switch (value) {
                .int => |int| return .{ .float = @floatFromInt(int) },
                .float => return value,
                .owned_handle, .stack_handle => unreachable,
            }
        },
        .round => {
            var result = try interp.evalExpressionNode(nodes, node_data.unary);
            defer result.release();
            const value = try interp.exprResultAsNumber(&result);
            switch (value) {
                .float => |float| return .{ .float = @round(float) },
                .int => return value,
                .owned_handle, .stack_handle => unreachable,
            }
        },
        .rand => {
            return .{ .float = interp.nextRandomFloat() };
        },
        .srand => {
            var result = try interp.evalExpressionNode(nodes, node_data.unary);
            defer result.release();
            const value = switch (result) {
                .int => |val| val,
                .float => |val| {
                    try interp.setResultFormatted("cannot seed random with {}", .{val});
                    return error.BadInteger;
                },
                .owned_handle => |val| try interp.getInteger(val),
                .stack_handle => |*val| try interp.getInteger(val),
            };

            interp.prng.seed(@bitCast(value));

            return .{ .float = interp.nextRandomFloat() };
        },
        .sin,
        .cos,
        .tan,
        .asin,
        .acos,
        .atan,
        .sinh,
        .cosh,
        .tanh,
        .ceil,
        .floor,
        .exp,
        .log,
        .log10,
        .sqrt,
        => {
            var result = try interp.evalExpressionNode(nodes, node_data.unary);
            defer result.release();
            const value = try interp.exprResultAsNumber(&result);
            const as_float: f64 = switch (value) {
                .int => |int| @floatFromInt(int),
                .float => |float| float,
                .owned_handle, .stack_handle => unreachable,
            };

            const computed = switch (node_tag) {
                .sin => @sin(as_float),
                .cos => @cos(as_float),
                .tan => @tan(as_float),
                .asin => std.math.asin(as_float),
                .acos => std.math.acos(as_float),
                .atan => std.math.atan(as_float),
                .sinh => std.math.sinh(as_float),
                .cosh => std.math.cosh(as_float),
                .tanh => std.math.tanh(as_float),
                .ceil => @ceil(as_float),
                .floor => @floor(as_float),
                .exp => @exp(as_float),
                .log => @log(as_float),
                .log10 => @log10(as_float),
                .sqrt => @sqrt(as_float),
                inline else => unreachable,
            };

            return .{ .float = computed };
        },
        .atan2, .fmod, .hypot => {
            var lhs_result = try interp.evalExpressionNode(nodes, node_data.binary.@"0");
            defer lhs_result.release();
            var rhs_result = try interp.evalExpressionNode(nodes, node_data.binary.@"0");
            defer rhs_result.release();
            const lhs_number = try interp.exprResultAsNumber(&lhs_result);
            const rhs_number = try interp.exprResultAsNumber(&rhs_result);
            const lhs: f64 = switch (lhs_number) {
                .int => |int| @floatFromInt(int),
                .float => |float| float,
                .owned_handle, .stack_handle => unreachable,
            };
            const rhs: f64 = switch (rhs_number) {
                .int => |int| @floatFromInt(int),
                .float => |float| float,
                .owned_handle, .stack_handle => unreachable,
            };

            const computed = switch (node_tag) {
                .atan2 => std.math.atan2(lhs, rhs),
                .fmod => @mod(lhs, rhs),
                .hypot => @sqrt(lhs * lhs + rhs + rhs),
                inline else => unreachable,
            };
            return .{ .float = computed };
        },
        .none => unreachable,
    }
}

pub fn evalExpression(interp: *Interp, handle: Handle, new_handle: *OptionalHandle) !ExprResult {
    errdefer new_handle.swapWithNone();

    // Combine the call frame's cache ID with the expression's content
    // hash, so identical expressions at different call sites get their
    // own cached variable lookups.
    var det: objutil.ErrorDetails = undefined;
    const cache_key = @as(u256, interp.currentCallFrame().signature.cache_id) ^ try handle.getHash();
    const expr = try interp.wrapError(&det, objutil.getExpression(&det, handle, cache_key));

    return evalExpressionNode(interp, expr.nodes, expr.root_node) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.EvalError,
    };
}

pub fn evalExpressionInPlace(interp: *Interp, handle: *Handle) !ExprResult {
    var new_handle: OptionalHandle = .none;
    const res = try evalExpression(interp, handle.*, &new_handle);
    handle.swapIfNew(new_handle);
    return res;
}

pub fn getBoolFromExpression(interp: *Interp, handle: *Handle) !bool {
    var expr_result = try interp.evalExpressionInPlace(handle);
    defer expr_result.release();
    const value = interp.exprResultAsBool(&expr_result) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => error.EvalError,
    };
    return value;
}

test "eval expression" {
    defer Heap.testFinish();
    const heap = try Heap.testStart(testing.allocator);
    var interp = try Interp.init();
    defer interp.deinit();

    var expr = try objutil.newString(heap, "5 + 10");
    defer expr.decrRefCount();
    var new_expr: OptionalHandle = .none;
    const result = try interp.evalExpression(expr, &new_expr);
    expr.swapIfNew(new_expr);
    try testing.expectEqual(ExprResult{ .int = 15 }, result);
}

pub fn evalObjectInner(interp: *Interp, script: Handle, cache_key: u256) Error!void {
    // Try to get the script, parsing if necessary.
    var det: objutil.ErrorDetails = undefined;
    const parsed = try interp.wrapError(&det, objutil.getScript(&det, script, cache_key));
    // Don't evaluate empty scripts.
    if (parsed.tags.items.len <= 1) return;

    // Reset the interpreter result. This is useful to return the empty result in the case of empty program.
    interp.setEmptyResult();

    // TODO need to set stack frame on error, something like:
    // errdefer interp.setErrorStack()

    // TODO implement JIM_OPTIMIZATION speedups

    // FIXME do I need `script->inUse++;`?

    _ = try interp.pushEvalFrame();
    defer interp.popEvalFrame();

    // Used for allocating the arguments passed into a command call.
    var sf = std.heap.stackFallback(@sizeOf(Handle) * 8, Heap.global_gpa);
    var args_alloc = sf.get();

    // Execute every command sequentially until the end of the script or an error occurs.
    var command_token_i: u32 = 0;

    const tags = parsed.tags.items;
    const values = objutil.listItems(parsed.values);
    // Loop through the script's commands.
    while (command_token_i < tags.len) {
        // First token of the line is always .script_command.
        const command_info = values[command_token_i].body.parsed_script_command;
        command_token_i += 1; // Skip .script_command.

        // This is not always the same as which word token we're on, as argument expansion
        // may write multiple arguments from one word.
        var args_written: usize = 0;
        var args = try args_alloc.alloc(Handle, command_info.arg_count);
        defer args_alloc.free(args);
        defer for (args[0..args_written]) |arg| arg.decrRefCount();

        // Populate the arguments by looping through each word of the command and
        // substituting.
        var word_token_i: u32 = command_token_i;
        while (word_token_i < command_token_i + command_info.arg_count) : (word_token_i += 1) {
            var word_parts: u32 = 1;
            const argument_expansion = tags[word_token_i] == .argument_expansion;
            if (tags[word_token_i] == .start_of_word or argument_expansion) {
                word_parts = @intCast(values[word_token_i].body.integer);
                word_token_i += 1;
            }

            var resultant_word: Handle = blk: {
                if (word_parts == 1) {
                    // Simple one-to-one substitution, so an easy case.
                    break :blk try interp.substituteOneToken(tags[word_token_i], objutil.listItem(parsed.values, word_token_i));
                } else {
                    // Helper function that'll interpolate all the word parts and merge them into a string.
                    break :blk try interp.interpolateTokens(tags[word_token_i..][0..word_parts], parsed.values, word_token_i, word_parts, false);
                }
            };

            if (argument_expansion) {
                // Argument expansion, so we'll need to shimmer the result to a list.
                det = undefined;
                var new_list: OptionalHandle = .none;
                const len = try wrapError(interp, &det, objutil.listLength(&det, resultant_word, &new_list));
                resultant_word.swapIfNew(new_list);
                // Free the list backing without running destructors, since we're going to steal the items
                // directly from the list.
                defer Heap.freeObjectBacking(resultant_word);

                if (len > 1) {
                    // Expanded into multiple tokens, so we'll need to resize args.
                    args = try args_alloc.realloc(args, args.len - 1 + len);
                }

                assert(resultant_word.canMutate());
                for (0..len) |list_idx| {
                    // Steal each object from the list.
                    args[args_written] = try Heap.steal(objutil.listItem(resultant_word, @intCast(list_idx)));
                    args_written += 1;
                }
            } else {
                args[args_written] = resultant_word;
                args_written += 1;
            }
        }

        command_token_i = word_token_i;

        // Now that we've populated the arguments for this command, we'll go ahead and run it.
        std.debug.print("Calling command: ", .{});
        for (args) |arg| std.debug.print("{{{s}}} ", .{try arg.getString()});
        std.debug.print("\n", .{});

        const cmd_result = interp.invokeCommand(interp.currentCallFrameIndex(), args);
        // TODO actually check for signals.
        if (false) {
            return error.Signal;
        } else {
            if (cmd_result) |_| {
                // Keep going through the commands.
            } else |err| switch (err) {
                error.PropagateResult => {
                    interp.return_propagate.left_to_go -= 1;
                    if (interp.return_propagate.left_to_go == 0) {
                        if (interp.return_propagate.return_at_end) |return_at_end| {
                            return return_at_end;
                        } else {
                            // Equivalent of TCL_OK.
                            return;
                        }
                    } else {
                        return error.PropagateResult;
                    }
                },
                else => return err,
            }
        }
    }

    return;
}

pub fn evalObject(interp: *Interp, script: Handle) Error!void {
    const cache_key = @as(u256, interp.currentCallFrame().signature.cache_id) ^ try script.getHash();
    return evalObjectInner(interp, script, cache_key);
}

pub fn init() !Interp {
    var new_interp: Interp = .{
        .result = Heap.local_heap.emptyObject(),
        .eval_frames = .empty,
        .call_frames = .empty,
        .current_call_epoch = 0,
        .global_procedure_epoch = 0,
        .global_commands = .empty,
        .eval_depth = 0,
        .max_eval_depth = 1000,
        .max_call_depth = 1000,
        .stack_trace = null,
        // TODO: init per interpreter
        .prng = .init(0),
    };

    _ = try new_interp.pushCallFrame(null, &.{}, .{
        .args = Heap.local_heap.emptyObject(),
        .body = Heap.local_heap.emptyObject(),
        .name = .none,
        .scope = .none,
        .required_arity = 0,
        .optional_arity = 0,
        .optional_values = .none,
        .has_args_parameter = false,
        .cache_id = Heap.nextCacheId(),
    });

    return new_interp;
}

pub fn deinit(interp: *Interp) void {
    interp.result.decrRefCount();
    interp.global_commands.deinit(Heap.global_gpa);

    // Deinit all frames.
    for (interp.call_frames.items) |*frame| {
        frame.deinit();
    }
    interp.call_frames.deinit(Heap.global_gpa);

    interp.eval_frames.deinit(Heap.global_gpa);
}

// Export various utility functions with a nicer interface.
pub fn integerOverflowError(interp: *Interp, value: ?[]const u8) error{ OutOfMemory, EvalError } {
    var det: objutil.ErrorDetails = undefined;
    interp.wrapError(&det, objutil.integerOverflowError(&det, value)) catch return error.EvalError;
}

pub fn wrapShimmerFn(
    interp: *Interp,
    handle: *Handle,
    to_call: fn (?*objutil.ErrorDetails, Handle, *OptionalHandle) objutil.Error!void,
) !void {
    var det: objutil.ErrorDetails = undefined;
    var new_handle: OptionalHandle = .none;
    try wrapError(interp, &det, to_call(&det, handle.*, &new_handle));
    handle.swapIfNew(new_handle);
}

/// Replaces `handle` in-place. Use `objutil.shimmerToInteger` if you need finer-grained
/// control.
pub fn getInteger(interp: *Interp, handle: *Handle) !i64 {
    try interp.wrapShimmerFn(handle, objutil.shimmerToInteger);
    return handle.peek().body.integer;
}

pub fn getIntegerNoShimmer(interp: *Interp, handle: Handle) Interp.Error!i64 {
    var det: objutil.ErrorDetails = undefined;
    return interp.wrapError(&det, objutil.integerGetNoShimmer(&det, handle));
}

/// Replaces `handle` in-place. Use `objutil.shimmerToFloat` if you need finer-grained
/// control.
pub fn getFloat(interp: *Interp, handle: *Handle) !f64 {
    try interp.wrapShimmerFn(handle, objutil.shimmerToFloat);
    return handle.peek().body.float;
}

pub fn getFloatNoShimmer(interp: *Interp, handle: Handle) Interp.Error!f64 {
    var det: objutil.ErrorDetails = undefined;
    return interp.wrapError(&det, objutil.floatGetNoShimmer(&det, handle));
}

pub fn getListLength(interp: *Interp, handle: *Handle) !u32 {
    var new_handle: OptionalHandle = .none;
    var det: objutil.ErrorDetails = undefined;
    try interp.wrapError(&det, objutil.shimmerToList(&det, handle.*, &new_handle));
    handle.swapIfNew(new_handle);
    return handle.peek().body.list.len;
}

pub fn listAppend(interp: *Interp, list: *Handle, item: Handle) !Handle {
    var det: objutil.ErrorDetails = undefined;
    var new_list: OptionalHandle = .none;

    try interp.wrapError(&det, objutil.shimmerToList(&det, list.*, &new_list));
    const result = try interp.wrapError(&det, objutil.listAppend(&det, new_list.orElse(list.*), &new_list, item));
    list.swapIfNew(new_list);

    return result;
}

pub fn ensureShimmerable(interp: *Interp, handle: *Handle) !void {
    _ = interp;

    var new_handle: OptionalHandle = .none;
    try Heap.ensureShimmerableOrDup(handle.*, &new_handle);
    handle.swapIfNew(new_handle);
}

pub fn setVariableToObject(interp: *Interp, name: *Handle, obj: Heap.Object) !void {
    var new_name: OptionalHandle = .none;
    try Heap.ensureShimmerableOrDup(name.*, &new_name);
    name.swapIfNew(new_name);
    try interp.setVariableImpl(interp.currentCallFrameIndex(), name.*, obj);
}

pub fn setVariableTo(interp: *Interp, name: *Handle, handle: Handle) !void {
    var new_name: OptionalHandle = .none;
    try Heap.ensureShimmerableOrDup(name.*, &new_name);
    name.swapIfNew(new_name);

    const handle_to_obj = try Heap.local_heap.dupOrReference(handle);
    try interp.setVariableImpl(interp.currentCallFrameIndex(), name.*, handle_to_obj);
}

pub fn getVariable(interp: *Interp, provided_name: *Handle) !OptionalHandle {
    var new_name: OptionalHandle = .none;
    try Heap.ensureShimmerableOrDup(provided_name.*, &new_name);
    provided_name.swapIfNew(new_name);
    const value = interp.getVariableInner(null, interp.currentCallFrameIndex(), provided_name.*) catch |err| switch (err) {
        error.VariableNotFound => return .none,
        else => return err,
    };
    return value.toOptional();
}

pub fn getVariableOrError(interp: *Interp, name: *Handle) !Handle {
    try interp.ensureShimmerable(name);
    var det: objutil.ErrorDetails = undefined;
    const var_value = try interp.wrapError(&det, interp.getVariableInner(&det, interp.currentCallFrameIndex(), name.*));
    return var_value;
}

pub fn getDictValue(interp: *Interp, dict: Handle, key: Handle) Interp.Error!struct {
    new_dict: ?Handle,
    value: ?Handle,
} {
    var det: objutil.ErrorDetails = undefined;
    const new_dict = try interp.wrapError(&det, objutil.shimmerToDict(&det, dict));
    return .{ .new_dict = new_dict, .value = objutil.dictLookupFollowRefs(new_dict orelse dict, key) };
}

pub fn getDictValueOrError(interp: *Interp, dict: Handle, key: Handle) Interp.Error!struct {
    new_dict: ?Handle,
    value: Handle,
} {
    const result = try interp.getDictValue(dict, key);
    if (result.value) |val| {
        return .{ .new_dict = result.new_dict, .value = val };
    } else {
        try interp.setResultFormatted("could not find value for key \"{f}\"", .{key});
        return error.EvalError;
    }
}

pub fn getDictValueRecursively(interp: *Interp, dict: *Handle, keys: []const Handle) Interp.Error!OptionalHandle {
    var det: objutil.ErrorDetails = undefined;
    const result = try interp.wrapError(&det, objutil.dictLookupRecursively(&det, dict.*, keys));
    dict.swapIfNew(result.new_dict);
    return result.value;
}

pub fn getDictValueRecursivelyOrError(interp: *Interp, dict: *Handle, keys: []const Handle) Interp.Error!Handle {
    const result = try interp.getDictValueRecursively(dict, keys);
    if (result.toHandle()) |val| return val;

    // Else, create a useful error message.
    if (keys.len == 1) {
        try interp.setResultFormatted("could not find value for key \"{f}\"", .{keys[0]});
    } else {
        var keys_list = try objutil.newList(keys);
        defer keys_list.decrRefCount();
        try interp.setResultFormatted("could not find value for keys \"{f}\"", .{keys_list});
    }

    return error.EvalError;
}

pub fn putDictValue(interp: *Interp, dict: Handle, new_dict: *OptionalHandle, key: Handle, value: Handle) Interp.Error!Handle {
    errdefer new_dict.swapWithNone();

    var det: objutil.ErrorDetails = undefined;
    try interp.wrapError(&det, objutil.shimmerToDict(&det, dict));

    const put_result = try objutil.dictPut(new_dict.orElse(dict), key, value);
    new_dict.swapRefIfNew(put_result.new_dict);

    return put_result.new_value;
}

pub fn putDictValueRecursively(interp: *Interp, dict: *Handle, keys: []const Handle, value: Handle) Interp.Error!Handle {
    var det: objutil.ErrorDetails = undefined;
    const put_result = try interp.wrapError(
        &det,
        objutil.dictPutRecursively(&det, dict.*, keys, try Heap.local_heap.dupOrReference(value)),
    );
    dict.swapIfNew(put_result.new_dict);
    return put_result.new_value;
}

/// Returns whether the value was removed.
pub fn removeDictValue(interp: *Interp, dict: Handle, new_dict: *OptionalHandle, key: Handle) !bool {
    errdefer new_dict.swapWithNone();

    var det: objutil.ErrorDetails = undefined;
    try interp.wrapError(&det, objutil.shimmerToDict(&det, dict, new_dict));

    const remove_result = try objutil.dictRemove(new_dict orelse dict, key);
    Handle.swapRefIfNew(&new_dict, remove_result.new_dict);
    return .{ .new_dict = new_dict, .did_remove = remove_result.did_remove };
}

pub fn removeDictValueRecursively(interp: *Interp, dict: *Handle, keys: []const Handle) Interp.Error!bool {
    var det: objutil.ErrorDetails = undefined;
    const put_result = try interp.wrapError(&det, objutil.dictRemoveRecursively(&det, dict.*, keys));
    dict.swapIfNew(put_result.new_dict);
    return put_result.did_remove;
}

test "recursive dict keys" {
    defer Heap.testFinish();
    const heap = try Heap.testStart(testing.allocator);
    var interp = try Interp.init();
    defer interp.deinit();

    var dict = try objutil.newDict(heap, &.{});
    defer dict.decrRefCount();
    var key_foo = try objutil.newString(heap, "foo");
    defer key_foo.decrRefCount();
    var key_bar = try objutil.newString(heap, "bar");
    defer key_bar.decrRefCount();
    var key_baz = try objutil.newString(heap, "baz");
    defer key_baz.decrRefCount();
    const value_qux = try objutil.newString(heap, "qux");
    defer value_qux.decrRefCount();

    _ = try interp.putDictValueRecursively(&dict, &[_]Handle{ key_foo, key_bar, key_baz }, value_qux);
    try testing.expectEqualStrings("foo {bar {baz qux}}", try dict.getString());

    // Try taking ownership of one of the intermediate dictionaries.
    var to_take_result = try interp.getDictValueRecursively(&dict, &.{ key_foo, key_bar });
    const to_take = to_take_result.toHandle().?.borrow();
    defer to_take.decrRefCount();

    // See if setting still works correctly.
    _ = try interp.putDictValueRecursively(&dict, &.{ key_foo, key_bar, key_baz }, value_qux);
    try testing.expectEqual(1, to_take.debugRefCount());

    // Let's try some very cursed aliasing.
    _ = try interp.putDictValueRecursively(&dict, &.{ key_foo, key_bar }, objutil.dictItem(dict, 0));
    try testing.expectEqualStrings("foo {bar foo}", try dict.getString());

    const value_result = try interp.getDictValueRecursively(&dict, &.{ key_foo, key_bar });
    try testing.expectEqualStrings("foo", try value_result.toHandle().?.getString());
}

fn testRecursiveDictRemoval(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    const heap = try Heap.testStart(ta);
    var interp = try Interp.init();
    defer interp.deinit();

    var dict = try objutil.newDict(heap, &.{});
    defer dict.decrRefCount();
    var key_foo = try objutil.newString(heap, "foo");
    defer key_foo.decrRefCount();
    var key_bar = try objutil.newString(heap, "bar");
    defer key_bar.decrRefCount();
    var key_baz = try objutil.newString(heap, "baz");
    defer key_baz.decrRefCount();
    const value_qux = try objutil.newString(heap, "qux");
    defer value_qux.decrRefCount();

    // Test 1: Remove a deeply nested value (3 levels).
    _ = try interp.putDictValueRecursively(&dict, &.{ key_foo, key_bar, key_baz }, value_qux);

    try testing.expectEqualStrings("foo {bar {baz qux}}", try dict.getString());
    var did_remove = try interp.removeDictValueRecursively(&dict, &.{ key_foo, key_bar, key_baz });
    try testing.expect(did_remove);
    try testing.expectEqualStrings("foo {bar {}}", try dict.getString());

    // Test 2: Try to remove the same key again (should return false).
    did_remove = try interp.removeDictValueRecursively(&dict, &.{ key_foo, key_bar, key_baz });
    try testing.expect(!did_remove);
    try testing.expectEqualStrings("foo {bar {}}", try dict.getString());

    // Test 3: Remove a non-existent key from an existing intermediate dict.
    did_remove = try interp.removeDictValueRecursively(&dict, &.{ key_foo, key_bar, key_foo });
    try testing.expect(!did_remove);
    try testing.expectEqualStrings("foo {bar {}}", try dict.getString());

    // Test 4: Remove from a non-existent intermediate dict.
    try memutil.expectErrorOrOom(
        error.EvalError,
        interp.removeDictValueRecursively(&dict, &.{ key_bar, key_baz, key_foo }),
    );
    try testing.expectEqualStrings(
        \\key "bar" not known in dictionary "foo {bar {}}"
    , try interp.result.getString());
    try testing.expectEqualStrings("foo {bar {}}", try dict.getString());

    // Test 5: Single-level removal (base case).
    did_remove = try interp.removeDictValueRecursively(&dict, &.{key_foo});
    try testing.expect(did_remove);
    try testing.expectEqualStrings("", try dict.getString());

    // Test 6: Two-level removal.
    _ = try interp.putDictValueRecursively(&dict, &.{ key_foo, key_bar }, value_qux);
    try testing.expectEqualStrings("foo {bar qux}", try dict.getString());
    did_remove = try interp.removeDictValueRecursively(&dict, &.{ key_foo, key_bar });
    try testing.expect(did_remove);
    try testing.expectEqualStrings("foo {}", try dict.getString());

    // Test 7: Removal when intermediate dict is shared (copy-on-write).
    var interm_test_dict = try objutil.newDict(heap, &.{});
    defer interm_test_dict.decrRefCount();
    _ = try interp.putDictValueRecursively(&interm_test_dict, &.{ key_foo, key_bar, key_baz }, value_qux);
    _ = try interp.putDictValueRecursively(&interm_test_dict, &.{ key_foo, key_bar, key_foo }, value_qux);

    // Borrow the intermediate dict.
    var interm_result = try interp.getDictValueRecursively(&interm_test_dict, &.{ key_foo, key_bar });
    const intermediate = interm_result.toHandle().?.borrow();
    defer intermediate.decrRefCount();

    const initial_refcount = intermediate.debugRefCount();
    try testing.expectEqualStrings("baz qux foo qux", try intermediate.getString());

    // Remove from the nested dict while it's owned elsewhere.
    did_remove = try interp.removeDictValueRecursively(&interm_test_dict, &.{ key_foo, key_bar, key_baz });
    try testing.expect(did_remove);

    // The intermediate dict we own should be unchanged (copy-on-write).
    try testing.expectEqualStrings("baz qux foo qux", try intermediate.getString());
    // But the main dict should have a new copy without 'baz'.
    const foo_bar_result = try interp.getDictValueRecursively(&interm_test_dict, &.{ key_foo, key_bar });
    try testing.expectEqualStrings("foo qux", try foo_bar_result.toHandle().?.getString());
    // Reference count should drop by 1 since the parent no longer references it.
    try testing.expectEqual(initial_refcount - 1, intermediate.debugRefCount());

    // Test 8: Remove multiple items from a nested dict.
    dict.swap(try objutil.newDict(heap, &.{}));
    _ = try interp.putDictValueRecursively(&dict, &.{ key_foo, key_bar }, value_qux);
    _ = try interp.putDictValueRecursively(&dict, &.{ key_foo, key_baz }, value_qux);
    try testing.expectEqualStrings("foo {bar qux baz qux}", try dict.getString());
    did_remove = try interp.removeDictValueRecursively(&dict, &.{ key_foo, key_bar });
    try testing.expect(did_remove);
    try testing.expectEqualStrings("foo {baz qux}", try dict.getString());
    did_remove = try interp.removeDictValueRecursively(&dict, &.{ key_foo, key_baz });
    try testing.expect(did_remove);
    try testing.expectEqualStrings("foo {}", try dict.getString());
}

test "recursive dict removal" {
    try testing.checkAllAllocationFailures(testing.allocator, testRecursiveDictRemoval, .{});
}

pub fn nextRandomFloat(interp: *Interp) f64 {
    // https://stackoverflow.com/questions/46901022/how-to-convert-a-uint64-t-to-a-double-float-between-0-and-1-with-maximum-accurac
    const two63: u64 = 0x8000000000000000;
    const two64f = @as(f64, @bitCast(two63)) * 2.0;
    const as_float = @as(f64, @bitCast(interp.prng.next())) / two64f;
    return as_float;
}

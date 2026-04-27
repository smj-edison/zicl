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
/// Depth of [unknown] calls. Used to catch infinite recursion.
unknown_depth: usize,
/// String containing `unknown`. Used to cached unknown lookup.
unknown_str: Handle,
/// If this is greater than 0, it means we're catching and handling
/// signals. Otherwise signals are ignored. This gets incremented
/// when running [catch -signal].
signal_depth: usize,
/// Bit mask of caught signals, or 0 if none.
signal: u64,

/// Used to propagate `error.Continue` or `error.Break` up multiple
/// loop levels. This is a separate counter from return_propagate, since
/// this counter only goes down when going through a loop command, not
/// just any ol' command.
loop_propagate: u32 = 0,
/// Used for propagating a return code up multiple eval levels.
return_propagate: struct {
    left_to_go: u32 = 0,
    return_at_end: ?EvalError = null,
} = .{},
/// Stack trace captured at the error site.
stack_trace: OptionalHandle,
/// Error code set by `[error]` or `[return -errorcode ...]`. Not a Tcl-visible
/// global, it lives here only to cross the Zig call boundary to `[catch]`/`[try]`.
/// Note that this is not the same as a return code. For example, a return code
/// would be error.OutOfMemory, but an error code would be "ZICL OOM".
pending_error_code: OptionalHandle,
/// If an error occurs while a `on`/`trap`/`finally` executes, it can be easy to
/// lose track of the original error. So instead when this happens we store the
/// original error in a `-pending` key, inside of the new error.
pending_error_during: OptionalHandle,

prng: std.Random.DefaultPrng,

pub const CommandHashTable = std.StringArrayHashMapUnmanaged(NativeCommand);
pub const CommandFn = fn (interp: *Interp, args: []Handle) Error!void;
pub const CCommandFn = fn (interp: *Interp, argc: c_int, argv: [*]Handle) callconv(.c) ReturnCode;

pub const EvalError = error{
    OutOfMemory,
    EvalError,
    PropagateResult,
    Break,
    Continue,
    Signal,
    Exit,
};
pub const Error = EvalError || error{
    WrongUsage,
    Tailcall,
};

pub fn narrowError(err: anyerror) EvalError {
    return switch (err) {
        error.Break => error.Break,
        error.Continue => error.Continue,
        error.EvalError => error.EvalError,
        error.Exit => error.Exit,
        error.OutOfMemory => error.OutOfMemory,
        error.Signal => error.Signal,
        else => error.EvalError,
    };
}
pub fn narrowToEvalError(result: anytype) blk: {
    const info = @typeInfo(@TypeOf(result));
    break :blk if (info == .error_set) EvalError else EvalError!info.error_union.payload;
} {
    if (@typeInfo(@TypeOf(result)) == .error_set) {
        return narrowError(result);
    } else if (result) |val| {
        return val;
    } else |err| return narrowError(err);
}

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
            interp.setResultOwning(det.message);
            return error.EvalError;
        }
    }

    if (result) |val| {
        return val;
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (det.message.heap != 0) {
                std.debug.print("err: {}\n", .{err});
            }
            // This error should have error details, if it's not OOM.
            interp.setResultOwning(det.message);
            return error.EvalError;
        },
    }
}

/// Resolves to the variable's value, if any. Does not account for dict sugar.
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

const no_variable_fmt_string = "can't read \"{s}\": no such variable";
/// This always recalculates .variable. You probably should be using `ensureValidVariableType`.
/// Must be called with a heap-native variable name, so it can shimmer in place.
fn reshimmerToVariable(
    interp: *Interp,
    det: ?*objutil.ErrorDetails,
    var_call_frame: u32,
    name: Handle,
) error{ OutOfMemory, VariableNotFound }!void {
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
        if (det) |details| details.* = .{
            .message = try objutil.newStringFmt(no_variable_fmt_string, .{var_name}),
        };
        return error.VariableNotFound;
    }
}

/// Ensures that this is a valid variable or upvar. If not, it'll shimmer it to whichever one applies.
/// Returns an error if it's DictSugar, since that requires special handling and there's not a good
/// way to handle it in the general case. Must be called with a heap-native variable name.
fn ensureValidVariableType(
    interp: *Interp,
    det: ?*objutil.ErrorDetails,
    var_call_frame: u32,
    name: Handle,
) error{ OutOfMemory, VariableNotFound, DictSugar }!void {
    assert(name.canShimmer());

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
            return error.DictSugar;
        },
        else => {
            // Fall through.
        },
    }

    // We don't know whether this is a normal variable or dict sugar yet.
    const var_name = try name.getString();
    if (std.mem.indexOf(u8, var_name, "::") != null) return error.DictSugar;

    // Make sure the variable exists.
    try interp.reshimmerToVariable(det, var_call_frame, name);
}

// Must be called with a heap-native variable name. Does not account for dict sugar.
fn createVariable(interp: *Interp, call_frame_idx: u32, name: Handle, value: Heap.Object) !void {
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

const DictSugar = struct { name: Handle, path: Handle };
fn parseDictSugar(var_name: [:0]const u8) error{OutOfMemory}!?DictSugar {
    const double_colons = std.mem.indexOf(u8, var_name, "::");
    const start_at = if (double_colons) |val| val else return null;

    const dict_name = try objutil.newString(var_name[0..start_at]);
    errdefer dict_name.decrRefCount();

    var dict_path = try objutil.newList(&.{});
    errdefer dict_path.decrRefCount();

    var last_path_start: ?usize = null;
    var i = start_at;
    while (i <= var_name.len) : (i += 1) {
        if (i == var_name.len or (var_name[i] == ':' and var_name[i + 1] == ':')) {
            if (last_path_start) |val| {
                const path_section = var_name[val..i];
                const path_section_handle = try objutil.newString(path_section);
                defer path_section_handle.decrRefCount();

                var new_dict_path: OptionalHandle = .none;
                _ = objutil.listAppend(null, dict_path, &new_dict_path, path_section_handle) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => unreachable,
                };
                dict_path.swapIfNew(new_dict_path);
            }

            // Keep advancing until we've passed the colon(s).
            while (i < var_name.len and var_name[i + 1] == ':') i += 1;
            last_path_start = i + 1;
        }
    }

    return .{ .name = dict_name, .path = dict_path };
}

/// This should only ever be called if you know that this variable is in dict sugar form.
fn shimmerToDictSugarAssumeValid(name: Handle) error{OutOfMemory}!void {
    if (name.tag() == .dict_sugar) return;

    const dict_sugar = (try parseDictSugar(try name.getString())).?;
    errdefer dict_sugar.name.decrRefCount();
    errdefer dict_sugar.path.decrRefCount();

    try name.prepareToShimmer();
    name.peek().head.tag = .dict_sugar;
    name.peek().body.dict_sugar = .{
        .dict_name_index = dict_sugar.name.index,
        .path_index = dict_sugar.path.index,
    };
}

/// Must be called with a heap-native name. Always takes ownership of `value`, even in error cases.
pub fn setVariableInner(
    interp: *Interp,
    det: ?*objutil.ErrorDetails,
    call_frame_idx: u32,
    name: Handle,
    value: Heap.Object,
) error{ OutOfMemory, BadDict }!void {
    // TODO PERF a lot of functions look the variable back up after setting it. We should probably
    // return the variable's new handle after setting it. After doing so, be sure to audit all
    // the call sites.

    var value_taken = false;
    errdefer if (!value_taken) {
        var value_mut = value;
        value_mut.deinitSingle(Heap.local_heap);
    };

    if (interp.ensureValidVariableType(null, call_frame_idx, name)) {
        switch (name.tag()) {
            .cached_local_var => {
                const cached_var = &name.peek().body.cached_local_var;
                const var_value = Heap.local_heap.getHandle(cached_var.cached_index);
                if (var_value.tag() == .upvar_link) {
                    const upvar_link = var_value.peek().body.upvar_link;
                    // Set the value through the linked name in the linked frame.
                    try interp.setVariableInner(
                        det,
                        upvar_link.call_frame,
                        Heap.local_heap.getHandle(upvar_link.linked_name),
                        value,
                    );
                    return;
                }

                const var_call_frame = &interp.call_frames.items[call_frame_idx];

                value_taken = true;
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
                value_taken = true;
                try createVariable(interp, call_frame_idx, name, value);
            },
            else => unreachable,
        }
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.VariableNotFound => {
            value_taken = true;
            try createVariable(interp, call_frame_idx, name, value);
        },
        error.DictSugar => {
            try shimmerToDictSugarAssumeValid(name);
            const dict_sugar = name.peek().body.dict_sugar;
            const dict_name = name.getHeap().getHandle(dict_sugar.dict_name_index);
            const dict_path = name.getHeap().getHandle(dict_sugar.path_index);

            var resolved_dict = blk: {
                if (interp.getVariableInner(null, call_frame_idx, dict_name)) |dict| {
                    break :blk dict.borrow();
                } else |get_err| switch (get_err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.BadDict => unreachable, // `dict_name` can't be .dict_sugar.
                    error.VariableNotFound => {
                        // If it's not found, then we'll just create it.
                        break :blk try objutil.newDictInner(Heap.local_heap, &.{});
                    },
                }
            };
            defer resolved_dict.decrRefCount();

            var keys = try objutil.listToHandles(Heap.global_gpa, dict_path);
            defer keys.deinit(Heap.global_gpa);

            var maybe_new_dict: OptionalHandle = .none;
            value_taken = true;
            _ = objutil.dictPutRecursively(null, resolved_dict, &maybe_new_dict, keys.items, value) catch |put_err| switch (put_err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => unreachable,
            };
            resolved_dict.swapIfNew(maybe_new_dict);

            try interp.setVariableInner(det, call_frame_idx, dict_name, resolved_dict.reference());
        },
    }
}

pub fn setVariableLinkInner(
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
            .message = try objutil.newStringFmt("variable \"{s}\" already exists", .{name_bytes}),
        };

        return error.VariableAlreadyExists;
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.VariableNotFound => {
            // Fall through.
        },
        error.DictSugar => {
            if (det) |details| details.* = .{
                .message = try objutil.newString("cannot create an upvar name that has dict sugar"),
            };
            return error.DictSugarInUpvarName;
        },
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
                    .message = try objutil.newString("can't upvar from variable to itself"),
                };
                return error.CircularUpvar;
            }

            const var_exists = interp.ensureValidVariableType(null, target_call_frame_idx, obj_currently_checking);
            if (var_exists) |_| {
                // Can't use `getVariableInner` here, as it follows upvars.
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
                    // It's not pointing at a variable, so the chain is broken.
                    break;
                }
            } else |err| switch (err) {
                error.VariableNotFound => {
                    // If the target var doesn't exist, then of course the var name != nothing,
                    // so it's not equal to itself.
                    break;
                },
                error.DictSugar => {
                    // It's not pointing at a variable, so the chain is broken.
                    break;
                },
                error.OutOfMemory => return error.OutOfMemory,
            }
        }

        const target_name_duped = try objutil.newString(target_name_bytes);

        interp.setVariableInner(null, call_frame_idx, name, .{
            .head = .{ .str = Heap.Object.null_string, .tag = .upvar_link },
            .body = .{ .upvar_link = .{
                .call_frame = target_call_frame_idx,
                .linked_name = target_name_duped.index,
            } },
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // We already checked that the name isn't dict sugar, so it's definitely
            // impossible for it to be a bad dict.
            error.BadDict => unreachable,
        };
    }
}

pub fn unsetVariableInner(
    interp: *Interp,
    det: ?*objutil.ErrorDetails,
    call_frame_idx: u32,
    name: Handle,
) !void {
    interp.ensureValidVariableType(det, call_frame_idx, name) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.VariableNotFound => return error.VariableNotFound,
        error.DictSugar => {
            try shimmerToDictSugarAssumeValid(name);

            const dict_sugar = name.peek().body.dict_sugar;
            const dict_name = name.getHeap().getHandle(dict_sugar.dict_name_index);
            const dict_path = name.getHeap().getHandle(dict_sugar.path_index);

            if (interp.getVariableInner(null, call_frame_idx, dict_name)) |dict| {
                // Build keys from the path list elements.
                var keys = try objutil.listToHandles(Heap.global_gpa, dict_path);
                defer keys.deinit(Heap.global_gpa);

                const remove_result = objutil.dictRemoveRecursively(det, dict, keys.items) catch |rerr| switch (rerr) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        if (det) |details| details.* = .{
                            .message = try objutil.newStringFmt(
                                "can't unset \"{s}\": no such element in dictionary",
                                .{try name.getString()},
                            ),
                        };
                        return error.VariableNotFound;
                    },
                };
                if (!remove_result.did_remove) {
                    assert(remove_result.new_dict == .none);
                    if (det) |details| details.* = .{
                        .message = try objutil.newStringFmt(
                            "can't unset \"{s}\": no such element in dictionary",
                            .{try name.getString()},
                        ),
                    };
                    return error.VariableNotFound;
                } else if (remove_result.new_dict.toHandle()) |new_dict| {
                    try interp.setVariableInner(det, call_frame_idx, dict_name, new_dict.referenceTakeOwnership());
                }
            } else |get_err| switch (get_err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    if (det) |details| details.* = .{
                        .message = try objutil.newStringFmt("can't unset \"{f}\": no such element in dictionary", .{name}),
                    };
                    return error.VariableNotFound;
                },
            }
        },
    };

    switch (name.tag()) {
        .cached_local_var => {
            const cached_var = &name.peek().body.cached_local_var;
            const var_value = Heap.local_heap.getHandle(cached_var.cached_index);
            if (var_value.tag() == .upvar_link) {
                const upvar_link = var_value.peek().body.upvar_link;
                const linked_name = Heap.local_heap.getHandle(upvar_link.linked_name);
                // Unset the value through the linked name in the linked frame.
                try interp.unsetVariableInner(det, upvar_link.call_frame, linked_name);
                return;
            }

            const call_frame = &interp.call_frames.items[call_frame_idx];
            const remove_result = try objutil.dictRemove(call_frame.variables, name);
            if (!remove_result.did_remove) {
                assert(remove_result.new_dict == .none);
                if (det) |details| details.* = .{
                    .message = try objutil.newStringFmt("can't unset \"{f}\": no such variable", .{name}),
                };
                return error.VariableNotFound;
            } else if (remove_result.new_dict.toHandle()) |new_dict| {
                call_frame.variables.swap(new_dict);
            }

            call_frame.call_epoch = interp.nextCallEpoch();
        },
        .cached_lexical_var => {
            const call_frame = &interp.call_frames.items[call_frame_idx];
            const remove_result = try objutil.dictRemove(call_frame.variables, name);
            if (!remove_result.did_remove) {
                assert(remove_result.new_dict == .none);
                if (det) |details| details.* = .{
                    .message = try objutil.newStringFmt("can't unset \"{f}\": no such variable", .{name}),
                };
                return error.VariableNotFound;
            } else if (remove_result.new_dict.toHandle()) |new_dict| {
                call_frame.variables.swap(new_dict);
            }

            call_frame.call_epoch = interp.nextCallEpoch();
        },
        else => unreachable,
    }
}

/// Resolves to the variable's value. Must be called with a heap-native name.
pub fn getVariableInner(
    interp: *Interp,
    det: ?*objutil.ErrorDetails,
    call_frame_idx: u32,
    name: Handle,
) error{ OutOfMemory, VariableNotFound, BadDict }!Handle {
    interp.ensureValidVariableType(det, call_frame_idx, name) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.VariableNotFound => return error.VariableNotFound,
        error.DictSugar => {
            try shimmerToDictSugarAssumeValid(name);

            const dict_sugar = name.peek().body.dict_sugar;
            const dict_name = name.getHeap().getHandle(dict_sugar.dict_name_index);
            const dict_path = name.getHeap().getHandle(dict_sugar.path_index);

            const resolved_dict = try interp.getVariableInner(det, call_frame_idx, dict_name);

            var keys = try objutil.listToHandles(Heap.global_gpa, dict_path);
            defer keys.deinit(Heap.global_gpa);

            var new_dict: OptionalHandle = .none;
            const result = objutil.dictLookupRecursively(null, resolved_dict, &new_dict, keys.items) catch |lerr| switch (lerr) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    if (det) |details| details.* = .{
                        .message = try objutil.newStringFmt("variable \"{f}\" is not a valid dictionary", .{dict_name}),
                    };
                    return error.BadDict;
                },
            };

            if (new_dict.toHandle()) |new| {
                try interp.setVariableInner(det, call_frame_idx, dict_name, new.referenceTakeOwnership());
            }

            if (result.toHandle()) |val| {
                return val;
            } else {
                if (det) |details| details.* = .{
                    .message = try objutil.newStringFmt("can't read \"{f}\": no such variable", .{name}),
                };
                return error.VariableNotFound;
            }
        },
    };

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
        else => unreachable,
    }
}

pub fn expectErrorOrOom(expected_error: anyerror, actual_error_union: anytype) !void {
    if (actual_error_union) |_| {
        try testing.expectError(expected_error, actual_error_union);
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => try testing.expectError(expected_error, actual_error_union),
    }
}
fn testVariables(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    const heap = try Heap.testStart(ta, testing.io);
    var interp = try Interp.init();
    defer interp.deinit();

    var str_foo = try objutil.newStringInner(heap, "foo");
    defer str_foo.decrRefCount();

    // Make sure it doesn't resolve to anything.
    try testing.expectEqual(null, interp.resolveVariable(0, str_foo));

    const str_value = try objutil.newStringInner(heap, "value");
    defer str_value.decrRefCount();
    try interp.setVariableTo(&str_foo, str_value);

    const cached_lookup_value = (try interp.resolveVariable(0, str_foo)).?.local_variable.target;
    try testing.expectEqualStrings("value", try cached_lookup_value.getString());
    // Also try resolving the value from a new string.
    var str2_foo = try objutil.newStringInner(heap, "foo");
    defer str2_foo.decrRefCount();
    const lookup_value = (try interp.resolveVariable(0, str2_foo)).?.local_variable.target;
    try testing.expectEqualStrings("value", try lookup_value.getString());

    // Next, we test dict sugar.
    var str_foo_bar = try objutil.newStringInner(heap, "foo::bar");
    defer str_foo_bar.decrRefCount();
    var str_baz = try objutil.newStringInner(heap, "baz");
    defer str_baz.decrRefCount();

    // Make sure trying to read a dict value fails when it's not a dict.
    try expectErrorOrOom(error.BadDict, interp.getVariableInner(null, 0, str_foo_bar));

    // // Clear foo so we can set it to a dictionary.
    try interp.setVariableInner(null, 0, str_foo, Heap.emptyObject());
    try interp.setVariableInner(null, 0, str_foo_bar, str_baz.reference());
    // try std.testing.expectEqual(str_baz, try interp.getVariableInner(null, 0, str_foo_bar));
}

test "variable basics" {
    try testing.checkAllAllocationFailures(testing.allocator, testVariables, .{});
}

fn testVariableLink(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    const heap = try Heap.testStart(ta, testing.io);
    var interp = try Interp.init();
    defer interp.deinit();

    // Create a variable `foo` containing `value`, then upvar `bar` to `foo`.
    var str_foo = try objutil.newStringInner(heap, "foo");
    defer str_foo.decrRefCount();

    try testing.expectEqual(null, interp.resolveVariable(0, str_foo));
    const str_value = try objutil.newStringInner(heap, "value");
    defer str_value.decrRefCount();
    try interp.setVariableTo(&str_foo, str_value);

    var str_bar = try objutil.newStringInner(heap, "bar");
    defer str_bar.decrRefCount();
    try interp.setVariableLinkInner(null, 0, str_bar, 0, str_foo);

    // Make sure we can get the value of `foo` through `bar`.
    var lookup_value = try interp.getVariableInner(null, 0, str_bar);
    try testing.expectEqualStrings("value", try lookup_value.getString());

    // Modify `foo` through `bar`.
    const str_new_value = try objutil.newStringInner(heap, "new value");
    defer str_new_value.decrRefCount();
    try interp.setVariableInner(null, 0, str_bar, str_new_value.reference());
    lookup_value = try interp.getVariableInner(null, 0, str_foo);
    try testing.expectEqualStrings("new value", try lookup_value.getString());
}

test "variable link" {
    try testing.checkAllAllocationFailures(testing.allocator, testVariableLink, .{});
}

pub const NativeCommand = struct {
    description: ?[]const u8 = "",
    min_arity: usize = 0,
    max_arity: ?usize = null,
    /// If the command argument length needs to be a multiple of some
    /// amount, set this. A good example is `dict create`, as it needs
    /// an even number of arguments.
    multiple_of: ?usize = null,

    call_info: union(enum) {
        zig: *const CommandFn,
        c: *const CCommandFn,
    },

    /// Returns a string containing all the usage information. Allocates the string
    /// onto `gpa`. Produces something like `cmd ...`, or `cmd arg1 arg2 ?arg3?`
    pub fn getUsageInfo(command: *NativeCommand, gpa: std.mem.Allocator, command_name: []const u8) ![]const u8 {
        var aw = std.Io.Writer.Allocating.init(gpa);
        defer aw.deinit();

        // Write command name.
        aw.writer.writeAll(command_name) catch return error.OutOfMemory;

        if (command.description) |description| {
            aw.writer.print(" {s}", .{description}) catch return error.OutOfMemory;
        } else {
            aw.writer.writeAll(" ...") catch return error.OutOfMemory;
        }

        return try aw.toOwnedSlice();
    }

    pub fn minArity(command: NativeCommand) usize {
        switch (command.call_info) {
            .zig => |info| return info.min_arity,
            .c => |info| return @intCast(info.min_arity),
        }
    }

    pub fn maxArity(command: NativeCommand) ?usize {
        switch (command.call_info) {
            .zig => |info| return info.max_arity,
            .c => |info| if (info.max_arity >= 0) {
                return @intCast(info.max_arity);
            } else return null,
        }
    }

    pub fn multipleOf(command: NativeCommand) ?usize {
        switch (command.call_info) {
            .zig => |info| return info.multiple_of,
            .c => |info| if (info.multiple_of >= 0) {
                return @intCast(info.multiple_of);
            } else return null,
        }
    }
};

fn wrongArgumentCountError(det: ?*objutil.ErrorDetails, command_usage: []const u8) !void {
    if (det) |details| details.* = .{
        .message = try objutil.newStringFmt("wrong # args: should be \"{s}\"", .{command_usage}),
    };

    return Error.WrongUsage;
}

/// `name` should be a static variable guaranteed to exist as long as the
/// interpreter exists.
pub fn registerCommand(interp: *Interp, name: []const u8, command: NativeCommand) !void {
    try interp.global_commands.put(Heap.global_gpa, name, command);

    var var_name = try objutil.newString(name);
    defer var_name.decrRefCount();

    const var_name_escaped = try objutil.newList(&.{var_name});
    defer var_name_escaped.decrRefCount();
    var combined = std.ArrayList(u8).empty;
    defer combined.deinit(Heap.global_gpa);
    try combined.appendSlice(Heap.global_gpa, "nativefn ");
    try combined.appendSlice(Heap.global_gpa, try var_name_escaped.getString());
    const var_value = try objutil.newString(combined.items);

    try interp.setVariableToObject(&var_name, var_value.referenceTakeOwnership());

    // FIXME need to handle this if it wraps around.
    interp.global_procedure_epoch += 1;
}

pub fn parseClosure(det: ?*objutil.ErrorDetails, bytes: []const u8) !Heap.Closure {
    const is_method, const prefix_len = blk: {
        if (bytes.len > 3 and std.mem.eql(u8, bytes[0..3], "fn "))
            break :blk .{ false, @as(usize, 3) };
        if (bytes.len > 7 and std.mem.eql(u8, bytes[0..7], "method "))
            break :blk .{ true, @as(usize, 7) };
        if (det) |details| details.* = .{
            .message = try objutil.newStringFmt("not a valid function: \"{s}\"", .{bytes}),
        };
        return error.BadClosure;
    };

    var closure_value = try objutil.newString(bytes[prefix_len..]);
    defer closure_value.decrRefCount();

    var dict_new: OptionalHandle = .none;
    objutil.shimmerToDict(null, closure_value, &dict_new) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (det) |details| details.* = .{
                .message = try objutil.newStringFmt("not a valid function: \"{s}\"", .{bytes}),
            };
            return error.BadClosure;
        },
    };
    closure_value.swapIfNew(dict_new);

    const maybe_name = try objutil.dictLookupFollowLinks(closure_value, Heap.local_heap.getInternedString(.name));
    const maybe_impl = try objutil.dictLookupFollowLinks(closure_value, Heap.local_heap.getInternedString(.impl));
    const maybe_scope = try objutil.dictLookupFollowLinks(closure_value, Heap.local_heap.getInternedString(.scope));

    var args, const body = blk: {
        if (maybe_impl.toHandle()) |impl| {
            var impl_new: OptionalHandle = .none;
            defer impl_new.decrOptional();
            objutil.shimmerToList(null, impl, &impl_new) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    if (det) |details| details.* = .{
                        .message = try objutil.newStringFmt("not a valid function implementation: \"{s}\"", .{bytes}),
                    };
                    return error.BadClosure;
                },
            };
            const impl_as_list = impl_new.orElse(impl);

            if (objutil.listLengthRaw(impl_as_list) != 2) {
                if (det) |details| details.* = .{
                    .message = try objutil.newStringFmt("not a valid function implementation: \"{s}\"", .{bytes}),
                };
                return error.BadClosure;
            }

            break :blk .{ objutil.listItem(impl_as_list, 0).borrow(), objutil.listItem(impl_as_list, 1).borrow() };
        } else {
            if (det) |details| details.* = .{
                .message = try objutil.newStringFmt("function missing implementation: \"{s}\"", .{bytes}),
            };
            return error.BadClosure;
        }
    };
    defer args.decrRefCount();
    defer body.decrRefCount();

    // Make sure args is a list.
    var new_args: OptionalHandle = .none;
    objutil.shimmerToList(null, args, &new_args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (det) |details| details.* = .{
                .message = try objutil.newStringFmt("function args is not a valid list: \"{f}\"", .{args}),
            };
            return error.BadClosure;
        },
    };
    args.swapIfNew(new_args);

    // Make sure scope is a dict.
    var new_scope: OptionalHandle = .none;
    defer new_scope.decrOptional();
    const scope_as_dict: OptionalHandle = blk: {
        if (maybe_scope.toHandle()) |scope| {
            objutil.shimmerToDict(null, scope, &new_scope) catch |err| switch (err) {
                error.OutOfMemory => {
                    if (det) |details| details.* = .{
                        .message = try objutil.newStringFmt("function scope is not a valid dict: \"{f}\"", .{args}),
                    };
                    return error.OutOfMemory;
                },
                else => return error.BadClosure,
            };
            break :blk new_scope.orElse(scope).toOptional();
        } else break :blk .none;
    };

    const parsed_args = try parseClosureArgList(det, args);
    errdefer parsed_args.deinit();

    return .{
        .args = args.borrow(),
        .body = body.borrow(),
        .name = maybe_name.borrowOptional(),
        .scope = scope_as_dict.borrowOptional(),
        .required_arity = parsed_args.required_arity,
        .optional_arity = parsed_args.optional_arity,
        .optional_values = parsed_args.optional_values,
        .has_args_parameter = parsed_args.has_args_parameter,
        .is_method = is_method,
        .cache_id = Heap.nextCacheId(),
    };
}

const ParsedArgList = struct {
    required_arity: u32,
    optional_arity: u32,
    optional_values: OptionalHandle,
    has_args_parameter: bool,

    pub fn deinit(self: ParsedArgList) void {
        self.optional_values.decrOptional();
    }
};

/// Validates a closure argument list and extracts arity information. Modifies
/// the list in-place to strip default values from optional parameter specifiers.
/// `args` must already be shimmered to a list.
pub fn parseClosureArgList(det: ?*objutil.ErrorDetails, args: Handle) !ParsedArgList {
    const arg_list_len = objutil.listLengthRaw(args);

    // Pre-allocate for optional default values. arg_list_len is an upper bound.
    var optional_values: ?Handle = null;
    errdefer if (optional_values) |val| val.decrRefCount();
    var args_parameter_found = false;
    var required_arity: u32 = 0;
    var optional_arity: u32 = 0;

    for (0..arg_list_len) |i| {
        if (args_parameter_found) {
            if (det) |details| details.* = .{
                .message = try objutil.newString("parameter after 'args' not allowed"),
            };
            return error.BadClosure;
        }

        const arg_raw = objutil.listItem(args, @intCast(i));
        var arg_new: OptionalHandle = .none;
        defer arg_new.swapWithNone();
        objutil.shimmerToList(null, arg_raw, &arg_new) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                if (det) |details| details.* = .{
                    .message = try objutil.newStringFmt("too many fields in argument specifier \"{f}\"", .{arg_raw}),
                };
                return error.BadClosure;
            },
        };
        const arg = arg_new.orElse(arg_raw);
        const arg_len = objutil.listLengthRaw(arg);

        if (arg_len == 0) {
            if (det) |details| details.* = .{
                .message = try objutil.newString("argument with no name"),
            };
            return error.BadClosure;
        } else if (arg_len > 2) {
            if (det) |details| details.* = .{
                .message = try objutil.newStringFmt("too many fields in argument specifier \"{f}\"", .{arg}),
            };
            return error.BadClosure;
        } else if (arg_len == 2) {
            // Optional parameter.
            if (optional_values == null) {
                optional_values = try objutil.newListWithCapacity(arg_list_len);
            }

            if (try Heap.stringEquals(objutil.listItem(arg, 0), "args")) {
                if (det) |details| details.* = .{
                    .message = try objutil.newString("'args' must be a required parameter"),
                };
                return error.BadClosure;
            }

            // Add the optional parameter onto the optional parameters list.
            var never_new: OptionalHandle = .none;
            _ = try objutil.listAppend(det, optional_values.?, &never_new, objutil.listItem(arg, 1));
            assert(never_new == .none);

            // Replace {name default} with just the name in the args list.
            const new_item = objutil.listItem(arg, 0).dupOrRef();
            try objutil.listSetObject(null, args, &never_new, @intCast(i), new_item);
            assert(never_new == .none);

            optional_arity += 1;
        } else {
            if (optional_values != null) {
                if (det) |details| details.* = .{
                    .message = try objutil.newString("required parameter after optional parameter not allowed"),
                };
                return error.BadClosure;
            }

            const arg_name = try objutil.listItem(arg, 0).getString();
            if (std.mem.eql(u8, arg_name, "args")) args_parameter_found = true;

            required_arity += 1;
        }
    }

    return .{
        .required_arity = required_arity,
        .optional_arity = optional_arity,
        .optional_values = if (optional_values) |val| val.toOptional() else .none,
        .has_args_parameter = args_parameter_found,
    };
}

/// Creates a heap object with the `.closure` tag and associated extra data.
/// The closure's fields are borrowed, so the caller retains ownership of the
/// inputs. Returns an owned handle.
pub fn createClosureObject(closure: Heap.Closure) !Handle {
    const obj = try Heap.local_heap.createObject();
    errdefer obj.decrRefCount();
    const extra_data = try Heap.local_heap.createExtraData();
    errdefer Heap.local_heap.destroyExtraData(extra_data);
    Heap.local_heap.getExtraData(extra_data).* = .{ .closure = closure.borrow() };
    obj.peek().head.tag = .closure;
    obj.peek().body = .{ .closure = .{ .extra_data = extra_data } };
    return obj;
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
            interp.setVariableInner(null, call_frame_idx, var_name, list.reference()) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // It's impossible to hit bad dict when initializing a brand new call frame.
                error.BadDict => unreachable,
            };
        } else if (signature_idx >= closure.required_arity) {
            // This is an optional argument.

            // Are there any remaining unassigned arguments?
            if (called_idx < args.len) {
                interp.setVariableInner(
                    null,
                    call_frame_idx,
                    var_name,
                    args[called_idx].dupOrRef(),
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    // It's impossible to hit bad dict when initializing a brand new call frame.
                    error.BadDict => unreachable,
                };
                called_idx += 1;
            } else {
                // Else populate it with its default value.
                const default_value = objutil.listItem(closure.optional_values.toHandle().?, signature_idx - closure.required_arity);
                interp.setVariableInner(
                    null,
                    call_frame_idx,
                    var_name,
                    default_value.dupOrRef(),
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    // It's impossible to hit bad dict when initializing a brand new call frame.
                    error.BadDict => unreachable,
                };
            }
        } else {
            interp.setVariableInner(
                null,
                call_frame_idx,
                var_name,
                args[called_idx].dupOrRef(),
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // It's impossible to hit bad dict when initializing a brand new call frame.
                error.BadDict => unreachable,
            };
            called_idx += 1;
        }
    }

    try interp.evalObjectInner(closure.body, cache_key);
}

fn callNative(interp: *Interp, command: *NativeCommand, args: []Handle) !void {
    const arg_count = args.len - 1;
    wrong_arg_count: {
        // Check arg count.
        if (arg_count < command.min_arity) break :wrong_arg_count;
        if (command.max_arity) |max_arity| {
            if (arg_count > max_arity) break :wrong_arg_count;
        }
        if (command.multiple_of) |multiple_of| {
            if (@mod(arg_count, multiple_of) != 0) break :wrong_arg_count;
        }

        switch (command.call_info) {
            .zig => |to_call| try to_call(interp, args),
            .c => |to_call| {
                try ReturnCode.toError(to_call(interp, @intCast(args.len), args.ptr));
            },
        }

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
    interp.result = Heap.local_heap.emptyHandle();
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

pub fn setResultFloat(interp: *Interp, value: f64) !void {
    interp.setResultOwning(try objutil.newFloat(value));
}

pub fn setResultString(interp: *Interp, bytes: []const u8) !void {
    const bytes_handle = try objutil.newString(bytes);
    interp.setResultOwning(bytes_handle);
}

pub fn setResultBoolean(interp: *Interp, value: bool) !void {
    interp.setResultOwning(try objutil.newBoolean(value));
}

pub fn setResultInterned(interp: *Interp, interned: Heap.InternedString) void {
    interp.setResultOwning(Heap.local_heap.getInternedString(interned));
}

pub fn setResultFormatted(interp: *Interp, comptime fmt: []const u8, args: anytype) !void {
    const fmt_handle = try objutil.newStringFmt(fmt, args);

    interp.setResultOwning(fmt_handle);
}

pub fn setEmptyResult(interp: *Interp) void {
    interp.freeLastResult();
}

pub fn makeErrorMessage(interp: *Interp) !Handle {
    const st = interp.stack_trace.toHandle() orelse return error.NoStackTrace;
    const err_msg = try interp.result.getString();

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(Heap.global_gpa);
    try buf.appendSlice(Heap.global_gpa, err_msg);

    // Stack trace is a flat list: {name file line args} repeated per frame.
    const n_items = objutil.listLengthRaw(st);
    var i: u32 = 0;
    while (i < n_items) : (i += 4) {
        const file = objutil.listItem(st, i + 1);
        const line = objutil.listItem(st, i + 2);
        buf.print(Heap.global_gpa, "\n    at {f}:{f}", .{ file, line }) catch return error.OutOfMemory;
    }

    return try objutil.newString(buf.items);
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
};

pub fn currentCallFrameIndex(interp: *Interp) u32 {
    return @intCast(interp.call_frames.items.len - 1);
}

pub fn currentCallFrame(interp: *Interp) *CallFrame {
    return &interp.call_frames.items[interp.currentCallFrameIndex()];
}

/// Returns a dict containing this call frame's variables.
pub fn captureScope(interp: *Interp, det: ?*objutil.ErrorDetails, call_frame_idx: u32) !Handle {
    const frame = &interp.call_frames.items[call_frame_idx];
    const pairs = objutil.dictPairLengthRaw(frame.variables);

    // Make sure there's no upvars.
    for (0..pairs) |i_usize| {
        const i: u32 = @intCast(i_usize);
        const value = objutil.dictItem(frame.variables, i * 2 + 1);
        if (value.tag() == .upvar_link) break;
    } else {
        // No upvars found, so we can just borrow the variables.
        const scope = frame.variables.borrow();
        return scope;
    }

    // Found upvars if we made it to this point, so we need
    // to duplicate everything, and follow any upvars.
    const new_dict = try objutil.newDictWithCapacity(Heap.local_heap, pairs * 2);
    errdefer new_dict.decrRefCount();
    try objutil.dictSetLinkIfPresent(new_dict, frame.variables.getDictExtraData().parent_link);

    for (0..pairs) |i_usize| {
        const i: u32 = @intCast(i_usize);
        const key = objutil.dictItem(frame.variables, i * 2);
        const value = objutil.dictItem(frame.variables, i * 2 + 1);

        if (value.tag() == .upvar_link) {
            const upvar_link = value.peek().body.upvar_link;
            if (interp.getVariableInner(null, upvar_link.call_frame, Heap.local_heap.getHandle(upvar_link.linked_name))) |upvar_val| {
                assert((try objutil.dictPut(new_dict, key, upvar_val)).new_dict == .none);
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.BadDict => {
                    if (det) |details| details.* = .{
                        .message = try objutil.newStringFmtInner(
                            Heap.local_heap,
                            "failed to capture the variable \"{f}\", as it was an upvar that pointed at nothing",
                            .{key},
                        ),
                    };
                    return error.UninitializedUpvar;
                },
                error.VariableNotFound => {
                    // Don't put anything in the dictionary if the upvar
                    // doesn't point at anything.
                },
            }
        } else {
            assert((try objutil.dictPut(new_dict, key, value)).new_dict == .none);
        }
    }

    return new_dict;
}

/// Returns a dict capturing the current call frame's variables.
pub fn captureCurrentScope(interp: *Interp) !Handle {
    var det: objutil.ErrorDetails = undefined;
    return try interp.wrapError(&det, interp.captureScope(&det, interp.currentCallFrameIndex()));
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
    /// Arguments of the command currently being dispatched in this eval frame.
    args: []Handle,
    /// The line number of the command currently being dispatched, within
    /// the script being evaluated (note that this is relative, since that's
    /// how parsed scripts are stored). Combine with `source_info.line_no`
    /// to recover the absolute line at error-reporting time.
    current_line: u32,
    /// The object currently being evaluated.
    currently_evaluating: Handle,
};

pub fn currentEvalFrameIndex(interp: *Interp) u32 {
    return @intCast(interp.eval_frames.items.len - 1);
}

pub fn currentEvalFrame(interp: *Interp) *EvalFrame {
    return &interp.eval_frames.items[interp.currentEvalFrameIndex()];
}

fn pushCallFrame(interp: *Interp, parent: ?u32, args: []Handle, signature: Heap.Closure) !u32 {
    const vars_handle = try objutil.newDictInner(Heap.local_heap, &.{});
    errdefer vars_handle.decrRefCount();
    const borrowed_signature = signature.borrow();
    errdefer borrowed_signature.deinit();

    if (signature.scope.toHandle()) |scope| {
        // Safe since vars_handle is freshly allocated.
        try objutil.dictSetLink(vars_handle, scope);
    }

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

fn pushEvalFrame(interp: *Interp, script: Handle) !u32 {
    try interp.eval_frames.append(Heap.global_gpa, .{
        .call_frame = interp.currentCallFrameIndex(),
        .args = &.{},
        .current_line = 1,
        .currently_evaluating = script,
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

    var new_values = try std.ArrayList(Handle).initCapacity(tokens_alloc, value_len);
    defer new_values.deinit(tokens_alloc);
    defer for (new_values.items) |value| value.decrRefCount();

    // Substitute all the tokens, placing them in `new_values`.
    for (tags, value_start..(value_start + value_len)) |tag, value_index| {
        if (interp.substituteOneToken(tag, objutil.listItem(value_list, @intCast(value_index)))) |new_value| {
            new_values.appendAssumeCapacity(new_value);
        } else |err| {
            // Due to the error, we're actually going to return early, after we take care
            // of giving a useful error to the user.
            var new_err = err;

            if (substitution_only) {
                switch (err) {
                    error.Break => {
                        // Stop here.
                        break;
                    },
                    error.Continue => {
                        new_values.appendAssumeCapacity(Heap.local_heap.emptyHandle());
                        continue;
                    },
                    else => {},
                }
            } else {
                switch (err) {
                    error.Break => {
                        try interp.setResultString("invoked \"break\" outside of a loop");
                        new_err = error.EvalError;
                    },
                    error.Continue => {
                        try interp.setResultString("invoked \"continue\" outside of a loop");
                        new_err = error.EvalError;
                    },
                    else => {},
                }
            }

            return new_err;
        }
    }

    var new_str_len: usize = 0;
    for (new_values.items) |new_value| {
        new_str_len += (try new_value.getString()).len;
    }

    if (new_str_len == 0) return Heap.local_heap.emptyHandle();

    const new_str = try objutil.newStringToFill(Heap.local_heap, new_str_len);
    errdefer new_str.decrRefCount();
    if (Heap.getStringMut(new_str)) |new_str_mut| {
        var written: usize = 0;
        for (new_values.items) |new_value| {
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
fn getCommandInner(
    interp: *Interp,
    det: ?*objutil.ErrorDetails,
    call_frame: u32,
    name: Handle,
) !CommandOrClosure {
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
                    .message = try objutil.newStringFmt("invalid native command name \"{s}\"", .{bytes[9..]}),
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
        error.VariableNotFound, error.BadDict => {
            if (det) |details| details.* = .{
                .message = try objutil.newStringFmt("invalid command name \"{f}\"", .{name}),
            };
            return error.CommandNotFound;
        },
    }
}

pub fn getCommand(
    interp: *Interp,
    call_frame_idx: u32,
    handle: *Handle,
) !CommandOrClosure {
    try interp.ensureShimmerable(handle);
    var det: objutil.ErrorDetails = undefined;
    return interp.getCommandInner(&det, call_frame_idx, handle.*) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CommandNotFound => {
            interp.setResultOwning(det.message);
            return error.CommandNotFound;
        },
        else => {
            interp.setResultOwning(det.message);
            return error.EvalError;
        },
    };
}

fn invokeUnknown(interp: *Interp, args: []Handle) !void {
    const unknown_cmd = interp.getCommand(0, &interp.unknown_str) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CommandNotFound => {
            // No [unknown] command exists, so we'll default to the "no command found" error.
            try interp.setResultFormatted("invalid command name \"{f}\"", .{args[0]});
            return error.EvalError;
        },
        error.EvalError => return error.EvalError,
    };

    if (interp.unknown_depth > 50) {
        try interp.setResultString("infinite recursion in [unknown]");
        return error.EvalError;
    }

    interp.unknown_depth += 1;
    defer interp.unknown_depth -= 1;

    var new_args = std.ArrayList(Handle).empty;
    defer new_args.deinit(Heap.global_gpa);
    interp.unknown_str.incrRefCount();
    defer interp.unknown_str.decrRefCount();
    try new_args.append(Heap.global_gpa, interp.unknown_str);
    try new_args.appendSlice(Heap.global_gpa, args[1..]);

    try interp.invokeCommand(unknown_cmd, new_args.items);
}

const CommandError = Error || error{InfiniteRecursion};
fn invokeCommand(interp: *Interp, command_or_closure: CommandOrClosure, args: []Handle) CommandError!void {
    if (interp.eval_depth >= interp.max_eval_depth) {
        try interp.setResultString("Infinite eval recursion");
        return error.InfiniteRecursion;
    }

    interp.eval_depth += 1;
    defer interp.eval_depth -= 1;

    // Loop the calling section, as there may be a tailcall.
    var current_args = args;
    var tailcall_info: ?Tailcall = null;
    defer if (tailcall_info) |info| Heap.global_gpa.free(info.args);
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

        var tailcall_found = false;

        result catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Tailcall => {
                tailcall_found = true;
                const tailcall = interp.currentCallFrame().tailcall.?;

                // Be sure to free the previous tailcall.
                if (tailcall_info) |prev_tailcall| {
                    for (prev_tailcall.args) |arg| arg.decrRefCount();
                    Heap.global_gpa.free(prev_tailcall.args);
                }

                tailcall_info = tailcall;
                current_args = tailcall.args;
                interp.currentCallFrame().tailcall = null;
            },
            else => return err,
        };

        if (tailcall_found == false) {
            tailcall_info = null; // Avoid double free.
            break;
        }
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

pub const negative_denom_message = "negative denominator";
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
                interp.setResultInterned(.@"division by zero");
                return error.DivisionByZero;
            },
        },
        .mod => std.math.mod(i64, lhs, rhs) catch |err| switch (err) {
            error.NegativeDenominator => {
                try interp.setResultString(negative_denom_message);
                return error.NegativeDenominator;
            },
            error.DivisionByZero => {
                interp.setResultInterned(.@"division by zero");
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
                interp.setResultInterned(.@"division by zero");
                return error.DivisionByZero;
            } else {
                break :blk .{ .float = lhs / rhs };
            }
        },
        .mod => .{
            .float = std.math.mod(f64, lhs, rhs) catch |err| switch (err) {
                error.DivisionByZero => {
                    interp.setResultInterned(.@"division by zero");
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
            .float => |float| return try objutil.newFloat(float),
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
    const heap = try Heap.testStart(testing.allocator, testing.io);
    var interp = try Interp.init();
    defer interp.deinit();

    var expr = try objutil.newStringInner(heap, "5 + 10");
    defer expr.decrRefCount();
    var new_expr: OptionalHandle = .none;
    const result = try interp.evalExpression(expr, &new_expr);
    expr.swapIfNew(new_expr);
    try testing.expectEqual(ExprResult{ .int = 15 }, result);
}

pub fn setErrorStack(interp: *Interp, script: Handle) error{OutOfMemory}!void {
    if (interp.stack_trace != .none) return;
    interp.stack_trace.swapRef(try buildErrorStack(interp, script));
}

/// Builds the stack trace as a flat list of {name file line args} repeated once per call
/// frame. The top (innermost) frame is emitted first.
fn buildErrorStack(interp: *Interp, script: Handle) error{OutOfMemory}!Handle {
    var trace = try objutil.newListWithCapacity(@intCast(interp.call_frames.items.len * 4));
    errdefer trace.decrRefCount();

    var last_call_frame_idx: ?u32 = null;
    var is_top = true;

    // Eval frames are walked from top to bottom; each one is followed to its call frame.
    var i = interp.eval_frames.items.len;
    while (i > 0) {
        i -= 1;
        const eval_frame = &interp.eval_frames.items[i];

        // Skip duplicates by taking the topmost eval frame per call frame.
        if (last_call_frame_idx == eval_frame.call_frame) continue;
        last_call_frame_idx = eval_frame.call_frame;

        const call_frame = &interp.call_frames.items[eval_frame.call_frame];
        const closure_name = call_frame.signature.name.orEmpty();

        // Source info: the top frame uses the active script handle so command
        // substitution positions are reflected correctly; earlier frames use
        // their closure body.
        const body = if (is_top) script else call_frame.signature.body;
        const source_info = objutil.getSourceInfo(body);

        const file_name, const base_line = if (source_info) |info|
            .{ info.file_name.orEmpty(), info.line_no }
        else
            .{ Heap.local_heap.emptyHandle(), 1 };

        const abs_line = base_line + (eval_frame.current_line - 1);
        const line_handle = try objutil.newInteger(Heap.local_heap, @intCast(abs_line));
        defer line_handle.decrRefCount();

        // For the top frame, use the command args stored in the eval frame
        // (set just before invokeCommand while the slice is still live). For
        // lower frames use the invocation args stored in the call frame (set
        // when the frame was pushed, also still live on the Zig stack at this
        // point).
        const raw_args: []const Handle = if (is_top) eval_frame.args else call_frame.args;
        is_top = false;
        const args_list = try objutil.newList(raw_args);
        defer args_list.decrRefCount();

        objutil.listAppendAssumeCapacity(trace, closure_name.dupOrRef());
        objutil.listAppendAssumeCapacity(trace, file_name.dupOrRef());
        objutil.listAppendAssumeCapacity(trace, line_handle.dupOrRef());
        objutil.listAppendAssumeCapacity(trace, args_list.dupOrRef());
    }

    return trace;
}

/// Self will be returned borrowed. Caller is responsible for decrementing the ref count.
fn getCommandAndSelfParam(interp: *Interp, args: []Handle) !struct { command: ?CommandOrClosure, self: OptionalHandle } {
    const command = interp.getCommand(interp.currentCallFrameIndex(), &args[0]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EvalError => return error.EvalError,
        error.CommandNotFound => {
            // If the command name is unknown, we don't know if it's a method or not,
            // so we'll pretend like it's a function and invoke [unknown] with the
            // args passed in, and not inject self.
            try interp.invokeUnknown(args);
            return .{ .command = null, .self = .none };
        },
    };

    const is_method = switch (command) {
        .closure => |closure| closure.closure.is_method,
        .command => false,
    };
    if (is_method) {
        // `interp.getCommand` already made sure `args[0]` is a variable, so we can just
        // check if it's .dict_sugar.
        const method_dict_path = args[0];
        if (method_dict_path.tag() != .dict_sugar) {
            // Wasn't called with a dict path, so we treat it as a normal function call.
            return .{ .command = command, .self = .none };
        }
        const dict_sugar = method_dict_path.peek().body.dict_sugar;

        // Next, we need to find `self`, the second-to-last part of the dict path. For example, calling
        // foo::bar would have foo as `self`, or foo::bar::baz would have foo::bar as `self`.
        const dict_name = method_dict_path.getHeap().getHandle(dict_sugar.dict_name_index);
        const dict_resolved = interp.getVariableInner(null, interp.currentCallFrameIndex(), dict_name) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // This should always succeed, since when `interp.getCommand` was run earlier,
            // it ensured that the dict sugar resolved to something.
            else => unreachable,
        };
        const dict_path = method_dict_path.getHeap().getHandle(dict_sugar.path_index);

        var handles = try objutil.listToHandles(Heap.global_gpa, dict_path);
        defer handles.deinit(Heap.global_gpa);
        const all_but_last = handles.items[0..(handles.items.len - 1)];

        var maybe_new_dict: OptionalHandle = .none;
        var det: objutil.ErrorDetails = undefined;
        const maybe_self: OptionalHandle = try interp.wrapError(
            &det,
            objutil.dictLookupRecursively(&det, dict_resolved, &maybe_new_dict, all_but_last),
        );
        if (maybe_new_dict.toHandle()) |new_dict| {
            interp.setVariableInner(
                null,
                interp.currentCallFrameIndex(),
                dict_name,
                new_dict.referenceTakeOwnership(),
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.BadDict => unreachable,
            };
        }

        if (maybe_self.toHandle()) |self| {
            return .{ .command = command, .self = self.borrow().toOptional() };
        } else {
            const var_name = try args[0].getString();
            // Shave off the end, because we're looking up `self`, not the method in this case.
            var ending = std.mem.lastIndexOf(u8, var_name, "::").?;
            while (ending > 0 and var_name[ending - 1] == ':') ending -= 1;
            try interp.setResultFormatted(no_variable_fmt_string, .{var_name[0..ending]});
            return error.EvalError;
        }
    }

    return .{ .command = command, .self = .none };
}

/// Takes care of populating the `self` parameter. `args_raw` should be one item
/// larger than `args`, and `args` should be `args_raw[1..]`. If called with a
/// method, `args_raw[1]` will become `args_raw[0]`, opening up a space for the
/// `self` parameter.
fn invokeCommandMaybeMethod(interp: *Interp, args_raw: []Handle, args: *[]Handle) CommandError!void {
    const cmd_and_self = try interp.getCommandAndSelfParam(args.*);
    const command = if (cmd_and_self.command) |val| val else {
        // [unknown] was invoked, so there is no command to be had.
        return;
    };
    const maybe_self = cmd_and_self.self;

    // If the command ended up being a method, we move the command name to the
    // left, which opens up a hole for putting the `self` argument in.
    if (maybe_self.toHandle()) |self| {
        args_raw[0] = args_raw[1]; // Move command name to the left.
        // Set `self` to the empty handle, so if we fail to find `self`
        // the defer cleanup for args won't freak out.
        args_raw[1] = self;
        args.* = args_raw; // Include all the allocated args now.
    }

    // Be sure to update the eval frame's stored args.
    interp.currentEvalFrame().args = args.*;

    // Now that we've populated the arguments for this command, we'll go ahead and run it.
    var log = std.ArrayList(u8).empty;
    defer log.deinit(Heap.global_gpa);
    log.print(Heap.global_gpa, "Calling command: ", .{}) catch {};
    for (args.*) |arg| {
        log.print(Heap.global_gpa, "{{{f}}} ", .{arg}) catch {};
    }
    log.print(Heap.global_gpa, "\n", .{}) catch {};
    std.log.debug("{s}", .{log.items});

    try interp.invokeCommand(command, args.*);

    if (maybe_self.toHandle()) |_| {
        // Be sure to write back `self`.

        const call_frame = interp.currentCallFrameIndex();
        const method_dict_path = args.*[0];
        const new_self = args.*[1];

        // Make sure `method_dict_path` is still .dict_sugar, as it technically could have shimmered.
        var det: objutil.ErrorDetails = undefined;
        interp.ensureValidVariableType(&det, call_frame, args.*[0]) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.VariableNotFound => {
                interp.setResultOwning(det.message);
                return error.EvalError;
            },
            error.DictSugar => {
                // What we want.
                try shimmerToDictSugarAssumeValid(args.*[0]);
            },
        };
        method_dict_path.assert(method_dict_path.tag() == .dict_sugar);
        const dict_sugar = method_dict_path.peek().body.dict_sugar;

        const dict_name = method_dict_path.getHeap().getHandle(dict_sugar.dict_name_index);
        const dict_resolved = interp.getVariableInner(null, call_frame, dict_name) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
        const dict_path = method_dict_path.getHeap().getHandle(dict_sugar.path_index);

        var handles = try objutil.listToHandles(Heap.global_gpa, dict_path);
        defer handles.deinit(Heap.global_gpa);
        const all_but_last = handles.items[0..(handles.items.len - 1)];

        var maybe_new_dict: OptionalHandle = .none;
        _ = try interp.wrapError(&det, objutil.dictPutRecursively(
            &det,
            dict_resolved,
            &maybe_new_dict,
            all_but_last,
            new_self.reference(),
        ));

        if (maybe_new_dict.toHandle()) |new_dict| {
            const new_dict_obj = new_dict.referenceTakeOwnership();
            interp.setVariableInner(null, call_frame, dict_name, new_dict_obj) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.BadDict => unreachable,
            };
        }
    }
}

pub fn evalObjectInner(interp: *Interp, script: Handle, cache_key: u256) EvalError!void {
    // Try to get the script, parsing if necessary.
    var det: objutil.ErrorDetails = undefined;
    std.debug.print("raw script: `{f}`\n", .{script});
    const parsed = try interp.wrapError(&det, objutil.getScript(&det, script, cache_key));
    // Don't evaluate empty scripts.
    if (parsed.tags.items.len <= 1) return;

    // Reset the interpreter result. This is useful to return the empty result in the case of empty program.
    interp.setEmptyResult();

    // TODO implement JIM_OPTIMIZATION speedups

    _ = try interp.pushEvalFrame(script);
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
        interp.currentEvalFrame().current_line = command_info.line;

        // This is not always the same as which word token we're on, as argument expansion
        // may write multiple arguments from one word.
        var args_written: usize = 0;
        // We allocate an extra argument in case we discover that the command name is a method.
        var args_raw = try args_alloc.alloc(Handle, command_info.arg_count + 1);
        defer args_alloc.free(args_raw);
        // We may shift this back by one if we discover that the command name is a method.
        var args = args_raw[1..];
        defer for (args[0..args_written]) |arg| arg.decrRefCount();

        // Populate the arguments by looping through each word of the command and
        // substituting.
        var word_token_i: u32 = command_token_i;
        for (0..command_info.arg_count) |_| {
            var word_parts: u32 = 1;
            const argument_expansion = tags[word_token_i] == .argument_expansion;
            if (tags[word_token_i] == .start_of_word or argument_expansion) {
                word_parts = @intCast(values[word_token_i].body.integer);
                word_token_i += 1;
            }

            var resultant_word: Handle = blk: {
                if (word_parts == 1) {
                    // Simple one-to-one substitution, so an easy case.
                    const res = try interp.substituteOneToken(tags[word_token_i], objutil.listItem(parsed.values, word_token_i));
                    word_token_i += 1;
                    break :blk res;
                } else {
                    // Helper function that'll interpolate all the word parts and merge them into a string.
                    const res = try interp.interpolateTokens(tags[word_token_i..][0..word_parts], parsed.values, word_token_i, word_parts, false);
                    word_token_i += word_parts;
                    break :blk res;
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
                defer resultant_word.decrRefCount();

                if (len > 1) {
                    // Expanded into multiple tokens, so we'll need to resize args.
                    args = try args_alloc.realloc(args, args.len - 1 + len);
                }

                for (0..len) |list_idx| {
                    args[args_written] = objutil.listItem(resultant_word, @intCast(list_idx)).borrow();
                    args_written += 1;
                }
            } else {
                args[args_written] = resultant_word;
                args_written += 1;
            }
        }

        command_token_i = word_token_i;

        const command_result = interp.invokeCommandMaybeMethod(args_raw, &args);
        interp.currentEvalFrame().args = args;

        // TODO actually check for signals.
        if (false) {
            return error.Signal;
        } else {
            command_result catch |err| switch (err) {
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
                else => |narrowed_err| {
                    if (narrowed_err == error.OutOfMemory) {
                        // In the case of OOM, the inside function almost certainly didn't
                        // set a result, so we set it here.
                        interp.setResultInterned(.@"out of memory");
                        interp.pending_error_code.swapRef(Heap.local_heap.getInternedString(.@"ZICL OOM"));
                    }

                    if (narrowed_err == error.WrongUsage) {
                        try interp.setResultString("FIXME: prolly should explain how to use the command");
                    }

                    // `eval_frame.args` and `call_frame.args` are still live here; capture the stack
                    // trace before the loop-body defers unwind them.
                    try interp.setErrorStack(script);

                    return narrowToEvalError(narrowed_err);
                },
            };
        }
    }
}

/// Return code values matching Tcl's convention.
pub const ReturnCode = enum(u8) {
    ok = 0,
    @"error" = 1,
    @"return" = 2,
    @"break" = 3,
    @"continue" = 4,
    signal = 5,
    exit = 6,
    oom = 7,
    usage = 8,
    tailcall = 9,

    pub fn fromErrorUnion(value: Error!void) ReturnCode {
        if (value) {
            return .ok;
        } else |err| {
            return ReturnCode.fromError(err);
        }
    }

    pub fn fromError(err: Error) ReturnCode {
        return switch (err) {
            error.EvalError => .@"error",
            error.PropagateResult => .@"return",
            error.Break => .@"break",
            error.Continue => .@"continue",
            error.Signal => .signal,
            error.Exit => .exit,
            error.OutOfMemory => .oom,
            error.WrongUsage => .usage,
            error.Tailcall => .tailcall,
        };
    }

    pub fn toError(self: ReturnCode) Error!void {
        switch (self) {
            .ok => return,
            .@"error" => return error.EvalError,
            .@"return" => return error.PropagateResult,
            .@"break" => return error.Break,
            .@"continue" => return error.Continue,
            .signal => return error.Signal,
            .exit => return error.Exit,
            .oom => return error.OutOfMemory,
            .usage => return error.WrongUsage,
            .tailcall => return error.Tailcall,
        }
    }
};
pub const ReturnCodeEnum = objutil.TclEnum(Interp.ReturnCode, "return code", true);

pub fn evalObject(interp: *Interp, script: Handle) EvalError!void {
    // Reset the stack trace at each new top-level invocation.
    interp.stack_trace.swapWithNone();
    const cache_key = @as(u256, interp.currentCallFrame().signature.cache_id) ^ try script.getHash();
    return evalObjectInner(interp, script, cache_key);
}

pub fn evalFile(interp: *Interp, filename: []const u8) EvalError!void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        Heap.global_io,
        filename,
        Heap.global_gpa,
        .unlimited,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try interp.setResultFormatted("couldn't read file \"{s}\": {}", .{ filename, err });
            return;
        },
    };
    defer Heap.global_gpa.free(bytes);

    const filename_handle = try objutil.newString(filename);
    defer filename_handle.decrRefCount();
    const script = try objutil.newString(bytes);
    defer script.decrRefCount();
    try objutil.setSourceInfo(script, .{
        .file_name = filename_handle.toOptional(),
        .line_no = 1,
    });

    try interp.evalObject(script);
}

pub fn init() !Interp {
    const unknown_str = try objutil.newString("unknown");
    errdefer unknown_str.decrRefCount();

    var new_interp: Interp = .{
        .result = Heap.local_heap.emptyHandle(),
        .eval_frames = .empty,
        .call_frames = .empty,
        .current_call_epoch = 0,
        .global_procedure_epoch = 0,
        .global_commands = .empty,
        .eval_depth = 0,
        .max_eval_depth = 1000,
        .max_call_depth = 1000,
        .unknown_depth = 0,
        .unknown_str = unknown_str,
        .stack_trace = .none,
        .pending_error_code = .none,
        .pending_error_during = .none,
        .signal_depth = 0,
        .signal = 0,
        // TODO: init per interpreter
        .prng = .init(0),
    };

    _ = try new_interp.pushCallFrame(null, &.{}, .{
        .args = Heap.local_heap.emptyHandle(),
        .body = Heap.local_heap.emptyHandle(),
        .name = .none,
        .scope = .none,
        .required_arity = 0,
        .optional_arity = 0,
        .optional_values = .none,
        .has_args_parameter = false,
        .is_method = false,
        .cache_id = Heap.nextCacheId(),
    });

    return new_interp;
}

pub fn deinit(interp: *Interp) void {
    interp.result.decrRefCount();
    interp.stack_trace.decrOptional();
    interp.pending_error_code.decrOptional();
    interp.unknown_str.decrRefCount();
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

pub fn getBoolean(interp: *Interp, handle: *Handle) !bool {
    try interp.wrapShimmerFn(handle, objutil.shimmerToBoolean);
    return handle.peek().body.bool.data;
}

/// Shimmers a handle to a dict, updating it in place if a duplicate was
/// created. Converts errors to EvalError via the interpreter result.
pub fn shimmerToDict(interp: *Interp, handle: *Handle) !void {
    var det: objutil.ErrorDetails = undefined;
    var new_handle: OptionalHandle = .none;
    try wrapError(interp, &det, objutil.shimmerToDict(&det, handle.*, &new_handle));
    handle.swapIfNew(new_handle);
}

/// Shimmers a handle to a list, updating it in place if a duplicate was
/// created. Converts errors to EvalError via the interpreter result.
pub fn shimmerToList(interp: *Interp, handle: *Handle) !void {
    var det: objutil.ErrorDetails = undefined;
    var new_handle: OptionalHandle = .none;
    try wrapError(interp, &det, objutil.shimmerToList(&det, handle.*, &new_handle));
    handle.swapIfNew(new_handle);
}

pub fn getListLength(interp: *Interp, handle: *Handle) !u32 {
    try interp.shimmerToList(handle);
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
    var det: objutil.ErrorDetails = undefined;
    try interp.wrapError(&det, interp.setVariableInner(&det, interp.currentCallFrameIndex(), name.*, obj));
}

pub fn setVariableSilent(interp: *Interp, name: *Handle, handle: Handle) !void {
    var new_name: OptionalHandle = .none;
    try Heap.ensureShimmerableOrDup(name.*, &new_name);
    name.swapIfNew(new_name);

    const handle_to_obj = handle.dupOrRef();
    try interp.setVariableInner(null, interp.currentCallFrameIndex(), name.*, handle_to_obj);
}

pub fn setVariableTo(interp: *Interp, name: *Handle, handle: Handle) !void {
    var new_name: OptionalHandle = .none;
    try Heap.ensureShimmerableOrDup(name.*, &new_name);
    name.swapIfNew(new_name);

    const handle_to_obj = handle.dupOrRef();
    var det: objutil.ErrorDetails = undefined;
    try interp.wrapError(&det, interp.setVariableInner(
        &det,
        interp.currentCallFrameIndex(),
        name.*,
        handle_to_obj,
    ));
}

pub fn getVariable(interp: *Interp, provided_name: *Handle) !OptionalHandle {
    var new_name: OptionalHandle = .none;
    try Heap.ensureShimmerableOrDup(provided_name.*, &new_name);
    provided_name.swapIfNew(new_name);

    const value = interp.getVariableInner(null, interp.currentCallFrameIndex(), provided_name.*) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.VariableNotFound => return .none,
        error.BadDict => {
            // We normally don't capture the error message, but in this case we want the error,
            // so we'll just rerun it, this time with `det`.
            var det: objutil.ErrorDetails = undefined;
            _ = interp.getVariableInner(&det, interp.currentCallFrameIndex(), provided_name.*) catch |inner_err| switch (inner_err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.BadDict => {},
                else => unreachable,
            };
            interp.setResultOwning(det.message);
            return error.EvalError;
        },
    };
    return value.toOptional();
}

pub fn getVariableOrError(interp: *Interp, name: *Handle) !Handle {
    try interp.ensureShimmerable(name);
    var det: objutil.ErrorDetails = undefined;
    const var_value = try interp.wrapError(&det, interp.getVariableInner(&det, interp.currentCallFrameIndex(), name.*));
    return var_value;
}

pub fn unsetVariable(interp: *Interp, name: *Handle) !void {
    try interp.ensureShimmerable(name);
    var det: objutil.ErrorDetails = undefined;
    try interp.wrapError(&det, interp.unsetVariableInner(&det, interp.currentCallFrameIndex(), name.*));
}

pub fn unsetVariableSilent(interp: *Interp, name: *Handle) !void {
    try interp.ensureShimmerable(name);
    try interp.unsetVariableInner(null, interp.currentCallFrameIndex(), name.*);
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
    var new_dict: OptionalHandle = .none;
    const result = try interp.wrapError(&det, objutil.dictLookupRecursively(&det, dict.*, &new_dict, keys));
    dict.swapIfNew(new_dict);
    return result;
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
    var new_dict: OptionalHandle = .none;
    const put_result = try interp.wrapError(&det, objutil.dictPutRecursively(
        &det,
        dict.*,
        &new_dict,
        keys,
        value.dupOrRef(),
    ));
    dict.swapIfNew(new_dict);
    return put_result;
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
    const heap = try Heap.testStart(testing.allocator, testing.io);
    var interp = try Interp.init();
    defer interp.deinit();

    var dict = try objutil.newDictInner(heap, &.{});
    defer dict.decrRefCount();
    var key_foo = try objutil.newStringInner(heap, "foo");
    defer key_foo.decrRefCount();
    var key_bar = try objutil.newStringInner(heap, "bar");
    defer key_bar.decrRefCount();
    var key_baz = try objutil.newStringInner(heap, "baz");
    defer key_baz.decrRefCount();
    const value_qux = try objutil.newStringInner(heap, "qux");
    defer value_qux.decrRefCount();

    _ = try interp.putDictValueRecursively(&dict, &[_]Handle{ key_foo, key_bar, key_baz }, value_qux);
    try testing.expectEqualStrings("foo {bar {baz qux}}", try dict.getString());

    // Try taking ownership of one of the intermediate dictionaries.
    const to_take = (try interp.getDictValueRecursively(&dict, &.{ key_foo, key_bar })).toHandle().?;

    // See if setting still works correctly.
    _ = try interp.putDictValueRecursively(&dict, &.{ key_foo, key_bar, key_baz }, value_qux);
    try testing.expectEqual(1, to_take.debugRefCount());

    // Let's try some very cursed aliasing.
    _ = try interp.putDictValueRecursively(&dict, &.{ key_foo, key_bar }, objutil.dictItem(dict, 0));
    try testing.expectEqualStrings("foo {bar foo}", try dict.getString());

    const value_result = (try interp.getDictValueRecursively(&dict, &.{ key_foo, key_bar })).toHandle().?;
    try testing.expectEqualStrings("foo", try value_result.getString());
}

fn testRecursiveDictRemoval(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    const heap = try Heap.testStart(ta, testing.io);
    // var interp = try Interp.init();
    // defer interp.deinit();
    _ = heap;

    // var dict = try objutil.newDict(heap, &.{});
    // defer dict.decrRefCount();
    // var key_foo = try objutil.newString(heap, "foo");
    // defer key_foo.decrRefCount();
    // var key_bar = try objutil.newString(heap, "bar");
    // defer key_bar.decrRefCount();
    // var key_baz = try objutil.newString(heap, "baz");
    // defer key_baz.decrRefCount();
    // const value_qux = try objutil.newString(heap, "qux");
    // defer value_qux.decrRefCount();

    // // Test 1: Remove a deeply nested value (3 levels).
    // _ = try interp.putDictValueRecursively(&dict, &.{ key_foo, key_bar, key_baz }, value_qux);

    // try testing.expectEqualStrings("foo {bar {baz qux}}", try dict.getString());
    // var did_remove = try interp.removeDictValueRecursively(&dict, &.{ key_foo, key_bar, key_baz });
    // try testing.expect(did_remove);
    // try testing.expectEqualStrings("foo {bar {}}", try dict.getString());

    // // Test 2: Try to remove the same key again (should return false).
    // did_remove = try interp.removeDictValueRecursively(&dict, &.{ key_foo, key_bar, key_baz });
    // try testing.expect(!did_remove);
    // try testing.expectEqualStrings("foo {bar {}}", try dict.getString());

    // // Test 3: Remove a non-existent key from an existing intermediate dict.
    // did_remove = try interp.removeDictValueRecursively(&dict, &.{ key_foo, key_bar, key_foo });
    // try testing.expect(!did_remove);
    // try testing.expectEqualStrings("foo {bar {}}", try dict.getString());

    // // Test 4: Remove from a non-existent intermediate dict.
    // try memutil.expectErrorOrOom(
    //     error.EvalError,
    //     interp.removeDictValueRecursively(&dict, &.{ key_bar, key_baz, key_foo }),
    // );
    // try testing.expectEqualStrings(
    //     \\key "bar" not known in dictionary "foo {bar {}}"
    // , try interp.result.getString());
    // try testing.expectEqualStrings("foo {bar {}}", try dict.getString());

    // // Test 5: Single-level removal (base case).
    // did_remove = try interp.removeDictValueRecursively(&dict, &.{key_foo});
    // try testing.expect(did_remove);
    // try testing.expectEqualStrings("", try dict.getString());

    // // Test 6: Two-level removal.
    // _ = try interp.putDictValueRecursively(&dict, &.{ key_foo, key_bar }, value_qux);
    // try testing.expectEqualStrings("foo {bar qux}", try dict.getString());
    // did_remove = try interp.removeDictValueRecursively(&dict, &.{ key_foo, key_bar });
    // try testing.expect(did_remove);
    // try testing.expectEqualStrings("foo {}", try dict.getString());

    // // Test 7: Removal when intermediate dict is shared (copy-on-write).
    // var interm_test_dict = try objutil.newDict(heap, &.{});
    // defer interm_test_dict.decrRefCount();
    // _ = try interp.putDictValueRecursively(&interm_test_dict, &.{ key_foo, key_bar, key_baz }, value_qux);
    // _ = try interp.putDictValueRecursively(&interm_test_dict, &.{ key_foo, key_bar, key_foo }, value_qux);

    // // Borrow the intermediate dict.
    // const intermediate = (try interp.getDictValueRecursively(&interm_test_dict, &.{ key_foo, key_bar })).toHandle().?;
    // intermediate.incrRefCount();
    // defer intermediate.decrRefCount();

    // const initial_refcount = intermediate.debugRefCount();
    // try testing.expectEqualStrings("baz qux foo qux", try intermediate.getString());

    // // Remove from the nested dict while it's owned elsewhere.
    // did_remove = try interp.removeDictValueRecursively(&interm_test_dict, &.{ key_foo, key_bar, key_baz });
    // try testing.expect(did_remove);

    // // The intermediate dict we own should be unchanged (copy-on-write).
    // try testing.expectEqualStrings("baz qux foo qux", try intermediate.getString());
    // // But the main dict should have a new copy without 'baz'.
    // const foo_bar_result = (try interp.getDictValueRecursively(&interm_test_dict, &.{ key_foo, key_bar })).toHandle().?;
    // try testing.expectEqualStrings("foo qux", try foo_bar_result.getString());
    // // Reference count should drop by 1 since the parent no longer references it.
    // try testing.expectEqual(initial_refcount - 1, intermediate.debugRefCount());

    // // Test 8: Remove multiple items from a nested dict.
    // dict.swap(try objutil.newDict(heap, &.{}));
    // _ = try interp.putDictValueRecursively(&dict, &.{ key_foo, key_bar }, value_qux);
    // _ = try interp.putDictValueRecursively(&dict, &.{ key_foo, key_baz }, value_qux);
    // try testing.expectEqualStrings("foo {bar qux baz qux}", try dict.getString());
    // did_remove = try interp.removeDictValueRecursively(&dict, &.{ key_foo, key_bar });
    // try testing.expect(did_remove);
    // try testing.expectEqualStrings("foo {baz qux}", try dict.getString());
    // did_remove = try interp.removeDictValueRecursively(&dict, &.{ key_foo, key_baz });
    // try testing.expect(did_remove);
    // try testing.expectEqualStrings("foo {}", try dict.getString());
}

test "recursive dict removal" {
    try testing.checkAllAllocationFailures(testing.allocator, testRecursiveDictRemoval, .{});
}

pub fn testRunScript(interp: *Interp, script: []const u8) !Handle {
    var script_handle = try objutil.newString(script);
    defer script_handle.decrRefCount();
    try interp.evalObject(script_handle);
    return interp.result;
}

pub fn testExpectScriptResult(interp: *Interp, expected: []const u8, script: []const u8) !void {
    const result = testRunScript(interp, script);
    if (result) |success| {
        try testing.expectEqualStrings(expected, try success.getString());
    } else |err| {
        std.debug.print("Test failed with zig error {} and error message \"{f}\"", .{ err, interp.result });
        return err;
    }
}

pub fn testExpectScriptError(interp: *Interp, expected_error: anyerror, expected_str: []const u8, script: []const u8) !void {
    if (testRunScript(interp, script)) |_| {
        return error.TestUnexpectedResult;
    } else |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        const error_str = try interp.result.getString();
        if (err == expected_error and std.mem.eql(u8, expected_str, error_str)) {
            // All good!
        } else {
            return error.TestUnexpectedResult;
        }
    }
}

pub fn checkSignal(interp: *Interp) bool {
    return interp.signal_depth > 0 and interp.signal != 0;
}

// Maps signal numbers to their interned name handle. Only includes signals
// available on the current platform.
const signal_name_map = blk: {
    const SIG = std.posix.SIG;
    const Entry = struct { num: u6, name: Heap.InternedString };
    const candidates = .{
        .{ "HUP", .SIGHUP },       .{ "INT", .SIGINT },   .{ "QUIT", .SIGQUIT },
        .{ "ILL", .SIGILL },       .{ "TRAP", .SIGTRAP }, .{ "ABRT", .SIGABRT },
        .{ "BUS", .SIGBUS },       .{ "FPE", .SIGFPE },   .{ "KILL", .SIGKILL },
        .{ "USR1", .SIGUSR1 },     .{ "SEGV", .SIGSEGV }, .{ "USR2", .SIGUSR2 },
        .{ "PIPE", .SIGPIPE },     .{ "ALRM", .SIGALRM }, .{ "TERM", .SIGTERM },
        .{ "CHLD", .SIGCHLD },     .{ "CONT", .SIGCONT }, .{ "STOP", .SIGSTOP },
        .{ "TSTP", .SIGTSTP },     .{ "TTIN", .SIGTTIN }, .{ "TTOU", .SIGTTOU },
        .{ "URG", .SIGURG },       .{ "XCPU", .SIGXCPU }, .{ "XFSZ", .SIGXFSZ },
        .{ "VTALRM", .SIGVTALRM }, .{ "PROF", .SIGPROF }, .{ "WINCH", .SIGWINCH },
        .{ "IO", .SIGIO },         .{ "PWR", .SIGPWR },   .{ "SYS", .SIGSYS },
    };
    var entries: []const Entry = &.{};
    for (candidates) |pair| {
        if (@hasDecl(SIG, pair[0])) {
            entries = entries ++ &[_]Entry{.{ .num = @field(SIG, pair[0]), .name = pair[1] }};
        }
    }
    break :blk entries;
};

/// Build a list of signal name strings for each signal bit set in `mask`.
pub fn signalMaskToList(mask: u64) !Handle {
    const list = try objutil.newListWithCapacity(@popCount(mask));
    errdefer list.decrRefCount();
    inline for (signal_name_map) |entry| {
        if (mask & (@as(u64, 1) << entry.num) != 0) {
            const str = Heap.local_heap.getInternedString(entry.name);
            objutil.listAppendAssumeCapacity(list, str.peek().*);
        }
    }
    return list;
}

pub fn nextRandomFloat(interp: *Interp) f64 {
    // https://stackoverflow.com/questions/46901022/how-to-convert-a-uint64-t-to-a-double-float-between-0-and-1-with-maximum-accurac
    const two63: u64 = 0x8000000000000000;
    const two64f = @as(f64, @bitCast(two63)) * 2.0;
    const as_float = @as(f64, @bitCast(interp.prng.next())) / two64f;
    return as_float;
}

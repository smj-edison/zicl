const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const Tokenizer = @import("Tokenizer.zig");
const Heap = @import("Heap.zig");
const Handle = Heap.Handle;
const OptionalHandle = Heap.OptionalHandle;
const objutil = @import("objutil.zig");
const memutil = @import("memutil.zig");

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

pub const CommandHashTable = std.StringArrayHashMapUnmanaged(NativeCommand);
pub const CommandFn = fn (interp: *Interp, args: []Handle) Error!void;
pub const CCommandFn = fn (interp: *Interp, argc: c_int, argv: [*]Handle) callconv(.c) c_int;

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
};

fn narrowError(err: anyerror) EvalError {
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

/// This always recalculates .variable. You probably should be using `ensureValidVariableType`.
/// Must be called with a heap-native variable name, so it can shimmer in place.
fn reshimmerToVariable(
    interp: *Interp,
    det: ?*objutil.ErrorDetails,
    var_call_frame: u32,
    name: Handle,
) error{ OutOfMemory, VariableNotFound }!void {
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
fn ensureValidVariableType(
    interp: *Interp,
    det: ?*objutil.ErrorDetails,
    var_call_frame: u32,
    name: Handle,
) error{ OutOfMemory, VariableNotFound }!void {
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
        .dict_sugar => unreachable,
        else => {
            // Fall through.
        },
    }

    try interp.reshimmerToVariable(det, var_call_frame, name);
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
pub fn setVariableInner(
    interp: *Interp,
    det: ?*objutil.ErrorDetails,
    call_frame_idx: u32,
    name: Handle,
    value: Heap.Object,
) error{ OutOfMemory, BadDict }!void {
    _ = det;
    // TODO PERF a lot of functions look the variable back up after setting it. We should probably
    // return the variable's new handle after setting it. After doing so, be sure to audit all
    // the call sites.

    var value_taken = false;
    errdefer if (!value_taken) {
        var value_mut = value;
        value_mut.deinitSingle(Heap.local_heap);
    };

    name.assert(name.getHeap() == Heap.local_heap);
    name.assert(name.canShimmer());

    if (interp.ensureValidVariableType(null, call_frame_idx, name)) {
        switch (name.tag()) {
            .dict_sugar => {
                const dict_sugar = name.peek().body.dict_sugar;
                const dict_name = name.getHeap().getHandle(dict_sugar.dict_name_index);
                const dict_path = name.getHeap().getHandle(dict_sugar.path_index);

                var resolved_dict = interp.getVariableInner(null, call_frame_idx, dict_name) catch unreachable;

                value_taken = true;
                const result = objutil.dictPutInner(resolved_dict, objutil.listItem(dict_path, 0), value) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => unreachable,
                };
                resolved_dict.swapIfNew(result.new_dict);

                try interp.setVariableInner(null, call_frame_idx, dict_name, resolved_dict.reference());
            },
            .cached_local_var => {
                const cached_var = &name.peek().body.cached_local_var;
                const var_value = Heap.local_heap.getHandle(cached_var.cached_index);
                if (var_value.tag() == .upvar_link) {
                    const upvar_link = var_value.peek().body.upvar_link;
                    // Set the value through the linked name in the linked frame.
                    try interp.setVariableInner(
                        null,
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
    }
}

/// Resolves to the variable's value. Must be called with a heap-native name.
pub fn getVariableInner(
    interp: *Interp,
    det: ?*objutil.ErrorDetails,
    call_frame_idx: u32,
    name: Handle,
) error{ OutOfMemory, VariableNotFound, BadDict }!Handle {
    try interp.ensureValidVariableType(det, call_frame_idx, name);

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
        .dict_sugar => unreachable,
        else => unreachable,
    }
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
};

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
    const closure_value = try objutil.newString(Heap.local_heap, bytes[8..]);
    defer closure_value.decrRefCount();

    const name_str = try objutil.newString(Heap.local_heap, "name");
    const impl_str = try objutil.newString(Heap.local_heap, "impl");
    const scope_str = try objutil.newString(Heap.local_heap, "scope");

    const name = try objutil.dictLookupFollowRefs(closure_value, name_str);
    const impl_raw = try objutil.dictLookupFollowRefs(closure_value, impl_str);
    const scope = try objutil.dictLookupFollowRefs(closure_value, scope_str);

    const args = objutil.listItem(impl_raw.toHandle().?, 0);
    const body = objutil.listItem(impl_raw.toHandle().?, 1);

    // Make sure args is a list.
    var args_new: OptionalHandle = .none;
    errdefer args_new.swapWithNone();
    objutil.shimmerToList(null, args, &args_new) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (det) |details| details.* = .{
                .message = try objutil.newStringFmt(Heap.local_heap, "closure args is not a valid list: \"{f}\"", .{args}),
            };
            return error.BadClosure;
        },
    };
    const args_list = args_new.orElse(args);

    const parsed_args = try parseClosureArgList(det, args_list);
    errdefer parsed_args.deinit();

    return .{
        .args = args_list.borrow(),
        .body = body.borrow(),
        .name = name.borrowOptional(),
        .scope = scope.borrowOptional(),
        .required_arity = parsed_args.required_arity,
        .optional_arity = parsed_args.optional_arity,
        .optional_values = parsed_args.optional_values,
        .has_args_parameter = parsed_args.has_args_parameter,
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
    const optional_values: ?Handle = null;
    errdefer if (optional_values) |val| val.decrRefCount();
    var args_parameter_found = false;
    var required_arity: u32 = 0;
    const optional_arity: u32 = 0;

    for (0..arg_list_len) |i| {
        if (args_parameter_found) {
            if (det) |details| details.* = .{
                .message = try objutil.newString(Heap.local_heap, "parameter after 'args' not allowed"),
            };
            return error.BadClosure;
        }

        const arg_raw = objutil.listItem(args, @intCast(i));
        var arg_new: OptionalHandle = .none;
        defer arg_new.swapWithNone();
        objutil.shimmerToList(null, arg_raw, &arg_new) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
        const arg = arg_new.orElse(arg_raw);
        const arg_len = objutil.listLengthRaw(arg);

        assert(arg_len == 1);
        if (optional_values != null) unreachable;

        const arg_name = try objutil.listItem(arg, 0).getString();
        if (std.mem.eql(u8, arg_name, "args")) args_parameter_found = true;

        required_arity += 1;
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
        unreachable;
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

    unreachable;
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
    const bytes_handle = try objutil.newString(Heap.local_heap, bytes);
    interp.setResultOwning(bytes_handle);
}

pub fn setResultInterned(interp: *Interp, interned: Heap.InternedString) void {
    interp.setResultOwning(Heap.local_heap.getInternedString(interned));
}

pub fn setResultFormatted(interp: *Interp, comptime fmt: []const u8, args: anytype) !void {
    const fmt_handle = try objutil.newStringFmt(Heap.local_heap, fmt, args);

    interp.setResultOwning(fmt_handle);
}

pub fn setEmptyResult(interp: *Interp) void {
    interp.freeLastResult();
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

fn currentCallFrameIndex(interp: *Interp) u32 {
    return @intCast(interp.call_frames.items.len - 1);
}

fn currentCallFrame(interp: *Interp) *CallFrame {
    return &interp.call_frames.items[interp.currentCallFrameIndex()];
}

/// Returns a dict containing this call frame's variables.
pub fn captureScope(interp: *Interp, det: ?*objutil.ErrorDetails, call_frame_idx: u32) !Handle {
    _ = det;
    const frame = &interp.call_frames.items[call_frame_idx];
    return frame.variables.borrow();
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
};

fn currentEvalFrameIndex(interp: *Interp) u32 {
    return @intCast(interp.eval_frames.items.len - 1);
}

fn currentEvalFrame(interp: *Interp) *EvalFrame {
    return &interp.eval_frames.items[interp.currentEvalFrameIndex()];
}

fn pushCallFrame(interp: *Interp, parent: ?u32, args: []Handle, signature: Heap.Closure) !u32 {
    const vars_handle = try objutil.newDict(Heap.local_heap, &.{});
    errdefer vars_handle.decrRefCount();
    const borrowed_signature = signature.borrow();
    errdefer borrowed_signature.deinit();

    if (signature.scope.toHandle()) |scope| {
        // Safe since vars_handle is freshly allocated.
        vars_handle.getDictExtraData().parent_link = scope.borrow().toOptional();
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

fn pushEvalFrame(interp: *Interp) !u32 {
    try interp.eval_frames.append(Heap.global_gpa, .{
        .call_frame = interp.currentCallFrameIndex(),
        .args = &.{},
        .current_line = 1,
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
        if (interp.substituteOneToken(tag, objutil.listItemFollowRefs(value_list, @intCast(value_index)))) |new_value| {
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
        error.VariableNotFound, error.BadDict => {
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

    try interp.callNative(command_or_closure.command, args);
}

fn exprResultAsBool(interp: *Interp, result: *ExprResult) !bool {
    _ = interp;
    _ = result;
    return true;
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
        interp.currentEvalFrame().current_line = command_info.line;

        // This is not always the same as which word token we're on, as argument expansion
        // may write multiple arguments from one word.
        var args_written: usize = 0;
        var args = try args_alloc.alloc(Handle, command_info.arg_count);
        defer args_alloc.free(args);
        defer for (args[0..args_written]) |arg| arg.decrRefCount();

        // Populate the arguments by looping through each word of the command and
        // substituting.
        var word_token_i: u32 = command_token_i;
        for (0..command_info.arg_count) |_| {
            var word_parts: u32 = 1;
            if (tags[word_token_i] == .start_of_word) {
                word_parts = @intCast(values[word_token_i].body.integer);
                word_token_i += 1;
            }
            assert(word_parts == 1);

            const resultant_word = try interp.substituteOneToken(tags[word_token_i], objutil.listItem(parsed.values, word_token_i));
            word_token_i += 1;

            args[args_written] = resultant_word;
            args_written += 1;
        }

        command_token_i = word_token_i;

        // Now that we've populated the arguments for this command, we'll go ahead and run it.
        std.debug.print("Calling command: ", .{});
        for (args) |arg| std.debug.print("{{{s}}} ", .{try arg.getString()});
        std.debug.print("\n", .{});

        // `args` is stored in the eval frame so `buildErrorStack` can read it if this command
        // fails. The slice is still live at that point (before the loop body `defer` frees it),
        // mirroring Jim's `evalFrame->argv` pattern.
        interp.currentEvalFrame().args = args[0..args_written];
        defer interp.currentEvalFrame().args = &.{};

        const cmd_result = interp.invokeCommand(interp.currentCallFrameIndex(), args);

        // TODO actually check for signals.
        if (false) {
            return error.Signal;
        } else {
            cmd_result catch unreachable;
        }
    }
}

pub fn evalObject(interp: *Interp, script: Handle) EvalError!void {
    const cache_key = @as(u256, interp.currentCallFrame().signature.cache_id) ^ try script.getHash();
    return evalObjectInner(interp, script, cache_key);
}

pub fn init() !Interp {
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

fn testRunScript(interp: *Interp, script: []const u8) !Handle {
    var script_handle = try objutil.newString(Heap.local_heap, script);
    defer script_handle.decrRefCount();
    try interp.evalObject(script_handle);
    return interp.result;
}

pub fn testExpectScriptResult(interp: *Interp, expected: []const u8, script: []const u8) !void {
    try testing.expectEqualStrings(expected, try (try testRunScript(interp, script)).getString());
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

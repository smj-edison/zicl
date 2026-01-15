const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const Tokenizer = @import("Tokenizer.zig");
const Heap = @import("Heap.zig");
const Handle = Heap.Handle;
const OptionalHandle = Heap.OptionalHandle;
const object = @import("object.zig");
const memutil = @import("memutil.zig");
const expr_parse = @import("expr_parse.zig");

const Interp = @This();

heap: *Heap,
gpa: std.mem.Allocator,

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
/// when it overflows it'll scan through the heap and invalidate all
/// variables.
current_call_epoch: u31,
current_procedure_epoch: u31,
commands: CommandHashTable,
namespace: ?Handle,

evaluating_safe_expr: bool,
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

pub const CommandFn = fn (interp: *Interp, args: []Handle) Error!void;
pub const CCommandFn = fn (interp: *Interp, argc: c_int, argv: [*]Handle) c_int;

pub const Error = std.mem.Allocator.Error || error{
    EvaluatingSafeExpression,
    EvalError,
    Break,
    Continue,
    Signal,
    PropagateResult,
    VariableNotFound,
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
pub fn wrapError(interp: *Interp, det: *object.ErrorDetails, result: anytype) wrapErrorDetailsReturnType(@TypeOf(result)) {
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

fn variableNotFoundError(det: ?*object.ErrorDetails, var_name: []const u8) !void {
    if (det) |details| details.* = .{
        .message = try object.newStringFmt(Heap.local_heap, "can't read \"{s}\": no such variable", .{var_name}),
    };

    return error.VariableNotFound;
}

const VariableInfo = struct {
    target_index: u32,
    call_frame_idx: u32,
};

/// Resolves to the variable's value, if any. If `var_name` starts with `::` it'll do a global
/// lookup, else it'll lookup in `var_call_frame`.
fn resolveVariable(interp: *Interp, var_call_frame: u32, var_name: [:0]const u8) ?VariableInfo {
    // This call frame is separate than `var_call_frame`, since if the variable is global,
    // it won't be in `var_call_frame`. This gets set to whichever call frame ends up
    // being correct.
    var call_frame_idx: u32 = undefined;
    // The resolved variable value, if any.
    var var_value: ?Handle = null;

    // No need to check slice length since it's null terminated.
    if (var_name[0] == ':' and var_name[1] == ':') {
        call_frame_idx = 0; // Global frame.

        // Skip as many colons as are present to match tcl behavior.
        var trimmed_var_name = var_name;
        while (trimmed_var_name[0] == ':') trimmed_var_name = trimmed_var_name[1..];

        const var_dict = interp.call_frames.items[call_frame_idx].variables;

        {
            interp.heap.setTempObjectString(trimmed_var_name);
            defer interp.heap.resetTempObject();
            // Can't fail since we know a string exists for it (the string in question is the temp object
            // we just initialized).
            var_value = object.dictLookupFollowRefs(var_dict, interp.heap.tempObject()) catch unreachable;
        }

        // Global scope doesn't have statics.
    } else {
        call_frame_idx = var_call_frame; // Use provided call frame.

        const var_dict = interp.call_frames.items[call_frame_idx].variables;
        const statics_dict = interp.call_frames.items[call_frame_idx].signature.statics;

        // Check the variables dictionary.
        interp.heap.setTempObjectString(var_name);
        // Can't fail since we know a string exists for it (the temp string we just set).
        var_value = object.dictLookupFollowRefs(var_dict, interp.heap.tempObject()) catch unreachable;
        interp.heap.resetTempObject();

        if (var_value == null) {
            // Wasn't in the variables, maybe it's in the statics dictionary instead?
            if (statics_dict) |dict| {
                interp.heap.setTempObjectString(var_name);
                defer interp.heap.resetTempObject();
                // Can't fail since we know a string exists for it (the temp string we just set).
                var_value = object.dictLookupFollowRefs(dict, interp.heap.tempObject()) catch unreachable;
            }
        }
    }

    if (var_value) |val| {
        assert(val.heap == interp.heap.heapId());

        return .{
            .target_index = val.index,
            .call_frame_idx = call_frame_idx,
        };
    }

    return null;
}

/// This always recalculates .variable. You probably should be using `ensureValidVariableType`.
/// Must be called with a heap-native variable name, so it can shimmer in place.
fn reshimmerToVariable(interp: *Interp, det: ?*object.ErrorDetails, call_frame_idx: u32, name: Handle) !void {
    name.assert(name.getHeap() == interp.heap and name.canShimmer());

    const var_name = try Heap.getString(name);
    const call_frame = interp.call_frames.items[call_frame_idx];

    if (interp.resolveVariable(call_frame_idx, var_name)) |var_info| {
        // Free the old representation and set the new one.
        try name.prepareToShimmer();
        name.peek().tag = .variable;
        name.peek().body.variable = .{
            .call_epoch = call_frame.call_epoch,
            .index = var_info.target_index,
            .is_global = var_info.call_frame_idx == 0,
        };
    } else {
        return variableNotFoundError(det, var_name);
    }
}

/// Ensures that this is a valid variable, dict sugar, or upvar. If not, it'll shimmer it to whichever one applies.
/// Must be called with a heap-native variable name.
fn ensureValidVariableType(interp: *Interp, det: ?*object.ErrorDetails, call_frame_idx: u32, name: Handle) !void {
    const call_frame = interp.call_frames.items[call_frame_idx];

    const name_obj = name.peek();
    const name_heap = name.getHeap();
    const bytes = try Heap.getString(name);

    if (name_obj.tag == .variable) {
        // Fast case: if we're in the same epoch as last time,
        // we don't need to do anything.
        if (name_obj.body.variable.call_epoch == call_frame.call_epoch) {
            return;
        } else {
            // Need to re-resolve the variable in the current call frame.
            // Will be valid after this completes.
            try interp.reshimmerToVariable(det, call_frame_idx, name);
            return;
        }
    } else if (name_obj.tag == .upvar) {
        const upvar = &name_heap.getExtraData(name_obj.body.upvar).upvar;

        // Fast case is same as for .variable.
        if (upvar.call_frame_epoch == call_frame.call_epoch) {
            return;
        } else {
            // Need to look this back up.
            switch (upvar.name) {
                .dict_sugar => {
                    @panic("Dict sugar not implemented yet");
                },
                .normal => |name_index| {
                    // `bytes` is the name of the variable in the upvar's scope, but we want the name
                    // of the variable in the original scope. Case in point: if we ran `upvar upper here`,
                    // `bytes` would contain "here", while `original_name` would contain "upper".
                    const original_name = try Heap.getString(interp.heap.getHandle(name_index));
                    // Be sure to look it up in the upvar's call frame.
                    if (interp.resolveVariable(upvar.call_frame_idx, original_name)) |upvar_target| {
                        upvar.index = upvar_target.target_index;
                        return;
                    } else {
                        return variableNotFoundError(det, bytes);
                    }
                },
            }
        }
    } else if (name_obj.tag == .dict_subst) {
        @panic("Dict sugar not implemented yet");
    } else {
        // We don't know whether this is a normal variable or dict sugar yet.
        const var_name = try Heap.getString(name);
        if (var_name.len >= 2 and var_name[0] == '(' and var_name[var_name.len - 1] == ')') {
            @panic("Dict sugar not implemented yet");
            // name_obj.tag = .dict_subst;
        } else {
            try interp.reshimmerToVariable(det, call_frame_idx, name);
        }
    }
}

// Must be called with a heap-native variable name.
fn createVariable(interp: *Interp, call_frame_idx: u32, name: Handle, value: Heap.Object) !void {
    assert(name.getHeap() == interp.heap and name.canShimmer());

    const call_frame = &interp.call_frames.items[call_frame_idx];
    const name_bytes = try Heap.getString(name);

    if (name_bytes.len >= 2 and name_bytes[0] == ':' and name_bytes[1] == ':') {
        var trimmed = name_bytes;
        // Trim all preceding colons to match tcl behavior.
        while (trimmed[0] == ':') trimmed = trimmed[1..];

        // Add variable.
        const value_location = blk: {
            interp.heap.setTempObjectString(trimmed);
            defer interp.heap.resetTempObject();
            const put_result = try object.dictPutInner(interp.call_frames.items[0].variables, interp.heap.tempObject(), value);
            interp.call_frames.items[0].variables.swapIfNew(put_result.new_dict);
            break :blk put_result.new_value;
        };

        try name.prepareToShimmer();
        name.peek().tag = .variable;
        name.peek().body.variable = .{
            .call_epoch = call_frame.call_epoch,
            .index = value_location.index,
            .is_global = true,
        };
    } else {
        // Add variable.
        const put_result = try object.dictPutInner(call_frame.variables, name, value);
        call_frame.variables.swapIfNew(put_result.new_dict);

        name.peek().tag = .variable;
        name.peek().body.variable = .{
            .call_epoch = call_frame.call_epoch,
            .index = put_result.new_value.index,
            .is_global = false,
        };
    }
}

/// Must be called with a heap-native name. Always takes ownership of `value`, even in error cases.
fn setVariableImpl(interp: *Interp, call_frame_idx: u32, name: Handle, value: Heap.Object) !void {
    if (interp.ensureValidVariableType(null, call_frame_idx, name)) {
        switch (name.peek().tag) {
            .dict_subst => @panic("Dict sugar not implemented"),
            .variable => {
                const variable = &name.peek().body.variable;
                const var_call_frame_idx = if (variable.is_global) 0 else call_frame_idx;
                var var_call_frame = &interp.call_frames.items[var_call_frame_idx];

                const old_variables_handle = var_call_frame.variables; // Copy
                const new_value_handle = blk: {
                    const put_result = try object.dictPutInner(var_call_frame.variables, name, value);
                    var_call_frame.variables.swapIfNew(put_result.new_dict);
                    break :blk object.followIfRef(put_result.new_value);
                };
                // Did the dict change locations? If so, all cached lookups are now invalid.
                const did_dict_move = old_variables_handle != var_call_frame.variables;
                // Even if the dict didn't move, the variable may have. If so, we still
                // need to bump the epoch.
                const did_variable_move = variable.index != new_value_handle.index;
                if (did_dict_move or did_variable_move) {
                    var_call_frame.call_epoch = interp.nextCallEpoch();
                }

                variable.* = .{
                    .call_epoch = var_call_frame.call_epoch,
                    // The cached index is relative to the variables dict.
                    .index = new_value_handle.index - var_call_frame.variables.index,
                    .is_global = variable.is_global,
                };
            },
            .upvar => {
                const upvar = &interp.heap.getExtraData(name.peek().body.upvar).upvar;

                switch (upvar.name) {
                    .dict_sugar => @panic("Dict sugar not implemented"),
                    .normal => |upvar_name_idx| {
                        const name_handle = interp.heap.getHandle(upvar_name_idx);

                        if (upvar.index == Heap.null_object_idx) {
                            // The upvar doesn't target anything, which means we need to create a variable
                            // in its target's scope.
                            try interp.createVariable(upvar.call_frame_idx, name_handle, value);
                            assert(name_handle.peek().tag == .variable);
                            const variable = name_handle.peek().body.variable;

                            upvar.* = .{
                                .call_frame_epoch = variable.call_epoch,
                                .call_frame_idx = upvar.call_frame_idx,
                                .index = variable.index,
                                .name = .{ .normal = upvar_name_idx },
                            };
                        } else {
                            // Normal case: upvar has a target.
                            try interp.setVariableImpl(upvar.call_frame_idx, name_handle, value);
                            assert(name_handle.peek().tag == .variable);
                            const variable = name_handle.peek().body.variable;

                            upvar.* = .{
                                .call_frame_epoch = variable.call_epoch,
                                .call_frame_idx = upvar.call_frame_idx,
                                .index = variable.index,
                                .name = .{ .normal = upvar_name_idx },
                            };
                        }
                    },
                }
            },
            else => unreachable,
        }
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.VariableNotFound => try createVariable(interp, call_frame_idx, name, value),
    }
}

/// Resolves to the variable's value. Must be called with a heap-native name.
pub fn getVariableImpl(interp: *Interp, det: ?*object.ErrorDetails, name: Handle) !Handle {
    if (interp.evaluating_safe_expr) return error.EvaluatingSafeExpression;

    try interp.ensureValidVariableType(det, interp.currentCallFrameIndex(), name);

    const name_obj = name.peek();
    const name_heap = name.getHeap();

    switch (name_obj.tag) {
        .variable => {
            return name_heap.getHandle(name_obj.body.variable.index);
        },
        .upvar => {
            return name_heap.getHandle(name_heap.getExtraData(name_obj.body.upvar).upvar.index);
        },
        .dict_subst => {
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

    try testing.expectEqual(null, interp.resolveVariable(0, "foo"));
    var foo = try object.newString(heap, "foo");
    defer foo.decrRefCount();
    const value = try object.newString(heap, "value");
    defer value.decrRefCount();
    foo.swapIfNew(try interp.setVariableTo(foo, value));

    const lookup_value = interp.resolveVariable(0, "foo").?.target_index;
    try testing.expectEqualStrings("value", try Heap.getString(Heap.local_heap.getHandle(lookup_value)));
}

test "variables" {
    try testing.checkAllAllocationFailures(testing.allocator, testVariables, .{});
}

const ProcedureSignature = struct {
    /// Handle to the argument list of the procedure.
    args: Handle,
    /// Handle to the ScriptId object.
    body: Handle,
    /// Handle to the statics dictionary.
    statics: ?Handle,
    /// Required number of arguments.
    required_arity: u32,
    /// Optional number of arguments.
    optional_arity: u32,
    /// Values of optional arguments, if any.
    optional_values: ?Handle,
    /// Whether `args` is provided as an argument name. `args`, if present, is always
    /// the last argument name.
    has_args_parameter: bool,

    pub fn borrow(sign: ProcedureSignature) !ProcedureSignature {
        sign.args.incrRefCount();
        errdefer sign.args.decrRefCount();
        sign.body.incrRefCount();
        errdefer sign.body.decrRefCount();
        if (sign.statics) |val| val.incrRefCount();
        errdefer if (sign.statics) |val| val.decrRefCount();
        if (sign.optional_values) |val| val.incrRefCount();
        errdefer if (sign.optional_values) |val| val.decrRefCount();

        return .{
            .args = sign.args,
            .body = sign.body,
            .statics = sign.statics,
            .required_arity = sign.required_arity,
            .optional_arity = sign.optional_arity,
            .optional_values = sign.optional_values,
            .has_args_parameter = sign.has_args_parameter,
        };
    }

    pub fn deinit(signature: ProcedureSignature) void {
        signature.args.decrRefCount();
        signature.body.decrRefCount();
        if (signature.statics) |statics| statics.decrRefCount();
        if (signature.optional_values) |values| values.decrRefCount();
    }
};

pub const Command = struct {
    pub const NativeCommand = struct {
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

    namespace: ?Handle,
    call_info: union(enum) {
        native: NativeCommand,
        tcl: struct {
            signature: ProcedureSignature,
        },
    },

    pub fn deinit(command: *Command) void {
        if (command.namespace) |namespace| namespace.decrRefCount();

        switch (command.call_info) {
            .tcl => |val| val.signature.deinit(),
            .native => {},
        }
    }

    /// Returns a string containing all the usage information. Allocates the string
    /// onto the arena. Produces something like `cmd ...`, or `cmd arg1 arg2 ?arg3?`
    pub fn getUsageInfo(command: *Command, arena: std.mem.Allocator, command_name: []const u8) ![]const u8 {
        var aw = std.Io.Writer.Allocating.init(arena);
        defer aw.deinit();

        // Write command name.
        aw.writer.writeAll(command_name) catch return error.OutOfMemory;

        switch (command.call_info) {
            .tcl => |call_info| {
                const args_list = call_info.signature.args;
                const args_len = object.listLengthRaw(args_list);

                for (0..args_len) |i| {
                    const arg = object.listItem(args_list, @intCast(i));

                    aw.writer.writeAll(" ") catch return error.OutOfMemory;

                    if (i == args_len - 1 and call_info.signature.has_args_parameter) {
                        // Handle `args` paramater.
                        aw.writer.writeAll("?arg ...?") catch return error.OutOfMemory;
                    } else {
                        // If this argument is a list, it means that it has a default value.
                        if (arg.peek().tag == .list) {
                            assert(object.listLengthRaw(arg) == 2);

                            aw.writer.print("?{s}?", .{try Heap.getString(arg)}) catch return error.OutOfMemory;
                        } else {
                            aw.writer.writeAll(try Heap.getString(arg)) catch return error.OutOfMemory;
                        }
                    }
                }

                return aw.toOwnedSlice();
            },
            .native => |call_info| {
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

pub const CommandHashTable = std.StringArrayHashMapUnmanaged(Command);

fn wrongArgumentCountError(det: ?*object.ErrorDetails, command_usage: []const u8) !void {
    if (det) |details| details.* = .{
        .message = try object.newStringFmt(Heap.local_heap, "wrong # args: should be \"{s}\"", .{command_usage}),
    };

    return Error.WrongUsage;
}

/// Takes ownership of name.
pub fn createCommand(interp: *Interp, name: []const u8, command: Command) !void {
    // TODO make sure to check interp->local if we end up needing it in our impl
    var old_command = try interp.commands.fetchPut(interp.gpa, name, command);
    if (old_command) |*val| val.value.deinit();

    // FIXME need to handle this if it wraps around.
    interp.current_procedure_epoch += 1;
}

pub fn registerCommand(interp: *Interp, name: []const u8, details: Command.NativeCommand) !void {
    const name_duped = try interp.gpa.dupe(u8, name);
    errdefer interp.gpa.free(name_duped);
    try interp.commands.put(interp.gpa, name_duped, .{ .namespace = null, .call_info = .{ .native = details } });
}

pub fn callProcedure(interp: *Interp, command: *Command, args: []Handle) !void {
    const signature = &command.call_info.tcl.signature;
    const arg_count = args.len - 1; // - 1 to skip command name as first argument.

    // Check arity.
    if (arg_count < signature.required_arity or
        (!signature.has_args_parameter and arg_count > signature.required_arity + signature.optional_arity))
    {
        // Wrong argument count, error accordingly.
        var sf = std.heap.stackFallback(64, interp.gpa);
        const scratch = sf.get();
        const command_name = try Heap.getString(args[0]);
        const command_usage = try command.getUsageInfo(scratch, command_name);
        defer scratch.free(command_usage);
        var det: object.ErrorDetails = undefined;
        return interp.wrapError(&det, wrongArgumentCountError(&det, command_usage));
    }

    // Check for infinite recursion.
    if (interp.currentCallFrame().level >= interp.max_call_depth) {
        try interp.setResultString("Too many nested calls. Infinite recursion?");
        return Error.InfiniteRecursion;
    }

    const parent_idx = interp.currentCallFrameIndex();
    const call_frame_idx = try interp.pushCallFrame(parent_idx, args, signature.*);
    defer interp.call_frames.pop().?.deinit();

    // Populate call frame.

    // Where we are in the arguments that this was called with.
    var called_idx: usize = 1;
    // Where we are in the signature.
    var signature_idx: u32 = 0;
    const signature_len = object.listLengthRaw(signature.args);

    while (signature_idx < signature_len) : (signature_idx += 1) {
        const var_name = object.listItem(signature.args, signature_idx);

        // Are we at the last argument? If so, is it `args`?
        if (signature_idx == signature_len - 1 and signature.has_args_parameter) {
            // Assign remaining arguments to `args`.
            const list = try object.newList(args[called_idx..]);
            defer list.decrRefCount();
            try interp.setVariableImpl(call_frame_idx, var_name, list.reference());
        } else if (signature_idx > signature.required_arity) {
            // This is an optional argument.

            // Are there any remaining unassigned arguments?
            if (called_idx < args.len) {
                try interp.setVariableImpl(call_frame_idx, var_name, try interp.heap.dupOrReference(args[called_idx]));
                called_idx += 1;
            } else {
                // Else populate it with its default value.
                const default_value = object.listItem(signature.optional_values.?, signature_idx - signature.required_arity);
                try interp.setVariableImpl(call_frame_idx, var_name, try interp.heap.dupOrReference(default_value));
            }
        } else {
            try interp.setVariableImpl(call_frame_idx, var_name, try interp.heap.dupOrReference(args[called_idx]));
            called_idx += 1;
        }
    }

    // TODO implement trace

    var new_body: OptionalHandle = .none;
    try interp.evalObject(signature.body, &new_body);
    signature.body.swapIfNew(new_body);
}

fn callNative(interp: *Interp, command: *Command, args: []Handle) !void {
    const signature = command.call_info.native;

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

        try command.call_info.native.to_call(interp, args);
        return;
    }

    var sf = std.heap.stackFallback(64, interp.gpa);
    const scratch = sf.get();
    const command_name = try Heap.getString(args[0]);
    const command_usage = try command.getUsageInfo(scratch, command_name);
    defer scratch.free(command_usage);
    var det: object.ErrorDetails = undefined;
    return interp.wrapError(&det, wrongArgumentCountError(&det, command_usage));
}

pub fn evalList(interp: *Interp, list: Handle) !void {
    _ = interp;
    _ = list;

    @panic("unimplemented");
}
fn freeLastResult(interp: *Interp) void {
    interp.result.decrRefCount();
    interp.result = interp.heap.emptyObject();
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
    interp.setResultOwning(try object.newInteger(interp.heap, value));
}

pub fn setResultString(interp: *Interp, bytes: []const u8) !void {
    interp.freeLastResult();
    const bytes_handle = try object.newString(interp.heap, bytes);

    setResult(interp, bytes_handle);
}

pub fn setResultFormatted(interp: *Interp, comptime fmt: []const u8, args: anytype) !void {
    interp.freeLastResult();
    const fmt_handle = try object.newStringFmt(interp.heap, fmt, args);

    setResult(interp, fmt_handle);
}

pub fn setEmptyResult(interp: *Interp) void {
    interp.freeLastResult();
    interp.result = interp.heap.emptyObject();
}

const VariableMap = std.StringHashMap(Handle);
/// Call frame.
const CallFrame = struct {
    /// Parent index.
    parent: ?u32,
    /// Level of the call frame. 0 = global.
    level: u32,
    /// Dictionary containing the frame's variables.
    variables: Handle,
    /// Arguments of the procedure call. Managed by creator.
    args: []Handle,
    /// Signature of the procedure that this is being called with.
    signature: ProcedureSignature,
    /// An object that contains a string with the current namespace. For example,
    /// it might contain "foo::bar", with that being the current namespace.
    namespace: ?Handle,
    /// Call epoch. Used to invalidate previous variable lookups. Can overflow,
    /// but when it overflows it'll scan the heap and reset all cached lookups.
    call_epoch: u31,
    /// Set this during evaluation to trigger a tailcall.
    tailcall: ?Tailcall,

    pub fn deinit(frame: *const CallFrame) void {
        // Args are managed externally, so we don't free them.
        if (frame.namespace) |namespace| namespace.decrRefCount();
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

fn nextCallEpoch(interp: *Interp) u31 {
    const epoch = interp.current_call_epoch;
    interp.current_call_epoch = std.math.add(u31, interp.current_call_epoch, 1) catch @panic("TODO handle overflow properly");
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

fn pushCallFrame(interp: *Interp, parent: ?u32, args: []Handle, signature: ProcedureSignature) !u32 {
    if (interp.namespace) |val| val.incrRefCount();
    errdefer if (interp.namespace) |ns| ns.decrRefCount();
    const vars_handle = try object.newDict(interp.heap, &.{});
    errdefer vars_handle.decrRefCount();
    const borrowed_signature = try signature.borrow();
    errdefer borrowed_signature.deinit();

    const level = if (parent) |val| interp.call_frames.items[val].level + 1 else 0;
    const new_call_frame_idx = interp.call_frames.items.len;
    try interp.call_frames.append(interp.gpa, .{
        .parent = parent,
        .args = args,
        .call_epoch = interp.nextCallEpoch(),
        .level = level,
        .namespace = interp.namespace,
        .signature = borrowed_signature,
        // TODO PERF recycle variable hash table if possible.
        .variables = vars_handle,
        .tailcall = null,
    });

    return @intCast(new_call_frame_idx);
}

fn pushEvalFrame(interp: *Interp) !u32 {
    try interp.eval_frames.append(interp.gpa, .{
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
            var det: object.ErrorDetails = undefined;
            const var_target = try interp.wrapError(&det, interp.getVariableImpl(&det, value));
            return var_target.borrow();
        },
        .dict_sugar => {
            @panic("Dict sugar unimplemented");
        },
        .expression_sugar => {
            @panic("Expression sugar unimplemented");
        },
        .command_subst => {
            var new_script: OptionalHandle = .none;
            try interp.evalObject(value, &new_script);
            if (new_script.toHandle()) |new| {
                // The only case where the new value is not the same as the last value is if `eval`
                // converted it from a string to a script. If so, we want to copy that script id
                // back to the token list so we'll use the cached script for future invocations.
                assert(value.heap == interp.heap.heapId());
                assert(new.heap == interp.heap.heapId());
                assert(new.peek().tag == .script);

                // Copy over the new script id.
                value.invalidateBody();
                value.peek().tag = .script;
                value.peek().body.script = new.peek().body.script;
            }

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
    var sf = std.heap.stackFallback(@sizeOf(Handle) * 8, interp.gpa);
    const tokens_alloc = sf.get();

    const new_values = try tokens_alloc.alloc(Handle, value_len);
    defer tokens_alloc.free(new_values);

    // Substitute all the tokens, placing them in `new_values`.
    for (tags, value_start..(value_start + value_len), 0..) |tag, value_index, i| {
        if (interp.substituteOneToken(tag, object.dictItemFollowRefs(value_list, @intCast(value_index)))) |new_value| {
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
                        new_values[i] = interp.heap.emptyObject();
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
        new_str_len += (try Heap.getString(new_value)).len;
    }

    const new_str = try object.newStringToFill(interp.heap, new_str_len);
    errdefer new_str.decrRefCount();
    if (Heap.getStringMut(new_str)) |new_str_mut| {
        var written: usize = 0;
        for (new_values) |new_value| {
            const value_str = try Heap.getString(new_value);
            @memcpy(new_str_mut[written..][0..value_str.len], value_str);
            written += value_str.len;
        }
    } else |err| switch (err) {
        error.NotMutable => unreachable,
    }

    return new_str;
}

/// Qualifies a name to its canonical version. For example, a name of "bar", and a namespace
/// of "foo" would return "foo::bar". Allocated on the arena. Returns null if no qualification
/// is needed.
pub fn qualifyName(arena: std.mem.Allocator, namespace: ?Handle, name: []const u8) !?[]const u8 {
    // We're in a non-global namespace, so we'll need to append the namespace to the
    // beginning of the name, if the name isn't globally scoped (e.g. by not
    // having :: at the beginning).
    if (name.len < 2 or name[0] != ':' or name[1] != ':') {
        const namespace_name = try Heap.getString(namespace orelse Heap.local_heap.emptyObject());
        return try std.fmt.allocPrint(arena, "{s}::{s}", .{ namespace_name, name });
    }

    return null;
}

/// This function returns the command that's found based on the string contents of `handle`.
/// This also specializes the object to contain a cached lookup for the command.
pub fn getCommand(interp: *Interp, det: ?*object.ErrorDetails, provided_handle: Handle, new_handle: *OptionalHandle) !*Command {
    errdefer new_handle.swapWithNull();

    early_exit: {
        // Can't use a command's cached value if it's from another heap.
        if (provided_handle.heap != interp.heap.heapId()) break :early_exit;

        const obj = provided_handle.peek();

        // TODO PERF honestly at this point, because the namespace has to be stored off the heap,
        // it might be faster to just do a hashmap lookup every time if it's not in the global
        // namespace.

        // In order for the cached value to be valid, the proc epoch must match and the
        // lookup must have occurred in the same namespace.
        if (obj.tag == .command and obj.body.command.procedure_epoch == interp.current_procedure_epoch) {
            if (interp.currentCallFrame().namespace) |namespace| {
                // Another check: if this command was in a namespace, it needs to be the same as the current
                // call frame's namespace.
                if (obj.body.command.in_global_namespace) break :early_exit;
                const obj_namespace = interp.heap.getExtraData(obj.body.command.u.other_namespace).command;
                if (!try Heap.checkIfEqual(namespace, provided_handle.getHeap().getHandle(obj_namespace.namespace))) {
                    break :early_exit;
                }
            } else if (!obj.body.command.in_global_namespace) {
                // The interpreter is in a global namespace, and this object wasn't, so we'll need to look
                // up the command again.
                break :early_exit;
            }

            // TODO should I implement `local`?

            // All checks passed, so now we can return the cached command's pointer.
            const command = blk: {
                if (obj.body.command.in_global_namespace) {
                    break :blk &interp.commands.values()[obj.body.command.u.global_namespace.command_index];
                } else {
                    const extra_data = interp.heap.getExtraData(obj.body.command.u.other_namespace);
                    break :blk &interp.commands.values()[extra_data.command.command_index];
                }
            };
            return command;
        } else {
            break :early_exit;
        }
    }

    const command_name = try Heap.getString(provided_handle);

    // There wasn't a cached version, or it was invalid, so we'll need to look up this command.
    const current_namespace = interp.currentCallFrame().namespace;
    var sf = std.heap.stackFallback(64, interp.gpa);
    const scratch = sf.get();
    const qualified = blk: {
        // Only qualify if we're in a namespace.
        if (current_namespace) |namespace| {
            break :blk try qualifyName(scratch, namespace, command_name);
        }
        break :blk null;
    };
    defer if (qualified) |unwrapped| scratch.free(unwrapped);

    var command_index: ?usize = interp.commands.getIndex(qualified orelse command_name);
    if (qualified != null and command_index == null) {
        // If we couldn't find the command in the namespace, we should check if it's in the global
        // namespace (by not qualifying the name, and instead using it raw).
        command_index = interp.commands.getIndex(command_name);
    }

    // Cache the command.
    if (command_index) |index| {
        try Heap.ensureShimmerableOrDup(provided_handle, new_handle);
        const handle = new_handle.orElse(provided_handle);

        if (current_namespace) |namespace| {
            assert(handle.heap == interp.heap.heapId());

            const borrowed_namespace = namespace.borrow();
            errdefer borrowed_namespace.decrRefCount();
            assert(borrowed_namespace.heap == handle.heap);

            const extra_data = try interp.heap.createExtraData();
            errdefer interp.heap.destroyExtraData(extra_data);
            interp.heap.getExtraData(extra_data).* = .{
                .command = .{
                    .command_index = @intCast(index),
                    .namespace = borrowed_namespace.index,
                },
            };

            try handle.prepareToShimmer();
            handle.peek().tag = .command;
            handle.peek().body.command = .{
                .procedure_epoch = interp.current_procedure_epoch,
                .in_global_namespace = false,
                .u = .{ .other_namespace = extra_data },
            };
        } else {
            try handle.prepareToShimmer();
            handle.peek().tag = .command;
            handle.peek().body.command = .{
                .procedure_epoch = interp.current_procedure_epoch,
                .in_global_namespace = true,
                .u = .{ .global_namespace = .{ .command_index = @intCast(index) } },
            };
        }

        return &interp.commands.values()[index];
    } else {
        // If it was null, we better error.
        if (det) |details| details.* = .{
            .message = try object.newStringFmt(interp.heap, "invalid command name \"{s}\"", .{command_name}),
        };
        return error.CommandNotFound;
    }
}

fn invokeCommand(interp: *Interp, args: []Handle) !void {
    var det: object.ErrorDetails = undefined;

    var new_command: OptionalHandle = .none;
    const command = getCommand(interp, &det, args[0], &new_command) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CommandNotFound => {
            // TODO invoke jim unknown
            std.debug.print("Tried to call command: {f}\n", .{args[0]});
            @panic("unimplemented");
            // try interp.wrapErrorDetails(&det, err);
        },
    };
    args[0].swapIfNew(new_command);

    if (interp.eval_depth >= interp.max_eval_depth) {
        try interp.setResultString("Infinite eval recursion");
        return error.InfiniteRecursion;
    }

    interp.eval_depth += 1;

    // Loop the calling section, as there may be a tailcall.
    var current_args = args;
    var tailcall_info: ?Tailcall = null;
    while (true) {
        interp.currentEvalFrame().args = current_args;
        // TODO implement tracing.

        // Be sure to clear the previous result.
        interp.setEmptyResult();

        const result = blk: {
            switch (command.call_info) {
                .native => |info| {
                    _ = info;

                    break :blk interp.callNative(command, current_args);
                },
                .tcl => |info| {
                    _ = info;

                    break :blk interp.callProcedure(command, current_args);
                },
            }
        };

        if (result) {
            if (interp.currentCallFrame().tailcall) |tailcall| {
                // Be sure to free the previous tailcall.
                if (tailcall_info) |prev_tailcall| {
                    for (prev_tailcall.args) |arg| arg.decrRefCount();
                    interp.gpa.free(prev_tailcall.args);
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
            const bool_result = object.getBoolean(null, string.*, &new_handle) catch |err| switch (err) {
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
            const bool_result = object.getBoolean(null, string.*, &new_handle) catch |err| switch (err) {
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
            const int_result = object.integerGet(null, string.*, &new_handle) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    // Try parsing it as a float.
                    var new_float: OptionalHandle = .none;
                    const val = try interp.getFloat(string.*, &new_float);
                    string.swapIfNew(new_float);
                    return .{ .float = val };
                },
            };
            string.swapIfNew(new_handle);
            return .{ .int = int_result };
        },
        .stack_handle => |*string| {
            var new_handle: OptionalHandle = .none;
            const int_result = object.integerGet(null, string.*, &new_handle) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    // Try parsing it as a float.
                    var new_float: OptionalHandle = .none;
                    const val = try interp.getFloat(string.*, &new_float);
                    string.swapIfNew(new_float);
                    return .{ .float = val };
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
    var det: object.ErrorDetails = undefined;
    return switch (oper) {
        .mul => blk: {
            break :blk std.math.mul(i64, lhs, rhs) catch {
                const rendered = std.math.mulWide(i64, lhs, rhs);
                return interp.wrapError(&det, object.integerOverflowErrorWithWide(&det, rendered));
            };
        },
        .div => std.math.divFloor(i64, lhs, rhs) catch |err| switch (err) {
            error.Overflow => {
                return interp.wrapError(&det, object.integerOverflowError(&det, null));
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
        .sub => std.math.sub(i64, lhs, rhs) catch return interp.wrapError(&det, object.integerOverflowError(&det, null)),
        .add => std.math.add(i64, lhs, rhs) catch return interp.wrapError(&det, object.integerOverflowError(&det, null)),
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
            return interp.wrapError(&det, object.integerOverflowError(&det, null));
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

    pub fn toObject(result: ExprResult, interp: *Interp) !Handle {
        switch (result) {
            .int => |int| return try object.newInteger(interp.heap, int),
            .float => |float| return try object.newFloat(interp.heap, float),
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
                .owned_handle => |val| (try Heap.getString(val.*))[0..],
                .stack_handle => |val| (try Heap.getString(val))[0..],
            };
            var rhs_buffer: [50]u8 = @splat(0);
            var rhs_alloc = std.heap.FixedBufferAllocator.init(rhs_buffer[0..]);
            const rhs_string = switch (lhs_value) {
                .float => |val| std.fmt.allocPrint(rhs_alloc.allocator(), "{}", .{val}) catch unreachable,
                .int => |val| std.fmt.allocPrint(rhs_alloc.allocator(), "{}", .{val}) catch unreachable,
                .owned_handle => |val| (try Heap.getString(val.*))[0..],
                .stack_handle => |val| (try Heap.getString(val))[0..],
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
            var new_handle: OptionalHandle = .none;
            const result = interp.evalObject(node_data.object, &new_handle);
            // This should not change, since it should be a local heap object.
            assert(new_handle == .none);

            if (result) {
                return .{ .stack_handle = interp.result.borrow() };
            } else |err| {
                // Be sure to propagate any error that eval returned.
                return err;
            }
        },
        .variable_subst => {
            var new_handle: OptionalHandle = .none;
            const var_value = try interp.getVariableOrError(node_data.object, &new_handle);
            // This should not change, since it should be a local heap object.
            assert(new_handle == .none);

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
                    var new_handle: OptionalHandle = .none;
                    const res = try interp.getInteger(val.*, &new_handle);
                    val.swapIfNew(new_handle);
                    break :blk res;
                },
                .stack_handle => |*val| blk: {
                    var new_handle: OptionalHandle = .none;
                    const res = try interp.getInteger(val.*, &new_handle);
                    val.swapIfNew(new_handle);
                    break :blk res;
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
                        var det: object.ErrorDetails = undefined;
                        return interp.wrapError(&det, object.integerOverflowErrorWithWide(&det, @abs(int)));
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
                .owned_handle => |val| blk: {
                    var new_handle: OptionalHandle = .none;
                    const res = try interp.getInteger(val.*, &new_handle);
                    val.swapIfNew(new_handle);
                    break :blk res;
                },
                .stack_handle => |*val| blk: {
                    var new_handle: OptionalHandle = .none;
                    const res = try interp.getInteger(val.*, &new_handle);
                    val.swapIfNew(new_handle);
                    break :blk res;
                },
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
    errdefer new_handle.swapWithNull();

    // Try to get the expression, parsing if necessary.
    var det: object.ErrorDetails = undefined;
    const expr = try interp.wrapError(&det, object.getExpression(&det, handle, new_handle));

    return evalExpressionNode(interp, expr.nodes, expr.root_node) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.EvalError,
    };
}

pub fn getBoolFromExpression(interp: *Interp, handle: Handle) !struct { new_handle: ?Handle, value: bool } {
    const expr_result = try interp.evalExpression(handle);
    defer expr_result.value.release();
    const value = interp.exprResultAsBool(&expr_result.value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => error.EvalError,
    };
    return .{ .new_handle = expr_result.new_handle, .value = value };
}

test "eval expression" {
    defer Heap.testFinish();
    const heap = try Heap.testStart(testing.allocator);
    var interp = try Interp.init();
    defer interp.deinit();

    var expr = try object.newString(heap, "5 + 10");
    defer expr.decrRefCount();
    var new_expr: OptionalHandle = .none;
    const result = try interp.evalExpression(expr, &new_expr);
    expr.swapIfNew(new_expr);
    try testing.expectEqual(ExprResult{ .int = 15 }, result);
}

pub fn evalObject(interp: *Interp, script: Handle, new_script: *OptionalHandle) Error!void {
    errdefer new_script.swapWithNull();

    // Try to get the script, parsing if necessary.
    var det: object.ErrorDetails = undefined;
    const parsed = try interp.wrapError(&det, object.getScript(&det, script, new_script));
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
    var sf = std.heap.stackFallback(@sizeOf(Handle) * 8, interp.gpa);
    var args_alloc = sf.get();

    // Execute every command sequentially until the end of the script or an error occurs.
    var command_token_i: u32 = 0;

    const tags = parsed.tags.items;
    const values = object.listItems(parsed.values);
    // Loop through the script's commands.
    while (command_token_i < tags.len) {
        // First token of the line is always .script_command.
        const command_info = values[command_token_i].body.script_command;
        command_token_i += 1; // Skip .script_command.

        // This is not always the same as which word token we're on, as argument expansion
        // may write multiple arguments from one word.
        var args_written: usize = 0;
        var args = try args_alloc.alloc(Handle, command_info.arg_count);
        defer args_alloc.free(args);
        defer for (args) |arg| arg.decrRefCount();

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
                    break :blk try interp.substituteOneToken(tags[word_token_i], object.listItem(parsed.values, word_token_i));
                } else {
                    // Helper function that'll interpolate all the word parts and merge them into a string.
                    break :blk try interp.interpolateTokens(tags[word_token_i..][0..word_parts], parsed.values, word_token_i, word_parts, false);
                }
            };

            if (argument_expansion) {
                // Argument expansion, so we'll need to shimmer the result to a list.
                det = undefined;
                var new_list: OptionalHandle = .none;
                const len = try wrapError(interp, &det, object.listLength(&det, resultant_word, &new_list));
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
                    args[args_written] = try Heap.steal(object.listItem(resultant_word, @intCast(list_idx)));
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
        for (args) |arg| std.debug.print("{{{s}}} ", .{try Heap.getString(arg)});
        std.debug.print("\n", .{});

        const cmd_result = interp.invokeCommand(args);
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

pub fn init() !Interp {
    var new_interp: Interp = .{
        .heap = Heap.local_heap,
        .gpa = testing.allocator,
        .result = Heap.local_heap.emptyObject(),
        .eval_frames = .empty,
        .call_frames = .empty,
        .current_call_epoch = 0,
        .current_procedure_epoch = 0,
        .commands = .empty,
        .namespace = null,
        .evaluating_safe_expr = false,
        .eval_depth = 0,
        .max_eval_depth = 100_000,
        .max_call_depth = 100_000,
        .stack_trace = null,
        // TODO: init per interpreter
        .prng = .init(0),
    };

    _ = try new_interp.pushCallFrame(null, &.{}, .{
        .args = Heap.local_heap.emptyObject(),
        .body = Heap.local_heap.emptyObject(),
        .has_args_parameter = false,
        .optional_arity = 0,
        .optional_values = null,
        .required_arity = 0,
        .statics = null,
    });

    return new_interp;
}

pub fn deinit(interp: *Interp) void {
    interp.result.decrRefCount();
    var iter = interp.commands.iterator();
    while (iter.next()) |*entry| {
        interp.gpa.free(entry.key_ptr.*);
        entry.value_ptr.deinit();
    }
    interp.commands.deinit(interp.gpa);

    // Deinit all frames.
    for (interp.call_frames.items) |frame| {
        frame.deinit();
    }
    interp.call_frames.deinit(interp.gpa);

    interp.eval_frames.deinit(interp.gpa);
}

// Export various utility functions with a nicer interface.
pub fn integerOverflowError(interp: *Interp, value: ?[]const u8) error{ OutOfMemory, EvalError } {
    var det: object.ErrorDetails = undefined;
    interp.wrapError(&det, object.integerOverflowError(&det, value)) catch return error.EvalError;
}

pub fn wrapShimmer(
    interp: *Interp,
    handle: *Handle,
    to_call: fn (det: ?*object.ErrorDetails, provided_handle: Handle) object.Error!?Handle,
) !void {
    var det: object.ErrorDetails = undefined;
    handle.swapIfNew(try wrapError(interp, &det, to_call(&det, handle.*)));
}

pub fn getInteger(interp: *Interp, handle: Handle, new_handle: *OptionalHandle) !i64 {
    var det: object.ErrorDetails = undefined;
    try interp.wrapError(&det, object.shimmerToInteger(&det, handle, new_handle));
    return new_handle.orElse(handle).peek().body.integer;
}

pub fn getIntegerNoShimmer(interp: *Interp, handle: Handle) Interp.Error!i64 {
    var det: object.ErrorDetails = undefined;
    return interp.wrapError(&det, object.integerGetNoShimmer(&det, handle));
}

pub fn getFloat(interp: *Interp, handle: Handle, new_handle: *OptionalHandle) !f64 {
    var det: object.ErrorDetails = undefined;
    try interp.wrapError(&det, object.shimmerToFloat(&det, handle, new_handle));
    const value_handle = new_handle.orElse(handle);
    return value_handle.peek().body.float;
}

pub fn getFloatNoShimmer(interp: *Interp, handle: Handle) Interp.Error!f64 {
    var det: object.ErrorDetails = undefined;
    return wrapError(interp, &det, object.floatGetNoShimmer(&det, handle));
}

pub fn getListLength(interp: *Interp, handle: Handle) !struct { new_handle: ?Handle, value: u32 } {
    var det: object.ErrorDetails = undefined;
    const new_handle = try wrapError(interp, &det, object.shimmerToList(&det, handle));
    const value_handle = new_handle orelse handle;
    return .{ .new_handle = new_handle, .value = value_handle.peek().body.list.len };
}

pub fn listAppend(interp: *Interp, list: Handle, item: Handle) !struct { new_handle: ?Handle, value: Handle } {
    var det: object.ErrorDetails = undefined;
    const result = try wrapError(interp, &det, object.listAppend(&det, list, item));
    return .{ .new_handle = result.new_handle, .value = result.value_handle };
}

pub fn setVariableToObject(interp: *Interp, name: Handle, obj: Heap.Object) !OptionalHandle {
    const new_name = try Heap.ensureShimmerableOrDup(name);
    errdefer if (new_name) |val| val.decrRefCount();
    const name_handle = new_name orelse name;
    try interp.setVariableImpl(interp.currentCallFrameIndex(), name_handle, obj);
    return new_name;
}

pub fn setVariableTo(interp: *Interp, provided_name: Handle, handle: Handle) !OptionalHandle {
    var new_name: OptionalHandle = .none;
    errdefer new_name.swapWithNull();
    try Heap.ensureShimmerableOrDup(provided_name, &new_name);
    const name = new_name.orElse(provided_name);

    const handle_to_obj = try Heap.local_heap.dupOrReference(handle);
    try interp.setVariableImpl(interp.currentCallFrameIndex(), name, handle_to_obj);

    return new_name;
}

pub fn getVariable(interp: *Interp, provided_name: Handle, new_name: *OptionalHandle) !OptionalHandle {
    errdefer new_name.swapWithNull();
    try Heap.ensureShimmerableOrDup(provided_name, &new_name);

    const value = interp.getVariableImpl(null, new_name.orElse(provided_name)) catch |err| switch (err) {
        error.VariableNotFound => return .none,
        else => return err,
    };
    return value;
}

pub fn getVariableOrError(interp: *Interp, name: Handle, new_name: *OptionalHandle) !Handle {
    errdefer new_name.swapWithNull();
    try Heap.ensureShimmerableOrDup(name, new_name);
    var det: object.ErrorDetails = undefined;
    return try interp.wrapError(&det, interp.getVariableImpl(&det, new_name.orElse(name)));
}

pub fn getDictValue(interp: *Interp, dict: Handle, key: Handle) Interp.Error!struct {
    new_dict: ?Handle,
    value: ?Handle,
} {
    var det: object.ErrorDetails = undefined;
    const new_dict = try interp.wrapError(&det, object.shimmerToDict(&det, dict));
    return .{ .new_dict = new_dict, .value = object.dictLookupFollowRefs(new_dict orelse dict, key) };
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

pub fn getDictValueRecursively(interp: *Interp, dict: Handle, new_dict: *OptionalHandle, keys: []const Handle) Interp.Error!OptionalHandle {
    var det: object.ErrorDetails = undefined;
    const result = try interp.wrapError(&det, object.dictLookupRecursively(&det, dict, keys));
    new_dict.swapRefIfNew(result.new_dict);
    return result.value;
}

pub fn getDictValueRecursivelyOrError(interp: *Interp, dict: Handle, new_dict: *OptionalHandle, keys: []const Handle) Interp.Error!Handle {
    const result = try interp.getDictValueRecursively(dict, new_dict, keys);
    if (result.value) |val| return val;

    // Else, create a useful error message.
    if (keys.len == 1) {
        try interp.setResultFormatted("could not find value for key \"{f}\"", .{keys[0]});
    } else {
        var keys_list = try object.newList(keys);
        defer keys_list.decrRefCount();
        try interp.setResultFormatted("could not find value for keys \"{f}\"", .{keys_list});
    }

    return error.EvalError;
}

pub fn putDictValue(interp: *Interp, dict: Handle, new_dict: *OptionalHandle, key: Handle, value: Handle) Interp.Error!Handle {
    errdefer new_dict.swapWithNull();

    var det: object.ErrorDetails = undefined;
    try interp.wrapError(&det, object.shimmerToDict(&det, dict));

    const put_result = try object.dictPut(new_dict.orElse(dict), key, value);
    new_dict.swapRefIfNew(put_result.new_dict);

    return put_result.new_value;
}

/// Returns a new handle to where the value (or reference to the value) resides.
pub fn putDictValueRecursively(interp: *Interp, dict: Handle, new_dict: *OptionalHandle, keys: []const Handle, value: Handle) Interp.Error!Handle {
    var det: object.ErrorDetails = undefined;
    var new_obj = try interp.heap.dupOrReference(value);
    const put_result = try interp.wrapError(
        &det,
        object.dictPutRecursively(&det, dict, keys, &new_obj),
    );
    new_dict.swapRefIfNew(put_result.new_dict);
    return put_result.new_value;
}

/// Returns whether the value was removed.
pub fn removeDictValue(interp: *Interp, dict: Handle, new_dict: *OptionalHandle, key: Handle) !bool {
    errdefer new_dict.swapWithNull();

    var det: object.ErrorDetails = undefined;
    try interp.wrapError(&det, object.shimmerToDict(&det, dict, new_dict));

    const remove_result = try object.dictRemove(new_dict orelse dict, key);
    Handle.swapRefIfNew(&new_dict, remove_result.new_dict);
    return .{ .new_dict = new_dict, .did_remove = remove_result.did_remove };
}

pub fn removeDictValueRecursively(interp: *Interp, dict: Handle, new_dict: *OptionalHandle, keys: []const Handle) Interp.Error!bool {
    var det: object.ErrorDetails = undefined;
    const put_result = try interp.wrapError(&det, object.dictRemoveRecursively(&det, dict, keys));
    new_dict.swapRefIfNew(put_result.new_dict);
    return put_result.did_remove;
}

test "recursive dict keys" {
    defer Heap.testFinish();
    const heap = try Heap.testStart(testing.allocator);
    var interp = try Interp.init();
    defer interp.deinit();

    var dict = try object.newDict(heap, &.{});
    defer dict.decrRefCount();
    var key_foo = try object.newString(heap, "foo");
    defer key_foo.decrRefCount();
    var key_bar = try object.newString(heap, "bar");
    defer key_bar.decrRefCount();
    var key_baz = try object.newString(heap, "baz");
    defer key_baz.decrRefCount();
    const value_qux = try object.newString(heap, "qux");
    defer value_qux.decrRefCount();

    var new_dict: OptionalHandle = .none;
    _ = try interp.putDictValueRecursively(dict, &new_dict, &[_]Handle{ key_foo, key_bar, key_baz }, value_qux);
    dict.swapAndClear(&new_dict);
    try testing.expectEqualStrings("foo {bar {baz qux}}", try Heap.getString(dict));

    // Try taking ownership of one of the intermediate dictionaries.
    var to_take_result = try interp.getDictValueRecursively(dict, &new_dict, &.{ key_foo, key_bar });
    dict.swapAndClear(&new_dict);
    const to_take = to_take_result.toHandle().?.borrow();
    defer to_take.decrRefCount();

    // See if setting still works correctly.
    _ = try interp.putDictValueRecursively(dict, &new_dict, &.{ key_foo, key_bar, key_baz }, value_qux);
    dict.swapAndClear(&new_dict);
    try testing.expectEqual(1, to_take.debugRefCount());

    // Let's try some very cursed aliasing.
    _ = try interp.putDictValueRecursively(dict, &new_dict, &.{ key_foo, key_bar }, object.dictItem(dict, 0));
    dict.swapAndClear(&new_dict);
    try testing.expectEqualStrings("foo {bar foo}", try Heap.getString(dict));

    const value_result = try interp.getDictValueRecursively(dict, &new_dict, &.{ key_foo, key_bar });
    dict.swapAndClear(&new_dict);
    try testing.expectEqualStrings("foo", try Heap.getString(value_result.toHandle().?));
}

fn testRecursiveDictRemoval(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    const heap = try Heap.testStart(ta);
    var interp = try Interp.init();
    defer interp.deinit();

    var dict = try object.newDict(heap, &.{});
    defer dict.decrRefCount();
    var key_foo = try object.newString(heap, "foo");
    defer key_foo.decrRefCount();
    var key_bar = try object.newString(heap, "bar");
    defer key_bar.decrRefCount();
    var key_baz = try object.newString(heap, "baz");
    defer key_baz.decrRefCount();
    const value_qux = try object.newString(heap, "qux");
    defer value_qux.decrRefCount();

    var new_dict: OptionalHandle = .none;
    // Test 1: Remove a deeply nested value (3 levels).
    _ = try interp.putDictValueRecursively(dict, &new_dict, &.{ key_foo, key_bar, key_baz }, value_qux);
    dict.swapAndClear(&new_dict);

    try testing.expectEqualStrings("foo {bar {baz qux}}", try Heap.getString(dict));
    var did_remove = try interp.removeDictValueRecursively(dict, &new_dict, &.{ key_foo, key_bar, key_baz });
    dict.swapAndClear(&new_dict);
    try testing.expect(did_remove);
    try testing.expectEqualStrings("foo {bar {}}", try Heap.getString(dict));

    // Test 2: Try to remove the same key again (should return false).
    did_remove = try interp.removeDictValueRecursively(dict, &new_dict, &.{ key_foo, key_bar, key_baz });
    dict.swapAndClear(&new_dict);
    try testing.expect(!did_remove);
    try testing.expectEqualStrings("foo {bar {}}", try Heap.getString(dict));

    // Test 3: Remove a non-existent key from an existing intermediate dict.
    did_remove = try interp.removeDictValueRecursively(dict, &new_dict, &.{ key_foo, key_bar, key_foo });
    dict.swapAndClear(&new_dict);
    try testing.expect(!did_remove);
    try testing.expectEqualStrings("foo {bar {}}", try Heap.getString(dict));

    // Test 4: Remove from a non-existent intermediate dict.
    try memutil.expectErrorOrOom(
        error.EvalError,
        interp.removeDictValueRecursively(dict, &new_dict, &.{ key_bar, key_baz, key_foo }),
    );
    try testing.expectEqualStrings(
        \\key "bar" not known in dictionary "foo {bar {}}"
    , try Heap.getString(interp.result));
    try testing.expectEqualStrings("foo {bar {}}", try Heap.getString(dict));

    // Test 5: Single-level removal (base case).
    did_remove = try interp.removeDictValueRecursively(dict, &new_dict, &.{key_foo});
    dict.swapAndClear(&new_dict);
    try testing.expect(did_remove);
    try testing.expectEqualStrings("", try Heap.getString(dict));

    // Test 6: Two-level removal.
    _ = try interp.putDictValueRecursively(dict, &new_dict, &.{ key_foo, key_bar }, value_qux);
    dict.swapAndClear(&new_dict);
    try testing.expectEqualStrings("foo {bar qux}", try Heap.getString(dict));
    did_remove = try interp.removeDictValueRecursively(dict, &new_dict, &.{ key_foo, key_bar });
    dict.swapAndClear(&new_dict);
    try testing.expect(did_remove);
    try testing.expectEqualStrings("foo {}", try Heap.getString(dict));

    // Test 7: Removal when intermediate dict is shared (copy-on-write).
    var interm_test_dict = try object.newDict(heap, &.{});
    defer interm_test_dict.decrRefCount();
    _ = try interp.putDictValueRecursively(interm_test_dict, &new_dict, &.{ key_foo, key_bar, key_baz }, value_qux);
    interm_test_dict.swapAndClear(&new_dict);
    _ = try interp.putDictValueRecursively(interm_test_dict, &new_dict, &.{ key_foo, key_bar, key_foo }, value_qux);
    interm_test_dict.swapAndClear(&new_dict);

    // Borrow the intermediate dict.
    var interm_result = try interp.getDictValueRecursively(interm_test_dict, &new_dict, &.{ key_foo, key_bar });
    interm_test_dict.swapAndClear(&new_dict);
    const intermediate = interm_result.toHandle().?.borrow();
    defer intermediate.decrRefCount();

    const initial_refcount = intermediate.debugRefCount();
    try testing.expectEqualStrings("baz qux foo qux", try Heap.getString(intermediate));

    // Remove from the nested dict while it's owned elsewhere.
    did_remove = try interp.removeDictValueRecursively(interm_test_dict, &new_dict, &.{ key_foo, key_bar, key_baz });
    interm_test_dict.swapAndClear(&new_dict);
    try testing.expect(did_remove);

    // The intermediate dict we own should be unchanged (copy-on-write).
    try testing.expectEqualStrings("baz qux foo qux", try Heap.getString(intermediate));
    // But the main dict should have a new copy without 'baz'.
    const foo_bar_result = try interp.getDictValueRecursively(interm_test_dict, &new_dict, &.{ key_foo, key_bar });
    interm_test_dict.swapAndClear(&new_dict);
    try testing.expectEqualStrings("foo qux", try Heap.getString(foo_bar_result.toHandle().?));
    // Reference count should drop by 1 since the parent no longer references it.
    try testing.expectEqual(initial_refcount - 1, intermediate.debugRefCount());

    // Test 8: Remove multiple items from a nested dict.
    dict.swap(try object.newDict(heap, &.{}));
    _ = try interp.putDictValueRecursively(dict, &new_dict, &.{ key_foo, key_bar }, value_qux);
    dict.swapAndClear(&new_dict);
    _ = try interp.putDictValueRecursively(dict, &new_dict, &.{ key_foo, key_baz }, value_qux);
    dict.swapAndClear(&new_dict);
    try testing.expectEqualStrings("foo {bar qux baz qux}", try Heap.getString(dict));
    did_remove = try interp.removeDictValueRecursively(dict, &new_dict, &.{ key_foo, key_bar });
    dict.swapAndClear(&new_dict);
    try testing.expect(did_remove);
    try testing.expectEqualStrings("foo {baz qux}", try Heap.getString(dict));
    did_remove = try interp.removeDictValueRecursively(dict, &new_dict, &.{ key_foo, key_baz });
    dict.swapAndClear(&new_dict);
    try testing.expect(did_remove);
    try testing.expectEqualStrings("foo {}", try Heap.getString(dict));
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

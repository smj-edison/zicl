const std = @import("std");
const assert = std.debug.assert;

const Parser = @import("Parser.zig");
const Heap = @import("Heap.zig");
const object = @import("object.zig");

const Interp = @This();

heap: *Heap,
gpa: std.mem.Allocator,

/// The result from a procedure or eval call
result: Heap.Handle,
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
namespace: ?Heap.Handle,

evaluating_safe_expr: bool,
eval_depth: usize,
max_eval_depth: usize,
max_call_depth: usize,

pub const CommandFn = fn (interp: *Interp, args: []const Heap.Handle) void;

pub const Error = std.mem.Allocator.Error || error{
    EvaluatingSafeExpression,
    EvalError,
    Break,
    Continue,
    Signal,
    VariableNotFound,
    CommandNotFound,
    InfiniteRecursion,
    WrongArgumentCount,
};

/// Used to convert from an object error to an interpreter error (e.g. putting
/// it in the interpreter result, instead of det)
fn wrapErrorDetails(interp: *Interp, det: *object.ErrorDetails, result: anytype) @TypeOf(result) {
    if (result) |unwrapped| {
        return unwrapped;
    } else |err| {
        switch (err) {
            Error.OutOfMemory => return Error.OutOfMemory,
            else => {
                // This error should have error details, if it's not OOM.
                interp.setResultOwning(det.message);
            },
        }
    }
}

fn variableNotFoundError(heap: *Heap, det: ?object.ErrorDetails, var_name: []const u8) !void {
    if (det) |details| details.* = .{
        .message = try object.newStringFmt(heap, "can't read \"{s}\": no such variable", .{var_name}),
    };

    return Error.VariableNotFound;
}

const VariableInfo = struct {
    target_index: u32,
    call_frame_idx: u32,
};

/// Resolves to the variable's value, if any. Accounts for :: for globals.
fn resolveVariable(interp: *Interp, var_call_frame: u32, var_name: [:0]const u8) ?VariableInfo {
    var call_frame_idx: u32 = 0;
    var var_value: ?Heap.Handle = null;

    //  No need to check slice length since it's null terminated.
    if (var_name[0] == ':' and var_name[1] == ':') {
        call_frame_idx = 0; // global frame

        // Skip as many colons as are present to match tcl behavior.
        var trimmed_var_name = var_name;
        while (trimmed_var_name[0] == ':') trimmed_var_name = trimmed_var_name[1..];

        const var_dict = interp.call_frames.items[call_frame_idx].variables;
        var_value = var_dict.get(trimmed_var_name);

        // Global scope doesn't have statics.
    } else {
        call_frame_idx = var_call_frame;

        const var_hash_map = interp.call_frames.items[call_frame_idx].variables;
        const statics_dict = interp.call_frames.items[call_frame_idx].signature.statics;

        // Check the variables dictionary.
        var_value = var_hash_map.get(var_name);

        // Maybe it's in the statics dictionary instead?
        if (var_value == null) {
            if (statics_dict) |dict| {
                // The temp object is an object with a long string. What we can do is
                // swap out that long string's `string` value to the var name. This avoids
                // allocating a heap object, just to immediately drop it.
                try interp.heap.setTempObjectString(var_name);
                var_value = object.dictLookupRaw(dict, interp.heap.tempObject());
                interp.heap.resetTempObject();
            }
        }
    }

    if (var_value) |unwrapped| {
        assert(unwrapped.heap == interp.heap);
        assert(!unwrapped.ref_counted);

        return .{
            .target_index = unwrapped.index,
            .call_frame_idx = call_frame_idx,
        };
    }

    return null;
}

/// This always shimmers to .variable. You probably should be using `ensureValidVariableType`.
fn reshimmerToVariable(interp: *Interp, call_frame_idx: u32, det: ?object.ErrorDetails, name: *Heap.Handle) !void {
    const var_name = try Heap.getString(name.*);

    if (interp.resolveVariable(call_frame_idx, var_name)) |var_info| {
        // Free the old representation and set the new one.
        name.invalidateBody();

        name.peek().tag = .variable;
        name.peek().body.variable = .{
            .epoch = interp.current_call_epoch,
            .index = var_info.index,
            .is_global = var_info.call_frame_idx == 0,
        };
    } else {
        return variableNotFoundError(interp.heap, var_name, det);
    }
}

/// Ensures that this is a valid variable, dict sugar, or upvar.
fn ensureValidVariableType(interp: *Interp, det: ?object.ErrorDetails, call_frame_idx: u32, name: *Heap.Handle) !void {
    // This ensures that the name is local to this interpreter's heap.
    try interp.heap.ensureShimmerable(name);

    const name_obj = name.peek();
    const name_heap = name.getHeap();
    const bytes = try Heap.getString(name.*);

    if (name_obj.tag == .variable) {
        // Fast case: if we're in the same epoch as last time,
        // we don't need to do anything.
        if (name_obj.body.variable.call_epoch == interp.currentCallFrame().call_epoch) {
            return;
        } else {
            // Need to re-resolve the variable in the current call frame.
            try interp.reshimmerToVariable(call_frame_idx, name);
            return;
        }
    } else if (name_obj.tag == .upvar) {
        const upvar = name_heap.getExtraData(name_obj.body.upvar).upvar;

        // Fast case is same as for .variable.
        if (upvar.epoch == interp.currentCallFrame().call_epoch) {
            return;
        } else {
            // Need to look this back up.
            if (upvar.dict_sugar) |_| {
                @panic("Dict sugar not implemented yet");
            } else {
                // Be sure to look it up in the upvar's call frame.
                if (try interp.resolveVariable(bytes, upvar.call_frame_idx)) |upvar_target| {
                    upvar.index = upvar_target.target_index;
                    return;
                } else {
                    return variableNotFoundError(interp.heap, det, bytes);
                }
            }
        }
    } else if (name_obj.tag == .dict_subst) {
        @panic("Dict sugar not implemented yet");
    } else {
        // We don't know whether this is a normal variable or dict sugar yet.
        const var_name = try Heap.getString(name.*);
        if (var_name.len >= 2 and var_name[0] == '(' and var_name[var_name.len - 1] == ')') {
            @panic("Dict sugar not implemented yet");
            // name_obj.tag = .dict_subst;
        } else {
            try reshimmerToVariable(interp, name);
        }
    }
}

fn createVariable(interp: *Interp, call_frame_idx: u32, name: *Heap.Handle, value: *Heap.Handle) !void {
    const call_frame = &interp.call_frames.items[call_frame_idx];
    const name_bytes = try Heap.getString(name.*);

    assert(!value.getMetadata().cross_thread);
    assert(value.ref_counted);
    value.incrRefCount();

    if (name_bytes.len >= 2 and name_bytes[0] == ':' and name_bytes[1] == ':') {
        var trimmed = name_bytes;
        // Trim all preceding colons to match tcl behavior.
        while (trimmed[0] == ':') trimmed = trimmed[1..];

        // Add variable.
        try interp.call_frames.items[0].variables.putNoClobber(trimmed, value.*);

        assert(name.canShimmer());
        name.peek().tag = .variable;
        name.peek().body.variable = .{
            .call_epoch = call_frame.call_epoch,
            .index = value.*.index,
            .is_global = true,
        };
    } else {
        // Add variable.
        try call_frame.variables.putNoClobber(name_bytes, value.*);

        assert(name.canShimmer());
        name.peek().tag = .variable;
        name.peek().body.variable = .{
            .call_epoch = call_frame.call_epoch,
            .index = value.*.index,
            .is_global = false,
        };
    }
}

fn setVariableTo(interp: *Interp, call_frame_idx: u32, name: *Heap.Handle, value: *Heap.Handle) !void {
    const call_frame = &interp.call_frames.items[call_frame_idx];

    if (value.getMetadata().cross_thread or !value.ref_counted) {
        // We can only create a variable reference to something in our heap, so
        // we'll need to duplicate the value before we can reference it. We also
        // can't reference something that's not reference counted, since part of
        // pointing to something is incrementing its reference.
        const old_value = value.*;
        const new_value = try interp.heap.duplicate(old_value);
        value.* = new_value;
        old_value.release();
    }
    value.incrRefCount();
    defer value.release();

    if (interp.ensureValidVariableType(null, call_frame_idx, name)) {
        switch (name.peek().tag) {
            .dict_subst => @panic("Dict sugar not implemented"),
            .variable => {
                const variable = &name.peek().body.variable;
                // Release last value.
                interp.heap.normalHandle(variable.index).release();
                // Borrow new value.
                value.incrRefCount();
                variable.* = .{
                    .call_epoch = interp.current_call_epoch,
                    .index = value.index,
                };
                call_frame.variables.
            },
            .upvar => {
                const upvar = &interp.heap.getExtraData(name.peek().body.upvar).upvar;

                switch (upvar.name) {
                    .dict_sugar => @panic("Dict sugar not implemented"),
                    .normal => |upvar_name| {
                        var name_handle = interp.heap.normalHandle(upvar_name);

                        if (upvar.index == Heap.null_object_idx) {
                            // The upvar doesn't target anything, which means we need to create a variable
                            // in its scope.
                            try interp.createVariable(upvar.call_frame_idx, &name_handle, value);
                            assert(name_handle.peek().tag == .variable);
                            const variable = name_handle.peek().body.variable;

                            upvar.* = .{
                                .call_frame_epoch = variable.call_epoch,
                                .call_frame_idx = upvar.call_frame_idx,
                                .index = variable.index,
                                .name = .{ .normal = upvar_name },
                            };
                        } else {
                            // Normal case: upvar
                            try interp.setVariableTo(upvar.call_frame_idx, &name_handle, value);
                            assert(name_handle.peek().tag == .variable);
                            const variable = name_handle.peek().body.variable;

                            upvar.* = .{
                                .call_frame_epoch = variable.call_epoch,
                                .call_frame_idx = upvar.call_frame_idx,
                                .index = variable.index,
                                .name = .{ .normal = upvar_name },
                            };
                        }
                    },
                }
            },
        }
    } else |err| switch (err) {
        Error.OutOfMemory => return Error.OutOfMemory,
        Error.VariableNotFound => try createVariable(interp, call_frame_idx, name, value),
    }
}

/// Resolves to the variable's value.
pub fn getVariable(interp: *Interp, det: ?object.ErrorDetails, name: Heap.Handle) !Heap.Handle {
    if (interp.evaluating_safe_expr) return Error.EvaluatingSafeExpression;

    var new_name = name;
    try interp.ensureValidVariableType(det, &new_name);

    const new_name_obj = new_name.peek();
    const new_name_heap = new_name.getHeap();

    switch (new_name_obj.tag) {
        .variable => {
            // Variable contents are stored in a dict, so it's not a ref-counted handle.
            return new_name_heap.getHandle(new_name_obj.body.variable.index, false);
        },
        .upvar => {
            // Variable contents are stored in a dict, so it's not a ref-counted handle.
            return new_name_heap.getHandle(new_name_heap.getUpvar(new_name_obj.body.upvar).index, false);
        },
        .dict_subst => {
            @panic("Unimplemented");
        },
        else => unreachable,
    }
}

const ProcedureSignature = struct {
    /// Handle to the argument list of the procedure.
    args: Heap.Handle,
    /// Handle to the ScriptId object.
    body: Heap.Handle,
    /// Handle to the statics dictionary.
    statics: ?Heap.Handle,
    /// Required number of arguments.
    required_arity: usize,
    /// Optional number of arguments.
    optional_arity: usize,
    /// Whether `args` is provided as an argument name. `args`, if present, is always
    /// the last argument name.
    has_args_parameter: bool,

    pub fn borrow(signature: ProcedureSignature, heap: Heap) !ProcedureSignature {
        return .{
            .args = try heap.borrow(signature.args),
            .body = try heap.borrow(signature.body),
            .statics = try heap.borrowOptional(signature.statics),
            .required_arity = signature.required_arity,
            .optional_arity = signature.optional_arity,
            .args_parameter = signature.args_parameter,
        };
    }

    pub fn release(signature: ProcedureSignature) void {
        signature.args.release();
        signature.body.release();
        if (signature.statics) |statics| statics.release();
    }
};

pub const Command = struct {
    ref_count: u32,
    namespace: ?Heap.Handle,
    call_info: union(enum) {
        native: struct {
            to_call: *const CommandFn,
            description: ?[]const u8,
        },
        tcl: struct {
            signature: ProcedureSignature,
        },
    },

    pub fn deinit(gpa: std.mem.Allocator) void {
        _ = gpa;
    }

    pub fn call(command: *Command, interp: *Interp, args: []Heap.Handle) !void {
        // Dispatch to native or procedure call.
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
                    const arg = object.listItemRaw(args_list, i);

                    try aw.writer.writeAll(" ") catch return error.OutOfMemory;

                    if (i == call_info.signature.args_parameter) {
                        // Handle `args` paramater.
                        aw.writer.writeAll("?arg ...?") catch return error.OutOfMemory;
                    } else {
                        // If this argument is a list, it means that it has a default value.
                        if (arg.peek().tag == .list) {
                            assert(object.listLengthRaw(arg) == 2);

                            aw.writer.print("?{}?", .{try Heap.getString(arg)}) catch return error.OutOfMemory;
                        } else {
                            aw.writer.writeAll(try Heap.getString(arg)) catch return error.OutOfMemory;
                        }
                    }
                }

                return aw.toOwnedSlice();
            },
            .native => |call_info| {
                if (call_info.description) |description| {
                    aw.writer.print(" {}", .{description}) catch return error.OutOfMemory;
                } else {
                    aw.writer.writeAll(" ...") catch return error.OutOfMemory;
                }
            },
        }

        return try aw.toOwnedSlice();
    }
};

pub const CommandHashTable = std.StringArrayHashMapUnmanaged(Command);

fn wrongArgumentCountError(heap: *Heap, det: ?object.ErrorDetails, command_usage: []const u8) !void {
    if (det) |details| details.* = .{
        .message = try object.newStringFmt(heap, "wrong # args: should be \"{s}\"", .{command_usage}),
    };

    return Error.CommandNotFound;
}

fn createCommand(interp: *Interp, name: []const u8, command: Command) !void {
    const name_obj = try object.newString(interp.heap, name);
    errdefer name_obj.release();

    // TODO make sure to check interp->local if we end up needing it in our impl
    const old_command = try interp.commands.fetchPut(interp.gpa, name_obj, command);
    if (old_command) |unwrapped| unwrapped.value.deinit(interp.gpa);
}

pub fn registerCommand(interp: *Interp, name: []const u8, to_call: *const CommandFn) !void {
    try interp.createCommand(name, .{
        .ref_count = 1,
        .call = .{
            .native = to_call,
        },
    });
}

fn callProcedure(interp: *Interp, command: *Command, args: []Heap.Handle) !void {
    const signature = command.call_info.tcl.signature;
    const arg_count = args.len - 1; // - 1 to skip command name as first argument.

    // Check arity.
    if (arg_count < signature.required_arity or
        (!signature.has_args_parameter and arg_count > signature.required_arity + signature.optional_arity))
    {
        // Wrong argument count, error accordingly.
        const scratch = std.heap.stackFallback(64, interp.gpa).get();
        const command_name = try Heap.getString(args[0]);
        const command_usage = command.getUsageInfo(scratch, command_name);
        defer scratch.free(command_usage);
        var det: object.ErrorDetails = undefined;
        return interp.wrapErrorDetails(&det, wrongArgumentCountError(&det, command_usage));
    }

    // Check for infinite recursion.
    if (interp.currentCallFrame().level >= interp.max_call_depth) {
        interp.setResultString("Too many nested calls. Infinite recursion?");
        return Error.InfiniteRecursion;
    }

    try interp.pushCallFrame(interp.currentCallFrameIndex(), args, signature);

    // Where we are in the arguments that this was called with.
    var called_idx: usize = 1;
    // Where we are in the signature.
    var signature_idx: usize = 0;
    const signature_len = object.listLengthRaw(signature.args);

    while (signature_idx < signature_len) : (signature_idx += 1) {
        const var_name = object.listItemRaw(signature.args, signature_idx);

        // Are we at the last argument? If so, is it `args`?
        if (signature_idx == signature_len - 1 and signature.has_args_parameter) {
            // Assign remaining arguments to `args`.
            const list = try object.listNew(interp.heap, args[called_idx..]);
            errdefer list.release();
        }
    }
}

pub fn evalList(interp: *Interp, list: Heap.Handle) !void {
    _ = interp;
    _ = list;

    @panic("unimplemented");
}

pub fn getResult(interp: *Interp) Heap.Handle {
    if (interp.result) |result| {
        return result;
    } else {
        return interp.heap.emptyObject();
    }
}

fn freeLastResult(interp: *Interp) void {
    interp.result.release();
    interp.result = interp.heap.emptyObject();
}

pub fn setResult(interp: *Interp, handle: Heap.Handle) !void {
    interp.freeLastResult();
    interp.result = try interp.heap.borrow(handle);
}

pub fn setResultOwning(interp: *Interp, handle: Heap.Handle) void {
    interp.freeLastResult();
    interp.result = handle;
}

pub fn setResultString(interp: *Interp, bytes: []const u8) !void {
    interp.freeLastResult();
    const bytes_handle = try object.newString(interp.heap, bytes);
    defer bytes_handle.release();

    setResult(interp, bytes_handle);
}

pub fn setEmptyResult(interp: *Interp) void {
    interp.freeLastResult();
    interp.result = interp.heap.emptyObject();
}

const VariableMap = std.StringHashMap(Heap.Handle);
/// Call frame.
const CallFrame = struct {
    /// Parent index.
    parent: u32,
    /// Level of the call frame. 0 = global.
    level: u32,
    /// Dictionary containing the frame's variables.
    variables: Heap.Handle,
    /// Arguments of the procedure call.
    args: []Heap.Handle,
    /// Signature of the procedure that this is being called with.
    signature: ProcedureSignature,
    /// An object that contains a string with the current namespace. For example,
    /// it might contain "foo::bar", with that being the current namespace.
    namespace: ?Heap.Handle,
    /// Call epoch. Used to invalidate previous variable lookups. Can overflow,
    /// but when it overflows it'll scan the heap and reset all cached lookups.
    call_epoch: u31,
};

fn currentCallFrameIndex(interp: *Interp) u32 {
    return @intCast(interp.call_frames.items.len - 1);
}

fn currentCallFrame(interp: *Interp) *CallFrame {
    return &interp.call_frames.items[interp.currentCallFrameIndex()];
}

fn incrementCallEpoch(interp: *Interp) void {
    interp.current_call_epoch = std.math.add(u31, interp.current_call_epoch, 1) catch @panic("TODO handle overflow properly");
}

/// Evaluation frame.
const EvalFrame = struct {
    /// Pointer to the corrisponding call frame.
    call_frame: u32,
    /// Arguments of this eval frame.
    args: []Heap.Handle,
};

fn currentEvalFrameIndex(interp: *Interp) u32 {
    return @intCast(interp.eval_frames.items.len - 1);
}

fn currentEvalFrame(interp: *Interp) *EvalFrame {
    return &interp.eval_frames[interp.currentCallFrameIndex()];
}

fn pushCallFrame(interp: *Interp, parent: u32, args: []Heap.Handle, signature: ProcedureSignature) !u32 {
    const namespace = try interp.heap.borrowOptional(interp.namespace);
    errdefer if (namespace) |ns| ns.release();
    const borrowed_signature = try signature.borrow(interp.heap);
    errdefer borrowed_signature.release();

    const new_call_frame_idx = interp.call_frames.items.len;
    try interp.call_frames.append(interp.gpa, .{
        .parent = parent,
        .args = args,
        .call_epoch = interp.current_call_epoch,
        .level = interp.call_frames.items[parent].level + 1,
        .namespace = namespace,
        .signature = borrowed_signature,
    });

    interp.incrementCallEpoch();

    return @intCast(new_call_frame_idx);
}

fn pushEvalFrame(interp: *Interp) u32 {
    interp.eval_frames.append(interp.gpa, .{
        .call_frame = interp.currentCallFrameIndex(),
    });
    return interp.currentEvalFrameIndex();
}

fn popEvalFrame(interp: *Interp) void {
    interp.eval_frames.pop() orelse unreachable;
}

/// Caller should release return value when they're done.
fn substituteOneToken(interp: *Interp, tag: Parser.Token.Tag, value: Heap.Handle) !Heap.Handle {
    switch (tag) {
        .simple_string => {
            return try interp.heap.borrow(value);
        },
        .variable_subst => {
            var det: object.ErrorDetails = undefined;
            const var_target = try interp.wrapErrorDetails(&det, interp.getVariable(&det, value));
            return try interp.heap.borrow(var_target);
        },
        .dict_sugar => {
            @panic("Dict sugar unimplemented");
        },
        .expression_sugar => {
            @panic("Expression sugar unimplemented");
        },
        .command_subst => {
            var new_value = value;
            const result = interp.eval(&new_value);

            // The only case where the new value is not the same as the last value is if `eval`
            // converted it from a string to a script. If so, we want to copy that script id
            // back to the token list so we'll use the cached script for future invocations.
            if (new_value != value) {
                assert(value.heap == interp.heap.heap_id);
                assert(new_value.heap == interp.heap.heap_id);
                assert(new_value.peek().tag == .script);

                // Copy over the new script id.
                value.invalidateBody();
                value.peek().tag = .script;
                value.peek().body.script = new_value.peek().body.script;
            }

            // Be sure to propagate any error that eval returned.
            if (result) {
                return interp.getResult();
            } else |err| {
                return err;
            }
        },
        else => {
            std.debug.panic("Tried to substitute token {}", .{tag});
        },
    }
}

fn interpolateTokens(
    interp: *Interp,
    tags: []const Parser.Token.Tag,
    value_list: Heap.Handle,
    value_start: u32,
    value_len: u32,
    substitution_only: bool,
) !Heap.Handle {
    const args_alloc_backing = std.heap.stackFallback(@sizeOf(Heap.Handle) * 8, interp.gpa);
    const tokens_alloc = args_alloc_backing.get();

    const new_values = try tokens_alloc.alloc(Heap.Handle, value_len);
    defer tokens_alloc.free(new_values);

    // Substitute all the tokens, placing them in `new_values`.
    for (tags, value_start..(value_start + value_len), 0..) |tag, value_index, i| {
        if (interp.substituteOneToken(tag, object.dictItemRaw(value_list, value_index))) |new_value| {
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
                        interp.setResultString("invoked \"break\" outside of a loop");
                        new_err = Error.EvalError;
                    },
                    Error.Continue => {
                        interp.setResultString("invoked \"continue\" outside of a loop");
                        new_err = Error.EvalError;
                    },
                    else => {},
                }
            }

            // Clean everything up before we return.
            for (0..i) |cleanup_idx| {
                new_values[cleanup_idx].release();
            }

            return new_err;
        }
    }

    var new_str_len: usize = 0;
    for (new_values) |new_value| {
        new_str_len += (try Heap.getString(new_value)).len;
    }

    const new_str = object.newStringToFill(interp.heap, new_str_len);
    if (Heap.getStringMut(new_str)) |new_str_mut| {
        var written: usize = 0;
        for (new_values) |new_value| {
            const value_str = try Heap.getString(new_value);
            @memcpy(new_str_mut[written..][0..value_str.len], value_str);
            written += value_str.len;
        }
    } else |err| {
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotMutable => unreachable,
        }
    }

    return new_str;
}

/// Qualifies a name to its canonical version. For example, a name of "bar", and a namespace
/// of "foo" would return "foo::bar", allocated on the arena.
fn qualifyName(arena: std.mem.Allocator, namespace: Heap.Handle, name: []const u8) ![]const u8 {
    // We're in a non-global namespace, so we'll need to append the namespace to the
    // beginning of the name, if the name isn't globally scoped (e.g. by not
    // having :: at the beginning).
    if (name.len < 2 or name[0] != ':' or name[1] != ':') {
        const namespace_name = try Heap.getString(unwrapped);
        return try std.fmt.allocPrint(arena, "{}::{}", .{ namespace_name, name });
    }
}

/// This function returns the command that's found based on the string contents of `handle`.
/// This also specializes the object to contain a cached lookup for the command.
pub fn getCommand(interp: *Interp, det: ?object.ErrorDetails, handle: *Heap.Handle) !*Command {
    early_exit: {
        // Can't use a command's cached value if it's from another heap.
        if (handle.heap != interp.heap.heap_id) break :early_exit;

        const obj = handle.peek();

        // TODO PERF: honestly at this point, because the namespace has to be stored off the heap,
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
                if (!try Heap.checkIfEqual(namespace, handle.getHeap().getLocalObject(obj_namespace.namespace))) {
                    break :early_exit;
                }
            } else if (!obj.body.command.in_global_namespace) {
                // The interpreter is in a global namespace, and this object wasn't, so we'll need to look
                // up the command again.
                break :early_exit;
            }

            // TODO should I implement `local`?

            // All checks passed, so now we can return the cached command's pointer.
            if (obj.body.command.in_global_namespace) {
                return obj.body.command.u.global_namespace.command_index;
            } else {
                const extra_data = interp.heap.getExtraData(obj.body.command.u.other_namespace);
                return &interp.commands.values()[extra_data.command.command_index];
            }
        } else break :early_exit;
    }

    const command_name = try Heap.getString(handle.*);

    // There wasn't a cached version, or it was invalid, so we'll need to look up this command.
    const current_namespace = interp.currentCallFrame().namespace;
    const fallback_allocator = std.heap.StackFallbackAllocator(64).get();
    const qualified = blk: {
        // Only qualify if we're in a namespace.
        if (current_namespace) |namespace| {
            break :blk qualifyName(fallback_allocator, namespace, command_name);
        }
        break :blk null;
    };
    defer if (qualified) |unwrapped| fallback_allocator.free(unwrapped);

    var command_index = interp.commands.getIndex(qualified orelse command_name);
    if (qualified != null and command_index == null) {
        // If we couldn't find the command in the namespace, we should check if it's in the global
        // namespace (by not qualifying the name, and instead using it raw).
        command_index = interp.commands.getIndex(command_name);
    }

    // Cache the command.
    if (command_index) |index| {
        try interp.heap.prepareToShimmer(handle);
        handle.peek().tag = .command;

        if (current_namespace) |namespace| {
            assert(handle.heap == interp.heap.heap_id);

            const borrowed_namespace = try interp.heap.borrow(namespace);
            errdefer borrowed_namespace.release();
            assert(borrowed_namespace.heap == handle.heap);

            const extra_data = try interp.heap.createExtraData();
            errdefer interp.heap.destroyExtraData(extra_data);
            interp.heap.extra.items[extra_data].command = .{
                .command_index = index,
                .namespace = borrowed_namespace.index,
            };

            handle.peek().body.command = .{
                .procedure_epoch = interp.current_procedure_epoch,
                .in_global_namespace = false,
                .u = .{ .other_namespace = extra_data },
            };
        } else {
            handle.peek().body.command = .{
                .procedure_epoch = interp.current_procedure_epoch,
                .in_global_namespace = true,
                .u = .{ .global_namespace = index },
            };
        }
    } else {
        // If it was null, we better error.
        if (det) |details| details.* = .{
            .message = object.newStringFmt(interp.heap, "invalid command name \"{s}\"", .{command_name}),
        };
        return Error.CommandNotFound;
    }
}

fn invokeCommand(interp: *Interp, args: []Heap.Handle) !void {
    var det: object.ErrorDetails = undefined;
    const command = interp.wrapErrorDetails(&det, getCommand(interp, &det, &args[0])) catch |err| switch (err) {
        Error.OutOfMemory => Error.OutOfMemory,
        Error.CommandNotFound => {
            // TODO invoke jim unknown
            @panic("unimplemented");
        },
    };

    if (interp.eval_depth >= interp.max_eval_depth) {
        interp.setResultString("Infinite eval recursion");
        return Error.InfiniteRecursion;
    }

    interp.eval_depth += 1;

    // Loop the calling section, as there may be a tailcall.
    var current_args = args;
    while (true) {
        interp.currentEvalFrame().args = current_args;
        // TODO implement tracing.

        // Be sure to clear the previous result.
        interp.setEmptyResult();
        command.call(interp, current_args);

        //command.
        break;
    }
}

pub fn evalObject(interp: *Interp, script: *Heap.Handle) !void {
    // If the object is of type "list", with no string rep we can call a specialized version of eval().
    if (script.peek().tag == .list and script.hasString()) {
        return interp.evalList(script);
    }

    // Try to get the script, parsing if necessary.
    var det: object.ErrorDetails = undefined;
    const parsed = try interp.wrapErrorDetails(&det, object.getScript(interp.heap, &det, script));

    // Reset the interpreter result. This is useful to return the empty result in the case of empty program.
    interp.setEmptyResult();

    // TODO need to set stack frame on error, something like:
    // errdefer interp.setErrorStack()

    // TODO implement JIM_OPTIMIZATION speedups

    // FIXME do I need `script->inUse++;`?

    _ = interp.pushEvalFrame();
    defer interp.popEvalFrame();

    // Used for allocating the arguments passed into a command call.
    const args_alloc_backing = std.heap.stackFallback(@sizeOf(Heap.Handle) * 8, interp.gpa);
    const args_alloc = args_alloc_backing.get();

    // Execute every command sequentially until the end of the script or an error occurs.
    var command_token_i: u32 = 0;

    const tags = parsed.tags.items;
    const values = object.listItemsRaw(parsed.values);
    // Loop through the script's commands.
    while (command_token_i < tags.len) : (command_token_i += 1) {
        // First token of the line is always .script_command.
        const command_info = values[command_token_i].body.script_command;
        command_token_i += 1; // Skip .script_command.

        // This is not always the same as which word token we're on, as argument expansion
        // may write multiple arguments from one word.
        var args_written: usize = 0;
        var args = try args_alloc.alloc(Heap.Handle, command_info.arg_count);
        defer args_alloc.free(args);
        defer for (args) |arg| arg.release();

        // Populate the arguments by looping through each word of the command and
        // substituting.
        var word_token_i: u32 = command_token_i;
        while (word_token_i < command_token_i + command_info.arg_count) : (word_token_i += 1) {
            var word_parts: u32 = 1;
            const argument_expansion = tags[word_token_i] == .argument_expansion;
            if (tags[word_token_i] == .start_of_word or argument_expansion) {
                word_parts = values[word_token_i].body.integer;
                word_token_i += 1;
            } else unreachable;

            var resultant_word: Heap.Handle = blk: {
                if (word_parts == 1) {
                    // Simple one-to-one substitution, so an easy case.
                    break :blk try interp.substituteOneToken(tags[word_token_i], object.listItemRaw(parsed.values, word_token_i));
                } else {
                    // Helper function that'll interpolate all the word parts and merge them into a string.
                    break :blk try interp.interpolateTokens(tags[word_token_i..][0..word_parts], parsed.values, word_token_i, word_parts);
                }
            };

            if (argument_expansion) {
                // Argument expansion, so we'll need to shimmer the result to a list.
                det = undefined;
                const len = try wrapErrorDetails(interp, &det, object.listLength(interp.heap, &det, &resultant_word));
                // Free the list backing without running destructors, since we're going to steal the items
                // directly from the list.
                defer Heap.freeObjectBacking(resultant_word);

                if (len > 1) {
                    // Expanded into multiple tokens, so we'll need to resize args.
                    args = try args_alloc.realloc(args, args.len - 1 + len);
                }

                assert(!resultant_word.isShared());
                for (0..len) |list_idx| {
                    // Steal each object from the list.
                    args[args_written] = try interp.heap.steal(object.listItemRaw(resultant_word, list_idx));
                    args_written += 1;
                }
            } else {
                args[args_written] = try interp.heap.steal(object.listItemRaw(resultant_word, 0));
                args_written += 1;
            }
        }

        // Now that we've populated the arguments for this command, we'll go ahead and run it.
        const result = interp.invokeCommand(args);
        // TODO actually check for signals.
        if (false) {
            return Error.Signal;
        } else {
            if (result) |_| {} else |err| return err;
        }
    }
}

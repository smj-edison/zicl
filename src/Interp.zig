const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const Parser = @import("Parser.zig");
const Heap = @import("Heap.zig");
const Handle = Heap.Handle;
const object = @import("object.zig");

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

pub const CommandFn = fn (interp: *Interp, args: []Handle) Error!void;

pub const Error = std.mem.Allocator.Error || object.Error || error{
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

const Tailcall = struct {
    args: []Handle,
};

/// Used to convert from an object error to an interpreter error (e.g. putting
/// it in the interpreter result, instead of det)
fn wrapErrorDetails(interp: *Interp, det: *object.ErrorDetails, result: anytype) @TypeOf(result) {
    if (result) |unwrapped| {
        return unwrapped;
    } else |err| {
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                // This error should have error details, if it's not OOM.
                interp.setResultOwning(det.message);
                return err;
            },
        }
    }
}

fn variableNotFoundError(det: ?*object.ErrorDetails, var_name: []const u8) !void {
    if (det) |details| details.* = .{
        .message = try object.newStringFmt("can't read \"{s}\": no such variable", .{var_name}),
    };

    return error.VariableNotFound;
}

const VariableInfo = struct {
    target_index: u32,
    call_frame_idx: u32,
};

/// Resolves to the variable's value, if any. Accounts for :: for globals.
fn resolveVariable(interp: *Interp, var_call_frame: u32, var_name: [:0]const u8) ?VariableInfo {
    var call_frame_idx: u32 = 0;
    var var_value: ?Handle = null;

    //  No need to check slice length since it's null terminated.
    if (var_name[0] == ':' and var_name[1] == ':') {
        call_frame_idx = 0; // global frame

        // Skip as many colons as are present to match tcl behavior.
        var trimmed_var_name = var_name;
        while (trimmed_var_name[0] == ':') trimmed_var_name = trimmed_var_name[1..];

        const var_dict = interp.call_frames.items[call_frame_idx].variables;

        interp.heap.setTempObjectString(trimmed_var_name);
        defer interp.heap.resetTempObject();
        // Can't fail since we know a string exists for it.
        var_value = (object.dictLookupRaw(var_dict, interp.heap.tempObject()) catch unreachable);

        // Global scope doesn't have statics.
    } else {
        call_frame_idx = var_call_frame;

        const var_dict = interp.call_frames.items[call_frame_idx].variables;
        const statics_dict = interp.call_frames.items[call_frame_idx].signature.statics;

        // Check the variables dictionary.
        interp.heap.setTempObjectString(var_name);
        // Can't fail since we know a string exists for it.
        var_value = (object.dictLookupRaw(var_dict, interp.heap.tempObject()) catch unreachable);
        interp.heap.resetTempObject();

        // Maybe it's in the statics dictionary instead?
        if (var_value == null) {
            if (statics_dict) |dict| {
                // The temp object is an object with a long string. What we can do is
                // swap out that long string's `string` value to the var name. This avoids
                // allocating a heap object, just to immediately drop it.
                interp.heap.setTempObjectString(var_name);
                // Can't fail since we know a string exists for it.
                var_value = object.dictLookupRaw(dict, interp.heap.tempObject()) catch unreachable;
                interp.heap.resetTempObject();
            }
        }
    }

    if (var_value) |unwrapped| {
        assert(unwrapped.heap == interp.heap.heapId());

        return .{
            .target_index = unwrapped.index,
            .call_frame_idx = call_frame_idx,
        };
    }

    return null;
}

/// This always shimmers to .variable. You probably should be using `ensureValidVariableType`.
/// Must be called with a heap-native variable name.
fn reshimmerToVariable(interp: *Interp, det: ?*object.ErrorDetails, call_frame_idx: u32, name: Handle) !void {
    assert(name.canShimmer());

    const var_name = try Heap.getString(name);
    const call_frame = interp.call_frames.items[call_frame_idx];

    if (interp.resolveVariable(call_frame_idx, var_name)) |var_info| {
        // Free the old representation and set the new one.
        name.invalidateBody();

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

/// Ensures that this is a valid variable, dict sugar, or upvar.
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
    assert(name.canShimmer());

    const call_frame = &interp.call_frames.items[call_frame_idx];
    const name_bytes = try Heap.getString(name);

    if (name_bytes.len >= 2 and name_bytes[0] == ':' and name_bytes[1] == ':') {
        var trimmed = name_bytes;
        // Trim all preceding colons to match tcl behavior.
        while (trimmed[0] == ':') trimmed = trimmed[1..];

        // Add variable.
        interp.heap.setTempObjectString(trimmed);
        defer interp.heap.resetTempObject();
        const new_value = try object.dictPutObject(&interp.call_frames.items[0].variables, interp.heap.tempObject(), value);

        name.peek().tag = .variable;
        name.peek().body.variable = .{
            .call_epoch = call_frame.call_epoch,
            .index = new_value.index,
            .is_global = true,
        };
    } else {
        // Add variable.
        const new_value = try object.dictPutObject(&call_frame.variables, name, value);

        name.peek().tag = .variable;
        name.peek().body.variable = .{
            .call_epoch = call_frame.call_epoch,
            .index = new_value.index,
            .is_global = false,
        };
    }
}

/// Must be called with a heap-native name.
fn setVariableImpl(interp: *Interp, call_frame_idx: u32, name: Handle, value: Heap.Object) !void {
    if (interp.ensureValidVariableType(null, call_frame_idx, name)) {
        switch (name.peek().tag) {
            .dict_subst => @panic("Dict sugar not implemented"),
            .variable => {
                const variable = &name.peek().body.variable;
                const var_call_frame_idx = if (variable.is_global) 0 else call_frame_idx;
                const var_call_frame = &interp.call_frames.items[var_call_frame_idx];

                const value_handle = try object.dictPutObject(&var_call_frame.variables, name, value);
                variable.* = .{
                    .call_epoch = var_call_frame.call_epoch,
                    .index = value_handle.index,
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
            @panic("Dict sugar unimplemented");
        },
        else => unreachable,
    }
}

fn testVariables(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    _ = try Heap.testStart(ta);
    var interp = try Interp.init();
    defer interp.deinit();

    try testing.expectEqual(null, interp.resolveVariable(0, "foo"));
    var foo = try object.newString("foo");
    defer foo.release();
    const value = try object.newString("value");
    defer value.release();
    try interp.setVariableTo(&foo, value);

    const lookup_value = interp.resolveVariable(0, "foo").?.target_index;
    try testing.expectEqualStrings("value", try Heap.getString(Heap.local_heap.getHandle(lookup_value)));
    // Should be copied.
    try testing.expect(lookup_value != value.index);
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

    pub fn borrow(signature: ProcedureSignature, heap: *Heap) !ProcedureSignature {
        const args = try heap.borrow(signature.args);
        errdefer args.release();
        const body = try heap.borrow(signature.body);
        errdefer body.release();
        const statics = try heap.borrowOptional(signature.statics);
        errdefer if (statics) |val| val.release();
        const optional_values = try heap.borrowOptional(signature.optional_values);
        errdefer if (optional_values) |val| val.release();

        return .{
            .args = args,
            .body = body,
            .statics = statics,
            .required_arity = signature.required_arity,
            .optional_arity = signature.optional_arity,
            .optional_values = optional_values,
            .has_args_parameter = signature.has_args_parameter,
        };
    }

    pub fn release(signature: ProcedureSignature) void {
        signature.args.release();
        signature.body.release();
        if (signature.statics) |statics| statics.release();
        if (signature.optional_values) |values| values.release();
    }
};

pub const Command = struct {
    pub const NativeCommand = struct {
        to_call: *const CommandFn,
        description: ?[]const u8,
        min_arity: usize,
        max_arity: ?usize,
        /// If the command argument length needs to be a multiple of some
        /// amount, set this. A good example is `dict create`, as it needs
        /// an even number of arguments.
        multiple_of: ?usize,
    };

    namespace: ?Handle,
    call_info: union(enum) {
        native: NativeCommand,
        tcl: struct {
            signature: ProcedureSignature,
        },
    },

    pub fn deinit(command: *Command) void {
        if (command.namespace) |namespace| namespace.release();

        switch (command.call_info) {
            .tcl => |val| val.signature.release(),
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
        .message = try object.newStringFmt("wrong # args: should be \"{s}\"", .{command_usage}),
    };

    return Error.CommandNotFound;
}

/// Takes ownership of name.
pub fn createCommand(interp: *Interp, name: []const u8, command: Command) !void {
    // TODO make sure to check interp->local if we end up needing it in our impl
    const old_command = try interp.commands.fetchPut(interp.gpa, name, command);
    if (old_command) |unwrapped| {
        var old_command_mut = unwrapped.value;
        old_command_mut.deinit();
    }
}

pub fn registerCommand(interp: *Interp, name: []const u8, details: Command.NativeCommand) !void {
    try interp.commands.put(interp.gpa, name, .{ .namespace = null, .call_info = .{ .native = details } });
}

fn callProcedure(interp: *Interp, command: *Command, args: []Handle) !void {
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
        return interp.wrapErrorDetails(&det, wrongArgumentCountError(&det, command_usage));
    }

    // Check for infinite recursion.
    if (interp.currentCallFrame().level >= interp.max_call_depth) {
        try interp.setResultString("Too many nested calls. Infinite recursion?");
        return Error.InfiniteRecursion;
    }

    const parent_idx = interp.currentCallFrameIndex();
    const call_frame_idx = try interp.pushCallFrame(parent_idx, args, signature.*);

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
            const list = try object.listNew(args[called_idx..]);
            defer list.release();
            try interp.setVariableImpl(call_frame_idx, var_name, list.reference());
        } else if (signature_idx > signature.required_arity) {
            // This is an optional argument.

            // Are there any remaining unassigned arguments?
            if (called_idx < args.len) {
                try interp.setVariableImpl(call_frame_idx, var_name, try interp.heap.referenceOrDuplicate(args[called_idx]));
                called_idx += 1;
            } else {
                // Else populate it with its default value.
                const default_value = object.listItem(signature.optional_values.?, signature_idx - signature.required_arity);
                try interp.setVariableImpl(call_frame_idx, var_name, try interp.heap.referenceOrDuplicate(default_value));
            }
        } else {
            try interp.setVariableImpl(call_frame_idx, var_name, try interp.heap.referenceOrDuplicate(args[called_idx]));
            called_idx += 1;
        }
    }

    // TODO implement trace

    return interp.evalObject(&signature.body);
}

fn callNative(interp: *Interp, command: *Command, args: []Handle) !void {
    const signature = command.call_info.native;

    early_exit: {
        // Check arg count.
        if (args.len < signature.min_arity) break :early_exit;
        if (signature.max_arity) |max_arity| {
            if (args.len > max_arity) break :early_exit;
        }
        if (signature.multiple_of) |multiple_of| {
            if (@mod(args.len, multiple_of) != 0) break :early_exit;
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
    return interp.wrapErrorDetails(&det, wrongArgumentCountError(&det, command_usage));
}

pub fn evalList(interp: *Interp, list: *Handle) !void {
    _ = interp;
    _ = list;

    @panic("unimplemented");
}
fn freeLastResult(interp: *Interp) void {
    interp.result.release();
    interp.result = interp.heap.emptyObject();
}

pub fn setResult(interp: *Interp, handle: Handle) !void {
    interp.freeLastResult();
    interp.result = try handle.borrow();
}

pub fn setResultOwning(interp: *Interp, handle: Handle) void {
    interp.freeLastResult();
    interp.result = handle;
}

pub fn setResultInteger(interp: *Interp, value: i64) !void {
    interp.setResultOwning(try object.integerNew(value));
}

pub fn setResultString(interp: *Interp, bytes: []const u8) !void {
    interp.freeLastResult();
    const bytes_handle = try object.newString(bytes);

    try setResult(interp, bytes_handle);
}

pub fn setResultFormatted(interp: *Interp, comptime fmt: []const u8, args: anytype) !void {
    interp.freeLastResult();
    const fmt_handle = try object.newStringFmt(fmt, args);

    try setResult(interp, fmt_handle);
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
    /// Arguments of the procedure call.
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
    args: ?[]Handle,
};

fn currentEvalFrameIndex(interp: *Interp) u32 {
    return @intCast(interp.eval_frames.items.len - 1);
}

fn currentEvalFrame(interp: *Interp) *EvalFrame {
    return &interp.eval_frames.items[interp.currentCallFrameIndex()];
}

fn pushCallFrame(interp: *Interp, parent: ?u32, args: []Handle, signature: ProcedureSignature) !u32 {
    const namespace = try Handle.borrowOptional(interp.namespace);
    errdefer if (namespace) |ns| ns.release();
    const vars_handle = try object.dictNew(&.{});
    errdefer vars_handle.release();

    const level = if (parent) |val| interp.call_frames.items[val].level + 1 else 0;
    const new_call_frame_idx = interp.call_frames.items.len;
    try interp.call_frames.append(interp.gpa, .{
        .parent = parent,
        .args = args,
        .call_epoch = interp.current_call_epoch,
        .level = level,
        .namespace = namespace,
        // Take ownership.
        .signature = signature,
        // TODO PERF recycle variable hash table if possible.
        .variables = vars_handle,
        .tailcall = null,
    });

    interp.incrementCallEpoch();

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
fn substituteOneToken(interp: *Interp, tag: Parser.Token.Tag, value: Handle) !Handle {
    switch (tag) {
        .simple_string => {
            return try value.borrow();
        },
        .variable_subst => {
            var det: object.ErrorDetails = undefined;
            const var_target = try interp.wrapErrorDetails(&det, interp.getVariableImpl(&det, value));
            return try var_target.borrow();
        },
        .dict_sugar => {
            @panic("Dict sugar unimplemented");
        },
        .expression_sugar => {
            @panic("Expression sugar unimplemented");
        },
        .command_subst => {
            var new_value = value;
            const result = interp.evalObject(&new_value);

            // The only case where the new value is not the same as the last value is if `eval`
            // converted it from a string to a script. If so, we want to copy that script id
            // back to the token list so we'll use the cached script for future invocations.
            if (new_value != value) {
                assert(value.heap == interp.heap.heapId());
                assert(new_value.heap == interp.heap.heapId());
                assert(new_value.peek().tag == .script);

                // Copy over the new script id.
                value.invalidateBody();
                value.peek().tag = .script;
                value.peek().body.script = new_value.peek().body.script;
            }

            // Be sure to propagate any error that eval returned.
            if (result) {
                return try interp.result.borrow();
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
        if (interp.substituteOneToken(tag, object.dictItem(value_list, @intCast(value_index)))) |new_value| {
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
                new_values[cleanup_idx].release();
            }

            return new_err;
        }
    }

    var new_str_len: usize = 0;
    for (new_values) |new_value| {
        new_str_len += (try Heap.getString(new_value)).len;
    }

    const new_str = try object.newStringToFill(new_str_len);
    errdefer new_str.release();
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
pub fn getCommand(interp: *Interp, det: ?*object.ErrorDetails, handle: *Handle) !*Command {
    early_exit: {
        // Can't use a command's cached value if it's from another heap.
        if (handle.heap != interp.heap.heapId()) break :early_exit;

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
                if (!try Heap.checkIfEqual(namespace, handle.getHeap().getHandle(obj_namespace.namespace))) {
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
                return &interp.commands.values()[obj.body.command.u.global_namespace.command_index];
            } else {
                const extra_data = interp.heap.getExtraData(obj.body.command.u.other_namespace);
                return &interp.commands.values()[extra_data.command.command_index];
            }
        } else break :early_exit;
    }

    const command_name = try Heap.getString(handle.*);

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
        try Heap.prepareToShimmer(handle);
        handle.peek().tag = .command;

        if (current_namespace) |namespace| {
            assert(handle.heap == interp.heap.heapId());

            const borrowed_namespace = try namespace.borrow();
            errdefer borrowed_namespace.release();
            assert(borrowed_namespace.heap == handle.heap);

            const extra_data = try interp.heap.createExtraData();
            errdefer interp.heap.destroyExtraData(extra_data);
            interp.heap.getExtraData(extra_data).* = .{
                .command = .{
                    .command_index = @intCast(index),
                    .namespace = borrowed_namespace.index,
                },
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
                .u = .{ .global_namespace = .{ .command_index = @intCast(index) } },
            };
        }

        return &interp.commands.values()[index];
    } else {
        // If it was null, we better error.
        if (det) |details| details.* = .{
            .message = try object.newStringFmt("invalid command name \"{s}\"", .{command_name}),
        };
        return error.CommandNotFound;
    }
}

fn invokeCommand(interp: *Interp, args: []Handle) !void {
    var det: object.ErrorDetails = undefined;
    const command = interp.wrapErrorDetails(&det, getCommand(interp, &det, &args[0])) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CommandNotFound => {
            // TODO invoke jim unknown
            @panic("unimplemented");
        },
    };

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
                    for (prev_tailcall.args) |arg| arg.release();
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

pub fn evalObject(interp: *Interp, script: *Handle) (Error || Parser.Error)!void {
    // If the object is of type "list", with no string rep we can call a specialized version of eval().
    if (script.peek().tag == .list and script.hasString()) {
        return interp.evalList(script);
    }

    // Try to get the script, parsing if necessary.
    var det: object.ErrorDetails = undefined;
    const parsed = try interp.wrapErrorDetails(&det, object.getScript(&det, script));

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

    parsed.printTokens();

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
        @memset(args, interp.heap.nullObject());
        defer args_alloc.free(args);
        defer for (args) |arg| arg.release();

        // Populate the arguments by looping through each word of the command and
        // substituting.
        var word_token_i: u32 = command_token_i;
        while (word_token_i < command_token_i + command_info.arg_count) : (word_token_i += 1) {
            std.debug.print(
                "word_token_i: {}, command_token_i: {}, command_info.arg_count: {}\n",
                .{ word_token_i, command_token_i, command_info.arg_count },
            );
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
                const len = try wrapErrorDetails(interp, &det, object.listLength(&det, &resultant_word));
                // Free the list backing without running destructors, since we're going to steal the items
                // directly from the list.
                defer Heap.freeObjectBacking(resultant_word);

                if (len > 1) {
                    // Expanded into multiple tokens, so we'll need to resize args.
                    args = try args_alloc.realloc(args, args.len - 1 + len);
                }

                assert(resultant_word.canModify());
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
        for (args) |arg| std.debug.print("{s} ", .{try Heap.getString(arg)});
        std.debug.print("\n", .{});

        const result = interp.invokeCommand(args);
        // TODO actually check for signals.
        if (false) {
            return Error.Signal;
        } else {
            if (result) |_| {} else |err| return err;
        }
    }
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
    };

    _ = try new_interp.pushCallFrame(null, &.{}, .{
        .args = try object.listNew(&.{}),
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
    interp.result.release();
    var iter = interp.commands.iterator();
    while (iter.next()) |*entry| {
        switch (entry.value_ptr.call_info) {
            .native => {
                // Don't free the string, as it's in .data
            },
            .tcl => {
                interp.gpa.free(entry.key_ptr.*);
            },
        }

        entry.value_ptr.deinit();
    }
    interp.commands.deinit(interp.gpa);

    // Deinit all frames.
    for (interp.call_frames.items) |frame| {
        // deinit args.
        for (frame.args) |arg| arg.release();
        interp.gpa.free(frame.args);

        if (frame.namespace) |namespace| namespace.release();
        frame.variables.release();
        frame.signature.release();
    }
    interp.call_frames.deinit(interp.gpa);

    interp.eval_frames.deinit(interp.gpa);
}

// Export various utility functions with a nicer interface.
pub fn getInteger(interp: *Interp, handle: *Handle) !i64 {
    var det: object.ErrorDetails = undefined;
    try wrapErrorDetails(interp, &det, object.shimmerToInteger(&det, handle));
    return handle.peek().body.integer;
}

pub fn getIntegerNoShimmer(interp: *Interp, handle: Handle) !i64 {
    var det: object.ErrorDetails = undefined;
    return interp.wrapErrorDetails(&det, object.integerGetNoShimmer(&det, handle));
}

pub fn getFloat(interp: *Interp, handle: *Handle) !f64 {
    var det: object.ErrorDetails = undefined;
    try wrapErrorDetails(interp, &det, object.shimmerToFloat(&det, handle));
    return handle.peek().body.float;
}

pub fn getListLength(interp: *Interp, handle: *Handle) !u32 {
    var det: object.ErrorDetails = undefined;
    try wrapErrorDetails(interp, &det, object.shimmerToList(&det, handle));
    return handle.peek().body.list.len;
}

pub fn listAppend(interp: *Interp, list: *Handle, item: Handle) !Handle {
    var det: object.ErrorDetails = undefined;
    return try wrapErrorDetails(interp, &det, object.listAppend(&det, list, item));
}

pub fn setVariableToObject(interp: *Interp, name: *Handle, obj: Heap.Object) !void {
    try Heap.prepareToShimmer(name);
    return interp.setVariableImpl(interp.currentCallFrameIndex(), name.*, obj);
}

pub fn setVariableTo(interp: *Interp, name: *Handle, handle: Handle) !void {
    try Heap.prepareToShimmer(name);
    return interp.setVariableImpl(interp.currentCallFrameIndex(), name.*, try Heap.local_heap.duplicateOrReference(handle));
}

pub fn getVariableNoDetails(interp: *Interp, name: *Handle) !Handle {
    try Heap.prepareToShimmer(name);
    return interp.getVariableImpl(null, name.*);
}

pub fn getVariable(interp: *Interp, name: *Handle) !Handle {
    try Heap.prepareToShimmer(name);
    var det: object.ErrorDetails = undefined;
    return interp.wrapErrorDetails(&det, interp.getVariableImpl(&det, name.*));
}

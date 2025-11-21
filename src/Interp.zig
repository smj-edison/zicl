const std = @import("std");
const assert = std.debug.assert;

const Heap = @import("Heap.zig");
const object = @import("object.zig");

const Interp = @This();

heap: *Heap,
gpa: std.mem.Allocator,

/// The result from a procedure or eval call
result: ?Heap.Handle,
error_details: object.ErrorDetails,
/// Eval frames are separate from call frames, as eval calls can be
/// nested while staying in the same scope. For example,
/// `puts [+ 2 2]` has one call frame (the global scope), and two
/// eval frames (one for puts, and while puts is running, another
/// for +).
eval_frames: std.ArrayList(EvalFrame),
call_frames: std.ArrayList(CallFrame),
/// Used to invalidate cached variable lookups. Will overflow, but
/// when it overflows it'll scan through the heap and invalidate all
/// variables.
current_epoch: u31,
commands: CommandHashTable,

evaluating_safe_expr: bool,

pub const CommandFn = fn (interp: *Interp, args: []const Heap.Handle) void;

pub const Error = std.mem.Allocator.Error || error{
    EvaluatingSafeExpression,
    IsDictSugar,
    VariableNotFound,
};

const ProcedureSignature = struct {
    /// Handle to the argument list of the procedure.
    args: Heap.Handle,
    /// Handle to the ScriptId object.
    body: Heap.Handle,
    /// Handle to the statics dictionary.
    statics: Heap.Handle,
};

pub const Command = struct {
    ref_count: u32,
    call: union(enum) {
        native: *const CommandFn,
        tcl: struct {
            signature: ProcedureSignature,
        },
    },

    pub fn deinit(gpa: std.mem.Allocator) void {
        _ = gpa;
    }
};

pub const CommandHashTable = std.HashMapUnmanaged(Heap.Handle, Command, struct {
    pub fn hash(ctx: @This(), key: Heap.Handle) u64 {
        _ = ctx;

        const str = key.getString() catch return 0;
        return std.hash_map.hashString(str);
    }

    pub fn eql(ctx: @This(), a: Heap.Handle, b: Heap.Handle) bool {
        _ = ctx;

        return Heap.checkIfEqual(a, b) catch return false;
    }
}, 80);

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

pub fn evalList(interp: *Interp, list: Heap.Handle) !void {
    _ = interp;
    _ = list;

    @panic("unimplemented");
}

pub fn setResult(interp: *Interp, handle: Heap.Handle) !void {
    interp.result = try interp.heap.borrow(handle);
}

pub fn setResultOwning(interp: *Interp, handle: Heap.Handle) void {
    interp.result = handle;
}

pub fn setResultString(interp: *Interp, bytes: []const u8) !void {
    const bytes_handle = try object.newString(interp.heap, bytes);
    defer bytes_handle.release();

    setResult(interp, bytes_handle);
}

pub fn setEmptyResult(interp: *Interp) void {
    interp.result = interp.heap.emptyObject();
}

fn variableNotFoundError(interp: *Interp, var_name: []const u8) !void {
    interp.error_details = .{
        .message = try object.newStringFmt(interp.heap, "can't read \"{s}\": no such variable", .{var_name}),
    };

    return error.VariableNotFound;
}

const VariableInfo = struct {
    target_index: u32,
    call_frame_idx: u32,
};

/// Resolves to the variables' value, if any. Accounts for :: for globals.
fn resolveVariable(interp: *Interp, name: Heap.Handle, var_call_frame: u32) !?VariableInfo {
    const var_name = try Heap.getString(name);

    var call_frame_idx: u32 = 0;
    var var_value: ?Heap.Handle = null;

    //  No need to check slice length since it's null terminated.
    if (var_name[0] == ':' and var_name[1] == ':') {
        call_frame_idx = 0; // global frame

        // Skip as many colons as are present to match tcl behavior.
        var trimmed_var_name = var_name;
        while (trimmed_var_name[0] == ':') trimmed_var_name = trimmed_var_name[1..];

        const var_dict = interp.call_frames.items[call_frame_idx].variables;
        // TODO PERF would it be possible to make dict lookup take a slice
        // instead of an object?
        const key = try object.newString(interp.heap, trimmed_var_name);
        defer key.release();

        var_value = object.dictLookupRaw(var_dict, key);
        // Global scope doesn't have statics.
    } else {
        call_frame_idx = var_call_frame;

        const var_dict = interp.call_frames.items[call_frame_idx].variables;
        const statics_dict = interp.call_frames.items[call_frame_idx].statics;

        // Check the variables dictionary.
        var_value = object.dictLookupRaw(var_dict, name);

        // Maybe it's in the statics dictionary instead?
        if (var_value == null) {
            if (statics_dict) |unwrapped| {
                var_value = object.dictLookupRaw(unwrapped, name);
            }
        }
    }

    if (var_value) |unwrapped| {
        assert(unwrapped.heap == interp.heap);

        return .{
            .target_index = unwrapped.index,
            .call_frame_idx = call_frame_idx,
        };
    }
}

/// This always shimmers to .variable. You probably should be using `ensureVariableType`.
fn reshimmerToVariable(interp: *Interp, name: *Heap.Handle) !void {
    const var_name = try Heap.getString(name.*);

    if (try interp.resolveVariable(name.*, interp.currentCallFrame())) |var_info| {
        // Free the old representation and set the new one.
        name.invalidateBody();

        name.peek().tag = .variable;
        name.peek().body.variable = .{
            .epoch = interp.current_epoch,
            .index = var_info.index,
            .is_global = var_info.call_frame_idx == 0,
        };
    } else {
        return interp.variableNotFoundError(var_name);
    }
}

/// Ensures that this is a valid variable, dict sugar, or upvar.
fn ensureVariableType(interp: *Interp, name: *Heap.Handle) !void {
    // This ensures that the name is local to this interpreters' heap.
    try interp.heap.ensureShimmerable(name);

    const name_obj = name.peek();
    const name_heap = name.getHeap();

    if (name_obj.tag == .variable) {
        // Fast case: if we're in the same epoch as last time,
        // we don't need to do anything.
        if (name_obj.body.variable.epoch == interp.current_epoch) {
            return;
        } else {
            // Need to re-resolve the variable in the current call frame.
            try reshimmerToVariable(interp, name);
            return;
        }
    } else if (name_obj.tag == .upvar) {
        const upvar = name_heap.getUpvar(name_obj.body.upvar);

        // Fast case is same as for .variable.
        if (upvar.epoch == interp.current_epoch) {
            return;
        } else {
            // Need to look this back up.
            if (upvar.dict_sugar) |_| {
                @panic("Dict sugar not implemented yet");
            } else {
                // Be sure to look it up in the upvar's call frame.
                if (try interp.resolveVariable(name.*, upvar.call_frame_idx)) |upvar_target| {
                    upvar.index = upvar_target.target_index;
                    return;
                } else {
                    return interp.variableNotFoundError(try Heap.getString(name.*));
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

/// Resolves to the variables' value.
pub fn getVariable(interp: *Interp, name: Heap.Handle) !Heap.Handle {
    if (interp.evaluating_safe_expr) return Error.EvaluatingSafeExpression;

    var new_name = name;
    try interp.ensureVariableType(&new_name);

    switch (new_name.peek().tag) {
        .variable => {
            return new_name.getHeap().getLocalObject(new_name.peek().body.variable.index);
        },
        .upvar, .dict_subst => {
            @panic("Unimplemented");
        },
        else => unreachable,
    }
}

/// Call frame.
const CallFrame = struct {
    /// Handle to a dictionary containing the variables.
    variables: Heap.Handle,
    /// Handle to a dictionary containing all the statics.
    statics: ?Heap.Handle,
    /// Arguments of the procedure call, a heap-stored list.
    args: Heap.Handle,
    /// Signature of the procedure that this is being called with.
    signature: ProcedureSignature,
    /// Epoch id. Used to invalidate previous variable lookups. Will overflow,
    /// but when it overflows it'll scan the heap and reset all cached lookups.
    epoch_id: u32,
};

fn currentCallFrame(interp: *Interp) usize {
    return interp.call_frames.items.len - 1;
}

/// Evaluation frame.
const EvalFrame = struct {
    /// Pointer to the corrisponding call frame.
    call_frame: usize,
};

fn currentEvalFrame(interp: *Interp) usize {
    return interp.eval_frames.items.len - 1;
}

pub const ControlFlow = enum {
    ok,
    propagate_error,
};

pub fn eval(interp: *Interp, script: *Heap.Handle) !ControlFlow {
    // If the object is of type "list", with no string rep we can call a specialized version of eval()
    if (script.peek().tag == .list and script.hasString()) {
        return interp.evalList(script);
    }

    // Try to get the script, parsing if necessary.
    const parsed_result = object.getScript(interp.heap, &interp.error_details, script);
    const parsed = blk: {
        if (parsed_result) |result| {
            break :blk result;
        } else |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            interp.setResultOwning(interp.error_details.message);
            // TODO write stack trace
            return .propagate_error;
        }
    };

    // Reset the interpreter result. This is useful to
    // return the empty result in the case of empty program.
    interp.setEmptyResult();

    // TODO implement JIM_OPTIMIZATION speedups

    // FIXME do I need `script->inUse++;`?

    interp.eval_frames.append(interp.gpa, .{
        .call_frame = interp.call_frames.items.len,
    });
    defer interp.eval_frames.pop();
    const eval_frame = interp.currentEvalFrame();

    // Used for allocating the arguments passed into a command call.
    const args_alloc_backing = std.heap.stackFallback(@sizeOf(Heap.Handle) * 8, interp.gpa);
    const args_alloc = args_alloc_backing.get();

    // Execute every command sequentially until the end of the script or an error occurs.
    var command_token_i: usize = 0;

    const tags = parsed.tags.items;
    const values = object.listItemsRaw(parsed.values);
    // Loop through commands.
    while (command_token_i < tags.len) : (command_token_i += 1) {
        // First token of the line is always .script_command.
        const command_info = values[command_token_i].body.script_command;
        command_token_i += 1; // Skip .script_command.

        const args = try args_alloc.alloc(Heap.Handle, command_info.arg_count);
        defer args_alloc.free(args);

        // Populate the arguments by looping through each word of the command and
        // substituting.
        var word_token_i: usize = command_token_i;
        while (word_token_i < command_token_i + command_info.arg_count) : (word_token_i += 1) {
            var word_parts: usize = 1;
            const argument_expansion = tags[word_token_i] == .argument_expansion;
            if (tags[word_token_i] == .start_of_word or argument_expansion) {
                word_parts = values[word_token_i].body.integer;
                word_token_i += 1;
            }

            const resultant_word: Heap.Handle = blk: {
                // Simple one-to-one substitution, so a simple case.
                if (word_parts == 1) {
                    switch (tags[word_token_i]) {
                        .simple_string => {
                            break :blk object.listItemRaw(parsed.values, word_token_i);
                        },
                        .variable_subst => {},
                    }
                }
            };
        }
    }
}

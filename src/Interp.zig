const std = @import("std");

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

fn shimmerToVariable(interp: *Interp, name: *Heap.Handle) !void {
    // This ensures that the name is local to this interpreters' heap.
    try interp.heap.ensureShimmerable(name);
    const name_obj = name.peek();

    if (name_obj.tag == .variable) {
        // Fast case: if we're in the same epoch as last time,
        // we don't need to do anything.
        if (name_obj.body.variable.epoch == interp.current_epoch) return;

        // Need to re-resolve the variable in the current call frame.
    } else if (name_obj.tag == .dict_subst) {
        return Error.IsDictSugar;
    }

    var var_name = try Heap.getString(name.*);

    // Make sure it's not syntax to get/set a dict.
    if (var_name.len >= 2 and var_name[0] == '(' and var_name[var_name.len - 1] == ')') {
        return Error.IsDictSugar;
    }

    var call_frame_id: u32 = 0;
    var is_global: bool = false;
    var var_value: ?Heap.Handle = null;

    //  No need to check slice length since it's null terminated.
    if (var_name[0] == ':' and var_name[1] == ':') {
        call_frame_id = 0; // global frame
        is_global = true;

        // Skip as many colons as are present to match tcl behavior.
        while (var_name[0] == ':') var_name = var_name[1..];

        const var_dict = interp.call_frames.items[call_frame_id].variables;
        // TODO PERF would it be possible to make dict lookup take a slice
        // instead of an object?
        const key = try object.newString(interp.heap, var_name);
        defer key.release();

        var_value = object.dictLookupRaw(var_dict, key);
    } else {
        call_frame_id = interp.currentCallFrame();
        is_global = false;

        const var_dict = interp.call_frames.items[call_frame_id].variables;
        const statics_dict = interp.call_frames.items[call_frame_id].statics;

        // Check the variables dictionary.
        var_value = object.dictLookupRaw(var_dict, name.*);

        // Maybe it's in the statics dictionary instead?
        if (var_value == null) {
            if (statics_dict) |unwrapped| {
                // Be sure to check the statics if we don't have a local
                // variable with the same name.
                var_value = object.dictLookupRaw(unwrapped, name.*);
            }
        }
    }

    if (var_value) |unwrapped| {
        // Free the old representation and set the new one.
        name.invalidateBody();

        name_obj.body.variable = .{
            .epoch = interp.current_epoch,
            .index = unwrapped.index,
            .is_global = is_global,
        };
    } else return Error.VariableNotFound;
}

/// Resolves to the variables' value.
pub fn getVariable(interp: *Interp, name: Heap.Handle) !Heap.Handle {
    if (interp.evaluating_safe_expr) return Error.EvaluatingSafeExpression;

    var new_name = name;
    const result = interp.shimmerToVariable(&new_name);
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

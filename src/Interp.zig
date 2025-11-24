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
current_epoch: u31,
commands: CommandHashTable,

evaluating_safe_expr: bool,

pub const CommandFn = fn (interp: *Interp, args: []const Heap.Handle) void;

pub const Error = std.mem.Allocator.Error || error{
    EvaluatingSafeExpression,
    EvalError,
    Break,
    Continue,
    Signal,
    VariableNotFound,
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

fn variableNotFoundError(interp: *Interp, det: ?object.ErrorDetails, var_name: []const u8) !void {
    if (det) |details| details.* = .{
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
        assert(!unwrapped.ref_counted);

        return .{
            .target_index = unwrapped.index,
            .call_frame_idx = call_frame_idx,
        };
    }
}

/// This always shimmers to .variable. You probably should be using `ensureVariableType`.
fn reshimmerToVariable(interp: *Interp, det: ?object.ErrorDetails, name: *Heap.Handle) !void {
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
        return interp.variableNotFoundError(var_name, det);
    }
}

/// Ensures that this is a valid variable, dict sugar, or upvar.
fn ensureVariableType(interp: *Interp, det: ?object.ErrorDetails, name: *Heap.Handle) !void {
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
                    return interp.variableNotFoundError(det, try Heap.getString(name.*));
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
pub fn getVariable(interp: *Interp, det: ?object.ErrorDetails, name: Heap.Handle) !Heap.Handle {
    if (interp.evaluating_safe_expr) return Error.EvaluatingSafeExpression;

    var new_name = name;
    try interp.ensureVariableType(det, &new_name);

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
    /// Handle to a dictionary containing the variables.
    variables: Heap.Handle,
    /// Handle to a dictionary containing all the statics.
    statics: ?Heap.Handle,
    /// Arguments of the procedure call.
    args: []Heap.Handle,
    /// Signature of the procedure that this is being called with.
    signature: ProcedureSignature,
    /// Call epoch. Used to invalidate previous variable lookups. Will overflow,
    /// but when it overflows it'll scan the heap and reset all cached lookups.
    call_epoch: u31,
};

fn currentCallFrame(interp: *Interp) usize {
    return interp.call_frames.items.len - 1;
}

/// Evaluation frame.
const EvalFrame = struct {
    /// Pointer to the corrisponding call frame.
    call_frame: u32,
};

fn currentEvalFrame(interp: *Interp) usize {
    return interp.eval_frames.items.len - 1;
}

fn substituteOneToken(interp: *Interp, tag: Parser.Token.Tag, value: Heap.Handle) !Heap.Handle {
    switch (tag) {
        .simple_string => {
            return value;
        },
        .variable_subst => {
            var det: object.ErrorDetails = undefined;
            return try interp.wrapErrorDetails(&det, interp.getVariable(&det, value));
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
}

pub fn eval(interp: *Interp, script: *Heap.Handle) !void {
    // If the object is of type "list", with no string rep we can call a specialized version of eval()
    if (script.peek().tag == .list and script.hasString()) {
        return interp.evalList(script);
    }

    // Try to get the script, parsing if necessary.
    var det: object.ErrorDetails = undefined;
    const parsed = try interp.wrapErrorDetails(&det, object.getScript(interp.heap, &det, script));

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
    var command_token_i: u32 = 0;

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
        var word_token_i: u32 = command_token_i;
        while (word_token_i < command_token_i + command_info.arg_count) : (word_token_i += 1) {
            var word_parts: u32 = 1;
            const argument_expansion = tags[word_token_i] == .argument_expansion;
            if (tags[word_token_i] == .start_of_word or argument_expansion) {
                word_parts = values[word_token_i].body.integer;
                word_token_i += 1;
            }

            const resultant_word: Heap.Handle = blk: {
                // Simple one-to-one substitution, so a simple case.
                if (word_parts == 1) {
                    break :blk try interp.substituteOneToken(tags[word_token_i], object.listItemRaw(parsed.values, word_token_i));
                } else {
                    break :blk try interp.interpolateTokens(tags[word_token_i..][0..word_parts], parsed.values, word_token_i, word_parts);
                }
            };
            defer resultant_word.release();

            if (argument_expansion) {}
        }
    }
}

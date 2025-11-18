const std = @import("std");

const Heap = @import("Heap.zig");
const object = @import("object.zig");

const Interp = @This();

heap: *Heap,
gpa: std.mem.Allocator,

/// The result from a procedure or eval call
result: ?Heap.Handle,
error_details: object.ErrorDetails,
eval_frame: ?EvalFrame,
call_frame: ?CallFrame,
commands: CommandHashTable,

pub const CommandFn = fn (interp: *Interp, args: []const Heap.Handle) void;

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

/// Call frame.
const CallFrame = struct {
    /// Parent call frame.
    parent: *CallFrame,
    /// Level of this frame. 0 = global.
    level: u32,
    /// Handle to a hash map containing the variables.
    variables: Heap.Handle,
    /// Handle to a hash map containing all the statics.
    statics: Heap.Handle,
    /// Arguments of the procedure call, a heap-stored list.
    args: Heap.Handle,
    /// Signature of the procedure that this is being called with.
    signature: ProcedureSignature,
};

/// Evaluation frame.
const EvalFrame = struct {
    /// Parent of this frame.
    parent: ?*EvalFrame,
    /// Pointer to the corrisponding call frame.
    call_frame: *CallFrame,
    /// Level of this frame. 0 = global.
    level: u32,
};

fn initAndPushEvalFrame(interp: *Interp, frame: *EvalFrame) void {
    const level = if (interp.eval_frame) |unwrapped| unwrapped.level else 0;
    frame.* = .{
        .call_frame = interp.call_frame.?,
        .level = level + 1,
        .parent = interp.eval_frame,
    };

    interp.eval_frame = frame;
}

fn popEvalFrame(interp: *Interp) void {
    if (interp.eval_frame) |current_frame| {
        interp.eval_frame = current_frame.parent;
    }
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

    var eval_frame: EvalFrame = undefined;

    // Eval frames become a linked list of frames on the stack.
    interp.initAndPushEvalFrame(&eval_frame);
    defer interp.popEvalFrame();

    const args_alloc_backing = std.heap.stackFallback(@sizeOf(Heap.Handle) * 8, interp.gpa);
    const args_alloc = args_alloc_backing.get();

    // Execute every command sequentially until the end of the script or an error occurs.
    var command_token_i: usize = 0;

    const tags = parsed.tags.items;
    while (command_token_i < tags.len) : (command_token_i += 1) {
        // First token of the line is always .script_command.
        const command_info = object.listItemRaw(parsed.values, command_token_i).peek().body.script_command;
        command_token_i += 1; // Skip .script_command.

        const args = try args_alloc.alloc(Heap.Handle, command_info.arg_count);
        defer args_alloc.free(args);

        // Populate the arguments objects.
        var word_i = 0;
        while (word_i < command_info.arg_count) {}
    }
}

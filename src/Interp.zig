const std = @import("std");
const math = std.math;
const testing = std.testing;
const mem = std.mem;
const assert = std.debug.assert;

const pcre2 = @import("pcre2");

const strutil = @import("strutil.zig");
const ioutil = @import("ioutil.zig");
const memutil = @import("memutil.zig");
const StructIterator = memutil.StructIterator;
const Tokenizer = @import("Tokenizer.zig");
const heap = @import("heap.zig");
const hashutil = heap.hashutil;
const Value = heap.Value;
const OptionalValue = heap.OptionalValue;
const Object = heap.Object;
const objects = @import("objects.zig");
const vartypes = @import("vartypes.zig");
const allocPrintZ = objects.allocPrintZ;
const Shimmerable = objects.Shimmerable;
const ErrorDetails = objects.ErrorDetails;
const Dictionary = objects.Dictionary;
const String = objects.String;
const List = objects.List;
const evaltypes = @import("evaltypes.zig");
const Closure = evaltypes.Closure;
const ReturnCode = evaltypes.ReturnCode;
const Script = evaltypes.Script;
const Expression = evaltypes.Expression;

const Interp = @This();
/// The result from a procedure or eval call
result: Value,
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
/// Used to invalidate cached variable lookups.
current_call_epoch: u64,
/// Used to invalidate cached procedures.
global_procedure_epoch: u64,
global_commands: CommandHashTable,

eval_depth: usize,
max_eval_depth: usize,
max_call_depth: usize,
/// Depth of [unknown] calls. Used to catch infinite recursion.
unknown_depth: usize,
/// String containing `unknown`. Used to cache unknown lookup.
unknown_str: Value = heap.createInternedString("unknown").get(),
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
    return_at_end: ?evaltypes.EvalError = null,
} = .{},
/// Stack trace captured at the error site.
stack_trace: OptionalValue,
/// Error code set by `[error]` or `[return -errorcode ...]`. Not a Tcl-visible
/// global, it lives here only to cross the Zig call boundary to `[catch]`/`[try]`.
/// Note that this is not the same as a return code. For example, a return code
/// would be error.OutOfMemory, but an error code would be "ZICL OOM".
pending_error_code: OptionalValue,
/// If an error occurs while a `on`/`trap`/`finally` executes, it can be easy to
/// lose track of the original error. So instead when this happens we store the
/// original error in a `-pending` key, inside of the new error.
pending_error_during: OptionalValue,

parsed_scripts: ParsedScripts,
parsed_exprs: ParsedExpressions,
parsed_closures: ParsedClosures,
parsed_substs: ParsedSubstitutions,

prng: std.Random.DefaultPrng,

const FullHashContext = struct {
    pub fn hash(self: @This(), full_hash: u256) u64 {
        _ = self;
        return @truncate(full_hash);
    }
    pub fn eql(self: @This(), a: u256, b: u256) bool {
        _ = self;
        return a == b;
    }
};
const ParsedScripts = memutil.LruCache(u256, *evaltypes.Script, FullHashContext);
const ParsedExpressions = memutil.LruCache(u256, *Expression, FullHashContext);
const ParsedClosures = memutil.LruCache(u256, evaltypes.ClosureValues, FullHashContext);
pub const Substitution = struct {
    subst: *evaltypes.Script,
    /// Currently only used for integrity checks.
    flags: Tokenizer.SubstFlags,
};
const ParsedSubstitutions = memutil.LruCache(u256, Substitution, FullHashContext);

pub const CommandHashTable = std.StringArrayHashMapUnmanaged(evaltypes.NativeCommand);

const interned_name = heap.createInternedString("name");
const interned_impl = heap.createInternedString("impl");
const interned_scope = heap.createInternedString("scope");

pub fn narrowError(err: anyerror) evaltypes.EvalError {
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
    break :blk if (info == .error_set) evaltypes.EvalError else evaltypes.EvalError!info.error_union.payload;
} {
    if (@typeInfo(@TypeOf(result)) == .error_set) {
        return narrowError(result);
    } else if (result) |val| {
        return val;
    } else |err| return narrowError(err);
}

const Tailcall = struct {
    args: []Shimmerable,
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
pub fn wrapError(interp: *Interp, det: *ErrorDetails, result: anytype) wrapErrorDetailsReturnType(@TypeOf(result)) {
    if (comptime std.meta.activeTag(@typeInfo(@TypeOf(result))) == .error_set) {
        if (result == error.OutOfMemory) {
            return error.OutOfMemory;
        } else {
            interp.setResultOwning(det.message);
            return error.EvalError;
        }
    }

    return result catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            // This error should have error details, if it's not OOM.
            interp.setResultOwning(det.message);
            return error.EvalError;
        },
    };
}

pub fn registerCommand(interp: *Interp, name: []const u8, command: evaltypes.NativeCommand) !void {
    try interp.global_commands.put(heap.global_gpa, name, command);

    const as_nativefn = try strutil.quoteStrings(heap.global_gpa, &.{ "nativefn", name });
    defer heap.global_gpa.free(as_nativefn);

    var var_name = try String.newValue(name);
    defer var_name.release();
    const var_value = try String.newValue(as_nativefn);
    defer var_value.release();

    var var_name_wb: Shimmerable = .{ .original = var_name };
    defer var_name_wb.discardChanges();
    try interp.setVariableTo(&var_name_wb, var_value);

    _ = interp.nextProcedureEpoch();
}

/// If called with a closure, this will _modify_ `args[1]`, not just shimmer it.
pub fn callClosure(interp: *Interp, closure: *const Closure.Content, cache_key: u256, args: []Shimmerable) !void {
    const arg_count = args.len - 1; // - 1 to skip command name as first argument.

    // Check arity.
    const too_few_arguments: bool = arg_count < closure.required_arity;
    const has_args: bool = closure.has_args_parameter;
    const too_many_arguments: bool = !has_args and arg_count > closure.required_arity + closure.optional_arity;
    if (too_few_arguments or too_many_arguments) {
        // Wrong argument count, error accordingly.
        const command_usage = try closure.getUsage(heap.local_arena, try args[0].current().getString());
        interp.setResultFormatted("wrong # args: should be \"{s}\"", .{command_usage});
        return error.WrongUsage;
    }

    // Check for infinite recursion.
    if (interp.callFrameIdx() >= interp.max_call_depth) {
        try interp.setResultString("Too many nested calls. Infinite recursion?");
        return error.InfiniteRecursion;
    }

    const call_frame_idx = try interp.pushCallFrame(args, closure);
    defer {
        var frame = interp.call_frames.pop().?;
        frame.deinit();
    }

    // Next, we'll populate the call frame.

    // Where we are in the arguments that this was called with.
    var called_idx: usize = 1;
    // Where we are in the signature.
    var signature_idx: u32 = 0;

    while (signature_idx < closure.args.len) : (signature_idx += 1) {
        const var_name: Shimmerable = .{ .original = closure.args[signature_idx] };
        defer var_name.discardChanges(); // TODO PERF write back here instead of deleting the temp object.

        // Are we at the last argument? If so, is it `args`?
        if (signature_idx == closure.args.len - 1 and closure.has_args_parameter) {
            // Assign remaining arguments to `args`.
            const list = try List.new(&.{});
            defer list.asHead().release();
            for (args[called_idx..]) |arg| try list.append(arg.current());

            var det: ErrorDetails = undefined;
            interp.setVariableInner(&det, call_frame_idx, &var_name, list.asHead().asValue()) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.LinkLookupFailed, error.BadVariableName => {
                    try interp.setResultStringOwning(det.message);
                    return error.EvalError;
                },
            };
        } else if (signature_idx >= closure.required_arity) {
            // This is an optional argument.

            // Are there any remaining unassigned arguments?
            if (called_idx < args.len) {
                var det: ErrorDetails = undefined;
                try interp.wrapError(&det, interp.setVariableInner(&det, call_frame_idx, &var_name, args[called_idx].current()));
                called_idx += 1;
            } else {
                // Else populate it with its default value.
                const default_value = closure.optional_values[signature_idx - closure.required_arity];
                var det: ErrorDetails = undefined;
                try interp.wrapError(&det, interp.setVariableInner(&det, call_frame_idx, &var_name, default_value));
            }
        } else {
            var det: ErrorDetails = undefined;
            try interp.wrapError(&det, interp.setVariableInner(&det, call_frame_idx, &var_name, args[called_idx].current().dupOrRef()));
            called_idx += 1;
        }
    }

    try interp.evalObjectInner(call_frame_idx, closure.body, cache_key);

    // When called as a method, we write back `self` to `args[1]`, so that the
    // caller can update the new method.
    if (closure.is_method) {
        var self_var_name: Shimmerable = .{ .original = closure.args[0] };
        defer self_var_name.discardChanges(); // TODO PERF don't discard, write back.
        if (interp.getVariableOrErrorInner(null, call_frame_idx, self_var_name)) |updated_self| {
            args[1].shimmered.swap(updated_self.borrow());
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadVariableName => {
                // This variable name was already checked when setting the arguments.
                unreachable;
            },
            error.VariableNotFound, error.LinkLookupFailed, error.BadDict => {
                try interp.setResultFormatted(
                    "{s} was removed while calling method",
                    .{try self_var_name.current().getString()},
                );
                return error.EvalError;
            },
        }
    }
}

fn callNative(interp: *Interp, command: *evaltypes.NativeCommand, args: []Shimmerable) !void {
    const arg_count = args.len - 1;
    wrong_arg_count: {
        // Check arg count.
        if (arg_count < command.min_arity) break :wrong_arg_count;
        if (command.max_arity) |max_arity| {
            if (arg_count > max_arity) break :wrong_arg_count;
        }
        if (command.multiple_of) |multiple_of| {
            if (@mod(arg_count - command.min_arity, multiple_of) != 0) break :wrong_arg_count;
        }

        switch (command.call_info) {
            .zig => |to_call| try to_call(interp, args),
            .c => |to_call| {
                const args_as_handles = try heap.local_arena.alloc(Value, args.len);
                for (args, args_as_handles) |arg, *native_arg| native_arg.* = arg.current().borrow();

                const retcode = ReturnCode.toError(to_call(interp, @intCast(args_as_handles.len), args_as_handles.ptr));

                for (args, args_as_handles) |*arg, native_arg| {
                    // We don't need to worry about this not firing with an ABA
                    // pointer address issue, since each argument has already
                    // been borrowed.
                    if (native_arg != arg.current()) {
                        arg.shimmered.swap(native_arg);
                    } else {
                        native_arg.release();
                    }
                }

                return retcode;
            },
        }

        return;
    }

    const command_usage = try command.getUsageInfo(try args[0].current().getString());
    try interp.setResultFormatted("wrong # args: should be \"{s}\"", .{command_usage});
    return error.WrongUsage;
}

fn freeLastResult(interp: *Interp) void {
    interp.result.release();
    interp.result = objects.interned_empty_string.get();
}

pub fn setResult(interp: *Interp, value: Value) void {
    interp.freeLastResult();
    interp.result = value.borrow();
}

pub fn setResultOwning(interp: *Interp, value: Value) void {
    interp.freeLastResult();
    interp.result = value;
}

pub fn setResultInteger(interp: *Interp, value: i64) !void {
    interp.setResultOwning(try objects.Integer.new(value));
}

pub fn setResultFloat(interp: *Interp, value: f64) void {
    interp.setResultOwning(objects.Float.new(value));
}

pub fn setResultString(interp: *Interp, bytes: []const u8) !void {
    interp.setResultOwning(try String.new(bytes));
}

pub fn setResultStringOwning(interp: *Interp, bytes: [:0]u8) !void {
    interp.setResultOwning((try String.newOwning(bytes)).asHead().asValue());
}

pub fn setResultBoolean(interp: *Interp, value: bool) void {
    interp.setResultOwning(objects.Boolean.new(value));
}

pub fn setResultFormatted(interp: *Interp, comptime fmt: []const u8, args: anytype) !void {
    const fmt_handle = try allocPrintZ(fmt, args);
    interp.setResultStringOwning(fmt_handle);
}

pub fn setEmptyResult(interp: *Interp) void {
    interp.freeLastResult();
}

pub fn makeErrorMessage(error_mesage: Value, stack_trace: *const List) !Value {
    if (stack_trace.items.len == 0 or @mod(stack_trace.items.len, 4) != 0) return error.WrongSize;

    var buf = std.ArrayList(u8).empty;

    const first_file = stack_trace.items[1];
    const first_line = stack_trace.items[2];

    try buf.print(heap.local_arena, "{f}:{f}: Error: {f}\n", .{ first_file, first_line, error_mesage });
    try buf.print(heap.local_arena, "Traceback:\n", .{});

    if (stack_trace.items.len <= 4) {
        // Stack trace only had one entry, so there's no point in printing the traceback.
        return try String.new(buf.items);
    }

    // Stack trace is a flat list of {command file line args} repeated per frame.
    var i: u32 = 0;
    while (i < stack_trace.items.len) : (i += 4) {
        const fn_name = try stack_trace.items[i].getString();
        const file = try stack_trace.items[i + 1].getString();
        const line = try stack_trace.items[i + 2].getString();
        const args = try stack_trace.items[i + 3].getString();

        if (file.len > 0) {
            try buf.print(heap.local_arena, "  File \"{s}\", line {s}", .{ file, line });
        }

        if (fn_name.len > 0) {
            if (file.len > 0) {
                try buf.print(heap.local_arena, ", in {s}", .{fn_name});
            } else {
                try buf.print(heap.local_arena, "  In {s}", .{fn_name});
            }
        }

        if (file.len > 0 or fn_name.len > 0) {
            try buf.append(heap.local_arena, '\n');
        }

        if (args.len > 0) {
            if (std.mem.indexOfScalar(u8, args, '\n')) |args_newline| {
                const shortened = args[0..args_newline];
                try buf.print(heap.local_arena, "    {s}...\n", .{shortened});
            } else {
                try buf.print(heap.local_arena, "    {s}\n", .{args});
            }
        }
    }

    // Remove trailing \n
    if (buf.getLastOrNull()) |last| if (last == '\n') {
        _ = buf.pop();
    };

    return try String.new(buf.items);
}

/// Call frame.
const CallFrame = struct {
    /// Dictionary containing the frame's variables.
    variables: objects.AlwaysCanBeType(Dictionary),
    /// Arguments of this procedure call. Lifetime managed by creator.
    args: []Shimmerable,
    /// Signature of this procedure.
    signature: Closure.Content,
    /// Call epoch. Used to invalidate previous variable lookups.
    call_epoch: u64,
    /// Set this during evaluation to trigger a tailcall.
    tailcall: ?Tailcall,

    pub fn deinit(frame: *CallFrame) void {
        // Args are managed externally, so we don't free them.
        frame.variables.asHead().release();
        frame.signature.deinit();
    }
};

pub fn callFrameIdx(interp: *Interp) u32 {
    return interp.evalFrame().call_frame;
}

pub fn callFrame(interp: *Interp) *CallFrame {
    return &interp.call_frames.items[interp.callFrameIdx()];
}

/// Returns a dict containing this call frame's variables.
pub fn captureScope(interp: *Interp, det: ?*ErrorDetails, call_frame_idx: u32) !*Dictionary {
    const frame = &interp.call_frames.items[call_frame_idx];

    const new_dict = (try frame.variables.asHead().duplicate()).castTo(Dictionary);
    errdefer new_dict.asHead().release();

    // Make sure there's no upvars, or if there are, resolve them to their values.
    var i: usize = 1;
    while (i < new_dict.items.len) : (i += 2) {
        if (new_dict.items[i].asType(vartypes.UpvarLink)) |link| {
            var name_shim: Shimmerable = .{ .original = link.linked_name };
            defer name_shim.discardChanges();
            if (try interp.getVariableInner(det, link.call_frame, &name_shim)) |linked_value| {
                new_dict.items[i].swap(linked_value.borrow());
            } else {
                if (det) |details| {
                    heap.global_gpa.free(details.message);
                    details.* = .{ .message = try allocPrintZ(
                        "failed to capture the variable \"{s}\", as it was an upvar that pointed at nothing",
                        .{try new_dict.items[i - 1].getString()},
                    ) };
                }
                return error.UninitializedUpvar;
            }
        }
    }

    return new_dict;
}

/// Returns a dict capturing the current call frame's variables.
pub fn captureCurrentScope(interp: *Interp) !Value {
    var det: ErrorDetails = undefined;
    return try interp.wrapError(&det, interp.captureScope(&det, interp.callFrameIdx()));
}

var global_proc_epoch: std.atomic.Value(u64) = .init(0);
fn nextProcedureEpoch(interp: *Interp) u64 {
    interp.global_procedure_epoch = global_proc_epoch.fetchAdd(1, .monotonic) + 1;
    return interp.global_procedure_epoch;
}

var global_call_epoch: std.atomic.Value(u64) = .init(0);
fn nextCallEpoch(interp: *Interp) u64 {
    interp.current_call_epoch = global_call_epoch.fetchAdd(1, .monotonic) + 1;
    return interp.current_call_epoch;
}

/// Evaluation frame.
pub const EvalFrame = struct {
    /// Pointer to the corrisponding call frame.
    call_frame: u32,
    /// Arguments of the command currently being dispatched in this eval frame.
    args: []Shimmerable,
    /// The line number of the command currently being dispatched, within
    /// the script being evaluated (note that this is relative, since that's
    /// how parsed scripts are stored). Combine with `source_info.line_no`
    /// to recover the absolute line at error-reporting time.
    current_line: u32,
    /// The object currently being evaluated.
    currently_evaluating: Value,
};

pub fn evalFrameIdx(interp: *Interp) u32 {
    return @intCast(interp.eval_frames.items.len - 1);
}

pub fn evalFrame(interp: *Interp) *EvalFrame {
    return &interp.eval_frames.items[interp.evalFrameIdx()];
}

fn pushCallFrame(interp: *Interp, args: []Shimmerable, signature: *const Closure.Content) !u32 {
    var variables = try Dictionary.new(&.{});
    errdefer variables.asHead().release();

    if (signature.scope_hash_ref) |scope_hash_ref| {
        try variables.put(objects.interned_tilde_parent.bytesPtr(), scope_hash_ref.inner.asValue());
    }

    const new_call_frame_idx = interp.call_frames.items.len;
    try interp.call_frames.append(heap.global_gpa, .{
        .args = args,
        .call_epoch = interp.nextCallEpoch(),
        .signature = if (signature.scope_hash_ref) |hash_ref| hash_ref.duplicate() else null,
        // TODO PERF recycle variable hash table if possible.
        .variables = variables,
        .tailcall = null,
    });

    return @intCast(new_call_frame_idx);
}

fn pushEvalFrame(interp: *Interp, call_frame: u32, script: Value) !u32 {
    try interp.eval_frames.append(heap.global_gpa, .{
        .call_frame = call_frame,
        .args = &.{},
        .current_line = 0,
        .currently_evaluating = script,
    });
    return interp.evalFrameIdx();
}

fn popEvalFrame(interp: *Interp) void {
    _ = interp.eval_frames.pop() orelse unreachable;
}

/// Caller should release return value when they're done.
fn substituteOneToken(interp: *Interp, tag: Tokenizer.Token.Tag, value: Value) !Value {
    switch (tag) {
        .simple_string => {
            return value.borrow();
        },
        .variable_subst => {
            var det: ErrorDetails = undefined;
            const var_target: Value = try interp.wrapError(
                &det,
                interp.getVariableOrErrorInner(&det, interp.callFrameIdx(), value),
            );
            return var_target.borrow();
        },
        .expression_sugar => {
            @panic("Expression sugar unimplemented");
        },
        .command_subst => {
            const nested_cache_key = @as(u256, interp.callFrame().signature.cache_id) ^ try value.getHashNoRegister();
            try interp.evalObjectInner(interp.callFrameIdx(), value, nested_cache_key);
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
    value_list: []const Value,
    value_start: usize,
    value_len: usize,
) !Value {
    var new_values = try std.ArrayList(Value).initCapacity(heap.local_arena, value_len);
    defer for (new_values.items) |value| value.decrRefCount();

    // Substitute all the tokens, placing them in `new_values`.
    for (tags, value_start..(value_start + value_len)) |tag, value_index| {
        if (interp.substituteOneToken(tag, value_list[value_index])) |new_value| {
            new_values.appendAssumeCapacity(new_value);
        } else |err| switch (err) {
            error.Break => {
                try interp.setResultString("invoked \"break\" outside of a loop");
                return error.EvalError;
            },
            error.Continue => {
                try interp.setResultString("invoked \"continue\" outside of a loop");
                return error.EvalError;
            },
            else => return err,
        }
    }

    var new_str_len: usize = 0;
    for (new_values.items) |new_value| {
        new_str_len += (try new_value.getString()).len;
    }

    if (new_str_len == 0) return heap.interned_empty_string.get();

    var new_bytes = try heap.global_gpa.alloc(u8, new_str_len);
    errdefer heap.global_gpa.free(new_bytes);
    var written: usize = 0;
    for (new_values.items) |new_value| {
        const value_str = try new_value.getString();
        @memcpy(new_bytes[written..][0..value_str.len], value_str);
        written += value_str.len;
    }

    return (try String.newOwning(new_bytes)).asHead().asValue();
}

pub fn getScript(interp: *Interp, det: ?*ErrorDetails, value: Value, cache_key: u256) !Script {
    if (interp.parsed_scripts.get(cache_key)) |parsed| {
        return parsed.script;
    } else {
        const new_script = try Script.parse(det, value);
        if (interp.parsed_scripts.put(cache_key, new_script)) |ejected| ejected.release();
        return new_script;
    }
}

pub const ClosureAndCacheKey = struct {
    closure: *Closure.Content,
    cache_key: u256,
};
pub fn getClosure(interp: *Interp, det: ?*ErrorDetails, value: Value, can_be_method: bool) !ClosureAndCacheKey {
    const closure_and_key: ClosureAndCacheKey = blk: {
        if (value.asType(Closure)) |closure| {
            break :blk .{ .closure = closure.closure, .cache_key = @as(u256, closure.closure.cache_id) };
        }

        const cache_key = try value.getHashNoRegister();

        if (interp.parsed_closures.getPtr(cache_key)) |cached| {
            break :blk .{ .closure = cached.closure, .cache_key = cache_key };
        } else {
            // We need to parse the closure.
            const closure = try Closure.parse(det, try value.getString());
            if (interp.parsed_closures.put(cache_key, closure)) |ejected| ejected.release();
            break :blk .{ .closure = closure, .cache_key = cache_key };
        }
    };

    if (!can_be_method and closure_and_key.closure.is_method) {
        if (det) |details| details.* = .{
            .message = try allocPrintZ("method cannot be invoked as function"),
        };
        return error.CannotBeMethod;
    }

    return closure_and_key;
}

const CommandOrClosure = union(enum) {
    closure: ClosureAndCacheKey,
    command: *evaltypes.NativeCommand,
};

fn getCommandInner(
    interp: *Interp,
    det: ?*ErrorDetails,
    call_frame: u32,
    name: *Shimmerable,
    can_be_method: bool,
) !CommandOrClosure {
    if (interp.getVariableOrErrorInner(det, call_frame, name)) |var_val| {
        if (var_val.tag() == .closure) {
            return .{ .closure = try interp.getClosure(det, var_val, can_be_method) };
        }

        // TODO PERF probably should cache nativefn lookup.
        const bytes = try var_val.getString();
        if (bytes.len > 9 and std.mem.eql(u8, bytes[0..9], "nativefn ")) {
            // TODO `bytes[9..]` doesn't account for a nativefn name in braces or with escapes.
            const cmd_name = bytes[9..];
            if (interp.global_commands.getPtr(cmd_name)) |command| {
                return .{ .command = command };
            }

            // Command not registered locally, so check the shared lazy-init registry.
            if (heap.nativefn_registry.get(cmd_name)) |init_fn| {
                init_fn(@ptrCast(interp));
                // Retry after initialization.
                if (interp.global_commands.getPtr(cmd_name)) |command| {
                    return .{ .command = command };
                }
            }

            if (det) |details| details.* = .{
                .message = try allocPrintZ("invalid native command name \"{s}\"", .{cmd_name}),
            };
            return error.CommandNotFound;
        } else {
            const closure = try interp.getClosure(det, var_val, can_be_method);
            return .{ .closure = closure };
        }
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.LinkLookupFailed => return error.LinkLookupFailed,
        error.BadVariableName => return error.BadVariableName,
        error.VariableNotFound, error.BadDict => {
            if (det) |details| {
                heap.global_gpa.free(details.message);
                details.* = .{
                    .message = try allocPrintZ("invalid command name \"{f}\"", .{name}),
                };
            }
            return error.CommandNotFound;
        },
    }
}

pub fn getCommand(interp: *Interp, call_frame_idx: u32, wb: *Shimmerable, can_be_method: bool) !CommandOrClosure {
    try wb.ensureShimmerable();
    var det: ErrorDetails = undefined;
    return interp.getCommandInner(&det, call_frame_idx, wb.current(), can_be_method) catch |err| switch (err) {
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

fn invokeUnknown(interp: *Interp, args: []Shimmerable) !void {
    var unknown_str: Shimmerable = .{ .original = interp.unknown_str };
    defer unknown_str.discardChanges();
    const unknown_cmd = interp.getCommand(0, &unknown_str, false) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CommandNotFound => {
            // No [unknown] command exists, so we'll default to the "no command found" error.
            try interp.setResultFormatted("invalid command name \"{f}\"", .{args[0].current()});
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

    var new_args = try heap.local_arena.alloc(Shimmerable, args.len);
    new_args[0] = .{ .original = interp.unknown_str };
    @memcpy(new_args[1..], args[1..]);

    try interp.invokeCommand(unknown_cmd, new_args);
}

const CommandError = evaltypes.Error || error{InfiniteRecursion};
fn invokeCommand(interp: *Interp, command_or_closure: CommandOrClosure, args: []Shimmerable) CommandError!void {
    if (interp.eval_depth >= interp.max_eval_depth) {
        try interp.setResultString("Infinite eval recursion");
        return error.InfiniteRecursion;
    }

    interp.eval_depth += 1;
    defer interp.eval_depth -= 1;

    // Loop the calling section, as there may be a tailcall.
    var current_args = args;
    var tailcall_info: ?Tailcall = null;
    defer if (tailcall_info) |info| heap.global_gpa.free(info.args);
    while (true) {
        interp.evalFrame().args = args;
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
                const tailcall = interp.callFrame().tailcall.?;

                // Be sure to free the previous tailcall.
                if (tailcall_info) |prev_tailcall| {
                    for (prev_tailcall.args) |*arg| arg.deinit();
                    heap.global_gpa.free(prev_tailcall.args);
                }

                tailcall_info = tailcall;
                current_args = tailcall.args;
                interp.callFrame().tailcall = null;
            },
            error.EvalError => {
                try interp.setErrorStack();
                return error.EvalError;
            },
            else => return err,
        };

        if (tailcall_found == false) {
            tailcall_info = null; // Avoid double free.
            break;
        }
    }
}

pub fn getExpression(interp: *Interp, value: Value, cache_key: u256) !*Expression {
    if (interp.parsed_exprs.get(cache_key)) |parsed| {
        return parsed;
    } else {
        var det: objects.ErrorDetails = undefined;
        const new_expr = try interp.wrapError(&det, Expression.parse(&det, value));
        if (interp.parsed_scripts.put(cache_key, new_expr)) |ejected| ejected.release();

        return new_expr;
    }
}

pub fn evalExpression(interp: *Interp, value: Value) !Value {
    // Combine the signature's cache id with the expression's content hash, so
    // identical expressions at different call sites get their own cached
    // variable lookups.
    var det: ErrorDetails = undefined;
    const cache_key = @as(u256, interp.callFrame().signature.cache_id) ^ try value.getHashNoRegister();
    const expr: *Expression = try interp.wrapError(&det, getExpression(&det, value, cache_key));

    return Expression.evalNode(interp, expr.nodes, expr.root_node) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => {
            // Give the caller some context for what failed.
            try interp.setResultFormatted(
                "error occured when evaluating expression {s}: {s}",
                .{ try value.getString(), try interp.result.getString() },
            );
            return error.EvalError;
        },
    };
}

test "eval expression" {
    try heap.testStart(testing.allocator, testing.io);
    defer heap.testFinish();
    var interp = try Interp.init();
    defer interp.deinit();

    var expr = try String.newValue("5 + 10");
    defer expr.release();
    const result = try interp.evalExpression(expr);
    try testing.expectEqual(Value.newInt(15), result);
}

pub fn evalSubstitution(interp: *Interp, value: Value, flags: Tokenizer.SubstFlags) !Value {
    var cache_key: u256 = try value.getHashNoRegister();
    // Combine the signature's cache id with the expression's content hash, so
    // identical expressions at different call sites get their own cached
    // variable lookups.
    cache_key ^= @as(u256, interp.callFrame().signature.cache_id);
    // Also make sure to include the flags in the cache id.
    cache_key ^= @as(u256, @as(u3, @bitCast(flags))) << @sizeOf(@TypeOf(interp.callFrame().signature.cache_id));

    var det: ErrorDetails = undefined;
    const subst: Substitution = try interp.wrapError(&det, getScript(&det, value, cache_key, flags));
    assert(subst.flags == flags); // Integrity check.

    return try interp.interpolateTokens(subst.subst.tags.items, subst.subst.values, 0, @intCast(subst.subst.tags.items.len));
}

pub fn setErrorStack(interp: *Interp) error{OutOfMemory}!void {
    if (interp.stack_trace != .none) return;
    interp.stack_trace.swap(try buildErrorStack(interp));
}

/// Builds the stack trace as a flat list of {name file line args} repeated once per call
/// frame. The top (innermost) frame is emitted first.
fn buildErrorStack(interp: *Interp) error{OutOfMemory}!Value {
    var trace = try objects.List.newWithCapacity(&.{}, interp.eval_frames.items.len * 4);
    errdefer trace.asHead().release();

    var last_call_frame_idx: ?u32 = null;

    // Eval frames are walked from top to bottom. Each one is followed to its
    // corresponding call frame.
    var i = interp.eval_frames.items.len;
    while (i > 0) {
        i -= 1;
        const eval_frame = &interp.eval_frames.items[i];

        // Skip duplicates by taking the topmost eval frame per call frame.
        if (last_call_frame_idx == eval_frame.call_frame) continue;
        last_call_frame_idx = eval_frame.call_frame;

        const call_frame = &interp.call_frames.items[eval_frame.call_frame];
        const closure_name = call_frame.signature.name.orEmpty();

        const source_info = eval_frame.currently_evaluating.asType(objects.Source);
        const file_name = if (source_info) |info| info.file_name.orEmpty() else heap.interned_empty_string.get();
        const base_line = if (source_info) |info| info.line_no else null;

        const base = if (base_line) |val| val else 1;
        const absolute_line = base + eval_frame.current_line;

        const args_list = try List.newWithCapacity(&.{}, eval_frame.args.len);
        defer args_list.asHead().release();

        for (eval_frame.args) |arg| args_list.appendAssumeCapacity(arg.original);

        trace.appendAssumeCapacity(closure_name);
        trace.appendAssumeCapacity(file_name);
        trace.appendAssumeCapacity(Value.newInt(absolute_line));
        trace.appendAssumeCapacity(args_list.asHead().asValue());
    }

    return trace;
}

/// Self will be returned borrowed. Caller is responsible for decrementing the ref count.
fn getCommandAndSelfParam(interp: *Interp, args: []Shimmerable) !struct { command: ?CommandOrClosure, self: OptionalValue } {
    const command = interp.getCommand(interp.callFrameIdx(), &args[0], true) catch |err| switch (err) {
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
        const method_dict_path = &args[0];
        const dict_sugar = method_dict_path.current().asType(vartypes.DictSugar) orelse {
            try interp.setResultFormatted("method \"{f}\" cannot be invoked as function", .{method_dict_path.current()});
            return error.EvalError;
        };

        // Next, we need to find `self`, the second-to-last part of the dict path. For example, calling
        // foo::bar would have foo as `self`, or foo::bar::baz would have foo::bar as `self`.
        const dict_resolved = vartypes.getVariable(
            interp,
            null,
            interp.callFrameIdx(),
            dict_sugar.dict_name,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // This should always succeed, since when `interp.getCommand` was run earlier,
            // it ensured that the dict sugar resolved to something.
            else => unreachable,
        };

        // We modify the dictionary at the end of the path.
        const all_but_last = dict_sugar.dict_path.items[0..(dict_sugar.dict_path.items - 1)];
        const method_ctx = objects.ValueSliceContext{ .items = all_but_last };

        var dict_shim: Shimmerable = .{ .original = dict_resolved.? };
        defer dict_shim.discardChanges();
        var det: ErrorDetails = undefined;
        const maybe_self: OptionalValue = try interp.wrapError(&det, Dictionary.getRecursively(&det, &dict_shim, method_ctx));
        if (dict_shim.shimmered.asValue()) |new_dict| {
            var dict_name: Shimmerable = .{ .original = dict_sugar.dict_name };
            defer dict_name.discardChanges();
            try interp.wrapError(&det, vartypes.setVariable(interp, &det, interp.callFrameIdx(), dict_name, new_dict));
        }

        if (maybe_self.asValue()) |self| {
            return .{ .command = command, .self = self.borrow() };
        } else {
            const var_name = try method_dict_path.current().getString();
            // Shave off the end, because we're looking up `self`, not the method in this case.
            var ending = std.mem.lastIndexOf(u8, var_name, "::").?;
            while (ending > 0 and var_name[ending - 1] == ':') ending -= 1;
            try interp.setResultFormatted("can't read \"{s}\": no such variable", .{var_name[0..ending]});
            return error.EvalError;
        }
    } else {
        return .{ .command = command, .self = .none };
    }
}

/// Takes care of populating the `self` parameter. `args_raw` should be one item
/// larger than `args`, and `args` should be `args_raw[1..]`. If called with a
/// method, `args_raw[1]` will become `args_raw[0]`, opening up a space for the
/// `self` parameter.
fn invokeCommandMaybeMethod(
    interp: *Interp,
    args_raw: []Shimmerable,
) CommandError!void {
    var args = args_raw[1..];

    const cmd_and_self = try interp.getCommandAndSelfParam(args);
    const command = if (cmd_and_self.command) |val| val else {
        // [unknown] was invoked and terminated normally, so there's nothing else to do.
        return;
    };
    const maybe_self = cmd_and_self.self;

    // If the command ended up being a method, we move the command name to the
    // left, which opens up a hole for putting the `self` argument in.
    if (maybe_self.asValue()) |self| {
        args_raw[0] = args_raw[1]; // Move command name to the left.
        args_raw[1] = .{ .original = self };
        args = args_raw[0..]; // Include all the allocated args now.
    }

    // Now that we've populated the arguments for this command, we'll go ahead and run it.
    try interp.invokeCommand(command, args);

    if (maybe_self.asValue()) |_| {
        // Be sure to write back `self`.

        const call_frame = interp.callFrameIdx();
        const method_dict_path = &args[0];
        // `self` is returned back through `args[1]`.
        const new_self = &args[1];
        assert(new_self.shimmered != .none);

        // Make sure `method_dict_path` is still .dict_sugar, as it technically could have shimmered.
        var det: ErrorDetails = undefined;
        try method_dict_path.ensureShimmerable();

        const ensure_result = try interp.wrapError(
            &det,
            vartypes.ensureValidVariableType(interp, &det, call_frame, method_dict_path.current()),
        );
        const as_dict_sugar = blk: {
            switch (ensure_result) {
                .not_found => {
                    const args_list = try command.closure.closure.args.get();
                    const self_name = try args_list.items[0].getString();
                    try interp.setResultFormatted("Could not update \"{s}\" as it was unset when calling method", .{self_name});
                    return error.EvalError;
                },
                .normal => unreachable,
                .dict_sugar => {
                    // What we want.
                    break :blk try vartypes.DictSugar.shimmerAssumeValid(method_dict_path);
                },
            }
        };
        var dict_name: Shimmerable = .{ .original = as_dict_sugar.dict_name };
        defer dict_name.discardChanges();

        const dict_resolved = vartypes.getVariableOrError(interp, &det, call_frame, &dict_name) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.LinkLookupFailed, error.VariableNotFound, error.BadDict, error.BadVariableName => {
                interp.setResultOwning((try objects.String.newOwning(det.message)).asHead().asValue());
                return error.EvalError;
            },
        };

        if (as_dict_sugar.dict_path.items.len == 1) {
            vartypes.setVariable(interp, &det, call_frame, &dict_name, new_self.current()) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.LinkLookupFailed, error.BadVariableName => {
                    interp.setResultOwning(det.message);
                    return error.EvalError;
                },
            };
        } else {
            const all_but_last = as_dict_sugar.dict_path.items[0..(as_dict_sugar.dict_path.items.len - 1)];
            const put_ctx = objects.ValueSliceContext{ .items = all_but_last };

            const duplicate = if (dict_resolved.canMutate()) null else try dict_resolved.duplicate();
            defer if (duplicate) |dup| dup.release();
            const to_use = duplicate orelse dict_resolved;

            var dict_resolved_shim: Shimmerable = .{ .original = to_use };
            _ = try interp.wrapError(&det, Dictionary.shimmerFrom(&det, &dict_resolved_shim));
            assert(dict_resolved_shim.shimmered == .none);
            const as_mutable = dict_resolved_shim.current().asType(Dictionary).?;
            try interp.wrapError(&det, as_mutable.putRecursively(&det, put_ctx, new_self.current()));
            interp.callFrame().variables.inner.invalidateString();

            if (duplicate) |dup| {
                vartypes.setVariable(interp, &det, call_frame, &dict_name, dup) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.LinkLookupFailed, error.BadVariableName => {
                        interp.setResultOwning(det.message);
                        return error.EvalError;
                    },
                };
            }
        }
    }
}

fn evalCommand(interp: *Interp, call_frame: u32, script: Value, parsed: evaltypes.Script, command_token_i: *u32) !void {
    _ = try interp.pushEvalFrame(call_frame, script);
    defer interp.popEvalFrame();

    const tags = parsed.tags.items;

    // First token of the command is always .parsed_script_command.
    const command_info = parsed.values[command_token_i.*].asType(evaltypes.ParsedScriptCommand).?;
    command_token_i.* += 1; // Skip .parsed_script_command.
    interp.evalFrame().current_line = command_info.line;

    var args_raw = try heap.local_arena.alloc(Shimmerable, command_info.word_count + 1);
    // Contains what is considered to be the current arguments.
    var args = args_raw[1..];
    args_raw[0] = .{ .original = heap.interned_empty_string.get() };

    {
        // This is not always the same as which word token we're on, as argument expansion
        // may write multiple arguments from one word.
        var args_written: usize = 0;
        errdefer for (args[0..args_written]) |*arg| arg.deinit();

        // Populate the arguments by looping through each word of the command and
        // substituting.
        var word_token_i: u32 = command_token_i.*;
        // We don't know the length of each word, but we know there's `word_count` words,
        // so we advance `word_count` times.
        for (0..command_info.word_count) |_| {
            var word_parts: usize = 1;
            const argument_expansion = tags[word_token_i] == .argument_expansion;
            if (tags[word_token_i] == .start_of_word or argument_expansion) {
                word_parts = @intCast(parsed.values[word_token_i].body.integer);
                word_token_i += 1;
            }

            var resultant_word: Value = blk: {
                if (word_parts == 1) {
                    // Simple one-to-one substitution, so an easy case.
                    const res = try interp.substituteOneToken(tags[word_token_i], parsed.values[word_token_i]);
                    word_token_i += 1;
                    break :blk res;
                } else {
                    // Helper function that'll interpolate all the word
                    // parts and merge them into a string.
                    const res = try interp.interpolateTokens(
                        tags[word_token_i..][0..word_parts],
                        parsed.values,
                        word_token_i,
                        word_parts,
                    );
                    word_token_i += word_parts;
                    break :blk res;
                }
            };

            if (argument_expansion) {
                // Argument expansion, so we'll need to shimmer the result to a list.
                const as_list = try interp.getListInPlace(&resultant_word);
                defer resultant_word.release();

                if (expansion_len != 1) {
                    // Expanded into multiple tokens, so we'll need to resize args.
                    // Note: len == 0 means the word disappears, so we shrink by 1.
                    args_raw = try args_alloc.realloc(args_raw, args_raw.len + expansion_len - 1);
                    args = args_raw[1..];
                }

                for (0..expansion_len) |list_idx| {
                    args[args_written] = .{ .original = objutil.listItem(resultant_word, @intCast(list_idx)).borrow() };
                    args_written += 1;
                }
            } else {
                args[args_written] = .{ .original = resultant_word };
                args_written += 1;
            }
        }

        assert(args_written == args.len);

        command_token_i.* = word_token_i;
    }
    defer for (args_raw) |*arg| arg.deinit();

    try interp.invokeCommandMaybeMethod(args_raw);
}

pub fn evalObjectInner(interp: *Interp, call_frame: u32, script: Handle, cache_key: u256) EvalError!void {
    // Try to get the script, parsing if necessary.
    var det: ErrorDetails = undefined;
    const parsed: Script = try interp.wrapError(&det, objutil.getScript(&det, script, cache_key)).borrow();
    defer parsed.release();
    // Don't evaluate empty scripts.
    if (parsed.tags.items.len <= 1) return;

    // Reset the interpreter result. This is useful to return the empty result in the case of empty program.
    interp.setEmptyResult();

    // TODO implement JIM_OPTIMIZATION speedups

    // Execute every command sequentially until the end of the script or an error occurs.
    var command_token_i: u32 = 0;

    // Loop through the script's commands.
    while (command_token_i < parsed.tags.items.len) {
        const token_i_at_start = command_token_i;

        const command_result = interp.evalCommand(call_frame, script, parsed, &command_token_i);

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
                        interp.pending_error_code.swap(Heap.local_heap.getInternedString(.@"ZICL OOM"));
                    }

                    if (narrowed_err == error.WrongUsage) {
                        try interp.setResultString("FIXME: prolly should explain how to use the command");
                    }

                    if (narrowed_err == error.EvalError) {
                        if (interp.stack_trace == .none) {
                            // Something went wrong when initializing the eval frame,
                            // so we'll set up a dummy frame, so there's at least a
                            // line number and file name.
                            const frame = try interp.pushEvalFrame(call_frame, script);
                            defer interp.popEvalFrame();

                            const first_token = objutil.listItem(parsed.values, token_i_at_start);
                            first_token.assert(first_token.tag() == .parsed_script_command);
                            const command_info = first_token.peek().body.parsed_script_command;

                            interp.eval_frames.items[frame].current_line = command_info.line;

                            try interp.setErrorStack();
                        } else {
                            try interp.setErrorStack();
                        }
                    }

                    return narrowToEvalError(narrowed_err);
                },
            };
        }
    }
}

pub fn evalObject(interp: *Interp, script: Handle) EvalError!void {
    // Reset the stack trace at each new top-level invocation.
    interp.stack_trace.swapWithNone();
    const cache_key = @as(u256, interp.callFrame().signature.cache_id) ^ try script.getHashNoRegister();
    return evalObjectInner(interp, interp.callFrameIdx(), script, cache_key);
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
        .current_call_epoch = global_call_epoch.fetchAdd(1, .monotonic) + 1,
        .global_procedure_epoch = global_proc_epoch.fetchAdd(1, .monotonic) + 1,
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

    _ = try new_interp.pushCallFrame(&.{}, .{
        .args = Heap.local_heap.emptyHandle(),
        .body = Heap.local_heap.emptyHandle(),
        .name = .none,
        .scope_hash_ref = .none,
        .required_arity = 0,
        .optional_arity = 0,
        .optional_values = .none,
        .has_args_parameter = false,
        .is_method = false,
        .cache_id = Heap.nextCacheId(),
    });
    errdefer new_interp.call_frames.deinit(Heap.global_gpa);
    errdefer new_interp.call_frames.items[0].deinit();

    _ = try new_interp.eval_frames.append(Heap.global_gpa, .{
        .args = &.{},
        .call_frame = 0,
        .current_line = 0,
        .currently_evaluating = Heap.local_heap.emptyHandle(),
    });
    errdefer new_interp.eval_frames.deinit(Heap.global_gpa);

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
    var det: ErrorDetails = undefined;
    interp.wrapError(&det, objutil.integerOverflowError(&det, value)) catch return error.EvalError;
}

pub fn wrapShimmerFn(
    interp: *Interp,
    ReturnType: type,
    wb: *Shimmerable,
    to_call: fn (?*ErrorDetails, *Shimmerable) anyerror!ReturnType,
) !ReturnType {
    var det: ErrorDetails = undefined;
    try wrapError(interp, &det, to_call(&det, wb));
}

pub fn wrapShimmerInPlaceFn(
    interp: *Interp,
    ReturnType: type,
    ref: *Value,
    to_call: fn (?*ErrorDetails, *Shimmerable) anyerror!*const ReturnType,
) !ReturnType {
    var ref_wb: Shimmerable = .{ .original = ref.* };
    var det: ErrorDetails = undefined;
    const result = try wrapError(interp, &det, to_call(&det, &ref_wb));
    ref.* = ref_wb.consume();
    return result;
}

pub fn wrapMutableFn(
    interp: *Interp,
    wb: *objutil.Mutable,
    to_call: fn (?*ErrorDetails, *objutil.Mutable) anyerror!void,
) !void {
    var det: ErrorDetails = undefined;
    try wrapError(interp, &det, to_call(&det, wb));
}

/// Shimmers `wb` to `.integer`. Returns the `i64` value.
pub fn getInteger(interp: *Interp, wb: *objutil.Shimmerable) !i64 {
    try interp.wrapShimmerFn(wb, objutil.shimmerToInteger);
    return wb.peek().body.integer;
}

pub fn getIntegerInPlace(interp: *Interp, ref: *Handle) !i64 {
    try interp.wrapShimmerInPlaceFn(ref, objutil.shimmerToInteger);
    return ref.peek().body.integer;
}

pub fn getIntegerNoShimmer(interp: *Interp, handle: Handle) Interp.Error!i64 {
    var det: ErrorDetails = undefined;
    return interp.wrapError(&det, objutil.integerGetNoShimmer(&det, handle));
}

/// Shimmers `wb` to `.float`. Returns the `f64` value.
pub fn getFloat(interp: *Interp, wb: *objutil.Shimmerable) !f64 {
    try interp.wrapShimmerFn(wb, objutil.shimmerToFloat);
    return wb.peek().body.float;
}

pub fn getFloatNoShimmer(interp: *Interp, handle: Handle) Interp.Error!f64 {
    var det: ErrorDetails = undefined;
    return interp.wrapError(&det, objutil.floatGetNoShimmer(&det, handle));
}

pub fn getIntOrFloatInPlace(interp: *Interp, ref: *Value) !objects.Number {
    var ref_shim: Shimmerable = .{ .original = ref.* };
    var det: objects.ErrorDetails = undefined;
    const result = interp.wrapError(&det, objects.Number.getAsIntOrFloat(&det, &ref_shim));
    ref.* = ref_shim.consume();
    return result;
}

/// Shimmers `wb` to `.bool`. Returns the `bool` value.
pub fn getBoolean(interp: *Interp, wb: *Shimmerable) !bool {
    return try interp.wrapShimmerFn(bool, wb, objects.Boolean.shimmerFrom);
}

pub fn getBooleanInPlace(interp: *Interp, ref: *Value) !bool {
    if (ref.asBool()) |as_bool| return as_bool;
    var det: ErrorDetails = undefined;
    const as_bool = try interp.wrapError(&det, objects.Boolean.fromString(&det, try ref.getString()));
    ref.swap(Value.newBool(as_bool));
}

/// Shimmers `wb` to `.index`. Returns the `Heap.ListIndex` value.
pub fn getIndex(interp: *Interp, wb: *objutil.Shimmerable) !Heap.ListIndex {
    try interp.wrapShimmerFn(wb, objutil.shimmerToIndex);
    return wb.peek().body.index.data;
}

/// Shimmers `wb` to `.hash_reference`. Returns the resolved handle.
pub fn resolveHash(interp: *Interp, wb: *objutil.Shimmerable) !Handle {
    try interp.wrapShimmerFn(wb, objutil.shimmerToHashReference);
    return wb.peek().body.hash_reference;
}

/// Shimmers a handle to a dict, updating it in place if a duplicate was
/// created. Converts errors to EvalError via the interpreter result.
pub fn shimmerToDict(interp: *Interp, wb: *objutil.Shimmerable) !void {
    try interp.wrapShimmerFn(wb, objutil.shimmerToDict);
}

/// Shimmers a handle to a list, updating it in place if a duplicate was
/// created. Converts errors to EvalError via the interpreter result.
pub fn shimmerToList(interp: *Interp, wb: *objutil.Shimmerable) !void {
    try interp.wrapShimmerFn(wb, objutil.shimmerToList);
}

pub fn shimmerToListInPlace(interp: *Interp, ref: *Handle) !void {
    try interp.wrapShimmerInPlaceFn(ref, objutil.shimmerToList);
}

/// Shimmers `wb` to `.list` and returns the item count.
pub fn getListLength(interp: *Interp, wb: *objutil.Shimmerable) !u32 {
    try interp.wrapShimmerFn(wb, objutil.shimmerToList);
    return wb.peek().body.list.len;
}

pub fn getListInPlace(interp: *Interp, ref: *Value) !*const List {
    return try interp.wrapShimmerInPlaceFn(List, ref, List.shimmerFrom);
}

/// Appends `item` to `wb` (which is shimmered to a list first). Returns a
/// non-owning handle to the appended item.
pub fn listAppend(interp: *Interp, wb: *objutil.Mutable, item: Handle) !Handle {
    var det: ErrorDetails = undefined;
    try interp.wrapError(&det, objutil.shimmerToList(&det, wb.asShimmerable()));
    return try interp.wrapError(&det, objutil.listAppend(&det, wb, item));
}

pub fn listAppendInPlace(interp: *Interp, ref: *Handle, item: Handle) !Handle {
    var wb: Mutable = .{ .original = ref.* };
    const result = try interp.listAppend(&wb, item);
    ref.* = wb.consume();
    return result;
}

pub fn getCodepointLength(interp: *Interp, wb: *Shimmerable) !usize {
    _ = interp;
    return try objutil.getCodepointLength(wb);
}

pub fn setVariableToObject(interp: *Interp, name: *Shimmerable, obj: Heap.Object) !void {
    try name.ensureShimmerable();
    var det: ErrorDetails = undefined;
    try interp.wrapError(&det, interp.setVariableInner(&det, interp.callFrameIdx(), name.current(), obj));
}

pub fn setVariableSilent(interp: *Interp, name: *Shimmerable, handle: Handle) !void {
    try name.ensureShimmerable();
    try interp.setVariableInner(null, interp.callFrameIdx(), name.*, handle.dupOrRef());
}

pub fn setVariable(interp: *Interp, name: *Shimmerable, value: Value) !void {
    var det: ErrorDetails = undefined;
    try interp.wrapError(&det, variables.setVariable(interp, &det, interp.callFrameIdx(), name, value));
}

pub fn getVariable(interp: *Interp, name: *Shimmerable) !OptionalHandle {
    try name.ensureShimmerable();

    var det: ErrorDetails = undefined;
    const value = interp.getVariableInner(&det, interp.callFrameIdx(), name.current()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadDict, error.LinkLookupFailed, error.BadVariableName => {
            interp.setResultOwning(det.message);
            return error.EvalError;
        },
    };
    return OptionalHandle.fromHandle(value);
}

pub fn getVariableOrError(interp: *Interp, name: *Shimmerable) !Handle {
    try name.ensureShimmerable();
    var det: ErrorDetails = undefined;
    return try interp.wrapError(&det, interp.getVariableInner(&det, interp.callFrameIdx(), name.current())) orelse {
        try interp.setResultFormatted("can't read \"{f}\": no such variable", .{name.current()});
        return error.EvalError;
    };
}

pub fn unsetVariable(interp: *Interp, name: *Shimmerable) !void {
    try name.ensureShimmerable();
    var det: ErrorDetails = undefined;
    try interp.wrapError(&det, interp.unsetVariableInner(&det, interp.callFrameIdx(), name.current()));
}

pub fn unsetVariableSilent(interp: *Interp, name: *Shimmerable) !void {
    try name.ensureShimmerable();
    try interp.unsetVariableInner(null, interp.callFrameIdx(), name.current());
}

pub fn getDictValue(interp: *Interp, dict: Handle, new_dict: OptionalHandle, key: Handle) Interp.Error!?Handle {
    var det: ErrorDetails = undefined;
    try interp.wrapError(&det, objutil.shimmerToDict(&det, dict));
    return try interp.wrapError(det, objutil.dictLookupFollowLinks(det, new_dict.orElse(dict), new_dict, key));
}

pub fn getDictValueOrError(interp: *Interp, dict: Handle, new_dict: OptionalHandle, key: Handle) Interp.Error!?Handle {
    const result = interp.getDictValue(dict, new_dict, key);
    if (result.value) |val| {
        return val;
    } else {
        try interp.setResultFormatted("could not find value for key \"{f}\"", .{key});
        return error.EvalError;
    }
}

pub fn getDictValueInPlace(interp: *Interp, dict: *Handle, key: Handle) !?Handle {
    var maybe_new_dict: OptionalHandle = .none;
    const result = try interp.getDictValue(dict.*, &maybe_new_dict, key);
    dict.swapIfNew(maybe_new_dict);
    return result;
}

pub fn getDictValueRecursively(interp: *Interp, wb: *Shimmerable, context: anytype) Interp.Error!OptionalHandle {
    var det: ErrorDetails = undefined;
    return try interp.wrapError(&det, objutil.dictLookupRecursively(&det, wb, context));
}

pub fn getDictValueRecursivelyOrError(interp: *Interp, wb: *Shimmerable, context: anytype) Interp.Error!Handle {
    const result = try interp.getDictValueRecursively(wb, context);
    if (result.toHandle()) |val| return val;

    // Else, create a useful error message.
    if (context.len() == 1) {
        try interp.setResultFormatted("could not find value for key \"{f}\"", .{context.get(0)});
    } else {
        const keys_list = try objutil.newListWithCapacity(@intCast(context.len()));
        defer keys_list.decrRefCount();
        for (0..context.len()) |i| objutil.listAppendAssumeCapacity(keys_list, context.get(i).dupOrRef());

        try interp.setResultFormatted("could not find value for keys \"{f}\"", .{keys_list});
    }

    return error.EvalError;
}

pub fn putDictValue(interp: *Interp, wb: *Mutable, key: Handle, value: Handle) Interp.Error!Handle {
    var det: ErrorDetails = undefined;
    try interp.wrapError(&det, objutil.shimmerToDict(&det, wb.asShimmerable()));
    return try objutil.dictPut(wb, key, value);
}

/// Like `putDictValue`, but updates the dict handle in place when the dict
/// has to be moved (e.g. because it was shared or inline).
pub fn putDictValueInPlace(interp: *Interp, ref: *Handle, key: Handle, value: Handle) Interp.Error!Handle {
    var ref_wb: Mutable = .{ .original = ref.* };
    const result = try interp.putDictValue(&ref_wb, key, value);
    ref.* = ref_wb.consume();
    return result;
}

pub fn putDictValueRecursively(interp: *Interp, wb: *Mutable, context: anytype, value: Handle) Interp.Error!Handle {
    var det: ErrorDetails = undefined;
    return try interp.wrapError(&det, objutil.dictPutRecursively(&det, wb, context, value.dupOrRef()));
}

/// Returns whether the value was removed.
pub fn removeDictValue(interp: *Interp, original: Handle, new: *OptionalHandle, key: Handle) !bool {
    errdefer new.swapWithNone();

    var det: ErrorDetails = undefined;
    try interp.wrapError(&det, objutil.shimmerToDict(&det, original, new));
    return try interp.wrapError(&det, objutil.dictRemove(&det, original, new, key));
}

pub fn removeDictValueRecursively(interp: *Interp, dict: *Mutable, context: anytype) Interp.Error!bool {
    var det: ErrorDetails = undefined;
    return try interp.wrapError(&det, objutil.dictRemoveRecursively(&det, dict, context));
}

test "recursive dict keys" {
    defer Heap.testFinish();
    try Heap.testStart(testing.allocator, testing.io);
    var interp = try Interp.init();
    defer interp.deinit();

    var dict: Mutable = .{ .original = try objutil.newDict(&.{}) };
    defer dict.deinit();
    var key_foo = try objutil.newString("foo");
    defer key_foo.decrRefCount();
    var key_bar = try objutil.newString("bar");
    defer key_bar.decrRefCount();
    var key_baz = try objutil.newString("baz");
    defer key_baz.decrRefCount();
    const value_qux = try objutil.newString("qux");
    defer value_qux.decrRefCount();

    _ = try interp.putDictValueRecursively(
        &dict,
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar, key_baz } },
        value_qux,
    );
    try testing.expectEqualStrings("foo {bar {baz qux}}", try dict.getString());

    // Try taking ownership of one of the intermediate dictionaries.
    const to_take = (try interp.getDictValueRecursively(
        dict.asShimmerable(),
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar } },
    )).toHandle().?;

    // See if setting still works correctly.
    _ = try interp.putDictValueRecursively(
        &dict,
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar, key_baz } },
        value_qux,
    );
    try testing.expectEqual(1, to_take.getRefCount());

    // Let's try some very cursed aliasing.
    _ = try interp.putDictValueRecursively(
        &dict,
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar } },
        objutil.dictItemNoFollow(dict.current(), 0),
    );
    try testing.expectEqualStrings("foo {bar foo}", try dict.getString());

    const value_result = (try interp.getDictValueRecursively(
        dict.asShimmerable(),
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar } },
    )).toHandle().?;
    try testing.expectEqualStrings("foo", try value_result.getString());
}

fn testRecursiveDictRemoval(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    try Heap.testStart(ta, testing.io);
    var interp = try Interp.init();
    defer interp.deinit();

    var dict: Mutable = .{ .original = try objutil.newDict(&.{}) };
    defer dict.deinit();
    var key_foo = try objutil.newString("foo");
    defer key_foo.decrRefCount();
    var key_bar = try objutil.newString("bar");
    defer key_bar.decrRefCount();
    var key_baz = try objutil.newString("baz");
    defer key_baz.decrRefCount();
    const value_qux = try objutil.newString("qux");
    defer value_qux.decrRefCount();

    // Test 1: Remove a deeply nested value (3 levels).
    _ = try interp.putDictValueRecursively(
        &dict,
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar, key_baz } },
        value_qux,
    );

    try testing.expectEqualStrings("foo {bar {baz qux}}", try dict.getString());
    var did_remove = try interp.removeDictValueRecursively(
        &dict,
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar, key_baz } },
    );
    try testing.expect(did_remove);
    try testing.expectEqualStrings("foo {bar {}}", try dict.getString());

    // Test 2: Try to remove the same key again (should return false).
    did_remove = try interp.removeDictValueRecursively(
        &dict,
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar, key_baz } },
    );
    try testing.expect(!did_remove);
    try testing.expectEqualStrings("foo {bar {}}", try dict.getString());

    // Test 3: Remove a non-existent key from an existing intermediate dict.objutil.HandleSliceContext{ .items =
    did_remove = try interp.removeDictValueRecursively(
        &dict,
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar, key_foo } },
    );
    try testing.expect(!did_remove);
    try testing.expectEqualStrings("foo {bar {}}", try dict.getString());

    // Test 4: Remove from a non-existent intermediate dict.
    try memutil.expectErrorOrOom(
        error.EvalError,
        interp.removeDictValueRecursively(&dict, objutil.HandleSliceContext{ .items = &.{ key_bar, key_baz, key_foo } }),
    );
    try testing.expectEqualStrings(
        \\key "bar" not known in dictionary "foo {bar {}}"
    , try interp.result.getString());
    try testing.expectEqualStrings("foo {bar {}}", try dict.getString());

    // Test 5: Single-level removal (base case).
    did_remove = try interp.removeDictValueRecursively(&dict, objutil.HandleSliceContext{ .items = &.{key_foo} });
    try testing.expect(did_remove);
    try testing.expectEqualStrings("", try dict.getString());

    // Test 6: Two-level removal.
    _ = try interp.putDictValueRecursively(
        &dict,
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar } },
        value_qux,
    );
    try testing.expectEqualStrings("foo {bar qux}", try dict.getString());
    did_remove = try interp.removeDictValueRecursively(&dict, objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar } });
    try testing.expect(did_remove);
    try testing.expectEqualStrings("foo {}", try dict.getString());

    // Test 7: Removal when intermediate dict is shared (copy-on-write).
    var interm_test_dict: Mutable = .{ .original = try objutil.newDict(&.{}) };
    defer interm_test_dict.deinit();
    _ = try interp.putDictValueRecursively(
        &interm_test_dict,
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar, key_baz } },
        value_qux,
    );
    _ = try interp.putDictValueRecursively(
        &interm_test_dict,
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar, key_foo } },
        value_qux,
    );

    // Borrow the intermediate dict.
    const intermediate = (try interp.getDictValueRecursively(
        interm_test_dict.asShimmerable(),
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar } },
    )).toHandle().?;
    intermediate.incrRefCount();
    defer intermediate.decrRefCount();

    const initial_refcount = intermediate.getRefCount();
    try testing.expectEqualStrings("baz qux foo qux", try intermediate.getString());

    // Remove from the nested dict while it's owned elsewhere.
    did_remove = try interp.removeDictValueRecursively(
        &interm_test_dict,
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar, key_baz } },
    );
    try testing.expect(did_remove);

    // The intermediate dict we own should be unchanged (copy-on-write).
    try testing.expectEqualStrings("baz qux foo qux", try intermediate.getString());
    // But the main dict should have a new copy without 'baz'.
    const foo_bar_result = (try interp.getDictValueRecursively(
        interm_test_dict.asShimmerable(),
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar } },
    )).toHandle().?;
    try testing.expectEqualStrings("foo qux", try foo_bar_result.getString());
    // Reference count should drop by 1 since the parent no longer references it.
    try testing.expectEqual(initial_refcount - 1, intermediate.getRefCount());

    // Test 8: Remove multiple items from a nested dict.
    dict.deinit();
    dict = .{ .original = try objutil.newDict(&.{}) };
    _ = try interp.putDictValueRecursively(&dict, objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar } }, value_qux);
    _ = try interp.putDictValueRecursively(&dict, objutil.HandleSliceContext{ .items = &.{ key_foo, key_baz } }, value_qux);
    try testing.expectEqualStrings("foo {bar qux baz qux}", try dict.getString());
    did_remove = try interp.removeDictValueRecursively(&dict, objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar } });
    try testing.expect(did_remove);
    try testing.expectEqualStrings("foo {baz qux}", try dict.getString());
    did_remove = try interp.removeDictValueRecursively(&dict, objutil.HandleSliceContext{ .items = &.{ key_foo, key_baz } });
    try testing.expect(did_remove);
    try testing.expectEqualStrings("foo {}", try dict.getString());
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
        ioutil.debug("Test failed with zig error {}", .{err});
        ioutil.debug(" and error message \"{f}\"\n", .{interp.result});
        return err;
    }
}

pub fn testExpectScriptError(interp: *Interp, expected_error: anyerror, expected_str: []const u8, script: []const u8) !void {
    if (testRunScript(interp, script)) |_| {
        ioutil.debug("Expected error {}, but got success\n", .{expected_error});
        return error.TestUnexpectedResult;
    } else |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        const error_str = try interp.result.getString();
        if (err == expected_error) {
            try testing.expectEqualStrings(expected_str, error_str);
        } else {
            ioutil.debug("Expected error {}, but got {} instead\n", .{ expected_error, err });
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

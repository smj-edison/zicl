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
const Shimmerable = objects.Shimmerable;
const ErrorDetails = objects.ErrorDetails;
const vartypes = @import("vartypes.zig");
const allocPrintZ = objects.allocPrintZ;
const Dictionary = objects.Dictionary;
const String = objects.String;
const List = objects.List;
const evaltypes = @import("evaltypes.zig");
const Closure = evaltypes.Closure;
const Script = evaltypes.Script;
const Expression = evaltypes.Expression;
const Substitution = evaltypes.Substitution;

// We re-export these so callers only need to import Interp and not evaltypes.
pub const ReturnCode = heap.ReturnCode;
pub const Error = heap.Error;
pub const ReturnCodeEnum = evaltypes.ReturnCodeEnum;

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
unknown_str: Value,
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
const ParsedScripts = memutil.LruCache(u256, *Script, FullHashContext);
const ParsedExpressions = memutil.LruCache(u256, *Expression, FullHashContext);
const ParsedClosures = memutil.LruCache(u256, *Closure, FullHashContext);
const ParsedSubstitutions = memutil.LruCache(u256, *Substitution, FullHashContext);

pub const CommandHashTable = std.StringArrayHashMapUnmanaged(evaltypes.NativeCommand);

const interned_name = heap.InternedString.newValue("name");
const interned_impl = heap.InternedString.newValue("impl");
const interned_scope = heap.InternedString.newValue("scope");
const interned_zicl_oom = heap.InternedString.newValue("ZICL OOM");
const interned_oom = heap.InternedString.newValue("out of memory");

pub fn narrowError(err: anyerror) heap.EvalError {
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
    break :blk if (info == .error_set) heap.EvalError else heap.EvalError!info.error_union.payload;
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
/// Reject wrapping a call that already reports through the interpreter.
///
/// Such a call returns exactly what `wrapErrorDetailsReturnType` produces, and
/// it consumed its own `ErrorDetails` on the way out. Wrapping it again means
/// this call's `det` is never written, and `wrapError` then hands that
/// uninitialized `message` to `setResultStringOwning`, which faults rather than
/// failing. Catching it here turns a general protection exception into a
/// compile error naming the call site.
fn assertWrappable(ResultType: type) void {
    comptime {
        const ErrorSet = switch (@typeInfo(ResultType)) {
            .error_set => ResultType,
            .error_union => |error_union| error_union.error_set,
            // Not fallible at all, so there is nothing to wrap either way.
            else => return,
        };
        // `anyerror` and an unresolved inferred set carry no member list, so
        // they cannot be checked. `wrapShimmerFn` legitimately lands here.
        const members = @typeInfo(ErrorSet).error_set orelse return;
        for (members) |member| {
            const already_interpreter_level = std.mem.eql(u8, member.name, "OutOfMemory") or
                std.mem.eql(u8, member.name, "EvalError");
            if (!already_interpreter_level) return;
        }
        @compileError("wrapError on a call that already reports its own errors, so this " ++
            "`det` would never be written. Call it directly with `try` instead. See the " ++
            "`interp.*` helpers that wrap internally, such as `getVariable` or `getSubstitution`.");
    }
}

/// Used to convert from an object error to an interpreter error (e.g. putting
/// it in the interpreter result, instead of det)
pub fn wrapError(interp: *Interp, det: *ErrorDetails, result: anytype) wrapErrorDetailsReturnType(@TypeOf(result)) {
    comptime assertWrappable(@TypeOf(result));

    if (comptime std.meta.activeTag(@typeInfo(@TypeOf(result))) == .error_set) {
        if (result == error.OutOfMemory) {
            return error.OutOfMemory;
        } else {
            try interp.setResultStringOwning(det.message);
            return error.EvalError;
        }
    }

    return result catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            // This error should have error details, if it's not OOM.
            try interp.setResultStringOwning(det.message);
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
    try interp.setVariable(&var_name_wb, var_value);

    _ = interp.nextProcedureEpoch();
}

/// If called with a method, this will _modify_ `args[1]`, not just shimmer it.
pub fn callClosure(interp: *Interp, closure: *Closure.Content, cache_key: u256, args: []Shimmerable) !void {
    const arg_count = args.len - 1; // - 1 to skip command name as first argument.

    const is_method = closure.is_method;

    // Check arity.
    const too_few_arguments: bool = arg_count < closure.required_arity;
    const has_args: bool = closure.has_args_parameter;
    const too_many_arguments: bool = !has_args and arg_count > closure.required_arity + closure.optional_arity;
    if (too_few_arguments or too_many_arguments) {
        // Wrong argument count, error accordingly.
        const command_usage = try closure.getUsage(heap.local_arena, try args[0].current().getString());
        try interp.setResultFormatted("wrong # args: should be \"{s}\"", .{command_usage});
        return error.WrongUsage;
    }

    // Check for infinite recursion.
    if (interp.callFrameIdx() >= interp.max_call_depth) {
        try interp.setResultString("Too many nested calls. Infinite recursion?");
        return error.InfiniteRecursion;
    }

    const call_frame_idx = try interp.pushCallFrame(args, closure);
    defer {
        var frame_mut = interp.call_frames.pop().?;
        frame_mut.deinit();
    }

    // Next, we'll populate the call frame.

    // Where we are in the arguments that this was called with.
    var called_idx: usize = 1;
    // Where we are in the signature.
    var signature_idx: u32 = 0;

    const arg_names = (try closure.arg_names.get()).items;
    const optional_values = if (closure.optional_values) |*vals| (try vals.get()).items else &.{};

    while (signature_idx < arg_names.len) : (signature_idx += 1) {
        var var_name: Shimmerable = .{ .original = arg_names[signature_idx] };
        defer var_name.discardChanges(); // TODO PERF write back here instead of deleting the temp object.

        // Are we at the last argument? If so, is it `args`?
        if (signature_idx == arg_names.len - 1 and closure.has_args_parameter) {
            // Assign remaining arguments to `args`.
            const list = try List.newWithCapacity(&.{}, args.len - called_idx);
            defer list.asHead().release();
            for (args[called_idx..]) |arg| list.appendAssumeCapacity(arg.current());

            try interp.setVariableInFrame(call_frame_idx, &var_name, list.asHead().asValue());
        } else if (signature_idx >= closure.required_arity) {
            // This is an optional argument.

            // Are there any remaining unassigned arguments?
            if (called_idx < args.len) {
                try interp.setVariableInFrame(call_frame_idx, &var_name, args[called_idx].current());
                called_idx += 1;
            } else {
                // Else populate it with its default value.
                const default_value = optional_values[signature_idx - closure.required_arity];
                try interp.setVariableInFrame(call_frame_idx, &var_name, default_value);
            }
        } else {
            try interp.setVariableInFrame(call_frame_idx, &var_name, args[called_idx].current());
            called_idx += 1;
        }
    }

    // Note that once we evaluate `closure`, we can no longer guarantee that it's still shimmered
    // as a Closure. This is because the closure and variable namespaces are the same, so something
    // like
    // ```
    // fn foo {} {
    //   upvar foo foo
    //   puts [dict get $foo name]
    // }
    // ```
    // will shimmer `foo` halfway through evaluation.

    // `[return -level N]` counts closure calls, so this is where a level is
    // consumed. Counting script evaluations instead would let a body such as an
    // [if] eat the level before the closure ever sees it:
    //
    // ```
    // fn f {} { if {true} { return 42 }; return 99 }
    // ```
    //
    // Here the `if` body is its own evaluation, so `f` would answer 99.
    interp.evalObjectInner(call_frame_idx, closure.body, cache_key) catch |err| switch (err) {
        error.PropagateResult => {
            interp.return_propagate.left_to_go -= 1;
            if (interp.return_propagate.left_to_go > 0) return error.PropagateResult;
            // Reaching zero means the return stops at this closure, and its
            // result is the closure's result.
        },
        else => return err,
    };

    // When called as a method, we write back `self` to `args[1]`, so that the
    // caller can update the new method.
    if (is_method) {
        var self_var_name: Shimmerable = .{ .original = arg_names[0] };
        defer self_var_name.discardChanges(); // TODO PERF don't discard, write back.
        if (vartypes.getVariableOrError(interp, null, call_frame_idx, &self_var_name)) |updated_self| {
            args[1].shimmered.swap(updated_self.borrow());
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadVariableName => {
                // This variable name was already checked when setting the arguments.
                unreachable;
            },
            error.VariableNotFound, error.LookupFailed => {
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

        switch (command.call_info) {
            // A command can also reject its arguments from inside its body, for
            // reasons the arity bounds cannot express. Routing that back through
            // the same path below gives it the real usage string, which only this
            // function can build since only it knows which command ran.
            .zig => |to_call| to_call(interp, args) catch |err| switch (err) {
                error.WrongUsage => break :wrong_arg_count,
                else => return err,
            },
            .c => |to_call| {
                try ReturnCode.toError(to_call(interp, @intCast(args.len), args.ptr));
            },
        }

        return;
    }

    const command_usage = try command.getUsageInfo(heap.local_arena, try args[0].current().getString());
    try interp.setResultFormatted("wrong # args: should be \"{s}\"", .{command_usage});
    return error.WrongUsage;
}

fn freeLastResult(interp: *Interp) void {
    interp.result.release();
    interp.result = heap.interned_empty_string;
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
    interp.setResultOwning(objects.Integer.new(value));
}

pub fn setResultFloat(interp: *Interp, value: f64) void {
    interp.setResultOwning(objects.Float.new(value));
}

pub fn setResultString(interp: *Interp, bytes: []const u8) !void {
    interp.setResultOwning(try String.newValue(bytes));
}

pub fn setError(interp: *Interp, value: Value) error{EvalError} {
    interp.setResult(value);
    return error.EvalError;
}

pub fn setErrorString(interp: *Interp, bytes: []const u8) error{ OutOfMemory, EvalError } {
    try interp.setResultString(bytes);
    return error.EvalError;
}

pub fn setErrorFormatted(interp: *Interp, comptime fmt: []const u8, args: anytype) error{ OutOfMemory, EvalError } {
    try interp.setResultFormatted(fmt, args);
    return error.EvalError;
}

/// Frees `bytes` in error cases.
pub fn setResultStringOwning(interp: *Interp, bytes: [:0]u8) !void {
    interp.setResultOwning((try String.newOwning(bytes)).asHead().asValue());
}

pub fn setResultBoolean(interp: *Interp, value: bool) void {
    interp.setResultOwning(objects.Boolean.new(value));
}

pub fn setResultFormatted(interp: *Interp, comptime fmt: []const u8, args: anytype) !void {
    const fmt_handle = try allocPrintZ(fmt, args);
    try interp.setResultStringOwning(fmt_handle);
}

pub fn setEmptyResult(interp: *Interp) void {
    interp.freeLastResult();
}

pub fn makeErrorMessage(error_mesage: Value, stack_trace: *const List) !Value {
    if (stack_trace.items.len == 0 or @mod(stack_trace.items.len, 4) != 0) return error.WrongSize;

    var buf = std.ArrayList(u8).empty;

    const first_file = stack_trace.items[1];
    const first_line = stack_trace.items[2];

    try buf.print(heap.global_gpa, "{s}:{s}: Error: {s}\n", .{
        try first_file.getString(),
        try first_line.getString(),
        try error_mesage.getString(),
    });
    try buf.print(heap.global_gpa, "Traceback:\n", .{});

    if (stack_trace.items.len <= 4) {
        // Stack trace only had one entry, so there's no point in printing the traceback.
        return try String.newValue(buf.items);
    }

    // Stack trace is a flat list of {command file line args} repeated per frame.
    var i: u32 = 0;
    while (i < stack_trace.items.len) : (i += 4) {
        const fn_name = try stack_trace.items[i].getString();
        const file = try stack_trace.items[i + 1].getString();
        const line = try stack_trace.items[i + 2].getString();
        const args = try stack_trace.items[i + 3].getString();

        if (file.len > 0) {
            try buf.print(heap.global_gpa, "  File \"{s}\", line {s}", .{ file, line });
        }

        if (fn_name.len > 0) {
            if (file.len > 0) {
                try buf.print(heap.global_gpa, ", in {s}", .{fn_name});
            } else {
                try buf.print(heap.global_gpa, "  In {s}", .{fn_name});
            }
        }

        if (file.len > 0 or fn_name.len > 0) {
            try buf.append(heap.global_gpa, '\n');
        }

        if (args.len > 0) {
            if (std.mem.indexOfScalar(u8, args, '\n')) |args_newline| {
                const shortened = args[0..args_newline];
                try buf.print(heap.global_gpa, "    {s}...\n", .{shortened});
            } else {
                try buf.print(heap.global_gpa, "    {s}\n", .{args});
            }
        }
    }

    // Remove trailing \n
    if (buf.getLastOrNull()) |last| if (last == '\n') {
        _ = buf.pop();
    };

    const owned_slice = try buf.toOwnedSliceSentinel(heap.global_gpa, 0);
    return (try String.newOwning(owned_slice)).asHead().asValue();
}

/// Call frame.
const CallFrame = struct {
    /// The frame's variables. Held by pointer, not inline, so that the
    /// `*VarTable` a `CachedLocalVar` caches survives `call_frames` reallocating.
    variables: *vartypes.VarTable,
    /// Arguments of this procedure call. Lifetime managed by creator.
    args: []Shimmerable,
    /// Signature of the closure that is being called. Note this is an abridged
    /// signature, since we only use a few of the fields of the closure during
    /// evaluation.
    signature: struct {
        cache_id: u64,
        /// Used during stack trace reporting, so we can say what closure was executed.
        name: OptionalValue,
        scope_hash_ref: ?objects.AlwaysCanBeType(objects.HashReference),
    },
    /// Call epoch. Used to invalidate previous variable lookups.
    call_epoch: u64,
    /// Set this during evaluation to trigger a tailcall.
    tailcall: ?Tailcall,

    pub fn deinit(frame: *CallFrame) void {
        // Args are managed externally, so we don't free them.
        frame.variables.destroy();
        frame.signature.name.release();
        if (frame.signature.scope_hash_ref) |*scope_hash_ref| scope_hash_ref.deinit();
    }
};

pub fn callFrameIdx(interp: *Interp) u32 {
    return interp.evalFrame().call_frame;
}

pub fn callFrame(interp: *Interp) *CallFrame {
    return &interp.call_frames.items[interp.callFrameIdx()];
}

/// Returns a dict containing this call frame's variables.
pub fn captureScope(interp: *Interp, call_frame_idx: u32) !*Dictionary {
    const frame = &interp.call_frames.items[call_frame_idx];
    const table = frame.variables;

    // The lexical scope link lives on the frame's signature rather than in the
    // table, so it has to be re-materialized here. It goes in first so that a
    // captured scope's iteration order, and therefore its content hash, doesn't
    // depend on when the link was established relative to the frame's variables.
    const parent_link: ?Value = if (frame.signature.scope_hash_ref) |ref| ref.inner.asValue() else null;
    const parent_slots: usize = if (parent_link != null) 2 else 0;

    // Note, the captured scope is a copy: the frame keeps mutating its variables
    // after this returns, while a captured scope must not change.
    const new_dict = try Dictionary.newWithCapacity(&.{}, table.count() * 2 + parent_slots);
    errdefer new_dict.asHead().release();

    if (parent_link) |link| try new_dict.put(objects.interned_tilde_parent, link);

    // Upvars can't be captured as links, since the frame they point into may be
    // gone by the time the closure runs, so they resolve to their values here.
    for (table.map.keys(), table.map.values()) |name, slot| {
        switch (slot) {
            .normal => |value| try new_dict.put(name, value),
            .upvar => |link| {
                var name_shim: Shimmerable = .{ .original = link.linked_name };
                defer name_shim.discardChanges();
                if ((try interp.getVariableInFrame(link.call_frame, &name_shim)).asValue()) |linked_value| {
                    try new_dict.put(name, linked_value);
                } else {
                    try interp.setResultFormatted(
                        "failed to capture the variable \"{s}\", as it was an upvar that pointed at nothing",
                        .{try name.getString()},
                    );
                    return error.UninitializedUpvar;
                }
            },
        }
    }

    return new_dict;
}

/// Returns a dict capturing the current call frame's variables.
pub fn captureCurrentScope(interp: *Interp) !*Dictionary {
    return try interp.captureScope(interp.callFrameIdx());
}

var global_proc_epoch: std.atomic.Value(u64) = .init(0);
fn nextProcedureEpoch(interp: *Interp) u64 {
    interp.global_procedure_epoch = global_proc_epoch.fetchAdd(1, .monotonic) + 1;
    return interp.global_procedure_epoch;
}

var global_call_epoch: std.atomic.Value(u64) = .init(0);
pub fn nextCallEpoch(interp: *Interp) u64 {
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

/// `signature` does not need to outlive this function call, as this borrows everything
/// needed from `signature` when creating the call frame.
fn pushCallFrame(interp: *Interp, args: []Shimmerable, signature: *const Closure.Content) !u32 {
    // The lexical scope link is not stored in the table; it lives on the frame's
    // signature below, and `captureScope` re-materializes it when it needs one.
    const variables = try vartypes.VarTable.create();
    errdefer variables.destroy();

    // Reserved up front, since a failing append would strand the references in its argument.
    try interp.call_frames.ensureUnusedCapacity(heap.global_gpa, 1);

    const new_call_frame_idx = interp.call_frames.items.len;
    interp.call_frames.appendAssumeCapacity(.{
        .args = args,
        .call_epoch = interp.nextCallEpoch(),
        .signature = .{
            .cache_id = signature.cache_id,
            .name = signature.name.borrow(),
            .scope_hash_ref = if (signature.scope_hash_ref) |val| val.duplicate() else null,
        },
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
            var name_shim: Shimmerable = .{ .original = value };
            defer name_shim.discardChanges();
            const var_target: Value = try interp.getVariableOrError(&name_shim);
            return var_target.borrow();
        },
        .expression_sugar => {
            return try interp.evalExpression(value);
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
    defer for (new_values.items) |value| value.release();

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

    if (new_str_len == 0) return heap.interned_empty_string;

    const new_bytes = blk: {
        var bytes = try heap.global_gpa.allocSentinel(u8, new_str_len, 0);
        errdefer heap.global_gpa.free(bytes);
        var written: usize = 0;
        for (new_values.items) |new_value| {
            const value_str = try new_value.getString();
            @memcpy(bytes[written..][0..value_str.len], value_str);
            written += value_str.len;
        }
        break :blk bytes;
    };

    return (try String.newOwning(new_bytes)).asHead().asValue();
}

pub fn getScript(interp: *Interp, value: Value, cache_key: u256) !*Script {
    if (interp.parsed_scripts.get(cache_key)) |parsed| {
        parsed.asHead().incrRefCount();
        return parsed;
    } else {
        var det: ErrorDetails = undefined;
        const new_script = try interp.wrapError(&det, Script.parse(&det, value));
        if (interp.parsed_scripts.put(cache_key, new_script)) |ejected| ejected.asHead().release();
        new_script.asHead().incrRefCount();
        return new_script;
    }
}

pub fn getSubstitution(interp: *Interp, value: Value, cache_key: u256, flags: Tokenizer.SubstFlags) !*Substitution {
    if (interp.parsed_substs.get(cache_key)) |parsed| {
        return parsed;
    } else {
        var det: ErrorDetails = undefined;
        const new_subst = try interp.wrapError(&det, Substitution.parse(&det, value, flags));
        if (interp.parsed_substs.put(cache_key, new_subst)) |ejected| ejected.asHead().release();
        return new_subst;
    }
}

pub const ClosureAndCacheKey = struct {
    closure: *Closure,
    cache_key: u256,
};
pub fn getClosure(interp: *Interp, value: Value, can_be_method: bool) !ClosureAndCacheKey {
    const closure_and_key: ClosureAndCacheKey = blk: {
        if (value.asType(Closure)) |closure| {
            break :blk .{ .closure = closure, .cache_key = @as(u256, closure.content.cache_id) };
        }

        const cache_key = try value.getHashNoRegister();

        if (interp.parsed_closures.get(cache_key)) |cached| {
            break :blk .{ .closure = cached, .cache_key = cache_key };
        } else {
            // We need to parse the closure.
            var det: ErrorDetails = undefined;
            const closure = try interp.wrapError(&det, Closure.parse(&det, try value.getString()));
            if (interp.parsed_closures.put(cache_key, closure)) |ejected| ejected.asHead().release();
            break :blk .{ .closure = closure, .cache_key = cache_key };
        }
    };

    if (!can_be_method and closure_and_key.closure.content.is_method) {
        interp.setResultOwning(heap.InternedString.newValue("method cannot be invoked as function"));
        return error.EvalError;
    }

    return closure_and_key;
}

const CommandOrClosure = union(enum) {
    closure: ClosureAndCacheKey,
    command: *evaltypes.NativeCommand,

    pub fn deinit(self: *CommandOrClosure) void {
        switch (self.*) {
            .closure => |*closure| closure.closure.asHead().release(),
            else => {},
        }
    }
};

/// If variant is `closure`, then the closure is returned borrowed.
fn getCommandInner(interp: *Interp, call_frame: u32, name: *Shimmerable, can_be_method: bool) !CommandOrClosure {
    var det: ErrorDetails = undefined;

    const var_val_raw: ?Value = try interp.wrapError(&det, vartypes.getVariable(interp, &det, call_frame, name));
    const var_val = var_val_raw orelse {
        try interp.setResultFormatted("invalid command name \"{s}\"", .{try name.current().getString()});
        return error.CommandNotFound;
    };

    if (var_val.asType(Closure)) |closure| {
        closure.asHead().incrRefCount();
        return .{ .closure = .{
            .closure = closure,
            .cache_key = @as(u256, closure.content.cache_id),
        } };
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

        try interp.setResultFormatted("invalid native command name \"{s}\"", .{cmd_name});
        return error.CommandNotFound;
    } else {
        const closure = try interp.getClosure(var_val, can_be_method);
        closure.closure.asHead().incrRefCount();
        return .{ .closure = closure };
    }
}

/// If variant is `closure`, then the closure is returned borrowed.
pub fn getCommand(interp: *Interp, call_frame_idx: u32, name: *Shimmerable, can_be_method: bool) !CommandOrClosure {
    return interp.getCommandInner(call_frame_idx, name, can_be_method) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CommandNotFound => return error.CommandNotFound,
        else => return error.EvalError,
    };
}

fn invokeUnknown(interp: *Interp, args: []Shimmerable) !void {
    var unknown_str: Shimmerable = .{ .original = interp.unknown_str };
    defer unknown_str.discardChanges();
    var unknown_cmd = interp.getCommand(0, &unknown_str, false) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CommandNotFound => {
            // No [unknown] command exists, so we'll default to the "no command found" error.
            try interp.setResultFormatted("invalid command name \"{s}\"", .{try args[0].current().getString()});
            return error.EvalError;
        },
        error.EvalError => return error.EvalError,
    };
    defer unknown_cmd.deinit();

    if (interp.unknown_depth > 50) {
        try interp.setResultString("infinite recursion in [unknown]");
        return error.EvalError;
    }

    interp.unknown_depth += 1;
    defer interp.unknown_depth -= 1;

    var new_args = try heap.local_arena.alloc(Shimmerable, args.len);
    new_args[0] = .{ .original = interp.unknown_str };
    @memcpy(new_args[1..], args[1..]);

    try interp.invokeCommand(&unknown_cmd, new_args);
}

const CommandError = heap.Error || error{InfiniteRecursion};
fn invokeCommand(interp: *Interp, command_or_closure: *CommandOrClosure, args: []Shimmerable) CommandError!void {
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
            switch (command_or_closure.*) {
                .command => |command| {
                    break :blk interp.callNative(command, current_args);
                },
                .closure => |*closure| {
                    break :blk interp.callClosure(closure.closure.content, closure.cache_key, current_args);
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
        if (interp.parsed_exprs.put(cache_key, new_expr)) |ejected| ejected.asHead().release();

        return new_expr;
    }
}

pub fn evalExpression(interp: *Interp, value: Value) !Value {
    // Combine the signature's cache id with the expression's content hash, so
    // identical expressions at different call sites get their own cached
    // variable lookups.
    const cache_key = @as(u256, interp.callFrame().signature.cache_id) ^ try value.getHashNoRegister();
    const expr: *Expression = try interp.getExpression(value, cache_key);

    return Expression.evalNode(interp, expr.parsed.nodes, expr.parsed.root_node) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => {
            var alloc_writer: std.Io.Writer.Allocating = .init(heap.global_gpa);
            defer alloc_writer.deinit();
            expr.parsed.render(&alloc_writer.writer) catch return error.OutOfMemory;

            // Give the caller some context for what failed.
            try interp.setResultFormatted(
                "error occured when evaluating expression {s}: {s}, parse tree: {s}",
                .{ try value.getString(), try interp.result.getString(), alloc_writer.writer.buffered() },
            );
            return error.EvalError;
        },
    };
}

test "eval expression" {
    try heap.testStart(testing.allocator, testing.io);
    defer heap.testFinish();
    var interp = try Interp.init(.{});
    defer interp.deinit();

    var expr = try String.newValue("5 + 10");
    defer expr.release();
    const result = try interp.evalExpression(expr);
    try testing.expect(try Value.newInt(15).equals(result));
}

pub fn getBoolFromExpression(interp: *Interp, value: Value) !bool {
    var expr_result = try interp.evalExpression(value);
    defer expr_result.release();
    var det: ErrorDetails = undefined;
    return try interp.wrapError(&det, objects.Boolean.getFromValue(&det, expr_result));
}

pub fn evalSubstitution(interp: *Interp, value: Value, flags: Tokenizer.SubstFlags) !Value {
    var cache_key: u256 = try value.getHashNoRegister();
    // Combine the signature's cache id with the expression's content hash, so
    // identical expressions at different call sites get their own cached
    // variable lookups.
    cache_key ^= @as(u256, interp.callFrame().signature.cache_id);
    // Also make sure to include the flags in the cache id.
    cache_key ^= @as(u256, @as(u3, @bitCast(flags))) << @sizeOf(@TypeOf(interp.callFrame().signature.cache_id));

    const subst: *Substitution = try interp.getSubstitution(value, cache_key, flags);
    assert(subst.flags == flags); // Integrity check.

    return try interp.interpolateTokens(subst.tags, subst.values, 0, @intCast(subst.tags.len));
}

pub fn setErrorStack(interp: *Interp) error{OutOfMemory}!void {
    if (interp.stack_trace.isSome()) return;
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
        const file_name = if (source_info) |info| info.file_name.orEmpty() else heap.interned_empty_string;
        const base_line = if (source_info) |info| info.line_no else null;

        const base = if (base_line) |val| val else 1;
        const absolute_line = base + eval_frame.current_line;

        const args_list = try List.newWithCapacity(&.{}, eval_frame.args.len);
        defer args_list.asHead().release();

        for (eval_frame.args) |arg| args_list.appendAssumeCapacity(arg.original);

        trace.appendAssumeCapacity(closure_name);
        trace.appendAssumeCapacity(file_name);
        trace.appendAssumeCapacity(objects.Integer.new(absolute_line));
        trace.appendAssumeCapacity(args_list.asHead().asValue());
    }

    return trace.asHead().asValue();
}

/// Self will be returned borrowed. Caller is responsible for decrementing the ref count.
fn getCommandAndSelfParam(interp: *Interp, args: []Shimmerable) !struct { command: ?CommandOrClosure, self: OptionalValue } {
    var command = interp.getCommand(interp.callFrameIdx(), &args[0], true) catch |err| switch (err) {
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
    errdefer command.deinit();

    const is_method = switch (command) {
        .closure => |closure| closure.closure.content.is_method,
        .command => false,
    };
    if (is_method) {
        // `interp.getCommand` already made sure `args[0]` is a variable, so we can just
        // check if it's .dict_sugar.
        const method_dict_path = &args[0];
        const dict_sugar = method_dict_path.current().asType(vartypes.DictSugar) orelse {
            try interp.setResultFormatted("method \"{s}\" cannot be invoked as function", .{try method_dict_path.current().getString()});
            return error.EvalError;
        };

        // Next, we need to find `self`, the second-to-last part of the dict path. For example, calling
        // foo::bar would have foo as `self`, or foo::bar::baz would have foo::bar as `self`.
        var dict_name_shim: Shimmerable = .{ .original = dict_sugar.dict_name };
        defer dict_name_shim.discardChanges();
        const dict_resolved = vartypes.getVariable(
            interp,
            null,
            interp.callFrameIdx(),
            &dict_name_shim,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // This should always succeed, since when `interp.getCommand` was run earlier,
            // it ensured that the dict sugar resolved to something.
            else => unreachable,
        };

        // We modify the dictionary at the end of the path.
        const all_but_last = dict_sugar.dict_path.items[0..(dict_sugar.dict_path.items.len - 1)];
        const method_ctx = objects.ValueSliceContext{ .items = all_but_last };

        var dict_shim: Shimmerable = .{ .original = dict_resolved.? };
        defer dict_shim.discardChanges();
        var det: ErrorDetails = undefined;
        const maybe_self: OptionalValue = try interp.wrapError(&det, Dictionary.getRecursively(&det, &dict_shim, method_ctx));
        if (dict_shim.shimmered.asValue()) |new_dict| {
            var dict_name: Shimmerable = .{ .original = dict_sugar.dict_name };
            defer dict_name.discardChanges();
            try interp.wrapError(&det, vartypes.setVariable(interp, &det, interp.callFrameIdx(), &dict_name, new_dict));
        }

        if (maybe_self.asValue()) |self| {
            return .{ .command = command, .self = self.borrow().asOptional() };
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
    var command: CommandOrClosure = cmd_and_self.command orelse {
        // [unknown] was invoked and terminated normally, so there's nothing else to do.
        return;
    };
    defer command.deinit();
    const maybe_self = cmd_and_self.self;

    // If the command ended up being a method, we move the command name to the
    // left, which opens up a hole for putting the `self` argument in.
    if (maybe_self.asValue()) |self| {
        args_raw[0] = args_raw[1]; // Move command name to the left.
        args_raw[1] = .{ .original = self };
        args = args_raw[0..]; // Include all the allocated args now.
    }

    // Now that we've populated the arguments for this command, we'll go ahead and run it.
    try interp.invokeCommand(&command, args);

    if (maybe_self.asValue()) |_| {
        // Be sure to write back `self`.

        const call_frame = interp.callFrameIdx();
        const method_dict_path = &args[0];
        // `self` is returned back through `args[1]`.
        const new_self = &args[1];
        assert(new_self.shimmered.isSome());

        // Make sure `method_dict_path` is still .dict_sugar, as it technically could have shimmered.
        var det: ErrorDetails = undefined;
        try method_dict_path.ensureShimmerable();

        const ensure_result = try interp.wrapError(
            &det,
            vartypes.ensureValidVariableType(interp, &det, call_frame, method_dict_path),
        );
        const as_dict_sugar = blk: {
            switch (ensure_result) {
                .not_found => {
                    const args_list = try command.closure.closure.content.arg_names.get();
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

        const dict_resolved = try interp.wrapError(&det, vartypes.getVariableOrError(interp, &det, call_frame, &dict_name));

        if (as_dict_sugar.dict_path.items.len == 1) {
            try interp.wrapError(&det, vartypes.setVariable(interp, &det, call_frame, &dict_name, new_self.current()));
        } else {
            const all_but_last = as_dict_sugar.dict_path.items[0..(as_dict_sugar.dict_path.items.len - 1)];
            const put_ctx = objects.ValueSliceContext{ .items = all_but_last };

            const duplicate = if (dict_resolved.canMutate()) null else try dict_resolved.duplicate();
            defer if (duplicate) |dup| dup.release();
            const to_use = duplicate orelse dict_resolved;

            var dict_resolved_shim: Shimmerable = .{ .original = to_use };
            _ = try interp.wrapError(&det, Dictionary.shimmerFrom(&det, &dict_resolved_shim));
            assert(dict_resolved_shim.shimmered.isNone());
            const as_mutable = dict_resolved_shim.current().asType(Dictionary).?;
            try interp.wrapError(&det, as_mutable.putRecursively(&det, put_ctx, new_self.current()));

            if (duplicate) |dup| {
                try interp.wrapError(&det, vartypes.setVariable(interp, &det, call_frame, &dict_name, dup));
            }
        }
    }
}

fn evalCommand(interp: *Interp, call_frame: u32, script: Value, parsed: *const evaltypes.Script, command_token_i: *usize) !void {
    _ = try interp.pushEvalFrame(call_frame, script);
    defer interp.popEvalFrame();

    // Registered before any other defer so it runs last, after `args_raw` (which
    // itself lives in the arena) has been deinited. Covers straight-line scripts,
    // where `evalObjectInner`'s reset would not fire until the script ended.
    const arena_snapshot = heap.local_arena_instance.snapshot();
    defer heap.local_arena_instance.rewind(arena_snapshot);

    const tags = parsed.tags;

    // First token of the command is always .parsed_script_command.
    const command_info = parsed.values[command_token_i.*].asType(evaltypes.ParsedScriptCommand).?;
    command_token_i.* += 1; // Skip .parsed_script_command.
    interp.evalFrame().current_line = command_info.line;

    // `args_raw` has one extra space at the beginning that can be used to store the
    // `self` param if needed later on. We don't do the shifting in this function though.
    var args_raw = try heap.local_arena.alloc(Shimmerable, command_info.word_count + 1);
    // Contains what is considered to be the current arguments.
    var args = args_raw[1..];
    args_raw[0] = .{ .original = heap.interned_empty_string };

    {
        // This is not always the same as which word token we're on, as argument expansion
        // may write multiple arguments from one word.
        var args_written: usize = 0;
        errdefer for (args[0..args_written]) |*arg| arg.deinit();

        // Populate the arguments by looping through each word of the command and
        // substituting.
        var word_token_i: usize = command_token_i.*;
        // We don't know the length of each word, but we know there's `word_count` words,
        // so we advance `word_count` times.
        for (0..command_info.word_count) |_| {
            var word_parts: usize = 1;
            const argument_expansion = tags[word_token_i] == .argument_expansion;
            if (tags[word_token_i] == .start_of_word or argument_expansion) {
                word_parts = @intCast(objects.Integer.asInt(parsed.values[word_token_i]).?);
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
                // `getListInPlace` can fail, so we put the `defer` here.
                defer resultant_word.release();

                // Argument expansion, so we'll need to shimmer the result to a list.
                const as_list = try interp.getListInPlace(&resultant_word);
                const expansion_len = as_list.items.len;

                if (expansion_len != 1) {
                    // Expanded into multiple tokens, so we'll need to resize args.
                    // Note: len == 0 means the word disappears, so we shrink by 1.
                    args_raw = try heap.local_arena.realloc(args_raw, args_raw.len + expansion_len - 1);
                    args = args_raw[1..];
                }

                for (0..expansion_len) |list_idx| {
                    args[args_written] = .{ .original = as_list.items[list_idx].borrow() };
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

pub fn evalObjectInner(interp: *Interp, call_frame: u32, script: Value, cache_key: u256) heap.EvalError!void {
    // A loop evaluates its body through here once per iteration, which is what
    // keeps an iterating script from accumulating. Nesting is safe, since an
    // inner evaluation snapshots at a higher watermark than an outer one.
    const arena_snapshot = heap.local_arena_instance.snapshot();
    defer heap.local_arena_instance.rewind(arena_snapshot);

    // Try to get the script, parsing if necessary.
    const parsed = (try interp.getScript(script, cache_key));
    defer parsed.asHead().release(); // `parsed` was borrowed by `getScript`.

    // Don't evaluate empty scripts.
    if (parsed.tags.len <= 1) return;

    // Reset the interpreter result. This is useful to return the empty result in the case of empty program.
    interp.setEmptyResult();

    // TODO implement JIM_OPTIMIZATION speedups

    // Execute every command sequentially until the end of the script or an error occurs.
    var command_token_i: usize = 0;

    // Loop through the script's commands.
    while (command_token_i < parsed.tags.len) {
        const token_i_at_start = command_token_i;

        const command_result = interp.evalCommand(call_frame, script, parsed, &command_token_i);

        // TODO actually check for signals.
        if (false) {
            return error.Signal;
        } else {
            command_result catch |err| switch (err) {
                // `-level` counts closure calls, not script evaluations, so this
                // just carries the result outward. `callClosure` is what consumes
                // a level; see the comment there.
                error.PropagateResult => return error.PropagateResult,
                else => |narrowed_err| {
                    if (narrowed_err == error.OutOfMemory) {
                        // In the case of OOM, the inside function almost certainly failed
                        // to set a result, so we set it here.
                        interp.setResult(interned_oom);
                        interp.pending_error_code.swap(interned_zicl_oom);
                    }

                    if (narrowed_err == error.EvalError) {
                        if (interp.stack_trace.isNone()) {
                            // Something went wrong when initializing the eval frame,
                            // so we'll set up a dummy frame, so there's at least a
                            // line number and file name.
                            const frame = try interp.pushEvalFrame(call_frame, script);
                            defer interp.popEvalFrame();

                            const command_info = parsed.values[token_i_at_start].asType(evaltypes.ParsedScriptCommand).?;

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

/// Evaluate a script entered from outside the interpreter, such as a file or an
/// embedder call. A `[return]` reaching this boundary has no closure left to
/// return from, so it ends the script and keeps its result instead of escaping
/// as an error. This is the only place a leftover level is discarded.
pub fn evalTopLevel(interp: *Interp, script: Value) heap.EvalError!void {
    interp.evalValue(script) catch |err| switch (err) {
        error.PropagateResult => interp.return_propagate = .{},
        else => return err,
    };
}

pub fn evalValue(interp: *Interp, script: Value) heap.EvalError!void {
    // Reset the stack trace at each new top-level invocation.
    interp.stack_trace.swapWithNone();
    const cache_key = @as(u256, interp.callFrame().signature.cache_id) ^ try script.getHashNoRegister();
    return evalObjectInner(interp, interp.callFrameIdx(), script, cache_key);
}

pub fn evalFile(interp: *Interp, filename: []const u8) heap.EvalError!void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        heap.global_io,
        filename,
        heap.global_gpa,
        .unlimited,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try interp.setResultFormatted("couldn't read file \"{s}\": {}", .{ filename, err });
            return;
        },
    };
    defer heap.global_gpa.free(bytes);

    const filename_value = try objects.String.newValue(filename);
    defer filename_value.release();
    const source = try objects.Source.new(bytes, filename_value.asOptional(), 1);
    defer source.asHead().release();

    try interp.evalTopLevel(source.asHead().asValue());
}

pub fn init(cfg: struct { cache_capacity: u32 = 512 }) !Interp {
    const unknown_str = try objects.String.newValue("unknown");
    errdefer unknown_str.release();

    var new_interp: Interp = .{
        .result = heap.interned_empty_string,
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
        // Caches are initialized below.
        .parsed_scripts = undefined,
        .parsed_exprs = undefined,
        .parsed_closures = undefined,
        .parsed_substs = undefined,
    };
    new_interp.parsed_scripts = try ParsedScripts.initWithCapacity(heap.global_gpa, cfg.cache_capacity);
    errdefer new_interp.parsed_scripts.deinit(heap.global_gpa);
    new_interp.parsed_exprs = try ParsedExpressions.initWithCapacity(heap.global_gpa, cfg.cache_capacity);
    errdefer new_interp.parsed_exprs.deinit(heap.global_gpa);
    new_interp.parsed_closures = try ParsedClosures.initWithCapacity(heap.global_gpa, cfg.cache_capacity);
    errdefer new_interp.parsed_closures.deinit(heap.global_gpa);
    new_interp.parsed_substs = try ParsedSubstitutions.initWithCapacity(heap.global_gpa, cfg.cache_capacity);
    errdefer new_interp.parsed_substs.deinit(heap.global_gpa);

    var arg_names: objects.AlwaysCanBeType(List) = .initOwning(try objects.List.new(&.{}));
    defer arg_names.deinit();
    // Push root call frame.
    _ = try new_interp.pushCallFrame(&.{}, &.{
        .arg_names = arg_names,
        .optional_values = null,
        .required_arity = 0,
        .optional_arity = 0,
        .body = heap.interned_empty_string,
        .name = .none,
        .scope_hash_ref = null,
        .has_args_parameter = false,
        .is_method = false,
        .cache_id = Closure.closure_cache_id.fetchAdd(1, .monotonic),
    });
    errdefer new_interp.call_frames.deinit(heap.global_gpa);
    errdefer new_interp.call_frames.items[0].deinit(); // Deinit root call frame on error.

    _ = try new_interp.eval_frames.append(heap.global_gpa, .{
        .args = &.{},
        .call_frame = 0,
        .current_line = 0,
        .currently_evaluating = heap.interned_empty_string,
    });
    errdefer new_interp.eval_frames.deinit(heap.global_gpa);

    return new_interp;
}

pub fn deinit(interp: *Interp) void {
    interp.result.release();
    interp.stack_trace.swapWithNone();
    interp.pending_error_code.swapWithNone();
    interp.pending_error_during.swapWithNone();
    interp.unknown_str.release();
    interp.global_commands.deinit(heap.global_gpa);

    // Deinit all frames.

    for (interp.call_frames.items) |*frame| frame.deinit();
    interp.call_frames.deinit(heap.global_gpa);
    interp.eval_frames.deinit(heap.global_gpa);

    // Clean up caches as well.
    var scripts = interp.parsed_scripts.valueIterator();
    while (scripts.next()) |script| script.*.asHead().release();
    interp.parsed_scripts.deinit(heap.global_gpa);

    var exprs = interp.parsed_exprs.valueIterator();
    while (exprs.next()) |expr| expr.*.asHead().release();
    interp.parsed_exprs.deinit(heap.global_gpa);

    var closures = interp.parsed_closures.valueIterator();
    while (closures.next()) |closure| closure.*.asHead().deinit();
    interp.parsed_closures.deinit(heap.global_gpa);

    var substs = interp.parsed_substs.valueIterator();
    while (substs.next()) |subst| subst.*.asHead().release();
    interp.parsed_substs.deinit(heap.global_gpa);
}

// Export various utility functions with a nicer interface.
pub fn integerOverflowError(interp: *Interp, IntType: type, rendered_int: IntType) error{ OutOfMemory, EvalError } {
    var det: ErrorDetails = undefined;
    return interp.wrapError(&det, objects.Integer.overflowError(IntType, &det, rendered_int));
}

pub fn wrapShimmerFn(
    interp: *Interp,
    ReturnType: type,
    wb: *Shimmerable,
    to_call: fn (?*ErrorDetails, *Shimmerable) anyerror!ReturnType,
) !ReturnType {
    var det: ErrorDetails = undefined;
    return try wrapError(interp, &det, to_call(&det, wb));
}

pub fn wrapShimmerInPlaceFn(
    interp: *Interp,
    ReturnType: type,
    ref: *Value,
    to_call: fn (?*ErrorDetails, *Shimmerable) anyerror!ReturnType,
) !ReturnType {
    var ref_wb: Shimmerable = .{ .original = ref.* };
    var det: ErrorDetails = undefined;
    const result = try wrapError(interp, &det, to_call(&det, &ref_wb));
    ref.* = ref_wb.consume();
    return result;
}

pub fn getInteger(interp: *Interp, shim: *Shimmerable) !i64 {
    return try interp.wrapShimmerFn(i64, shim, objects.Integer.shimmerFrom);
}

pub fn getIntegerInPlace(interp: *Interp, ref: *Value) !i64 {
    return try interp.wrapShimmerInPlaceFn(i64, ref, objects.Integer.shimmerFrom);
}

pub fn getFloat(interp: *Interp, shim: *Shimmerable) !f64 {
    return try interp.wrapShimmerFn(f64, shim, objects.Float.get);
}

pub fn getIntOrFloatInPlace(interp: *Interp, ref: *Value) !objects.Number {
    var ref_shim: Shimmerable = .{ .original = ref.* };
    var det: objects.ErrorDetails = undefined;
    const result = interp.wrapError(&det, objects.Number.getAsIntOrFloat(&det, &ref_shim));
    ref.* = ref_shim.consume();
    return result;
}

pub fn getBoolean(interp: *Interp, shim: *Shimmerable) !bool {
    return try interp.wrapShimmerFn(bool, shim, objects.Boolean.shimmerFrom);
}

pub fn getBooleanInPlace(interp: *Interp, ref: *Value) !bool {
    return try interp.wrapShimmerInPlaceFn(bool, ref, objects.Boolean.shimmerFrom);
}

pub fn getIndex(interp: *Interp, shim: *Shimmerable) !objects.Index {
    return try interp.wrapShimmerFn(objects.Index, shim, objects.Index.get);
}

pub fn resolveHash(interp: *Interp, shim: *Shimmerable) !*const objects.HashReference {
    return try interp.wrapShimmerFn(*const objects.HashReference, shim, objects.HashReference.shimmerFrom);
}

pub fn getList(interp: *Interp, shim: *Shimmerable) !*const List {
    return try interp.wrapShimmerFn(*const List, shim, List.shimmerFrom);
}

pub fn getListInPlace(interp: *Interp, ref: *Value) !*const List {
    return try interp.wrapShimmerInPlaceFn(*const List, ref, List.shimmerFrom);
}

pub fn getDict(interp: *Interp, shim: *Shimmerable) !*const Dictionary {
    return try interp.wrapShimmerFn(*const Dictionary, shim, Dictionary.shimmerFrom);
}

pub fn getDictInPlace(interp: *Interp, ref: *Value) !*const Dictionary {
    return try interp.wrapShimmerInPlaceFn(*const Dictionary, ref, Dictionary.shimmerFrom);
}

pub fn setVariableInFrame(interp: *Interp, call_frame_idx: u32, name: *Shimmerable, value: Value) !void {
    var det: ErrorDetails = undefined;
    try interp.wrapError(&det, vartypes.setVariable(interp, &det, call_frame_idx, name, value));
}

pub fn setVariable(interp: *Interp, name: *Shimmerable, value: Value) !void {
    try interp.setVariableInFrame(interp.callFrameIdx(), name, value);
}

pub fn setVariableSilent(interp: *Interp, name: *Shimmerable, value: Value) !void {
    try vartypes.setVariable(interp, null, interp.callFrameIdx(), name, value);
}

pub fn setVariableUpvar(
    interp: *Interp,
    name: *Shimmerable,
    target_call_frame_idx: u32,
    target_name: Value,
) !void {
    var det: ErrorDetails = undefined;
    return try interp.wrapError(&det, vartypes.setVariableUpvar(
        interp,
        &det,
        interp.callFrameIdx(),
        name,
        target_call_frame_idx,
        target_name,
    ));
}

pub fn getVariable(interp: *Interp, name: *Shimmerable) !OptionalValue {
    var det: ErrorDetails = undefined;
    const value = interp.wrapError(&det, vartypes.getVariable(interp, &det, interp.callFrameIdx(), name)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try interp.setResultStringOwning(det.message);
            return error.EvalError;
        },
    };
    return OptionalValue.fromValue(value);
}

pub fn getVariableInFrame(interp: *Interp, call_frame_idx: u32, name: *Shimmerable) !OptionalValue {
    var det: ErrorDetails = undefined;
    const value = interp.wrapError(&det, vartypes.getVariable(interp, &det, call_frame_idx, name)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try interp.setResultStringOwning(det.message);
            return error.EvalError;
        },
    };
    return OptionalValue.fromValue(value);
}

pub fn getVariableOrError(interp: *Interp, name: *Shimmerable) !Value {
    try name.ensureShimmerable();
    var det: ErrorDetails = undefined;
    return try interp.wrapError(&det, vartypes.getVariableOrError(interp, &det, interp.callFrameIdx(), name));
}

pub fn unsetVariable(interp: *Interp, name: *Shimmerable) !void {
    try name.ensureShimmerable();
    var det: ErrorDetails = undefined;
    try interp.wrapError(&det, vartypes.unsetVariable(interp, &det, interp.callFrameIdx(), name));
}

pub fn unsetVariableSilent(interp: *Interp, name: *Shimmerable) !void {
    try name.ensureShimmerable();
    try vartypes.unsetVariable(interp, null, interp.callFrameIdx(), name);
}

pub fn getDictValue(interp: *Interp, dict: *Shimmerable, key: Value) heap.Error!?Value {
    var det: ErrorDetails = undefined;
    const opt = try interp.wrapError(&det, objects.Dictionary.getFollowingLinks(&det, dict, key));
    return opt.asValue();
}

pub fn getDictValueOrError(interp: *Interp, dict: *Shimmerable, key: Value) heap.Error!Value {
    const result = try interp.getDictValue(dict, key);
    if (result) |val| return val;

    try interp.setResultFormatted("could not find value for key \"{s}\"", .{try key.getString()});
    return error.EvalError;
}

pub fn getDictValueInPlace(interp: *Interp, dict: *Value, key: Value) !?Value {
    var dict_shim: Shimmerable = .{ .original = dict.* };
    errdefer dict_shim.discardChanges();
    const result = try interp.getDictValue(&dict_shim, key);
    dict.* = dict_shim.consume();
    return result;
}

pub fn getDictValueRecursively(interp: *Interp, shim: *Shimmerable, context: anytype) heap.Error!OptionalValue {
    var det: ErrorDetails = undefined;
    return try interp.wrapError(&det, objects.Dictionary.getRecursively(&det, shim, context));
}

pub fn getDictValueRecursivelyOrError(interp: *Interp, shim: *Shimmerable, context: anytype) heap.Error!Value {
    const result = try interp.getDictValueRecursively(shim, context);
    if (result.asValue()) |val| return val;

    // Else, create a useful error message.
    if (context.len() == 1) {
        try interp.setResultFormatted("could not find value for key \"{s}\"", .{try context.get(0).getString()});
    } else {
        // Create a list containing all the keys, so we can render the error message.
        const keys_list = try objects.List.newWithCapacity(&.{}, @intCast(context.len()));
        defer keys_list.asHead().release();
        for (0..context.len()) |i| keys_list.appendAssumeCapacity(context.get(i));

        try interp.setResultFormatted("could not find value for keys \"{s}\"", .{try keys_list.asHead().asValue().getString()});
    }

    return error.EvalError;
}

pub fn putDictValueRecursively(interp: *Interp, dict: *Dictionary, context: anytype, value: Value) heap.Error!void {
    var det: ErrorDetails = undefined;
    try interp.wrapError(&det, dict.putRecursively(&det, context, value));
}

/// Returns whether the value was removed.
pub fn removeDictValue(interp: *Interp, dict: *Dictionary, key: Value) !bool {
    var det: ErrorDetails = undefined;
    return try interp.wrapError(&det, dict.remove(&det, key));
}

pub fn removeDictValueRecursively(interp: *Interp, dict: *Dictionary, context: anytype) heap.Error!bool {
    var det: ErrorDetails = undefined;
    return try interp.wrapError(&det, dict.removeRecursively(&det, context));
}

test "recursive dict keys" {
    try heap.testStart(testing.allocator, testing.io);
    defer heap.testFinish();
    var interp = try Interp.init(.{});
    defer interp.deinit();

    var dict = try objects.Dictionary.new(&.{});
    defer dict.asHead().release();
    var key_foo = try objects.String.newValue("foo");
    defer key_foo.release();
    var key_bar = try objects.String.newValue("bar");
    defer key_bar.release();
    var key_baz = try objects.String.newValue("baz");
    defer key_baz.release();
    const value_qux = try objects.String.newValue("qux");
    defer value_qux.release();

    try interp.putDictValueRecursively(
        dict,
        objects.ValueSliceContext{ .items = &.{ key_foo, key_bar, key_baz } },
        value_qux,
    );
    try testing.expectEqualStrings("foo {bar {baz qux}}", try dict.asHead().getString());

    // `getDictValueRecursively` takes a *Shimmerable, so wrap `dict` in a
    // read-only view. Pure gets never shimmer the top level, so `discardChanges`
    // is a no-op here and `dict` keeps sole ownership.
    var dict_shim: Shimmerable = .{ .original = dict.asHead().asValue() };
    defer dict_shim.discardChanges();

    // Try taking ownership of one of the intermediate dictionaries.
    const to_take = (try interp.getDictValueRecursively(
        &dict_shim,
        objects.ValueSliceContext{ .items = &.{ key_foo, key_bar } },
    )).asValue().?;

    // See if setting still works correctly.
    try interp.putDictValueRecursively(
        dict,
        objects.ValueSliceContext{ .items = &.{ key_foo, key_bar, key_baz } },
        value_qux,
    );
    try testing.expectEqual(@as(u32, 1), to_take.asPtr().?.getRefCount());

    // Let's try some very cursed aliasing.
    try interp.putDictValueRecursively(dict, objects.ValueSliceContext{ .items = &.{ key_foo, key_bar } }, dict.items[0]);
    try testing.expectEqualStrings("foo {bar foo}", try dict.asHead().getString());

    const value_result = (try interp.getDictValueRecursively(
        &dict_shim,
        objects.ValueSliceContext{ .items = &.{ key_foo, key_bar } },
    )).asValue().?;
    try testing.expectEqualStrings("foo", try value_result.getString());
}

fn testRecursiveDictRemoval(ta: std.mem.Allocator) !void {
    try heap.testStart(ta, testing.io);
    defer heap.testFinish();
    var interp = try Interp.init(.{});
    defer interp.deinit();

    var dict = try objects.Dictionary.new(&.{});
    defer dict.asHead().release();
    var key_foo = try objects.String.newValue("foo");
    defer key_foo.release();
    var key_bar = try objects.String.newValue("bar");
    defer key_bar.release();
    var key_baz = try objects.String.newValue("baz");
    defer key_baz.release();
    const value_qux = try objects.String.newValue("qux");
    defer value_qux.release();

    // Test 1: Remove a deeply nested value (3 levels).
    try interp.putDictValueRecursively(
        dict,
        objects.ValueSliceContext{ .items = &.{ key_foo, key_bar, key_baz } },
        value_qux,
    );

    try testing.expectEqualStrings("foo {bar {baz qux}}", try dict.asHead().getString());
    var did_remove = try interp.removeDictValueRecursively(
        dict,
        objects.ValueSliceContext{ .items = &.{ key_foo, key_bar, key_baz } },
    );
    try testing.expect(did_remove);
    try testing.expectEqualStrings("foo {bar {}}", try dict.asHead().getString());

    // Test 2: Try to remove the same key again (should return false).
    did_remove = try interp.removeDictValueRecursively(
        dict,
        objects.ValueSliceContext{ .items = &.{ key_foo, key_bar, key_baz } },
    );
    try testing.expect(!did_remove);
    try testing.expectEqualStrings("foo {bar {}}", try dict.asHead().getString());

    // Test 3: Remove a non-existent key from an existing intermediate dict.
    did_remove = try interp.removeDictValueRecursively(
        dict,
        objects.ValueSliceContext{ .items = &.{ key_foo, key_bar, key_foo } },
    );
    try testing.expect(!did_remove);
    try testing.expectEqualStrings("foo {bar {}}", try dict.asHead().getString());

    // Test 4: Remove from a non-existent intermediate dict.
    try memutil.expectErrorOrOom(
        error.EvalError,
        interp.removeDictValueRecursively(dict, objects.ValueSliceContext{ .items = &.{ key_bar, key_baz, key_foo } }),
    );
    try testing.expectEqualStrings(
        \\key "bar" not known in dictionary "foo {bar {}}"
    , try interp.result.getString());
    try testing.expectEqualStrings("foo {bar {}}", try dict.asHead().getString());

    // Test 5: Single-level removal (base case).
    did_remove = try interp.removeDictValueRecursively(dict, objects.ValueSliceContext{ .items = &.{key_foo} });
    try testing.expect(did_remove);
    try testing.expectEqualStrings("", try dict.asHead().getString());

    // Test 6: Two-level removal.
    try interp.putDictValueRecursively(
        dict,
        objects.ValueSliceContext{ .items = &.{ key_foo, key_bar } },
        value_qux,
    );
    try testing.expectEqualStrings("foo {bar qux}", try dict.asHead().getString());
    did_remove = try interp.removeDictValueRecursively(dict, objects.ValueSliceContext{ .items = &.{ key_foo, key_bar } });
    try testing.expect(did_remove);
    try testing.expectEqualStrings("foo {}", try dict.asHead().getString());

    // Test 7: Removal when intermediate dict is shared (copy-on-write).
    var interm_test_dict = try objects.Dictionary.new(&.{});
    defer interm_test_dict.asHead().release();
    try interp.putDictValueRecursively(
        interm_test_dict,
        objects.ValueSliceContext{ .items = &.{ key_foo, key_bar, key_baz } },
        value_qux,
    );
    try interp.putDictValueRecursively(
        interm_test_dict,
        objects.ValueSliceContext{ .items = &.{ key_foo, key_bar, key_foo } },
        value_qux,
    );

    // Read-only view for the get calls below.
    var interm_shim: Shimmerable = .{ .original = interm_test_dict.asHead().asValue() };
    defer interm_shim.discardChanges();

    // Borrow the intermediate dict.
    const intermediate = (try interp.getDictValueRecursively(
        &interm_shim,
        objects.ValueSliceContext{ .items = &.{ key_foo, key_bar } },
    )).asValue().?;
    intermediate.asPtr().?.incrRefCount();
    defer intermediate.release();

    const initial_refcount = intermediate.asPtr().?.getRefCount();
    try testing.expectEqualStrings("baz qux foo qux", try intermediate.getString());

    // Remove from the nested dict while it's owned elsewhere.
    did_remove = try interp.removeDictValueRecursively(
        interm_test_dict,
        objects.ValueSliceContext{ .items = &.{ key_foo, key_bar, key_baz } },
    );
    try testing.expect(did_remove);

    // The intermediate dict we own should be unchanged (copy-on-write).
    try testing.expectEqualStrings("baz qux foo qux", try intermediate.getString());
    // But the main dict should have a new copy without 'baz'.
    const foo_bar_result = (try interp.getDictValueRecursively(
        &interm_shim,
        objects.ValueSliceContext{ .items = &.{ key_foo, key_bar } },
    )).asValue().?;
    try testing.expectEqualStrings("foo qux", try foo_bar_result.getString());
    // Reference count should drop by 1 since the parent no longer references it.
    try testing.expectEqual(initial_refcount - 1, intermediate.asPtr().?.getRefCount());

    // Test 8: Remove multiple items from a nested dict.
    var dict_multiple_items = try objects.Dictionary.new(&.{});
    defer dict_multiple_items.asHead().release();
    try interp.putDictValueRecursively(dict_multiple_items, objects.ValueSliceContext{ .items = &.{ key_foo, key_bar } }, value_qux);
    try interp.putDictValueRecursively(dict_multiple_items, objects.ValueSliceContext{ .items = &.{ key_foo, key_baz } }, value_qux);
    try testing.expectEqualStrings("foo {bar qux baz qux}", try dict_multiple_items.asHead().getString());
    did_remove = try interp.removeDictValueRecursively(dict_multiple_items, objects.ValueSliceContext{ .items = &.{ key_foo, key_bar } });
    try testing.expect(did_remove);
    try testing.expectEqualStrings("foo {baz qux}", try dict_multiple_items.asHead().getString());
    did_remove = try interp.removeDictValueRecursively(dict_multiple_items, objects.ValueSliceContext{ .items = &.{ key_foo, key_baz } });
    try testing.expect(did_remove);
    try testing.expectEqualStrings("foo {}", try dict_multiple_items.asHead().getString());
}

test "recursive dict removal" {
    try memutil.checkAllocationFailures(.exhaustive, testRecursiveDictRemoval, .{});
}

pub fn testRunScript(interp: *Interp, script: []const u8) !Value {
    var script_handle = try objects.String.newValue(script);
    defer script_handle.release();
    try interp.evalTopLevel(script_handle);
    return interp.result;
}

pub fn testExpectScriptResult(interp: *Interp, expected: []const u8, script: []const u8) !void {
    const result = testRunScript(interp, script);
    if (result) |success| {
        try testing.expectEqualStrings(expected, try success.getString());
    } else |err| {
        // Need to propagate error.OutOfMemory for OOM stress testing.
        if (err == error.OutOfMemory) return error.OutOfMemory;

        ioutil.debug("Test failed with zig error {}", .{err});
        ioutil.debug(" and error message \"{s}\"\n", .{try interp.result.getString()});
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

// Maps signal numbers to their interned name string. Only includes signals
// available on the current platform.
const signal_name_map = blk: {
    const SIG = std.posix.SIG;
    const Entry = struct { num: u6, name: []const u8 };
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
            entries = entries ++ &[_]Entry{.{ .num = @field(SIG, pair[0]), .name = pair[0] }};
        }
    }
    break :blk entries;
};

/// Build a list of signal name strings for each signal bit set in `mask`.
pub fn signalMaskToList(mask: u64) !Value {
    const list = try objects.List.newWithCapacity(&.{}, @popCount(mask));
    errdefer list.asHead().release();
    inline for (signal_name_map) |entry| {
        if (mask & (@as(u64, 1) << entry.num) != 0) {
            list.appendAssumeCapacity(heap.InternedString.newValue(entry.name));
        }
    }
    return list.asHead().asValue();
}

pub fn nextRandomFloat(interp: *Interp) f64 {
    // https://stackoverflow.com/questions/46901022/how-to-convert-a-uint64-t-to-a-double-float-between-0-and-1-with-maximum-accurac
    const two63: u64 = 0x8000000000000000;
    const two64f = @as(f64, @bitCast(two63)) * 2.0;
    const as_float = @as(f64, @bitCast(interp.prng.next())) / two64f;
    return as_float;
}

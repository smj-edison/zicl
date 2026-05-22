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

pub var variables: Handle = undefined;

/// The result from a procedure or eval call
result: Handle,
global_commands: CommandHashTable,

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

fn resolveVariable(var_name: Handle) !?Handle {
    const in_local_variables = try objutil.dictLookupInner(variables, var_name);
    return in_local_variables.toHandle();
}

/// This always recalculates .variable. You probably should be using `ensureValidVariableType`.
/// Must be called with a heap-native variable name, so it can shimmer in place.
fn reshimmerToVariable(name: Handle) error{ OutOfMemory, VariableNotFound }!void {
    name.assert(name.canShimmer());

    if (try resolveVariable(name)) |local_var| {
        try name.prepareToShimmer();
        name.peek().head.tag = .cached_local_var;
        name.peek().body.cached_local_var = .{
            .call_epoch = undefined,
            .cached_index = local_var.index,
        };
    } else {
        return error.VariableNotFound;
    }
}

/// Ensures that this is a valid variable, dict sugar, or upvar. If not, it'll shimmer it to whichever one applies.
/// Must be called with a heap-native variable name.
fn ensureValidVariableType(name: Handle) error{ OutOfMemory, VariableNotFound }!void {
    assert(name.canShimmer());
    try Interp.reshimmerToVariable(name);
}

// Must be called with a heap-native variable name.
fn createVariable(name: Handle, value: Heap.Object) !void {
    name.assert(name.canShimmer());

    // Add variable.
    const put_result = try objutil.dictPutInner(variables, name, value);
    variables.swapIfNew(put_result.new_dict);

    try name.prepareToShimmer();
    name.peek().head.tag = .cached_local_var;
    name.peek().body.cached_local_var = .{
        .call_epoch = undefined,
        .cached_index = put_result.new_value.index,
    };
}

/// Must be called with a heap-native name. Always takes ownership of `value`, even in error cases.
pub fn setVariableInner(name: Handle, value: Heap.Object) error{ OutOfMemory, BadDict }!void {
    var value_taken = false;
    errdefer if (!value_taken) {
        var value_mut = value;
        value_mut.deinitSingle(Heap.local_heap);
    };

    name.assert(name.canShimmer());

    if (ensureValidVariableType(name)) {
        switch (name.tag()) {
            .cached_local_var => {
                const cached_var = &name.peek().body.cached_local_var;

                value_taken = true;
                const put_result = try objutil.dictPutInner(variables, name, value);
                if (put_result.new_dict.toHandle()) |new_dict| {
                    // Did the dict change locations? If so, all cached lookups are now invalid.
                    variables.swap(new_dict);
                }

                cached_var.* = .{
                    .call_epoch = undefined,
                    .cached_index = put_result.new_value.index,
                };
            },
            else => unreachable,
        }
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.VariableNotFound => {
            value_taken = true;
            try createVariable(name, value);
        },
    }
}

/// Resolves to the variable's value. Must be called with a heap-native name.
pub fn getVariableInner(
    interp: *Interp,
    call_frame_idx: u32,
    name: Handle,
) error{ OutOfMemory, VariableNotFound, BadDict }!Handle {
    try interp.ensureValidVariableType(call_frame_idx, name);

    const name_obj = name.peek();
    const name_heap = name.getHeap();

    switch (name.tag()) {
        .cached_local_var => {
            const resolved = name_heap.getHandle(name_obj.body.cached_local_var.cached_index);
            // The cached index points at the dict slot, which may
            // hold a reference to the actual value.
            return objutil.followIfRef(resolved);
        },
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

    call_info: union(enum) {
        zig: ZigCommand,
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

    try setVariableToObject(&var_name, var_value.referenceTakeOwnership());
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
pub fn parseClosureArgList(args: Handle) !ParsedArgList {
    const arg_list_len = objutil.listLengthRaw(args);

    // Pre-allocate for optional default values. arg_list_len is an upper bound.
    const optional_values: ?Handle = null;
    errdefer if (optional_values) |val| val.decrRefCount();
    var required_arity: u32 = 0;

    for (0..arg_list_len) |i| {
        const arg_raw = objutil.listItem(args, @intCast(i));
        var arg_new: OptionalHandle = .none;
        defer arg_new.swapWithNone();
        objutil.shimmerToList(arg_raw, &arg_new) catch unreachable;
        const arg = arg_new.orElse(arg_raw);
        const arg_len = objutil.listLengthRaw(arg);

        assert(arg_len == 1);

        required_arity += 1;
    }

    return .{
        .required_arity = required_arity,
        .optional_arity = 0,
        .optional_values = .none,
        .has_args_parameter = false,
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

/// Caller should release return value when they're done.
fn substituteOneToken(interp: *Interp, tag: Tokenizer.Token.Tag, value: Handle) !Handle {
    switch (tag) {
        .simple_string => {
            return value.borrow();
        },
        .variable_subst => {
            const var_target = interp.getVariableInner(interp.currentCallFrame().level, value) catch unreachable;
            return var_target.borrow();
        },
        else => unreachable,
    }
}

/// `name` must be from the threadlocal heap.
fn getCommandInner(interp: *Interp, call_frame: u32, name: Handle) !*NativeCommand {
    if (interp.getVariableInner(call_frame, name)) |var_val| {
        const bytes = try var_val.getString();
        assert(std.mem.eql(u8, bytes[0..9], "nativefn "));
        return interp.global_commands.getPtr(bytes[9..]) orelse unreachable;
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.VariableNotFound, error.BadDict => return error.CommandNotFound,
    }
}

pub fn getCommand(
    interp: *Interp,
    call_frame_idx: u32,
    provided_handle: Handle,
    new_handle: *OptionalHandle,
) !*NativeCommand {
    errdefer new_handle.swapWithNone();
    try Heap.ensureShimmerableOrDup(provided_handle, new_handle);

    return interp.getCommandInner(call_frame_idx, new_handle.orElse(provided_handle));
}

fn invokeCommand(interp: *Interp, call_frame_idx: u32, args: []Handle) !void {
    var new_command: OptionalHandle = .none;
    const command = interp.getCommand(call_frame_idx, args[0], &new_command) catch unreachable;
    args[0].swapIfNew(new_command);

    try interp.callNative(command, args);
}

pub fn evalObjectInner(interp: *Interp, script: Handle, cache_key: u256) EvalError!void {
    const parsed = objutil.getScript(script, cache_key) catch unreachable;

    _ = try interp.pushEvalFrame();
    defer interp.popEvalFrame();

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
        var args = try Heap.global_gpa.alloc(Handle, command_info.arg_count);
        defer for (args[0..args_written]) |arg| arg.decrRefCount();

        // Populate the arguments by looping through each word of the command and
        // substituting.
        var word_token_i: u32 = command_token_i;
        for (0..command_info.arg_count) |_| {
            const resultant_word = try interp.substituteOneToken(tags[word_token_i], objutil.listItem(parsed.values, word_token_i));
            word_token_i += 1;

            args[args_written] = resultant_word;
            args_written += 1;
        }

        command_token_i = word_token_i;

        // `args` is stored in the eval frame so `buildErrorStack` can read it if this command
        // fails. The slice is still live at that point (before the loop body `defer` frees it),
        // mirroring Jim's `evalFrame->argv` pattern.
        interp.currentEvalFrame().args = args[0..args_written];

        interp.invokeCommand(interp.currentCallFrameIndex(), args) catch unreachable;
    }
}

pub fn evalObject(interp: *Interp, script: Handle) EvalError!void {
    const cache_key = @as(u256, interp.currentCallFrame().signature.cache_id) ^ try script.getHash();
    return evalObjectInner(interp, script, cache_key);
}

pub fn init() !Interp {
    variables = try objutil.newDict(Heap.local_heap, &.{});

    return .{
        .result = Heap.local_heap.emptyHandle(),
        .global_commands = .empty,
    };
}

pub fn deinit(interp: *Interp) void {
    interp.result.decrRefCount();
    interp.global_commands.deinit(Heap.global_gpa);
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
pub fn shimmerToList(handle: *Handle) void {
    var new_handle: OptionalHandle = .none;
    objutil.shimmerToList(handle.*, &new_handle) catch unreachable;
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

pub fn setVariableToObject(name: *Handle, obj: Heap.Object) !void {
    var new_name: OptionalHandle = .none;
    try Heap.ensureShimmerableOrDup(name.*, &new_name);
    name.swapIfNew(new_name);
    try setVariableInner(name.*, obj);
}

pub fn setVariableTo(name: *Handle, handle: Handle) !void {
    var new_name: OptionalHandle = .none;
    try Heap.ensureShimmerableOrDup(name.*, &new_name);
    name.swapIfNew(new_name);

    const handle_to_obj = handle.dupOrRef();
    try setVariableInner(name.*, handle_to_obj);
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

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
var global_commands: std.StringArrayHashMapUnmanaged(NativeCommand) = .empty;

pub const CommandFn = fn (args: []Handle) Error!void;

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

fn resolveVariable(var_name: Handle) !?Handle {
    const in_local_variables = try objutil.dictLookupInner(variables, var_name);
    return in_local_variables.toHandle();
}

/// This always recalculates .variable. You probably should be using `ensureValidVariableType`.
/// Must be called with a heap-native variable name, so it can shimmer in place.
fn reshimmerToVariable(name: Handle) error{ OutOfMemory, VariableNotFound }!void {
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

    if (reshimmerToVariable(name)) {
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
pub fn registerCommand(name: []const u8, call_info: NativeCommand.ZigCommand) !void {
    try global_commands.put(Heap.global_gpa, name, .{
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

    var new_var_name: OptionalHandle = .none;
    try Heap.ensureShimmerableOrDup(var_name, &new_var_name);
    var_name.swapIfNew(new_var_name);
    try setVariableInner(var_name, var_value.referenceTakeOwnership());
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

pub fn init() !void {
    variables = try objutil.newDict(Heap.local_heap, &.{});
}

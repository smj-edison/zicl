const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const Heap = @import("Heap.zig");
const Handle = Heap.Handle;
const OptionalHandle = Heap.OptionalHandle;
const objutil = @import("objutil.zig");
const memutil = @import("memutil.zig");

const Interp = @This();

pub var variables: Handle = undefined;

fn resolveVariable(var_name: Handle) !?Handle {
    const in_local_variables = try objutil.dictLookup(variables, var_name);
    return in_local_variables.toHandle();
}

/// This always recalculates .variable.
fn shimmerToVariable(name: Handle) error{ OutOfMemory, VariableNotFound }!void {
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
    assert(name.canShimmer());

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

    if (shimmerToVariable(name)) {
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

/// `name` should be a static variable guaranteed to exist as long as the
/// interpreter exists.
pub fn registerCommand(name: []const u8) !void {
    var var_name = try objutil.newString(Heap.local_heap, name);
    defer var_name.decrRefCount();

    const var_name_escaped = try objutil.newList(&.{var_name});
    defer var_name_escaped.decrRefCount();

    const var_value = try objutil.newString(Heap.local_heap, name);
    try setVariableInner(var_name, var_value.referenceTakeOwnership());
}

pub fn init() !void {
    variables = try objutil.newDict(Heap.local_heap, &.{});
}

/// [fn]
pub fn fnCmd(args: []Handle) !void {
    assert(args.len == 4);
    const fn_name = &args[1];
    const arglist = &args[2];
    const body = args[3];

    // Capture the current scope.
    const scope = Interp.variables.borrow();

    // Create the closure
    const closure_handle = try Heap.local_heap.createObject();
    const extra_data = try Heap.local_heap.createExtraData();

    const closure: Heap.Closure = .{
        .args = arglist.*,
        .body = body,
        .name = fn_name.toOptional(),
        .scope = scope.toOptional(),
        .required_arity = 1,
        .cache_id = Heap.nextCacheId(),
    };
    Heap.local_heap.getExtraData(extra_data).* = .{ .closure = closure.borrow() };
    closure_handle.peek().head.tag = .closure;
    closure_handle.peek().body = .{ .closure = .{ .extra_data = extra_data } };

    Interp.setVariableInner(fn_name.*, closure_handle.dupOrRef()) catch unreachable;
}

test "fn command" {
    _ = try Heap.testStart(testing.allocator, testing.io);
    try init();
    try registerCommand("fn");

    const fn_str = try objutil.newString(Heap.local_heap, "fn");
    const add_str = try objutil.newString(Heap.local_heap, "add");
    const a_b_str = try objutil.newString(Heap.local_heap, "a b");
    const fn1_body_str = try objutil.newString(Heap.local_heap, " + $a $b ");
    var fn1_args: [4]Handle = .{ fn_str, add_str, a_b_str, fn1_body_str };

    fnCmd(&fn1_args) catch unreachable;

    const addx_str = try objutil.newString(Heap.local_heap, "add");
    const a_str = try objutil.newString(Heap.local_heap, "a b");
    const fn2_body_str = try objutil.newString(Heap.local_heap, " + $a $x ");
    var fn2_args: [4]Handle = .{ fn_str, addx_str, a_str, fn2_body_str };

    fnCmd(&fn2_args) catch unreachable;
}

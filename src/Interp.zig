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
    const put_result = try objutil.dictPut(variables, name, value);
    variables.swapIfNew(put_result.new_dict);

    try name.prepareToShimmer();
    name.peek().head.tag = .cached_local_var;
    name.peek().body.cached_local_var = .{
        .call_epoch = undefined,
        .cached_index = put_result.new_value.index,
    };
}

/// Must be called with a heap-native name. Always takes ownership of `value`, even in error cases.
pub fn setVariable(name: Handle, value: Heap.Object) error{ OutOfMemory, BadDict }!void {
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
                const put_result = try objutil.dictPut(variables, name, value);
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
    try setVariable(var_name, var_value.referenceTakeOwnership());
}

pub fn init() !void {
    variables = try objutil.newDict(Heap.local_heap, &.{});
}

test "fn command" {
    _ = try Heap.testStart(testing.allocator, testing.io);
    try init();
    try registerCommand("fn");

    const foo_str = try objutil.newString(Heap.local_heap, "foo");
    variables.incrRefCount();
    try setVariable(foo_str, (try Heap.local_heap.createObject()).reference());

    const bar_str = try objutil.newString(Heap.local_heap, "bar");
    variables.incrRefCount();
    try setVariable(bar_str, (try Heap.local_heap.createObject()).reference());
}

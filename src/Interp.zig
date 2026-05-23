const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const Heap = @import("Heap.zig");
const Handle = Heap.Handle;
const OptionalHandle = Heap.OptionalHandle;
const objutil = @import("objutil.zig");
const memutil = @import("memutil.zig");

const Interp = @This();

var variables: Handle = undefined;

/// This always recalculates .variable.
fn shimmerToVariable(name: Handle) error{ OutOfMemory, VariableNotFound }!void {
    const var_val = try objutil.dictLookup(variables, name);
    if (var_val.toHandle()) |local_var| {
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
                value_taken = true;
                _ = try objutil.dictPut(variables, name, value);
                unreachable;
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

test "fn command" {
    _ = try Heap.testStart(testing.allocator, testing.io);
    variables = try objutil.newDict(Heap.local_heap, &.{});

    const foo_str = try objutil.newString(Heap.local_heap, "foo");
    try setVariable(foo_str, (try Heap.local_heap.createObject()).reference());

    const bar_str = try objutil.newString(Heap.local_heap, "bar");
    variables.incrRefCount();
    try setVariable(bar_str, (try Heap.local_heap.createObject()).reference());

    const baz_str = try objutil.newString(Heap.local_heap, "baz");
    variables.incrRefCount();
    try setVariable(baz_str, (try Heap.local_heap.createObject()).reference());
}

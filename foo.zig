const std = @import("std");

pub const Tag = enum { foo, bar, baz };

test {
    var table: std.StringArrayHashMap(u32) = .init(std.testing.allocator);
    try table.put("key", 5);

    const value = table.getIndex("key").?;

    std.debug.print("Index: {}", .{value});
}

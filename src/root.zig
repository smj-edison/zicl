const std = @import("std");
const zicl = @import("zicl.zig");
const Parser = @import("Parser.zig");
const stringutil = @import("stringutil.zig");

pub fn main() !void {
    var alloc = std.heap.page_allocator;

    const to_escape = "\\x41";
    var to_write = alloc.alloc(u8, to_escape.len) catch @panic("");
    defer alloc.free(to_write);

    const len = stringutil.removeEscaping(to_escape, to_write);
    std.debug.print("Result: {s}", .{to_write[0..len]});
}

test {
    // @import("std").testing.refAllDecls(@This());
    _ = @import("stringutil.zig");
    _ = @import("Parser.zig");
    _ = @import("object.zig");
    _ = @import("Heap.zig");
    // _ = @import("Interp.zig");
}

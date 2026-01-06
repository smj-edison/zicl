const std = @import("std");
const zicl = @import("zicl.zig");
const Tokenizer = @import("Tokenizer.zig");
const Heap = @import("Heap.zig");
const stringutil = @import("stringutil.zig");

pub fn main() !void {
    var alloc = std.heap.page_allocator;

    const to_escape = "\\x41";
    var to_write = alloc.alloc(u8, to_escape.len) catch @panic("");
    defer alloc.free(to_write);

    const len = stringutil.removeEscaping(to_escape, to_write);
    std.debug.print("Result: {s}", .{to_write[0..len]});
}

pub const panic = std.debug.FullPanic(panicAndPrintTraces);
fn panicAndPrintTraces(msg: []const u8, first_trace_addr: ?usize) noreturn {
    Heap.dumpLastTouchedTrace();
    std.debug.defaultPanic(msg, first_trace_addr);
}

test {
    // @import("std").testing.refAllDecls(@This());
    _ = @import("stringutil.zig");
    _ = @import("Tokenizer.zig");
    _ = @import("object.zig");
    _ = @import("Heap.zig");
    _ = @import("Interp.zig");
    _ = @import("commands.zig");
    _ = @import("expr_parse.zig");
}

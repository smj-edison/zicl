const std = @import("std");
const ioutil = @import("ioutil.zig");
// const objutil = @import("objutil.zig");
// const Heap = @import("Heap.zig");
// const Interp = @import("Interp.zig");
// const commands = @import("commands.zig");
const heap = @import("heap.zig");
const objects = @import("objects.zig");

pub fn main(init: std.process.Init) !void {
    _ = init;
    @panic("main is not yet implemented for the new heap design");
}

pub const panic = std.debug.FullPanic(panicAndPrintTraces);
fn panicAndPrintTraces(msg: []const u8, first_trace_addr: ?usize) noreturn {
    // Heap.dumpLastTouchedTrace(-1);
    std.debug.defaultPanic(msg, first_trace_addr);
}

test {
    _ = @import("heap.zig");
    _ = @import("objects.zig");
    _ = @import("memutil.zig");
    _ = @import("strutil.zig");
    _ = @import("ioutil.zig");
    _ = @import("leak_check.zig");

    // _ = @import("Tokenizer.zig");
    // _ = @import("Interp.zig");
    // _ = @import("commands.zig");
    // _ = @import("expr_parse.zig");
    // _ = @import("regex.zig");

    // _ = @import("test/test_root.zig");
}

const std = @import("std");
const objutil = @import("objutil.zig");
const Heap = @import("Heap.zig");
const Interp = @import("Interp.zig");
const commands = @import("commands.zig");

pub fn main(init: std.process.Init) !void {
    defer Heap.deinitAll();
    try Heap.initGlobals(init.gpa, init.io);
    try Heap.initLocalHeap();
    var interp = try Interp.init();
    defer interp.deinit();
    try commands.registerCoreCommands(&interp);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init.io, &stdin_buffer);

    const stdout = &stdout_writer.interface;
    const stdin = &stdin_reader.interface;

    try stdout.writeAll("Welcome to Zicl!\n");

    var line_read = try std.ArrayList(u8).initCapacity(init.gpa, 1024);
    defer line_read.deinit(init.gpa);
    while (true) {
        try stdout.writeAll("> ");
        try stdout.flush();

        // Read the next line.
        while (true) {
            stdin.fillMore() catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                error.EndOfStream => {
                    try stdout.writeAll("\nGoodbye!\n");
                    try stdout.flush();
                    return;
                },
            };

            if (std.mem.indexOfScalarPos(u8, stdin.buffer[0..stdin.end], stdin.seek, '\n')) |end| {
                try line_read.appendSlice(init.gpa, stdin.buffer[stdin.seek..end]);
                stdin.toss(end - stdin.seek + 1);
                break;
            } else {
                try line_read.appendSlice(init.gpa, stdin.buffered());
                stdin.tossBuffered();
            }
        }

        const str_handle = try objutil.newString(line_read.items);
        defer str_handle.decrRefCount();
        interp.evalObject(str_handle) catch |err| {
            std.debug.print("Error code: {s}\n", .{@errorName(err)});
        };
        try stdout.writeAll(try interp.result.getString());
        try stdout.writeAll("\n");
        try stdout.flush();

        line_read.clearRetainingCapacity();
    }
}

pub const panic = std.debug.FullPanic(panicAndPrintTraces);
fn panicAndPrintTraces(msg: []const u8, first_trace_addr: ?usize) noreturn {
    Heap.dumpLastTouchedTrace(-1);
    std.debug.defaultPanic(msg, first_trace_addr);
}

test {
    _ = @import("Heap.zig");
    _ = @import("memutil.zig");
    _ = @import("stringutil.zig");
    _ = @import("objutil.zig");
    _ = @import("Tokenizer.zig");
    _ = @import("Interp.zig");
    _ = @import("commands.zig");
    _ = @import("expr_parse.zig");

    _ = @import("test/test_root.zig");
}

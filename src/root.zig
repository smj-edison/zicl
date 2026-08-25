const std = @import("std");
const ioutil = @import("ioutil.zig");
const Interp = @import("Interp.zig");
const heap = @import("heap.zig");
const objects = @import("objects.zig");
const common = @import("commands/common.zig");

pub fn main(init: std.process.Init) !void {
    try heap.initGlobals(init.gpa, init.io, .{});
    defer heap.deinitGlobals();
    try heap.initThread();
    defer heap.deinitThread();
    var interp = try Interp.init(.{});
    defer interp.deinit();
    try common.registerCoreCommands(&interp);

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

        // Read the next line. Check what is already buffered before reading
        // more, or piped input past the first line is dropped at EOF.
        while (true) {
            if (std.mem.indexOfScalarPos(u8, stdin.buffer[0..stdin.end], stdin.seek, '\n')) |end| {
                try line_read.appendSlice(init.gpa, stdin.buffer[stdin.seek..end]);
                stdin.toss(end - stdin.seek + 1);
                break;
            }

            try line_read.appendSlice(init.gpa, stdin.buffered());
            stdin.tossBuffered();

            stdin.fillMore() catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                error.EndOfStream => {
                    if (line_read.items.len > 0) break;
                    try stdout.writeAll("\nGoodbye!\n");
                    try stdout.flush();
                    return;
                },
            };
        }

        const str_handle = try objects.String.newValue(line_read.items);
        defer str_handle.dropReference();
        interp.evalValue(str_handle) catch |err| {
            ioutil.debug("Error code: {s}\n", .{@errorName(err)});
        };
        try stdout.writeAll(try interp.result.getString());
        try stdout.writeAll("\n");
        try stdout.flush();

        line_read.clearRetainingCapacity();
    }
}

pub const panic = std.debug.FullPanic(panicAndPrintTraces);
fn panicAndPrintTraces(msg: []const u8, first_trace_addr: ?usize) noreturn {
    heap.dumpLastTouchedTrace(-1);
    std.debug.defaultPanic(msg, first_trace_addr);
}

test {
    _ = @import("memutil.zig");
    _ = @import("strutil.zig");
    _ = @import("ioutil.zig");
    _ = @import("leak_check.zig");

    _ = @import("heap.zig");
    _ = @import("Tokenizer.zig");
    _ = @import("objects.zig");
    _ = @import("Capability.zig");
    _ = @import("capabilities.zig");
    _ = @import("Interp.zig");
    _ = @import("expr_parse.zig");
    _ = @import("regex.zig");

    _ = @import("commands/common.zig");
}

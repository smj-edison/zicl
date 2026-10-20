const std = @import("std");
const ioutil = @import("ioutil.zig");
const Interp = @import("Interp.zig");
const heap = @import("heap.zig");
const objects = @import("objects.zig");
const common = @import("commands/common.zig");

pub fn main(init: std.process.Init) !void {
    try heap.initGlobals(init.gpa, init.io, .{ .shared = init.environ_map }, .{});
    defer heap.deinitGlobals();
    try heap.initThread();
    defer heap.deinitThread();
    var interp = try Interp.init(.{});
    defer interp.deinit();
    try common.registerCoreCommands(&interp);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const args = init.minimal.args.vector;
    if (args.len > 1) {
        const first_arg = std.mem.span(args[1]);
        if (std.mem.eql(u8, first_arg, "-e")) {
            if (args.len < 3) {
                var stderr_buf: [256]u8 = undefined;
                var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buf);
                try stderr_writer.interface.writeAll("zicl: -e requires an argument\n");
                try stderr_writer.interface.flush();
                std.process.exit(1);
            }
            const code = std.mem.span(args[2]);
            const str_handle = try objects.String.newValue(code);
            defer str_handle.dropReference();
            interp.evalValue(str_handle) catch |err| {
                const res = interp.result.getString() catch @errorName(err);
                var stderr_buf: [1024]u8 = undefined;
                var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buf);
                try stderr_writer.interface.writeAll(res);
                try stderr_writer.interface.writeAll("\n");
                try stderr_writer.interface.flush();
                std.process.exit(1);
            };
            const res = try interp.result.getString();
            if (res.len > 0) {
                try stdout.writeAll(res);
                try stdout.writeAll("\n");
                try stdout.flush();
            }
            return;
        } else if (std.mem.eql(u8, first_arg, "-h") or std.mem.eql(u8, first_arg, "--help")) {
            try stdout.writeAll("Usage: zicl [file.tcl] [arg ...]\n       zicl -e 'script'\n");
            try stdout.flush();
            return;
        } else {
            const filename = first_arg;
            var argv0_name_shim: objects.Shimmerable = .{ .original = try objects.String.newValue("argv0") };
            defer argv0_name_shim.original.dropReference();
            const argv0_val = try objects.String.newValue(filename);
            defer argv0_val.dropReference();
            try interp.setVariable(&argv0_name_shim, argv0_val);

            var argv_name_shim: objects.Shimmerable = .{ .original = try objects.String.newValue("argv") };
            defer argv_name_shim.original.dropReference();
            const argv_items = try init.gpa.alloc(heap.Value, args.len - 2);
            defer init.gpa.free(argv_items);
            for (args[2..], 0..) |arg_ptr, i| {
                const arg_str = std.mem.span(arg_ptr);
                argv_items[i] = try objects.String.newValue(arg_str);
            }
            const argv_list = try objects.List.new(argv_items);
            defer argv_list.asHead().dropReference();
            for (argv_items) |item| {
                item.dropReference();
            }
            try interp.setVariable(&argv_name_shim, argv_list.asHead().asValue());

            interp.evalFile(filename) catch |err| {
                const res = interp.result.getString() catch @errorName(err);
                var stderr_buf: [1024]u8 = undefined;
                var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buf);
                try stderr_writer.interface.writeAll(res);
                try stderr_writer.interface.writeAll("\n");
                try stderr_writer.interface.flush();
                std.process.exit(1);
            };
            return;
        }
    }

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init.io, &stdin_buffer);
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
            if (std.mem.findScalarPos(u8, stdin.buffer[0..stdin.end], stdin.seek, '\n')) |end| {
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
    _ = @import("vendor/Threaded_test.zig");

    _ = @import("commands/common.zig");
}

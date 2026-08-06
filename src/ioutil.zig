const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const heap = @import("heap.zig");

pub threadlocal var local_stdout_fd: i32 = std.posix.STDOUT_FILENO;
pub threadlocal var local_stderr_fd: i32 = std.posix.STDOUT_FILENO;

// TODO threadlocal version of stdout and stderr

pub fn getStdout() std.Io.File {
    return .{ .handle = local_stdout_fd, .flags = .{ .nonblocking = false } };
}

pub fn getStderr() std.Io.File {
    return .{ .handle = local_stderr_fd, .flags = .{ .nonblocking = false } };
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    const stderr = getStderr();
    var buffer: [64]u8 = undefined;
    var writer = stderr.writer(heap.global_io, &buffer);
    defer writer.flush() catch {};
    writer.interface.print(fmt, args) catch return;
}

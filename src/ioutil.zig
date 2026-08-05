const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const heap = @import("heap.zig");

var stdout_mutex: std.Io.Mutex = .init;
pub var global_stdout_fd: std.atomic.Value(i32) = .init(std.posix.STDOUT_FILENO);
var stderr_mutex: std.Io.Mutex = .init;
pub var global_stderr_fd: std.atomic.Value(i32) = .init(std.posix.STDERR_FILENO);

// TODO threadlocal version of stdout and stderr

pub fn lockStdout() std.Io.File {
    stdout_mutex.lockUncancelable(heap.global_io);
    const fd = global_stdout_fd.load(.monotonic);
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

pub fn unlockStdout() void {
    stdout_mutex.unlock(heap.global_io);
}

pub fn lockStderr() std.Io.File {
    stderr_mutex.lockUncancelable(heap.global_io);
    const fd = global_stderr_fd.load(.monotonic);
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

pub fn unlockStderr() void {
    stderr_mutex.unlock(heap.global_io);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    const stderr = lockStderr();
    defer unlockStderr();
    var buffer: [64]u8 = undefined;
    var writer = stderr.writer(heap.global_io, &buffer);
    defer writer.flush() catch {};
    writer.interface.print(fmt, args) catch return;
}

const Heap = @import("Heap.zig");
const std = @import("std");

var stdout_mutex: std.Io.Mutex = .init;
pub var global_stdout_fd: std.atomic.Value(i32) = .init(std.posix.STDOUT_FILENO);
var stderr_mutex: std.Io.Mutex = .init;
pub var global_stderr_fd: std.atomic.Value(i32) = .init(std.posix.STDERR_FILENO);

// TODO threadlocal version of stdout and stderr

pub fn lockStdout() std.Io.File {
    stdout_mutex.lockUncancelable(Heap.global_io);
    const fd = global_stdout_fd.load(.monotonic);
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

pub fn unlockStdout() void {
    stdout_mutex.unlock(Heap.global_io);
}

pub fn lockStderr() std.Io.File {
    stderr_mutex.lockUncancelable(Heap.global_io);
    const fd = global_stderr_fd.load(.monotonic);
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

pub fn unlockStderr() void {
    stderr_mutex.unlock(Heap.global_io);
}

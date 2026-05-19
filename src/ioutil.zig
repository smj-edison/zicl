const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const Heap = @import("Heap.zig");

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

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    const stderr = lockStderr();
    defer unlockStderr();
    var writer = stderr.writer(Heap.global_io, &.{});
    defer writer.flush() catch {};
    writer.interface.print(fmt, args) catch return;
}

export var __seq_cst_synchronize: u64 = 0;
pub fn debugWithBarrier(comptime fmt: []const u8, args: anytype) void {
    _ = @atomicLoad(u64, &__seq_cst_synchronize, .seq_cst);
    debug(fmt, args);
    _ = @atomicLoad(u64, &__seq_cst_synchronize, .seq_cst);
}

/// This is mostly copied from std.debug.ConfigurableTrace.
pub fn ConfigurableTrace(comptime size: usize, comptime stack_frame_count: usize, comptime is_enabled: bool) type {
    return struct {
        addrs: [actual_size][stack_frame_count]usize,
        notes: [actual_size][]const u8,
        index: Index,

        const actual_size = if (enabled) size else 0;
        const Index = if (enabled) usize else u0;

        pub const init: @This() = .{
            .addrs = undefined,
            .notes = undefined,
            .index = 0,
        };

        pub const enabled = is_enabled;

        pub const add = if (enabled) addNoInline else addNoOp;

        pub noinline fn addNoInline(t: *@This(), note: []const u8) void {
            comptime assert(enabled);
            return addAddr(t, @returnAddress(), note);
        }

        pub inline fn addNoOp(t: *@This(), note: []const u8) void {
            _ = t;
            _ = note;
            comptime assert(!enabled);
        }

        pub fn addAddr(t: *@This(), addr: usize, note: []const u8) void {
            if (!enabled) return;

            const index_to_use = if (t.index >= size) blk: {
                // Shift out the last value, so we can fit the new one. In my experience, the most
                // recent traces are the most useful.
                @memmove(t.notes[0..(size - 1)], t.notes[1..]);
                @memmove(t.addrs[0..(size - 1)], t.addrs[1..]);
                break :blk size - 1;
            } else t.index;

            t.notes[index_to_use] = note;
            const addrs = &t.addrs[index_to_use];
            const st = std.debug.captureCurrentStackTrace(.{ .first_address = addr }, addrs);
            if (st.return_addresses.len < addrs.len) {
                @memset(addrs[st.return_addresses.len..], 0); // zero unused frames to indicate end of trace
            }

            // Keep counting even if the end is reached so that the
            // user can find out how much more size they need.
            t.index += 1;
        }

        pub fn dump(t: @This()) void {
            if (!enabled) return;

            const stderr = lockStderr();
            defer unlockStderr();
            var buffer: [64]u8 = undefined;
            var writer = stderr.writer(Heap.global_io, &buffer);
            defer writer.flush() catch {};
            var terminal: Io.Terminal = .{ .writer = &writer.interface, .mode = .escape_codes };
            terminal.setColor(.reset) catch return;
            const end = @min(t.index, size);
            for (t.addrs[0..end], 0..) |frames_array, i| {
                terminal.writer.print("{s}:\n", .{t.notes[i]}) catch return;
                var frames_array_mutable = frames_array;
                const frames = std.mem.sliceTo(frames_array_mutable[0..], 0);
                const len = @min(t.index, frames.len);
                const stack_trace: std.debug.StackTrace = .{
                    .return_addresses = frames[0..len],
                    .skipped = if (len < frames.len) .none else .unknown,
                };
                std.debug.writeStackTrace(&stack_trace, terminal) catch return;
            }
            if (t.index > end) {
                terminal.writer.print("{d} traces dropped; consider increasing trace size\n", .{
                    t.index - end,
                }) catch return;
            }
        }

        pub fn format(
            t: @This(),
            comptime fmt: []const u8,
            options: std.fmt.Options,
            writer: *Io.Writer,
        ) !void {
            if (fmt.len != 0) std.fmt.invalidFmtError(fmt, t);
            _ = options;
            if (enabled) {
                try writer.writeAll("\n");
                t.dump();
                try writer.writeAll("\n");
            } else {
                return writer.writeAll("(value tracing disabled)");
            }
        }
    };
}

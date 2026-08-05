const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const builtin = @import("builtin");

const ioutil = @import("ioutil.zig");

const heap = @import("heap.zig");
const Capability = @import("Capability.zig");

const process = std.process;

pub const File = struct {
    pub const Mode = enum { r, @"r+", w, @"w+" };

    file: std.Io.File,
    mode: Mode,

    pub fn open(path: []const u8, mode: Mode) !*Capability {
        const cwd = std.Io.Dir.cwd();

        var file = switch (mode) {
            .r, .@"r+" => try cwd.openFile(heap.global_io, path, .{
                .mode = if (mode == .@"r+") .read_write else .read_only,
                .allow_directory = false,
            }),
            .w, .@"w+" => try cwd.createFile(heap.global_io, path, .{
                .read = mode == .@"w+",
            }),
        };
        errdefer file.close(heap.global_io);

        const cap_backing = try heap.global_gpa.create(Backing);
        errdefer heap.global_gpa.destroy(cap_backing);
        cap_backing.* = .{
            .head = .{ .vtable = &Backing.vtable, .id = undefined },
            .body = .{ .file = file, .mode = mode },
        };

        return try Capability.new(&cap_backing.head);
    }

    pub fn writeAll(file: *File, bytes: []const u8) !void {
        var buffer: [1024]u8 = undefined;

        var writer = std.Io.File.Writer.initStreaming(file.file, heap.global_io, &buffer);
        writer.interface.writeAll(bytes) catch return writer.err.?;
        writer.flush() catch return writer.err.?;
    }

    pub const Backing = struct {
        head: Capability.Head,
        body: File,

        fn deinitBody(head: *Capability.Head) void {
            const backing: *Backing = @fieldParentPtr("head", head);
            backing.body.file.close(heap.global_io);
        }

        fn destroyBacking(head: *Capability.Head) void {
            const backing: *Backing = @fieldParentPtr("head", head);
            heap.global_gpa.destroy(backing);
        }

        pub const vtable: Capability.Head.VTable = .{
            .deinitBody = deinitBody,
            .destroyBacking = destroyBacking,
            .name = "file-handle",
        };
    };
};

/// A running pipeline, held as one capability however many stages it has.
///
/// The capability is the whole handle: there is no pid table and nothing reaps a
/// child on its own. A script waits for the pipeline or closes it, and anything
/// left over is closed by `Capability.deinitGlobals` at shutdown. That is the
/// same bargain as a file handle, and it is why [exec] hands back a capability
/// rather than a pid, which is forgeable and goes stale into whatever process
/// the system next gives that number to.
pub const Process = struct {
    /// Guards `stages`. A capability name resolves from any thread, so two can
    /// reach `wait` at once; the first blocks in `Child.wait` and the rest read
    /// the status it recorded.
    mutex: std.Io.Mutex = .init,
    stages: []Stage,

    pub const Stage = struct {
        child: process.Child,
        /// Held apart from `child` because `Child.wait` clears the copy in
        /// there. Never written after construction, so it needs no lock.
        pid: process.Child.Id,
        /// Published separately from `term` so `pids` can tell a live stage from
        /// a reaped one without the mutex, which a `wait` in flight holds for as
        /// long as the pipeline runs.
        reaped: std.atomic.Value(bool) = .init(false),
        /// `Child.wait` may only be called once, so the status is kept here to
        /// answer a second [wait].
        term: ?process.Child.Term = null,

        /// Waits for this stage and records how it ended. The entry is gone once
        /// this returns, error or not, since `Child.wait` reaps before it
        /// reports. The caller holds whatever lock guards `term`.
        pub fn wait(self: *Stage) process.Child.WaitError!process.Child.Term {
            defer self.reaped.store(true, .release);
            const term = try self.child.wait(heap.global_io);
            self.term = term;
            return term;
        }

        /// Kills this stage and records that it is gone, doing nothing once it
        /// has been waited for. A status is recorded although `Child.kill`
        /// reports none, since a reaped stage without a `term` is one a later
        /// `wait` can neither collect nor describe.
        pub fn kill(self: *Stage) void {
            if (self.term != null) return;
            self.child.kill(heap.global_io);
            self.term = .{ .signal = .TERM };
            self.reaped.store(true, .release);
        }
    };

    /// Takes ownership of `stages` on success, which must have been allocated
    /// with `heap.global_gpa` and hold already-spawned children. On failure the
    /// slice is still the caller's, along with the children in it.
    pub fn new(stages: []Stage) !*Capability {
        const cap_backing = try heap.global_gpa.create(Backing);
        errdefer heap.global_gpa.destroy(cap_backing);
        cap_backing.* = .{
            .head = .{ .vtable = &Backing.vtable, .id = undefined },
            .body = .{ .stages = stages },
        };

        return try Capability.new(&cap_backing.head);
    }

    /// Blocks until every stage has exited and reports how the pipeline ended, a
    /// stage already waited for contributing the status it reported then. Safe
    /// to call from two threads at once, and safe to call again after any
    /// outcome, including a failure.
    pub fn wait(self: *Process) !process.Child.Term {
        self.mutex.lockUncancelable(heap.global_io);
        defer self.mutex.unlock(heap.global_io);

        for (self.stages) |*stage| {
            if (stage.term != null) continue;

            // An entry that is gone with no status recorded was collected by
            // something else: a close from another thread, or a wait of our own
            // that failed part way. The status is unrecoverable either way, and
            // `Child.wait` asserts rather than saying so.
            if (stage.child.id == null) {
                stage.term = .{ .unknown = 0 };
                continue;
            }
            _ = try stage.wait();
        }
        return pipelineTerm(self.stages);
    }

    /// The pids of the stages, in the order they were spawned, written into
    /// `out` and returned as a slice of it. `out` must have room for every
    /// stage. Null for a stage already reaped, whose number the system is free
    /// to hand to something else. A pid that does come back may be reaped before
    /// the caller can use it, a race inherent to naming a process by number
    /// rather than by capability.
    pub fn pids(self: *Process, out: []?process.Child.Id) []?process.Child.Id {
        assert(out.len >= self.stages.len);

        // Deliberately takes no lock, which a `wait` holds for as long as the
        // pipeline runs; going through it would report pids only once they had
        // all stopped being useful.
        for (self.stages, out[0..self.stages.len]) |*stage, *slot| {
            slot.* = if (stage.reaped.load(.acquire)) null else stage.pid;
        }
        return out[0..self.stages.len];
    }

    /// How the pipeline as a whole ended, every stage having been waited for.
    /// The last stage decides, except that an earlier failure is not swallowed:
    /// `exec {false} | {true}` reports the failure, not the success that
    /// happened to come last.
    pub fn pipelineTerm(stages: []const Stage) process.Child.Term {
        const last = stages[stages.len - 1].term.?;
        if (!isNormalExit(last)) return last;
        for (stages) |stage| {
            const term = stage.term.?;
            if (!isNormalExit(term)) return term;
        }
        return last;
    }

    pub fn isNormalExit(term: process.Child.Term) bool {
        return switch (term) {
            .exited => |code| code == 0,
            else => false,
        };
    }

    pub const Backing = struct {
        head: Capability.Head,
        body: Process,

        /// Kills whatever is still running, since a closed capability can no
        /// longer be named and nothing could ever wait for its children.
        fn deinitBody(head: *Capability.Head) void {
            const backing: *Backing = @fieldParentPtr("head", head);
            const self = &backing.body;

            self.mutex.lockUncancelable(heap.global_io);
            defer self.mutex.unlock(heap.global_io);
            for (self.stages) |*stage| stage.kill();
        }

        /// Runs at ref count zero rather than at close, so a thread holding the
        /// body through a `getBacking` that raced the close still reads valid
        /// memory.
        fn destroyBacking(head: *Capability.Head) void {
            const backing: *Backing = @fieldParentPtr("head", head);
            heap.global_gpa.free(backing.body.stages);
            heap.global_gpa.destroy(backing);
        }

        pub const vtable: Capability.Head.VTable = .{
            .deinitBody = deinitBody,
            .destroyBacking = destroyBacking,
            .name = "process",
        };
    };
};

test "file" {
    try heap.testStart(testing.allocator, testing.io);
    defer heap.testFinish();

    // Written into a temporary directory rather than the working one, so a test
    // run leaves nothing behind next to the source.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buffer[0..(try tmp.dir.realPath(heap.global_io, &path_buffer))];
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/test.txt", .{dir_path});
    defer testing.allocator.free(path);

    const cap = try File.open(path, .w);
    defer cap.asHead().release();
    defer cap.close();
    const file = &(try cap.getBacking(File.Backing, null)).body;
    try file.writeAll("hello ");
    try file.writeAll("world");

    const written = try tmp.dir.readFileAlloc(heap.global_io, "test.txt", testing.allocator, .limited(64));
    defer testing.allocator.free(written);
    try testing.expectEqualStrings("hello world", written);
}

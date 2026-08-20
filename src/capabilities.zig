const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const builtin = @import("builtin");

const ioutil = @import("ioutil.zig");

const heap = @import("heap.zig");
const Capability = @import("Capability.zig");
const memutil = @import("memutil.zig");
const objects = @import("objects.zig");
const ErrorDetails = objects.ErrorDetails;

const process = std.process;

pub const File = struct {
    pub const Mode = enum { r, @"r+", w, @"w+" };

    file: std.Io.File,
    close_when_done: bool,

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
            .body = .{ .file = file, .close_when_done = true },
        };

        return try Capability.new(&cap_backing.head);
    }

    pub fn openDescriptor(handle: std.Io.File.Handle) !*Capability {
        // TODO should this always be `nonblocking = false`?
        const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };

        const cap_backing = try heap.global_gpa.create(Backing);
        errdefer heap.global_gpa.destroy(cap_backing);
        cap_backing.* = .{
            .head = .{ .vtable = &Backing.vtable, .id = undefined },
            .body = .{ .file = file, .close_when_done = false },
        };

        return try Capability.new(&cap_backing.head);
    }

    pub fn writeAll(file: *File, bytes: []const u8) !void {
        var buffer: [1024]u8 = undefined;

        var writer = std.Io.File.Writer.initStreaming(file.file, heap.global_io, &buffer);
        writer.interface.writeAll(bytes) catch return writer.err.?;
        writer.flush() catch return writer.err.?;
    }

    /// Reads everything from the current position to EOF. Only the whole-file
    /// slurp is implemented for now (matching [read]'s minimal boot.folk use);
    /// a `numChars`/`-nonewline` form would need its own careful handling
    /// since Tcl counts characters, not bytes, and a partial read must not
    /// consume past the requested codepoint boundary.
    pub fn readAll(file: *File) ![:0]u8 {
        var buffer: [1024]u8 = undefined;
        var reader = std.Io.File.Reader.initStreaming(file.file, heap.global_io, &buffer);

        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(heap.global_gpa);
        reader.interface.appendRemaining(heap.global_gpa, &result, .unlimited) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            error.OutOfMemory => return error.OutOfMemory,
            error.StreamTooLong => unreachable, // `.unlimited` never trips this
        };

        return try result.toOwnedSliceSentinel(heap.global_gpa, 0);
    }

    pub const Backing = struct {
        head: Capability.Head,
        body: File,

        fn deinitBody(head: *Capability.Head) callconv(.c) void {
            const backing: *Backing = @fieldParentPtr("head", head);
            if (backing.body.close_when_done) backing.body.file.close(heap.global_io);
        }

        fn destroyBacking(head: *Capability.Head) callconv(.c) void {
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
        fn deinitBody(head: *Capability.Head) callconv(.c) void {
            const backing: *Backing = @fieldParentPtr("head", head);
            const self = &backing.body;

            self.mutex.lockUncancelable(heap.global_io);
            defer self.mutex.unlock(heap.global_io);
            for (self.stages) |*stage| stage.kill();
        }

        /// Runs at ref count zero rather than at close, so a thread holding the
        /// body through a `getBacking` that raced the close still reads valid
        /// memory.
        fn destroyBacking(head: *Capability.Head) callconv(.c) void {
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

/// A raw pointer whose lifetime has been handed over to Zicl. Meant for C code
/// (chiefly generated FFI wrappers, see `folk/lib/c.tcl`) that returns a
/// pointer it wants a script to be able to hold, pass around by its capability
/// URL, and eventually release -- without requiring a bespoke capability type
/// (and `Zicl_CapabilityHeadVTable`) for every pointed-to C type.
///
/// All `Pointer` capabilities share one vtable/name ("pointer"), so the type
/// checking a real per-type vtable would give `Capability.getBacking` for
/// free doesn't apply here -- passing a `v4l2_capability*` where a `Gpu*` is
/// expected would otherwise type-check fine at the capability layer and blow
/// up in the C function instead. `type_name` exists to close that hole:
/// `getTyped` checks it explicitly, so callers that care what the pointer
/// points to (which is effectively everyone using this from generated FFI
/// code) get the same safety a per-type vtable would have given them.
pub const Pointer = struct {
    /// Null is a legitimate value here (e.g. a C API whose pointer type uses
    /// NULL as a meaningful "empty" state, not just "allocation failed") --
    /// distinct from the capability itself, which always has a real identity
    /// whether or not the pointer it carries is null.
    ptr: ?*anyopaque,
    type_name: [:0]const u8,
    /// Runs once when the capability closes (explicitly, or via
    /// `Capability.deinitGlobals` at shutdown if never closed), and is handed
    /// back the original pointer. Null for a pointer that needs no cleanup,
    /// e.g. one borrowed from elsewhere. Never runs if `ptr` itself is null,
    /// since there is nothing to destroy.
    destructor: ?*const fn (ptr: *anyopaque) callconv(.c) void,

    pub fn new(ptr: ?*anyopaque, type_name: []const u8, destructor: ?*const fn (ptr: *anyopaque) callconv(.c) void) !*Capability {
        const owned_type_name = try heap.global_gpa.dupeSentinel(u8, type_name, 0);
        errdefer heap.global_gpa.free(owned_type_name);

        const cap_backing = try heap.global_gpa.create(Backing);
        errdefer heap.global_gpa.destroy(cap_backing);
        cap_backing.* = .{
            .head = .{ .vtable = &Backing.vtable, .id = undefined },
            .body = .{ .ptr = ptr, .type_name = owned_type_name, .destructor = destructor },
        };

        return try Capability.new(&cap_backing.head);
    }

    /// Like `Capability.getBacking`, but also requires the capability's
    /// `type_name` to equal `expected_type_name`, so a pointer of one C type
    /// can't stand in for another.
    pub fn getTyped(cap: *const Capability, expected_type_name: []const u8, det: ?*ErrorDetails) !*Pointer {
        const backing = try cap.getBacking(Backing, det);
        if (!std.mem.eql(u8, backing.body.type_name, expected_type_name)) {
            if (det) |details| details.* = .{
                .message = try objects.allocPrintZ(
                    "expected a pointer capability of type \"{s}\" but got \"{s}\"",
                    .{ expected_type_name, backing.body.type_name },
                ),
            };
            return error.BadCapability;
        }
        return &backing.body;
    }

    pub const Backing = struct {
        head: Capability.Head,
        body: Pointer,

        fn deinitBody(head: *Capability.Head) callconv(.c) void {
            const backing: *Backing = @fieldParentPtr("head", head);
            const ptr = backing.body.ptr orelse return;
            if (backing.body.destructor) |destroy| destroy(ptr);
        }

        fn destroyBacking(head: *Capability.Head) callconv(.c) void {
            const backing: *Backing = @fieldParentPtr("head", head);
            heap.global_gpa.free(backing.body.type_name);
            heap.global_gpa.destroy(backing);
        }

        pub const vtable: Capability.Head.VTable = .{
            .deinitBody = deinitBody,
            .destroyBacking = destroyBacking,
            .name = "pointer",
        };
    };
};

fn testPointerDestructorRunsOnClose(ta: std.mem.Allocator) !void {
    try heap.testStart(ta, testing.io);
    defer heap.testFinish();

    const Impl = struct {
        var destroyed: bool = false;
        var last_ptr: ?*anyopaque = null;

        fn destroy(ptr: *anyopaque) callconv(.c) void {
            destroyed = true;
            last_ptr = ptr;
        }
    };
    Impl.destroyed = false;
    Impl.last_ptr = null;

    var payload: u64 = 42;
    const cap = try Pointer.new(&payload, "u64*", Impl.destroy);
    defer cap.asHead().release();
    defer cap.close();

    const backing = try cap.getBacking(Pointer.Backing, null);
    try testing.expectEqual(@as(?*anyopaque, &payload), backing.body.ptr);
    try testing.expectEqualStrings("u64*", backing.body.type_name);

    try testing.expect(!Impl.destroyed);
    cap.close();
    try testing.expect(Impl.destroyed);
    try testing.expectEqual(@as(*anyopaque, &payload), Impl.last_ptr.?);

    // Closing again must not run the destructor a second time.
    Impl.destroyed = false;
    cap.close();
    try testing.expect(!Impl.destroyed);
}

test "pointer capability destructor runs on close" {
    try testing.checkAllAllocationFailures(testing.allocator, testPointerDestructorRunsOnClose, .{});
}

fn testPointerNullDestructorIsNoop(ta: std.mem.Allocator) !void {
    try heap.testStart(ta, testing.io);
    defer heap.testFinish();

    var payload: u64 = 7;
    const cap = try Pointer.new(&payload, "u64*", null);
    defer cap.asHead().release();
    defer cap.close();

    const backing = try cap.getBacking(Pointer.Backing, null);
    try testing.expectEqual(@as(?*anyopaque, &payload), backing.body.ptr);

    cap.close();
    try memutil.expectErrorOrOom(error.StaleCapability, cap.getBacking(Pointer.Backing, null));
}

test "pointer capability with null destructor is a no-op close" {
    try testing.checkAllAllocationFailures(testing.allocator, testPointerNullDestructorIsNoop, .{});
}

fn testPointerGetTypedChecksTypeName(ta: std.mem.Allocator) !void {
    try heap.testStart(ta, testing.io);
    defer heap.testFinish();

    var payload: u64 = 99;
    const cap = try Pointer.new(&payload, "Gpu*", null);
    defer cap.asHead().release();
    defer cap.close();

    const matched = try Pointer.getTyped(cap, "Gpu*", null);
    try testing.expectEqual(@as(?*anyopaque, &payload), matched.ptr);

    try memutil.expectErrorOrOom(error.BadCapability, Pointer.getTyped(cap, "v4l2_capability*", null));
}

test "pointer capability getTyped checks type_name" {
    try testing.checkAllAllocationFailures(testing.allocator, testPointerGetTypedChecksTypeName, .{});
}

fn testPointerNullPtrClosesWithoutRunningDestructor(ta: std.mem.Allocator) !void {
    try heap.testStart(ta, testing.io);
    defer heap.testFinish();

    const Impl = struct {
        var destroyed: bool = false;
        fn destroy(_: *anyopaque) callconv(.c) void {
            destroyed = true;
        }
    };
    Impl.destroyed = false;

    const cap = try Pointer.new(null, "Gpu*", Impl.destroy);
    defer cap.asHead().release();
    defer cap.close();

    const matched = try Pointer.getTyped(cap, "Gpu*", null);
    try testing.expectEqual(@as(?*anyopaque, null), matched.ptr);

    cap.close();
    try testing.expect(!Impl.destroyed);
}

test "pointer capability with null ptr closes without running destructor" {
    try testing.checkAllAllocationFailures(testing.allocator, testPointerNullPtrClosesWithoutRunningDestructor, .{});
}

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

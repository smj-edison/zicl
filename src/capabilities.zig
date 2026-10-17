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

pub const StreamOps = struct {
    lock_writer: *const fn (head: *Capability.Head) *std.Io.Writer,
    /// Be sure to call while locked.
    get_writer_error: *const fn (head: *Capability.Head) ?anyerror,
    unlock_writer: *const fn (head: *Capability.Head) void,
    lock_reader: *const fn (head: *Capability.Head) *std.Io.Reader,
    /// Be sure to call while locked.
    get_reader_error: *const fn (head: *Capability.Head) ?anyerror,
    /// Be sure to call while locked.
    get_eos_ptr: *const fn (head: *Capability.Head) *bool,
    unlock_reader: *const fn (head: *Capability.Head) void,
};

pub const SocketOps = struct {
    accept: *const fn (head: *Capability.Head) (std.Io.net.Server.AcceptError || error{OutOfMemory})!*Capability,
};

pub const File = struct {
    pub const Mode = enum { r, @"r+", w, @"w+", a, @"a+" };

    file: std.Io.File,
    close_when_done: bool,

    write_mutex: std.Io.Mutex,
    writer: std.Io.File.Writer,

    read_mutex: std.Io.Mutex,
    /// Set to true when end of stream is hit.
    eos_hit: bool = false,
    reader: std.Io.File.Reader,

    pub fn openFileMode(dir: std.Io.Dir, path: []const u8, mode: Mode) !std.Io.File {
        return switch (mode) {
            .r, .@"r+" => try dir.openFile(heap.global_io, path, .{
                .mode = if (mode == .@"r+") .read_write else .read_only,
                .allow_directory = false,
            }),
            .w, .@"w+", .a, .@"a+" => try dir.createFile(heap.global_io, path, .{
                .read = mode == .@"w+" or mode == .@"a+",
                .truncate = mode == .w or mode == .@"w+",
            }),
        };
    }

    pub fn open(path: []const u8, mode: Mode) !*Backing {
        const cwd = std.Io.Dir.cwd();

        const read_buffer = try heap.global_gpa.alloc(u8, 4096);
        errdefer heap.global_gpa.free(read_buffer);
        const write_buffer = try heap.global_gpa.alloc(u8, 4096);
        errdefer heap.global_gpa.free(write_buffer);

        const cap_backing = try heap.global_gpa.create(Backing);
        errdefer heap.global_gpa.destroy(cap_backing);

        const file = try openFileMode(cwd, path, mode);
        errdefer file.close(heap.global_io);

        var reader: std.Io.File.Reader = .init(file, heap.global_io, read_buffer);
        if (mode == .a or mode == .@"a+") try reader.seekTo(try file.length(heap.global_io));
        const writer: std.Io.File.Writer = .init(file, heap.global_io, write_buffer);

        // Take ownership of everything.
        cap_backing.* = .{
            .head = .{ .vtable = &Backing.vtable, .id = .not_set },
            .body = .{
                .file = file,
                .close_when_done = true,
                .write_mutex = .init,
                .writer = writer,
                .read_mutex = .init,
                .reader = reader,
            },
        };
        return cap_backing;
    }

    pub fn createFromFile(file: std.Io.File, close_when_done: bool) !*Backing {
        const read_buffer = try heap.global_gpa.alloc(u8, 4096);
        errdefer heap.global_gpa.free(read_buffer);
        const write_buffer = try heap.global_gpa.alloc(u8, 4096);
        errdefer heap.global_gpa.free(write_buffer);

        const cap_backing = try heap.global_gpa.create(Backing);

        cap_backing.* = .{
            .head = .{ .vtable = &Backing.vtable, .id = .not_set },
            .body = .{
                .file = file,
                .close_when_done = close_when_done,
                .write_mutex = .init,
                .writer = .initStreaming(file, heap.global_io, write_buffer),
                .read_mutex = .init,
                .reader = .initStreaming(file, heap.global_io, read_buffer),
            },
        };
        return cap_backing;
    }

    pub fn createFromDescriptor(handle: std.Io.File.Handle, nonblocking: bool, close_when_done: bool) !*Backing {
        const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = nonblocking } };
        return try createFromFile(file, close_when_done);
    }

    pub fn asHead(file: *File) *Capability.Head {
        const backing: *Backing = @fieldParentPtr("body", file);
        return &backing.head;
    }

    fn lockWriter(head: *Capability.Head) *std.Io.Writer {
        const backing: *Backing = @fieldParentPtr("head", head);
        backing.body.write_mutex.lockUncancelable(heap.global_io);
        return &backing.body.writer.interface;
    }

    fn getWriterError(head: *Capability.Head) ?anyerror {
        const backing: *Backing = @fieldParentPtr("head", head);
        return backing.body.writer.err;
    }

    fn unlockWriter(head: *Capability.Head) void {
        const backing: *Backing = @fieldParentPtr("head", head);
        backing.body.write_mutex.unlock(heap.global_io);
    }

    fn lockReader(head: *Capability.Head) *std.Io.Reader {
        const backing: *Backing = @fieldParentPtr("head", head);
        backing.body.read_mutex.lockUncancelable(heap.global_io);
        return &backing.body.reader.interface;
    }

    fn getReaderError(head: *Capability.Head) ?anyerror {
        const backing: *Backing = @fieldParentPtr("head", head);
        return backing.body.reader.err;
    }

    fn getEosPtr(head: *Capability.Head) *bool {
        const backing: *Backing = @fieldParentPtr("head", head);
        return &backing.body.eos_hit;
    }

    fn unlockReader(head: *Capability.Head) void {
        const backing: *Backing = @fieldParentPtr("head", head);
        backing.body.read_mutex.unlock(heap.global_io);
    }

    pub const Backing = struct {
        head: Capability.Head,
        body: File,

        fn deinitBody(head: *Capability.Head) callconv(.c) void {
            const backing: *Backing = @fieldParentPtr("head", head);
            if (backing.body.close_when_done) backing.body.file.close(heap.global_io);

            // We lock to make sure `.buffer` happens-after it was set.
            backing.body.read_mutex.lockUncancelable(heap.global_io);
            heap.global_gpa.free(backing.body.reader.interface.buffer);
            backing.body.read_mutex.unlock(heap.global_io);

            backing.body.write_mutex.lockUncancelable(heap.global_io);
            heap.global_gpa.free(backing.body.writer.interface.buffer);
            backing.body.write_mutex.unlock(heap.global_io);
        }

        fn destroyBacking(head: *Capability.Head) callconv(.c) void {
            const backing: *Backing = @fieldParentPtr("head", head);
            heap.global_gpa.destroy(backing);
        }

        pub const vtable: Capability.Head.VTable = .{
            .deinit_body = deinitBody,
            .destroy_backing = destroyBacking,
            .name = "file-handle",
            .stream_ops = &.{
                .lock_writer = lockWriter,
                .get_writer_error = getWriterError,
                .unlock_writer = unlockWriter,
                .lock_reader = lockReader,
                .get_reader_error = getReaderError,
                .get_eos_ptr = getEosPtr,
                .unlock_reader = unlockReader,
            },
        };
    };
};

pub const IpConnection = struct {
    stream: std.Io.net.Stream,

    write_mutex: std.Io.Mutex,
    writer: std.Io.net.Stream.Writer,

    read_mutex: std.Io.Mutex,
    /// Set to true when end of stream is hit. Only read/written
    /// behind `read_mutex`.
    eos_hit: bool = false,
    reader: std.Io.net.Stream.Reader,

    /// Only takes ownership of `stream` on success.
    pub fn init(stream: std.Io.net.Stream) error{OutOfMemory}!*Backing {
        const read_buffer = try heap.global_gpa.alloc(u8, 4096);
        errdefer heap.global_gpa.free(read_buffer);
        const write_buffer = try heap.global_gpa.alloc(u8, 4096);
        errdefer heap.global_gpa.free(write_buffer);

        const cap_backing = try heap.global_gpa.create(Backing);
        errdefer heap.global_gpa.destroy(cap_backing);

        cap_backing.* = .{
            .head = .{ .vtable = &Backing.vtable, .id = .not_set },
            .body = .{
                .stream = stream,
                .write_mutex = .init,
                .writer = stream.writer(heap.global_io, write_buffer),
                .read_mutex = .init,
                .reader = stream.reader(heap.global_io, read_buffer),
            },
        };
        return cap_backing;
    }

    fn lockWriter(head: *Capability.Head) *std.Io.Writer {
        const backing: *Backing = @fieldParentPtr("head", head);
        backing.body.write_mutex.lockUncancelable(heap.global_io);
        return &backing.body.writer.interface;
    }

    fn getWriterError(head: *Capability.Head) ?anyerror {
        const backing: *Backing = @fieldParentPtr("head", head);
        return backing.body.writer.err;
    }

    fn unlockWriter(head: *Capability.Head) void {
        const backing: *Backing = @fieldParentPtr("head", head);
        backing.body.write_mutex.unlock(heap.global_io);
    }

    fn lockReader(head: *Capability.Head) *std.Io.Reader {
        const backing: *Backing = @fieldParentPtr("head", head);
        backing.body.read_mutex.lockUncancelable(heap.global_io);
        return &backing.body.reader.interface;
    }

    fn getReaderError(head: *Capability.Head) ?anyerror {
        const backing: *Backing = @fieldParentPtr("head", head);
        return backing.body.reader.err;
    }

    fn getEosPtr(head: *Capability.Head) *bool {
        const backing: *Backing = @fieldParentPtr("head", head);
        return &backing.body.eos_hit;
    }

    fn unlockReader(head: *Capability.Head) void {
        const backing: *Backing = @fieldParentPtr("head", head);
        backing.body.read_mutex.unlock(heap.global_io);
    }

    pub const Backing = struct {
        head: Capability.Head,
        body: IpConnection,

        fn deinitBody(head: *Capability.Head) callconv(.c) void {
            const backing: *Backing = @fieldParentPtr("head", head);
            backing.body.stream.close(heap.global_io);

            // We lock to make sure `.buffer` happens-after it was set.
            backing.body.read_mutex.lockUncancelable(heap.global_io);
            heap.global_gpa.free(backing.body.reader.interface.buffer);
            backing.body.read_mutex.unlock(heap.global_io);

            backing.body.write_mutex.lockUncancelable(heap.global_io);
            heap.global_gpa.free(backing.body.writer.interface.buffer);
            backing.body.write_mutex.unlock(heap.global_io);
        }

        fn destroyBacking(head: *Capability.Head) callconv(.c) void {
            const backing: *Backing = @fieldParentPtr("head", head);
            heap.global_gpa.destroy(backing);
        }

        pub const vtable: Capability.Head.VTable = .{
            .deinit_body = deinitBody,
            .destroy_backing = destroyBacking,
            .name = "ip-connection",
            .stream_ops = &.{
                .lock_writer = lockWriter,
                .get_writer_error = getWriterError,
                .unlock_writer = unlockWriter,
                .lock_reader = lockReader,
                .get_reader_error = getReaderError,
                .get_eos_ptr = getEosPtr,
                .unlock_reader = unlockReader,
            },
        };
    };
};

pub const IpSocket = struct {
    server: std.Io.net.Server,

    pub fn listen(address: std.Io.net.IpAddress) !*Backing {
        const server = try address.listen(heap.global_io, .{ .mode = .stream });
        errdefer server.deinit(heap.global_io);

        const cap_backing = try heap.global_gpa.create(Backing);
        errdefer heap.global_gpa.destroy(cap_backing);

        cap_backing.* = .{
            .head = .{ .vtable = &Backing.vtable, .id = .not_set },
            .body = .{ .server = server },
        };
        return cap_backing;
    }

    fn accept(head: *Capability.Head) !*Backing {
        const backing: *Backing = @fieldParentPtr("head", head);
        const stream: std.Io.net.Stream = blk: while (true) {
            const conn = backing.body.server.accept(heap.global_io) catch |err| switch (err) {
                error.ConnectionAborted => continue, // Connection died before we could use it.
                else => return err,
            };
            break :blk conn;
        };
        errdefer stream.close(heap.global_io);
        return try IpConnection.init(stream);
    }

    pub const Backing = struct {
        head: Capability.Head,
        body: IpSocket,

        fn deinitBody(head: *Capability.Head) callconv(.c) void {
            const backing: *Backing = @fieldParentPtr("head", head);
            backing.body.server.deinit(heap.global_io);
        }

        fn destroyBacking(head: *Capability.Head) callconv(.c) void {
            const backing: *Backing = @fieldParentPtr("head", head);
            heap.global_gpa.destroy(backing);
        }

        pub const vtable: Capability.Head.VTable = .{
            .deinit_body = deinitBody,
            .destroy_backing = destroyBacking,
            .name = "ip-socket",
            .socket_ops = &.{
                .accept = accept,
            },
        };
    };
};

/// A raw pointer whose lifetime has been handed over to Zicl. Meant for C code
/// (chiefly generated FFI wrappers, see `folk/lib/c.tcl`) that returns a
/// pointer it wants a script to be able to hold, pass around by its capability
/// URL, and eventually drop -- without requiring a bespoke capability type
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
    /// e.g. one referenced from elsewhere. Never runs if `ptr` itself is null,
    /// since there is nothing to destroy.
    destructor: ?*const fn (ptr: *anyopaque) callconv(.c) void,

    pub fn new(ptr: ?*anyopaque, type_name: []const u8, destructor: ?*const fn (ptr: *anyopaque) callconv(.c) void) !*Capability {
        const cap_backing = backing_and_name: {
            const created = try heap.global_gpa.create(Backing);
            errdefer heap.global_gpa.destroy(created);
            const owned_type_name = try heap.global_gpa.dupeSentinel(u8, type_name, 0);
            break :backing_and_name .{ .backing = created, .type_name = owned_type_name };
        };
        // `newTakingOwnership` tears the backing down if publication fails, so
        // from here on no caller-side cleanup is needed.
        cap_backing.backing.* = .{
            .head = .{ .vtable = &Backing.vtable, .id = .not_set },
            .body = .{ .ptr = ptr, .type_name = cap_backing.type_name, .destructor = destructor },
        };

        return try Capability.newTakingOwnership(&cap_backing.backing.head);
    }

    /// Like `Capability.getBacking`, but also requires the capability's
    /// `type_name` to equal `expected_type_name`, so a pointer of one C type
    /// can't stand in for another. On success, the capability will be marked
    /// as in-flight.
    pub fn getTyped(cap: *const Capability, expected_type_name: []const u8, det: ?*ErrorDetails) !*Pointer {
        const backing = try cap.getBacking(Backing, det);
        errdefer backing.head.dropInFlight();
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
            .deinit_body = deinitBody,
            .destroy_backing = destroyBacking,
            .name = "pointer",
        };
    };
};
pub const DynLib = struct {
    handle: std.DynLib,
    /// The `{fnName {nativefn fnName} ...}` dict this library registered at load time
    /// (see [dynlib fns]).
    fns: heap.Value,

    /// Takes ownership of `handle` and `fns`.
    pub fn new(handle: std.DynLib, fns: heap.Value) !*Capability {
        const cap_backing = try heap.global_gpa.create(Backing);
        // `newTakingOwnership` tears the backing down if publication fails, so
        // from here on no caller-side cleanup is needed.
        fns.makeCrossthread();
        cap_backing.* = .{
            .head = .{ .vtable = &Backing.vtable, .id = .not_set },
            .body = .{ .handle = handle, .fns = fns },
        };

        return try Capability.newTakingOwnership(&cap_backing.head);
    }

    /// The address of `symbol_name` in this library, or null if it isn't
    /// exported.
    pub fn lookup(self: *DynLib, symbol_name: [:0]const u8) ?*anyopaque {
        return self.handle.lookup(*anyopaque, symbol_name);
    }

    pub const Backing = struct {
        head: Capability.Head,
        body: DynLib,

        fn deinitBody(head: *Capability.Head) callconv(.c) void {
            const backing: *Backing = @fieldParentPtr("head", head);
            backing.body.handle.close();
        }

        fn destroyBacking(head: *Capability.Head) callconv(.c) void {
            const backing: *Backing = @fieldParentPtr("head", head);
            backing.body.fns.dropReference();
            heap.global_gpa.destroy(backing);
        }

        pub const vtable: Capability.Head.VTable = .{
            .deinit_body = deinitBody,
            .destroy_backing = destroyBacking,
            .name = "dynlib",
        };
    };
};

fn testPointerDestructorRunsOnClose(ta: std.mem.Allocator) !void {
    try heap.testStart(ta, null);
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
    defer cap.asHead().dropReference();
    defer cap.close();

    {
        const backing = try cap.getBacking(Pointer.Backing, null);
        defer backing.head.dropInFlight();
        try testing.expectEqual(@as(?*anyopaque, &payload), backing.body.ptr);
        try testing.expectEqualStrings("u64*", backing.body.type_name);
    }

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
    try heap.testStart(ta, null);
    defer heap.testFinish();

    var payload: u64 = 7;
    const cap = try Pointer.new(&payload, "u64*", null);
    defer cap.asHead().dropReference();
    defer cap.close();

    {
        const backing = try cap.getBacking(Pointer.Backing, null);
        defer backing.head.dropInFlight();
        try testing.expectEqual(@as(?*anyopaque, &payload), backing.body.ptr);
    }

    cap.close();
    try memutil.expectErrorOrOom(error.StaleCapability, cap.getBacking(Pointer.Backing, null));
}

test "pointer capability with null destructor is a no-op close" {
    try testing.checkAllAllocationFailures(testing.allocator, testPointerNullDestructorIsNoop, .{});
}

fn testPointerGetTypedChecksTypeName(ta: std.mem.Allocator) !void {
    try heap.testStart(ta, null);
    defer heap.testFinish();

    var payload: u64 = 99;
    const cap = try Pointer.new(&payload, "Gpu*", null);
    defer cap.asHead().dropReference();
    defer cap.close();

    {
        const matched = try Pointer.getTyped(cap, "Gpu*", null);
        defer cap.head.dropInFlight();
        try testing.expectEqual(@as(?*anyopaque, &payload), matched.ptr);
    }

    try memutil.expectErrorOrOom(error.BadCapability, Pointer.getTyped(cap, "v4l2_capability*", null));
}

test "pointer capability getTyped checks type_name" {
    try testing.checkAllAllocationFailures(testing.allocator, testPointerGetTypedChecksTypeName, .{});
}

fn testPointerNullPtrClosesWithoutRunningDestructor(ta: std.mem.Allocator) !void {
    try heap.testStart(ta, null);
    defer heap.testFinish();

    const Impl = struct {
        var destroyed: bool = false;
        fn destroy(_: *anyopaque) callconv(.c) void {
            destroyed = true;
        }
    };
    Impl.destroyed = false;

    const cap = try Pointer.new(null, "Gpu*", Impl.destroy);
    defer cap.asHead().dropReference();
    defer cap.close();

    {
        const matched = try Pointer.getTyped(cap, "Gpu*", null);
        defer cap.head.dropInFlight();
        try testing.expectEqual(@as(?*anyopaque, null), matched.ptr);
    }

    cap.close();
    try testing.expect(!Impl.destroyed);
}

test "pointer capability with null ptr closes without running destructor" {
    try testing.checkAllAllocationFailures(testing.allocator, testPointerNullPtrClosesWithoutRunningDestructor, .{});
}

test "file" {
    try heap.testStart(testing.allocator, null);
    defer heap.testFinish();

    // Written into a temporary directory rather than the working one, so a test
    // run leaves nothing behind next to the source.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buffer[0..(try tmp.dir.realPath(heap.global_io, &path_buffer))];
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/test.txt", .{dir_path});
    defer testing.allocator.free(path);

    {
        const backing = try File.open(path, .w);
        const cap = try Capability.newTakingOwnership(&backing.head);
        defer cap.asHead().dropReference();
        defer cap.close();
        const got = try cap.getBacking(File.Backing, null);
        defer got.head.dropInFlight();
        const writer = got.head.vtable.stream_ops.?.lock_writer(&got.head);
        defer got.head.vtable.stream_ops.?.unlock_writer(&got.head);
        try writer.writeAll("hello ");
        try writer.writeAll("world");
        try writer.flush();
    }

    const written = try tmp.dir.readFileAlloc(heap.global_io, "test.txt", testing.allocator, .limited(64));
    defer testing.allocator.free(written);
    try testing.expectEqualStrings("hello world", written);
}

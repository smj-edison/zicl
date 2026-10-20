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

    pub fn connect(address: std.Io.net.IpAddress) (std.Io.net.IpAddress.ConnectError || error{OutOfMemory})!*Backing {
        const stream = try address.connect(heap.global_io, .{ .mode = .stream });
        errdefer stream.close(heap.global_io);
        return try init(stream);
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
        var server = try address.listen(heap.global_io, .{ .mode = .stream, .reuse_address = true });
        errdefer server.deinit(heap.global_io);

        const cap_backing = try heap.global_gpa.create(Backing);
        errdefer heap.global_gpa.destroy(cap_backing);

        cap_backing.* = .{
            .head = .{ .vtable = &Backing.vtable, .id = .not_set },
            .body = .{ .server = server },
        };
        return cap_backing;
    }

    fn accept(head: *Capability.Head) (std.Io.net.Server.AcceptError || error{OutOfMemory})!*Capability {
        const backing: *Backing = @fieldParentPtr("head", head);
        const stream: std.Io.net.Stream = blk: while (true) {
            const conn = backing.body.server.accept(heap.global_io) catch |err| switch (err) {
                error.ConnectionAborted => continue, // Connection died before we could use it.
                else => return err,
            };
            break :blk conn;
        };
        errdefer stream.close(heap.global_io);
        const ip_conn = try IpConnection.init(stream);
        return try Capability.newTakingOwnership(&ip_conn.head);
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

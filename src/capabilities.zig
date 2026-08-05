const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const builtin = @import("builtin");

const ioutil = @import("ioutil.zig");

const heap = @import("heap.zig");
const Capability = @import("Capability.zig");

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

test "file" {
    try heap.testStart(testing.allocator, testing.io);
    defer heap.testFinish();

    const cap = try File.open("test.txt", .w);
    defer cap.asHead().release();
    defer cap.close();
    const f = &(try cap.getBacking(File.Backing, null)).body;
    try f.writeAll("hello ");
    try f.writeAll("world");
}

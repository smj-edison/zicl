const std = @import("std");
const posix = std.posix;

const common = @import("common.zig");
const Shimmerable = common.Shimmerable;
const ErrorDetails = common.ErrorDetails;
const objects = common.objects;
const heap = common.heap;
const Capability = common.Capability;

pub const File = struct {
    file: posix.fd_t,
    close_file_on_deinit: bool,

    pub const FieldNameToO = blk: {
        var relevant_field_count = 0;
        for (std.meta.fieldNames(posix.O)) |field_name| {
            if (field_name[0] == '_' or std.mem.eql(u8, field_name, "ACCMODE")) continue;
            relevant_field_count += 1;
        }

        var relevant_fields: [relevant_field_count][]const u8 = undefined;
        var relevant_field_i = 0;
        for (std.meta.fieldNames(posix.O)) |field_name| {
            if (field_name[0] == '_' or std.mem.eql(u8, field_name, "ACCMODE")) continue;
            relevant_fields[relevant_field_i] = field_name;
            relevant_field_i += 1;
        }

        const all_modes = relevant_fields ++ .{ "RDONLY", "WRONLY", "RDWR" };

        var mapping_entries: [all_modes.len]struct { []const u8, posix.O } = undefined;
        for (relevant_fields, mapping_entries[0..relevant_fields.len]) |mode, *new_entry| {
            var built_o: posix.O = .{};
            @field(built_o, mode) = true;
            new_entry.* = .{ mode, built_o };
        }

        mapping_entries[mapping_entries.len - 3] = .{ all_modes[all_modes.len - 3], .{ .ACCMODE = .RDONLY } };
        mapping_entries[mapping_entries.len - 2] = .{ all_modes[all_modes.len - 2], .{ .ACCMODE = .WRONLY } };
        mapping_entries[mapping_entries.len - 1] = .{ all_modes[all_modes.len - 1], .{ .ACCMODE = .RDWR } };

        break :blk std.StaticStringMap(posix.O).initComptime(mapping_entries);
    };

    const OIntType = @typeInfo(posix.O).@"struct".backing_integer.?;

    pub fn parseOpenMode(det: ?*ErrorDetails, mode: []const u8) !posix.O {
        var result_o: posix.O = .{};

        if (mode.len > 0 and std.ascii.isUpper(mode[0])) {
            // Looks like we were given a list of modes to open with.
            var shim: Shimmerable = .{ .original = try objects.String.newValue(mode) };
            defer shim.deinit();
            const as_list = try objects.List.shimmerFrom(det, &shim);

            for (as_list.items) |item| {
                const bytes = try item.getString();
                const to_add = FieldNameToO.get(bytes) orelse {
                    if (det) |details| details.* = .{
                        .message = try objects.allocPrintZ("invalid open mode: \"{s}\"", .{bytes}),
                    };
                    return error.UnknownMode;
                };

                result_o = @bitCast(@as(OIntType, @bitCast(result_o)) | @as(OIntType, @bitCast(to_add)));
            }
        } else {
            // Normal parsing.
            for (mode) |char| switch (char) {
                'r' => result_o = .{ .ACCMODE = .RDONLY },
                'w' => result_o = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
                'a' => result_o = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
                '+' => result_o.ACCMODE = .RDWR,
                'x' => result_o.EXCL = true,
                else => {
                    if (det) |details| details.* = .{
                        .message = try objects.allocPrintZ("invalid open mode: \"{c}\"", .{char}),
                    };
                    return error.UnknownMode;
                },
            };
        }

        return result_o;
    }

    pub fn open(det: ?*ErrorDetails, path: []const u8, open_mode: posix.O) !*Capability {
        const opened = posix.openat(posix.AT.FDCWD, path, open_mode, 0o666) catch |err| {
            if (det) |details| details.* = .{
                .message = try objects.allocPrintZ("failed to open due to error: \"{s}\"", .{@errorName(err)}),
            };
            return error.FailedToOpen;
        };
        errdefer posix.system.close(opened);

        const cap_backing = try heap.global_gpa.create(Backing);
        errdefer heap.global_gpa.destroy(cap_backing);
        cap_backing.* = .{
            .head = .{ .vtable = &Backing.vtable, .id = undefined },
            .body = .{ .file = opened, .close_when_done = true },
        };

        return try Capability.new(&cap_backing.head);
    }

    pub const Backing = struct {
        head: Capability.Head,
        body: File,

        fn deinitBody(head: *Capability.Head) callconv(.c) void {
            const backing: *Backing = @fieldParentPtr("head", head);
            if (backing.body.close_when_done) posix.system.close(backing.body.file);
        }

        fn destroyBacking(head: *Capability.Head) callconv(.c) void {
            const backing: *Backing = @fieldParentPtr("head", head);
            heap.global_gpa.destroy(backing);
        }

        pub const vtable: Capability.Head.VTable = .{
            .deinit_body = deinitBody,
            .destroy_backing = destroyBacking,
            .name = "file-descriptor",
        };
    };
};

test "file modes" {
    var interp = try common.testStart(std.testing.allocator);
    defer common.testFinish(&interp);

    // std.debug.print("{any}", .{File.FieldNameToO.get("RDONLY")});
    std.debug.print("{any}", .{try File.parseOpenMode(null, "RDWR TRUNC APPENDs")});
}

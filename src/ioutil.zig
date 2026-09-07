const builtin = @import("builtin");
const native_os = builtin.os.tag;

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const heap = @import("heap.zig");

pub threadlocal var local_stdout_fd: i32 = std.posix.STDOUT_FILENO;
pub threadlocal var local_stderr_fd: i32 = std.posix.STDERR_FILENO;

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

// Temp file stuff.
const prefix = "zicl.tmp.";
// `+ 16` for the 16 bytes of hex we generate after the prefix, so
// the name is unique.
const name_len = prefix.len + 16;

/// Lifetime of returned string may be from `environ`.
pub fn defaultTempPath(environ: *const std.process.Environ.Map) []const u8 {
    return switch (native_os) {
        .windows => environ.get("TMP") orelse environ.get("TEMP") orelse environ.get("LOCALAPPDATA") orelse "C:\\Windows\\Temp",
        else => environ.get("TMPDIR") orelse "/tmp",
    };
}

pub fn openDefaultTempDir(io: Io, environ: *const std.process.Environ.Map) !Io.Dir {
    const default_path = defaultTempPath(environ);
    if (default_path.len == 0 or !std.fs.path.isAbsolute(default_path)) return error.BadTempDir;

    return try Io.Dir.cwd().openDir(io, default_path, .{});
}

/// Uses Linux's O_TMPFILE flag to create a temporary file without a race
/// between file creation and unlinking.
fn openTmpfileLinux(dir_fd: std.posix.fd_t) !Io.File {
    const linux = std.os.linux;

    const flags: linux.O = .{
        .ACCMODE = .RDWR,
        .TMPFILE = true,
        .DIRECTORY = true,
        .CLOEXEC = true,
    };
    const rc = linux.openat(dir_fd, ".", flags, 0o600);
    return switch (std.posix.errno(rc)) {
        .SUCCESS => .{ .handle = @intCast(rc), .flags = .{ .nonblocking = false } },
        .OPNOTSUPP, .ISDIR, .PERM => error.TmpfileUnsupported,
        .NOENT, .NOTDIR => error.FileNotFound,
        .ACCES => error.AccessDenied,
        .NFILE => error.SystemFdQuotaExceeded,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NOSPC => error.NoSpaceLeft,
        .NOMEM => error.SystemResources,
        .ROFS => error.ReadOnlyFileSystem,
        else => |e| std.posix.unexpectedErrno(e),
    };
}

const w = std.os.windows;
/// Mostly LLM generated.
fn createDeleteOnCloseWindows(dir: w.HANDLE, name: w.UNICODE_STRING) !Io.File {
    const attr: w.OBJECT.ATTRIBUTES = .{
        .RootDirectory = dir,
        .ObjectName = &name,
        .Attributes = .{ .CASE_INSENSITIVE = false },
    };

    var handle: w.HANDLE = undefined;
    var iosb: w.IO_STATUS_BLOCK = undefined;
    const rc = w.ntdll.NtCreateFile(
        &handle,
        .{
            .SPECIFIC = .{ .FILE = .{
                .READ_DATA = true,
                .WRITE_DATA = true,
                .READ_ATTRIBUTES = true,
                .WRITE_ATTRIBUTES = true,
            } },
            // DELETE is required by MODE.DELETE_ON_CLOSE and by the
            // disposition call; SYNCHRONIZE by IO.SYNCHRONOUS_NONALERT.
            .STANDARD = .{ .RIGHTS = .{ .DELETE = true }, .SYNCHRONIZE = true },
        },
        &attr,
        &iosb,
        null,
        // Hints the cache manager not to flush a file we intend to discard.
        .{ .TEMPORARY = true },
        // DELETE must be shared or nothing can touch a delete-pending name.
        .{ .READ = true, .WRITE = true, .DELETE = true },
        .CREATE, // Fails on collision rather than opening.
        .{
            .NON_DIRECTORY_FILE = true,
            .IO = .SYNCHRONOUS_NONALERT,
            .DELETE_ON_CLOSE = true,
        },
        null,
        0,
    );
    switch (rc) {
        .SUCCESS => {},
        .OBJECT_NAME_COLLISION => return error.PathAlreadyExists,
        // A prior name is mid-deletion. Redrawing costs less than sleeping.
        .DELETE_PENDING => return error.PathAlreadyExists,
        .OBJECT_PATH_NOT_FOUND, .OBJECT_NAME_NOT_FOUND => return error.FileNotFound,
        .ACCESS_DENIED, .SHARING_VIOLATION => return error.AccessDenied,
        .DISK_FULL => return error.NoSpaceLeft,
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        else => return w.unexpectedStatus(rc),
    }
    errdefer w.CloseHandle(handle);

    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
}

pub fn createSelfDeletingFile(dir: Io.Dir, io: Io) !Io.File {
    if (native_os == .linux) {
        if (openTmpfileLinux(dir.handle)) |file| {
            return file;
        } else |err| switch (err) {
            error.TmpfileUnsupported => {
                // Fall through.
            },
            else => |e| return e,
        }
    }

    var temp_filename: [name_len:0]u8 = undefined;
    @memcpy(temp_filename[0..prefix.len], prefix);
    // The rest of the bytes are filled in the loop.

    var retries: u32 = 0;
    while (retries < 100) : (retries += 1) {
        var random_bytes: [8]u8 = undefined;
        io.random(&random_bytes);
        const as_hex = std.fmt.bytesToHex(random_bytes, .lower);
        @memcpy(temp_filename[prefix.len..][0..16], &as_hex);

        if (native_os == .windows) {
            return createDeleteOnCloseWindows(dir.handle, temp_filename[0..name_len]) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => |e| return e,
            };
        } else {
            const file = dir.createFile(io, &temp_filename, .{
                .read = true,
                .truncate = false,
                .exclusive = true,
                // No need for it to be visible to anyone but us.
                .permissions = @enumFromInt(0o600),
            }) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => |e| return e,
            };
            errdefer file.close(io);

            while (true) {
                switch (std.posix.errno(std.posix.system.unlinkat(dir.handle, &temp_filename, 0))) {
                    .SUCCESS => return,
                    .NOENT => {
                        // We still hold a handle on the temp file, so even if it was deleted,
                        // we can still use it. And we don't need to unlink it, since it was
                        // deleted.
                    },
                    .INTR => continue,
                    else => |e| return std.posix.unexpectedErrno(e),
                }
            }
            return file;
        }
    }
    return error.NoUniqueName;
}

fn countDirEntries(dir: Io.Dir, io: Io) !usize {
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |_| n += 1;
    return n;
}

test "self-deleting temp file has no name" {
    if (native_os == .windows) return error.SkipZigTest;

    const io = std.testing.io;
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();

    var tmpdir = std.testing.tmpDir(.{ .iterate = true });
    defer tmpdir.cleanup();

    const file = try createSelfDeletingFile(tmpdir.dir, io);
    try file.writeStreamingAll(io, "hello"); // Make sure we can write to this file.

    // We shouldn't see any files in tmpdir, since we unlinked it.
    if (native_os != .windows) try std.testing.expectEqual(@as(usize, 0), try countDirEntries(tmpdir.dir, io));

    file.close(io);
    // After closing we should definitely not see any tempfiles in the tempdir.
    try std.testing.expectEqual(@as(usize, 0), try countDirEntries(tmpdir.dir, io));
}

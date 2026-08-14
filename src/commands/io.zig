const std = @import("std");
const builtin = @import("builtin");

const ioutil = @import("../ioutil.zig");
const Capability = @import("../Capability.zig");
const capabilities = @import("../capabilities.zig");
const strutil = @import("../strutil.zig");

const common = @import("common.zig");
const exec = @import("exec.zig");
const heap = common.heap;
const objects = common.objects;
const ErrorDetails = common.ErrorDetails;
const Interp = common.Interp;
const Shimmerable = common.Shimmerable;
const registerCommand = common.registerCommand;
const memutil = common.memutil;

/// [puts]
///
/// `puts ?-nonewline? ?channel? string`. With two arguments left after the flag
/// the first is a channel, which is how the ambiguity with the flag is settled:
/// a bare `puts -nonewline foo` still writes `foo` to stdout.
pub fn putsCmd(interp: *Interp, args: []Shimmerable) !void {
    var rest = args[1..];

    // Compared through the value rather than its bytes, so a short string can be
    // matched without its rendering being materialized.
    const print_newline = if (rest.len > 1 and try rest[0].current().equalsString("-nonewline")) blk: {
        rest = rest[1..];
        break :blk false;
    } else true;

    if (rest.len > 2) {
        try interp.setResultString("wrong # args: should be \"puts ?-nonewline? ?channel? string\"");
        return error.EvalError;
    }

    // A capability always begins with '<', so a leading '-' here is a mistyped
    // option rather than a channel, and saying so beats complaining that the
    // option is not a capability.
    if (rest.len == 2 and std.mem.startsWith(u8, try rest[0].getString(), "-")) {
        try interp.setResultString("The second argument must be -nonewline");
        return error.EvalError;
    }

    const to_print = try rest[rest.len - 1].getString();

    if (rest.len == 2) {
        var det: ErrorDetails = undefined;
        const cap: *const Capability = try interp.wrapError(&det, Capability.shimmerFrom(&det, &rest[0]));
        const backing = try interp.wrapError(&det, cap.getBacking(capabilities.File.Backing, &det));
        const body: *capabilities.File = &backing.body;

        body.writeAll(to_print) catch |err| return writeError(interp, err);
        if (print_newline) body.writeAll("\n") catch |err| return writeError(interp, err);
        return;
    }

    const stdout = ioutil.getStdout();
    var buf: [64]u8 = undefined;
    var writer = stdout.writer(heap.global_io, &buf);

    writer.interface.writeAll(to_print) catch return writeError(interp, writer.err.?);
    if (print_newline) writer.interface.writeAll("\n") catch return writeError(interp, writer.err.?);
    writer.flush() catch return writeError(interp, writer.err.?);
}

fn writeError(interp: *Interp, err: anyerror) Interp.Error {
    try interp.setResultFormatted("failed to write: {}", .{err});
    return error.EvalError;
}

fn readError(interp: *Interp, err: anyerror) Interp.Error {
    try interp.setResultFormatted("failed to read: {}", .{err});
    return error.EvalError;
}

/// [read]
///
/// `read fileId`, reading everything from the current position to EOF. The
/// `numChars`/`-nonewline` forms aren't implemented yet (see `File.readAll`).
pub fn readCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    var det: ErrorDetails = undefined;
    const cap: *const Capability = try interp.wrapError(&det, Capability.shimmerFrom(&det, &args[1]));
    const backing = try interp.wrapError(&det, cap.getBacking(capabilities.File.Backing, &det));
    const body: *capabilities.File = &backing.body;

    const bytes = body.readAll() catch |err| return readError(interp, err);
    try interp.setResultStringOwning(bytes);
}

/// [pid]
///
/// With no arguments, this process. With a process capability, the pids of its
/// stages, for reaching a child through something other than the capability, a
/// signal being the usual reason. A stage already waited for contributes
/// nothing, its number having stopped meaning anything.
pub fn pidCmd(interp: *Interp, args: []Shimmerable) !void {
    if (args.len == 1) {
        interp.setResultInteger(@intCast(std.os.linux.getpid()));
        return;
    }

    var det: ErrorDetails = undefined;
    const cap = try interp.wrapError(&det, Capability.shimmerFrom(&det, &args[1]));
    const backing = try interp.wrapError(&det, cap.getBacking(capabilities.Process.Backing, &det));

    var pid_buffer: [exec.max_pipeline_stages]?std.process.Child.Id = undefined;
    const pids = backing.body.pids(&pid_buffer);

    var values: std.ArrayList(heap.Value) = .empty;
    defer values.deinit(heap.local_arena);
    for (pids) |maybe_pid| {
        if (maybe_pid) |pid| try values.append(heap.local_arena, objects.Integer.new(@intCast(pid)));
    }

    const list = try objects.List.new(values.items);
    interp.setResultOwning(list.asHead().asValue());
}

pub fn fileCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const Subcommands = enum {
        exists,
        dirname,
        tail,
        rootname,
        join,
        mkdir,
        size,
        readable,
        isdirectory,
        mtime,
        readlink,
        tempfile,
    };
    const Parser = objects.SubcommandParser(Subcommands, &.{
        .{ .variant = .exists, .usage = "name", .min_args = 1, .max_args = 1 },
        .{ .variant = .dirname, .usage = "name", .min_args = 1, .max_args = 1 },
        .{ .variant = .tail, .usage = "name", .min_args = 1, .max_args = 1 },
        .{ .variant = .rootname, .usage = "name", .min_args = 1, .max_args = 1 },
        .{ .variant = .join, .usage = "name ?name ...?", .min_args = 1, .max_args = null },
        .{ .variant = .mkdir, .usage = "dir", .min_args = 1, .max_args = 1 },
        .{ .variant = .size, .usage = "name", .min_args = 1, .max_args = 1 },
        .{ .variant = .readable, .usage = "name", .min_args = 1, .max_args = 1 },
        .{ .variant = .isdirectory, .usage = "name", .min_args = 1, .max_args = 1 },
        .{ .variant = .mtime, .usage = "name", .min_args = 1, .max_args = 1 },
        .{ .variant = .readlink, .usage = "name", .min_args = 1, .max_args = 1 },
        .{ .variant = .tempfile, .usage = "?name?", .min_args = 0, .max_args = 1 },
    });

    var det: ErrorDetails = undefined;
    const subcommand: Subcommands = try interp.wrapError(&det, Parser.parse(&det, args));

    switch (subcommand) {
        .exists => {
            const path = try args[2].getString();
            const exists = blk: {
                std.Io.Dir.accessAbsolute(heap.global_io, path, .{}) catch |err| switch (err) {
                    error.FileNotFound => break :blk false,
                    else => {
                        try interp.setResultFormatted("could not access file: {s}", .{@errorName(err)});
                        return error.EvalError;
                    },
                };
                break :blk true;
            };
            interp.setResultBoolean(exists);
        },
        .dirname => {
            const path = try args[2].getString();
            const dir = std.Io.Dir.path.dirname(path) orelse ".";
            try interp.setResultString(dir);
        },
        .tail => {
            const path = try args[2].getString();
            const base = std.Io.Dir.path.basename(path);
            try interp.setResultString(base);
        },
        .rootname => {
            const path = try args[2].getString();
            const ext = std.Io.Dir.path.extension(path);
            const root = if (ext.len > 0) path[0 .. path.len - ext.len] else path;
            try interp.setResultString(root);
        },
        .join => {
            var path_parts = try std.ArrayList([]const u8).initCapacity(heap.local_arena, args.len - 2);
            for (args[2..]) |arg| {
                path_parts.appendAssumeCapacity(try arg.getString());
            }
            try interp.setResultStringOwning(try std.Io.Dir.path.joinZ(heap.global_gpa, path_parts.items));
        },
        .mkdir => {
            const path = try args[2].getString();
            std.Io.Dir.cwd().createDir(heap.global_io, path, .default_dir) catch |err| {
                try interp.setResultFormatted("could not create directory: {s}", .{@errorName(err)});
                return error.EvalError;
            };
            interp.setEmptyResult();
        },
        .size => {
            const path = try args[2].getString();
            const stat = std.Io.Dir.cwd().statFile(heap.global_io, path, .{}) catch |err| {
                try interp.setResultFormatted("could not stat file: {s}", .{@errorName(err)});
                return error.EvalError;
            };
            interp.setResultInteger(@intCast(stat.size));
        },
        .readable => {
            const path = try args[2].getString();
            const readable = blk: {
                std.Io.Dir.accessAbsolute(heap.global_io, path, .{ .read = true }) catch |err| switch (err) {
                    error.FileNotFound => break :blk false,
                    else => {
                        try interp.setResultFormatted("could not access file: {s}", .{@errorName(err)});
                        return error.EvalError;
                    },
                };
                break :blk true;
            };
            interp.setResultBoolean(readable);
        },
        .isdirectory => {
            const path = try args[2].getString();
            const is_dir = blk: {
                const stat = std.Io.Dir.cwd().statFile(heap.global_io, path, .{}) catch |err| switch (err) {
                    error.FileNotFound => break :blk false,
                    else => {
                        try interp.setResultFormatted("could not stat file: {s}", .{@errorName(err)});
                        return error.EvalError;
                    },
                };
                break :blk stat.kind == .directory;
            };
            interp.setResultBoolean(is_dir);
        },
        .mtime => {
            const path = try args[2].getString();
            const stat = std.Io.Dir.cwd().statFile(heap.global_io, path, .{}) catch |err| {
                try interp.setResultFormatted("could not stat file: {s}", .{@errorName(err)});
                return error.EvalError;
            };
            // Convert to millseconds first so we should fit within the f64's mantissa pretty well.
            const mtime_ms: f64 = @floatFromInt(stat.mtime.toMilliseconds());
            interp.setResultFloat(mtime_ms / 1000.0);
        },
        .readlink => {
            const path = try args[2].getString();
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const len = std.Io.Dir.cwd().readLink(heap.global_io, path, &buf) catch |err| {
                try interp.setResultFormatted("could not read link: {s}", .{@errorName(err)});
                return error.EvalError;
            };
            try interp.setResultString(buf[0..len]);
        },
        .tempfile => {
            const template = if (args.len > 2) try args[2].getString() else null;

            var temp = createTempFile(template) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NoUniqueName => {
                    try interp.setResultString("could not create a unique temporary file");
                    return error.EvalError;
                },
                else => {
                    try interp.setResultFormatted("could not create temp file: {s}", .{@errorName(err)});
                    return error.EvalError;
                },
            };
            temp.file.close(heap.global_io);
            try interp.setResultStringOwning(temp.path);
        },
    }
}

/// A temporary file, open and named. The caller owns both: close the file, and
/// free the path with `heap.global_gpa`.
pub const TempFile = struct {
    file: std.Io.File,
    path: [:0]u8,
};

/// Creates a fresh temporary file, open for reading and writing. `template`
/// names where it goes: a trailing `XXXXXX` is replaced with random characters,
/// and anything else is a prefix. With no template the file lands in the
/// platform's temporary directory under `tcl.tmp.`.
///
/// Created exclusively, since a name that merely looked free when it was
/// generated could be claimed before it was opened.
pub fn createTempFile(template: ?[]const u8) !TempFile {
    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(heap.global_gpa);

    if (template) |t| {
        try path_buf.appendSlice(heap.global_gpa, t);
    } else {
        const tmpdir = switch (builtin.os.tag) {
            .windows => blk: {
                const env_vars = &[_][]const u8{ "TMP", "TEMP", "LOCALAPPDATA", "USERPROFILE" };
                for (env_vars) |name| {
                    if (std.c.getenv(name.ptr)) |val| {
                        const slice = std.mem.span(val);
                        if (slice.len > 0) break :blk slice;
                    }
                }
                break :blk "C:\\Windows\\Temp";
            },
            else => blk: {
                if (std.c.getenv("TMPDIR")) |val| {
                    const slice = std.mem.span(val);
                    if (slice.len > 0) break :blk slice;
                }
                break :blk "/tmp";
            },
        };
        try path_buf.appendSlice(heap.global_gpa, tmpdir);
        if (!std.mem.endsWith(u8, path_buf.items, std.fs.path.sep_str)) {
            try path_buf.append(heap.global_gpa, std.fs.path.sep);
        }
        try path_buf.appendSlice(heap.global_gpa, "tcl.tmp.");
    }

    const base_len = path_buf.items.len;
    const has_template = if (template) |val| std.mem.endsWith(u8, val, "XXXXXX") else false;
    const suffix_start = if (has_template) base_len - 6 else base_len;
    const suffix_len: usize = if (has_template) 6 else 8;

    if (!has_template) {
        try path_buf.resize(heap.global_gpa, base_len + suffix_len);
    }

    const alnum = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    var random_bytes: [8]u8 = undefined;

    var retries: u32 = 0;
    const max_retries = 100;
    while (retries < max_retries) : (retries += 1) {
        heap.global_io.random(&random_bytes);

        for (0..suffix_len) |i| {
            path_buf.items[suffix_start + i] = alnum[random_bytes[i] % alnum.len];
        }

        const file = std.Io.Dir.createFileAbsolute(heap.global_io, path_buf.items, .{
            .read = true,
            .truncate = false,
            .exclusive = true,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |other| return other,
        };
        errdefer file.close(heap.global_io);

        return .{ .file = file, .path = try path_buf.toOwnedSliceSentinel(heap.global_gpa, 0) };
    }

    return error.NoUniqueName;
}

/// Whether the platform lets us ask for `O_APPEND`.
///
/// `std.Io` does not expose it, so the flag has to be set through the posix
/// layer, which only exists on platforms that have one. Checked by looking for
/// the field rather than by naming operating systems, since the flag is the
/// thing actually needed.
const has_posix_append = switch (@typeInfo(std.posix.O)) {
    .@"struct" => @hasField(std.posix.O, "APPEND"),
    else => false,
};

/// Opens `path` for appending, creating it if it is not there.
///
/// With `O_APPEND` every write moves to the true end of the file atomically, so
/// two writers appending to one file cannot land on top of each other. Without
/// it the cursor is placed at the end once, at open, and goes stale as soon as
/// anything else writes; a caller wanting a shared log then has to serialize for
/// itself.
pub fn openForAppend(path: []const u8, readable: bool) !std.Io.File {
    if (has_posix_append) {
        // Bypasses `heap.global_io` for this one call, which is the price of a
        // flag the `Io` layer has no way to pass along.
        const handle = try std.posix.openat(std.posix.AT.FDCWD, path, .{
            .ACCMODE = if (readable) .RDWR else .WRONLY,
            .CREAT = true,
            .APPEND = true,
        }, 0o666);
        // `nonblocking` has to describe the descriptor rather than be a request:
        // `O_NONBLOCK` is not set above, so anything reading this field would be
        // misled by saying otherwise.
        return .{ .handle = handle, .flags = .{ .nonblocking = false } };
    }

    // Turning truncation off keeps what is already there, but leaves the cursor
    // at the start, so it has to be moved by hand.
    const file = try std.Io.Dir.cwd().createFile(heap.global_io, path, .{
        .truncate = false,
        .read = readable,
    });
    errdefer file.close(heap.global_io);

    const size = (try file.stat(heap.global_io)).size;
    var seeker = file.writerStreaming(heap.global_io, &.{});
    try seeker.seekToUnbuffered(size);
    return file;
}

const FileOpenMode = objects.EnumConstructor(capabilities.File.Mode, false);

/// [fopen]
pub fn fopenCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const path = try args[1].getString();

    var det: ErrorDetails = undefined;
    const mode: capabilities.File.Mode =
        if (args.len == 3) try interp.wrapError(&det, FileOpenMode.get(&det, &args[2])) else .r;

    const cap = capabilities.File.open(path, mode) catch |err| {
        try interp.setResultFormatted("error while opening file: {}", .{err});
        return;
    };
    interp.setResultOwning(cap.asHead().asValue());
}

fn hasGlobMeta(segment: []const u8) bool {
    for (segment) |c| {
        if (c == '*' or c == '?' or c == '[') return true;
    }
    return false;
}

fn joinPath(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, dir, ".")) return try allocator.dupe(u8, name);
    if (std.mem.eql(u8, dir, "/")) return try std.fmt.allocPrint(allocator, "/{s}", .{name});
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
}

/// Matches `pattern` against the filesystem, appending every hit to
/// `results`. The pattern is split on '/' and matched one path segment at a
/// time, so a wildcard never crosses a directory boundary, matching both
/// shell globs and Tcl's own [glob].
fn globPattern(pattern: []const u8, results: *std.ArrayList([]const u8)) !void {
    const is_absolute = pattern.len > 0 and pattern[0] == '/';

    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(heap.local_arena);
    var seg_iter = std.mem.splitScalar(u8, pattern, '/');
    while (seg_iter.next()) |seg| {
        if (seg.len == 0) continue; // Collapses "//" and a leading/trailing '/'.
        try segments.append(heap.local_arena, seg);
    }
    if (segments.items.len == 0) return;

    var candidates: std.ArrayList([]const u8) = .empty;
    defer candidates.deinit(heap.local_arena);
    try candidates.append(heap.local_arena, if (is_absolute) "/" else ".");

    for (segments.items, 0..) |segment, seg_i| {
        const is_last = seg_i == segments.items.len - 1;
        var next_candidates: std.ArrayList([]const u8) = .empty;

        for (candidates.items) |dir_path| {
            if (hasGlobMeta(segment)) {
                var dir = std.Io.Dir.cwd().openDir(heap.global_io, dir_path, .{ .iterate = true }) catch continue;
                defer dir.close(heap.global_io);

                var it = dir.iterate();
                while (it.next(heap.global_io) catch null) |entry| {
                    // A dotfile only matches a pattern that itself starts with
                    // '.', the same as shell globs and Tcl's [glob].
                    if (entry.name.len > 0 and entry.name[0] == '.' and
                        !(segment.len > 0 and segment[0] == '.')) continue;
                    if (!strutil.globMatch(segment, entry.name, false)) continue;

                    try next_candidates.append(heap.local_arena, try joinPath(heap.local_arena, dir_path, entry.name));
                }
            } else {
                const full = try joinPath(heap.local_arena, dir_path, segment);
                const stat = std.Io.Dir.cwd().statFile(heap.global_io, full, .{}) catch continue;
                if (!is_last and stat.kind != .directory) continue;
                try next_candidates.append(heap.local_arena, full);
            }
        }

        candidates.deinit(heap.local_arena);
        candidates = next_candidates;
    }

    for (candidates.items) |path| try results.append(heap.local_arena, path);
}

/// [glob]
///
/// `glob ?-nocomplain? ?--? pattern ?pattern ...?`. Only `-nocomplain` is
/// implemented; `-directory`/`-types`/`-join`/etc. aren't, since nothing in
/// this codebase's boot path needs them.
pub fn globCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    var nocomplain = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (try args[i].current().equalsString("-nocomplain")) {
            nocomplain = true;
        } else if (try args[i].current().equalsString("--")) {
            i += 1;
            break;
        } else break;
    }
    if (i >= args.len) return error.WrongUsage;

    var results: std.ArrayList([]const u8) = .empty;
    defer results.deinit(heap.local_arena);

    for (args[i..]) |*pattern_arg| {
        const pattern = try pattern_arg.current().getString();
        try globPattern(pattern, &results);
    }

    if (results.items.len == 0 and !nocomplain) {
        try interp.setResultString("no files matched glob pattern");
        return error.EvalError;
    }

    const list = try objects.List.newWithCapacity(&.{}, results.items.len);
    errdefer list.asHead().release();
    for (results.items) |path| {
        list.appendAssumeCapacityOwning(try objects.String.newValue(path));
    }
    interp.setResultOwning(list.asHead().asValue());
}

pub fn registerCommands(interp: *Interp) !void {
    try registerCommand(interp, "puts", putsCmd, "?-nonewline? ?channel? string", 1, 3);
    try registerCommand(interp, "pid", pidCmd, "?process?", 0, 1);
    try registerCommand(interp, "file", fileCmd, "subcommand ?arg ...?", 1, null);
    try registerCommand(interp, "fopen", fopenCmd, "path ?mode?", 1, 2);
    try registerCommand(interp, "read", readCmd, "fileId", 1, 1);
    try registerCommand(interp, "glob", globCmd, "?-nocomplain? ?--? pattern ?pattern ...?", 1, null);
}

const testing = std.testing;

/// Run `script` with stdout redirected into a temporary file, and return what it
/// wrote. The caller owns the returned bytes.
///
/// A file rather than a pipe, because [puts] holds the stdout lock for the whole
/// write and a pipe would deadlock a reader waiting on the other end.
fn captureStdout(interp: *Interp, script: []const u8) ![]u8 {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(heap.global_io, "stdout", .{});
    {
        defer file.close(heap.global_io);
        const saved_fd = ioutil.local_stdout_fd;
        defer ioutil.local_stdout_fd = saved_fd;
        ioutil.local_stdout_fd = file.handle;

        try interp.testExpectScriptResult("", script);
    }

    return try tmp.dir.readFileAlloc(heap.global_io, "stdout", heap.global_gpa, .unlimited);
}

fn testPutsWritesALineToStdout(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    const written = try captureStdout(&interp, "puts hello");
    defer heap.global_gpa.free(written);
    try testing.expectEqualStrings("hello\n", written);
}

test "puts writes a line to stdout" {
    try memutil.checkAllocationFailures(.exhaustive, testPutsWritesALineToStdout, .{});
}

fn testPutsNonewlineOmitsTheTrailingNewline(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    const written = try captureStdout(&interp, "puts -nonewline hello");
    defer heap.global_gpa.free(written);
    try testing.expectEqualStrings("hello", written);
}

test "puts -nonewline omits the trailing newline" {
    try memutil.checkAllocationFailures(.exhaustive, testPutsNonewlineOmitsTheTrailingNewline, .{});
}

fn testPutsRejectsAnUnknownOption(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptError(
        error.EvalError,
        "The second argument must be -nonewline",
        "puts -bogus hello",
    );
}

test "puts rejects an unknown option" {
    try memutil.checkAllocationFailures(.exhaustive, testPutsRejectsAnUnknownOption, .{});
}

fn testPidReportsThisProcess(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    var expected: [32]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&expected, "{}", .{std.os.linux.getpid()});
    try interp.testExpectScriptResult(rendered, "pid");
}

test "pid reports this process" {
    try memutil.checkAllocationFailures(.exhaustive, testPidReportsThisProcess, .{});
}

fn testFileSplitsAPathIntoItsParts(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("/usr/lib", "file dirname /usr/lib/thing.so");
    try interp.testExpectScriptResult("thing.so", "file tail /usr/lib/thing.so");
    try interp.testExpectScriptResult("/usr/lib/thing", "file rootname /usr/lib/thing.so");
    // A path with no extension is its own root.
    try interp.testExpectScriptResult("/usr/lib/thing", "file rootname /usr/lib/thing");
    // A bare name has no directory, which Tcl reports as the current one.
    try interp.testExpectScriptResult(".", "file dirname thing.so");
}

test "file splits a path into its parts" {
    try memutil.checkAllocationFailures(.exhaustive, testFileSplitsAPathIntoItsParts, .{});
}

fn testFileJoinBuildsAPathFromParts(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("a/b/c", "file join a b c");
    try interp.testExpectScriptResult("a", "file join a");
}

test "file join builds a path from parts" {
    try memutil.checkAllocationFailures(.exhaustive, testFileJoinBuildsAPathFromParts, .{});
}

fn testFileExistsDistinguishesPresentFromAbsentPaths(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("true", "file exists /");
    try interp.testExpectScriptResult("true", "file isdirectory /");
    try interp.testExpectScriptResult("false", "file exists /nonexistent-zicl-test-path");

    // The spelling does not leak into conditionals.
    try interp.testExpectScriptResult("yes", "if {[file exists /]} { return yes } else { return no }");
}

test "file exists distinguishes present from absent paths" {
    try memutil.checkAllocationFailures(.exhaustive, testFileExistsDistinguishesPresentFromAbsentPaths, .{});
}

fn testFileTempfileCreatesAFileAndReturnsItsPath(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // The result is borrowed from the interpreter, so copy the path before the
    // next script overwrites it.
    const result = try interp.testRunScript("set path [file tempfile]");
    const path = try heap.global_gpa.dupe(u8, try result.getString());
    defer heap.global_gpa.free(path);
    defer std.Io.Dir.deleteFileAbsolute(heap.global_io, path) catch {};

    try testing.expect(path.len > 0);
    try testing.expect(std.mem.indexOf(u8, path, "tcl.tmp.") != null);

    // The file it names really is there.
    try interp.testExpectScriptResult("true", "file exists $path");
}

test "file tempfile creates a file and returns its path" {
    try memutil.checkAllocationFailures(.exhaustive, testFileTempfileCreatesAFileAndReturnsItsPath, .{});
}

fn testFileReportsAUsageErrorForABadSubcommand(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try memutil.expectErrorOrOom(error.EvalError, interp.testRunScript("file bogus /"));
}

test "file reports a usage error for a bad subcommand" {
    try memutil.checkAllocationFailures(.exhaustive, testFileReportsAUsageErrorForABadSubcommand, .{});
}

fn testFileCapability(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(heap.global_io, "foo.txt", .{});
    file.close(heap.global_io);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_path = path_buffer[0..(try tmp.dir.realPathFile(heap.global_io, "foo.txt", &path_buffer))];

    const script = try std.fmt.allocPrint(ta,
        \\set fd [fopen {s} w]
        \\puts $fd "first line"
        \\puts -nonewline $fd "no newline"
        \\close $fd
        \\set fd
    , .{absolute_path});
    defer ta.free(script);

    // Borrowed, since `testRunScript` hands back the interpreter's result
    // without taking a reference, and the failing script at the end of this
    // test replaces that result while `name` below is still in use.
    const handle = (try interp.testRunScript(script)).borrow();
    defer handle.release();

    // The capability renders as a delimited URL naming this machine.
    const name = try handle.getString();
    try testing.expect(std.mem.startsWith(u8, name, "<" ++ Capability.scheme));
    try testing.expect(std.mem.indexOf(u8, name, "/file-handle/") != null);

    const written = try std.Io.Dir.cwd().readFileAlloc(heap.global_io, absolute_path, ta, .limited(1024));
    defer ta.free(written);
    try testing.expectEqualStrings("first line\nno newline", written);

    // Closing takes the name out of circulation, so writing through it fails as
    // an unknown name rather than as something reporting itself closed.
}

test "file capability round trip" {
    try memutil.checkAllocationFailures(.exhaustive, testFileCapability, .{});
}

fn testReadSlurpsTheRemainderOfAFile(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(heap.global_io, "foo.txt", .{});
    try file.writeStreamingAll(heap.global_io, "first line\nsecond line");
    file.close(heap.global_io);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_path = path_buffer[0..(try tmp.dir.realPathFile(heap.global_io, "foo.txt", &path_buffer))];

    const script = try std.fmt.allocPrint(ta,
        \\set fd [fopen {s} r]
        \\set contents [read $fd]
        \\close $fd
        \\set contents
    , .{absolute_path});
    defer ta.free(script);

    try interp.testExpectScriptResult("first line\nsecond line", script);
}

test "read slurps the remainder of a file" {
    try memutil.checkAllocationFailures(.exhaustive, testReadSlurpsTheRemainderOfAFile, .{});
}

fn testReadResumesFromWhereAPriorReadLeftOff(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(heap.global_io, "foo.txt", .{});
    try file.writeStreamingAll(heap.global_io, "hello world");
    file.close(heap.global_io);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_path = path_buffer[0..(try tmp.dir.realPathFile(heap.global_io, "foo.txt", &path_buffer))];

    // A second [read] on the same handle picks up at EOF, since it's reading
    // through the same open file descriptor rather than reopening the path.
    const script = try std.fmt.allocPrint(ta,
        \\set fd [fopen {s} r]
        \\set first [read $fd]
        \\set second [read $fd]
        \\close $fd
        \\list $first $second
    , .{absolute_path});
    defer ta.free(script);

    try interp.testExpectScriptResult("{hello world} {}", script);
}

test "read resumes from where a prior read left off" {
    try memutil.checkAllocationFailures(.exhaustive, testReadResumesFromWhereAPriorReadLeftOff, .{});
}

fn testWritingToAClosedCapabilityReportsItAsStale(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(heap.global_io, "foo.txt", .{});
    file.close(heap.global_io);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_path = path_buffer[0..(try tmp.dir.realPathFile(heap.global_io, "foo.txt", &path_buffer))];

    const script = try std.fmt.allocPrint(testing.allocator,
        \\set fd [fopen {s} w]
        \\close $fd
        \\set fd
    , .{absolute_path});
    defer testing.allocator.free(script);

    const handle = (try interp.testRunScript(script)).borrow();
    defer handle.release();

    // Closing takes the name out of circulation, so writing through it fails as
    // an unknown name rather than as something reporting itself closed.
    const stale_message = try std.fmt.allocPrint(
        testing.allocator,
        "capability \"{s}\" is stale",
        .{try handle.getString()},
    );
    defer testing.allocator.free(stale_message);
    try interp.testExpectScriptError(error.EvalError, stale_message, "puts $fd x");
}

test "writing to a closed capability reports it as stale" {
    try memutil.checkAllocationFailures(.exhaustive, testWritingToAClosedCapabilityReportsItAsStale, .{});
}

fn testGlobMatchesFilesInADirectory(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "a.folk", "b.folk", "c.txt" }) |name| {
        const f = try tmp.dir.createFile(heap.global_io, name, .{});
        f.close(heap.global_io);
    }
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buffer[0..(try tmp.dir.realPath(heap.global_io, &path_buffer))];

    const script = try std.fmt.allocPrint(ta, "lsort [glob {s}/*.folk]", .{dir_path});
    defer ta.free(script);

    const expected = try std.fmt.allocPrint(ta, "{s}/a.folk {s}/b.folk", .{ dir_path, dir_path });
    defer ta.free(expected);
    try interp.testExpectScriptResult(expected, script);
}

test "glob matches files in a directory" {
    try memutil.checkAllocationFailures(.exhaustive, testGlobMatchesFilesInADirectory, .{});
}

fn testGlobMatchesADirectoryWildcardSegment(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(heap.global_io, "sub", .default_dir);
    var sub = try tmp.dir.openDir(heap.global_io, "sub", .{});
    defer sub.close(heap.global_io);
    const f = try sub.createFile(heap.global_io, "prog.folk", .{});
    f.close(heap.global_io);

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buffer[0..(try tmp.dir.realPath(heap.global_io, &path_buffer))];

    // Mirrors boot.folk's `glob -nocomplain builtin-programs/*/*.folk`: a
    // wildcard directory segment followed by a wildcard filename segment.
    const script = try std.fmt.allocPrint(ta, "glob -nocomplain {s}/*/*.folk", .{dir_path});
    defer ta.free(script);

    const expected = try std.fmt.allocPrint(ta, "{s}/sub/prog.folk", .{dir_path});
    defer ta.free(expected);
    try interp.testExpectScriptResult(expected, script);
}

test "glob matches a directory wildcard segment" {
    try memutil.checkAllocationFailures(.exhaustive, testGlobMatchesADirectoryWildcardSegment, .{});
}

fn testGlobNocomplainReturnsEmptyRatherThanErroring(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("", "glob -nocomplain /nonexistent-dir-xyz/*.folk");
}

test "glob -nocomplain returns empty rather than erroring" {
    try memutil.checkAllocationFailures(.exhaustive, testGlobNocomplainReturnsEmptyRatherThanErroring, .{});
}

fn testGlobWithoutNocomplainErrorsOnNoMatches(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptError(error.EvalError, "no files matched glob pattern", "glob /nonexistent-dir-xyz/*.folk");
}

test "glob without -nocomplain errors on no matches" {
    try memutil.checkAllocationFailures(.exhaustive, testGlobWithoutNocomplainErrorsOnNoMatches, .{});
}

const std = @import("std");
const builtin = @import("builtin");

const ioutil = @import("../ioutil.zig");

const common = @import("common.zig");
const heap = common.heap;
const objects = common.objects;
const ErrorDetails = common.ErrorDetails;
const Interp = common.Interp;
const Shimmerable = common.Shimmerable;
const registerCommand = common.registerCommand;

/// [puts]
pub fn putsCmd(interp: *Interp, args: []Shimmerable) !void {
    const to_print, const print_newline = blk: {
        if (args.len == 3) {
            const first_arg_str = try args[1].getString();
            if (!std.mem.eql(u8, first_arg_str, "-nonewline")) {
                try interp.setResultString("The second argument must be -nonewline");
                return error.EvalError;
            } else {
                break :blk .{ try args[2].getString(), false };
            }
        } else {
            break :blk .{ try args[1].getString(), true };
        }
    };

    const stdout = ioutil.lockStdout();
    defer ioutil.unlockStdout();
    var buf: [64]u8 = undefined;
    var writer = stdout.writer(heap.global_io, &buf);
    writer.interface.print("{s}", .{to_print}) catch {
        try interp.setResultFormatted("failed to print: {}", .{writer.err.?});
        return error.EvalError;
    };
    if (print_newline) {
        writer.interface.writeAll("\n") catch {
            try interp.setResultFormatted("failed to print: {}", .{writer.err.?});
            return error.EvalError;
        };
    }
    writer.flush() catch {
        try interp.setResultFormatted("failed to print: {}", .{writer.err.?});
        return error.EvalError;
    };
}

/// [pid]
pub fn pidCmd(interp: *Interp, args: []Shimmerable) !void {
    if (args.len != 1) {
        try interp.setResultString("wrong # args: should be \"pid\"");
        return error.EvalError;
    }
    try interp.setResultInteger(@intCast(std.os.linux.getpid()));
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
            // The parts are scratch that dies with the command, so they go in the
            // arena; the joined path becomes the result, so it is owned and moved.
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
            try interp.setResultInteger(@intCast(stat.size));
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
                    else => {
                        try interp.setResultFormatted("could not create temp file: {s}", .{@errorName(err)});
                        return error.EvalError;
                    },
                };
                defer file.close(heap.global_io);

                // The buffer already holds exactly the result, so move it rather
                // than copying. `toOwnedSliceSentinel` empties the list, which
                // leaves the `defer deinit` above a no-op.
                try interp.setResultStringOwning(try path_buf.toOwnedSliceSentinel(heap.global_gpa, 0));
                return;
            }

            try interp.setResultString("could not create a unique temporary file");
            return error.EvalError;
        },
    }
}

pub fn registerCommands(interp: *Interp) !void {
    try registerCommand(interp, "puts", putsCmd, "?-nonewline? string", 1, 2, null);
    try registerCommand(interp, "pid", pidCmd, "", 0, 0, null);
    try registerCommand(interp, "file", fileCmd, "subcommand ?arg ...?", 1, null, null);
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
        const saved_fd = ioutil.global_stdout_fd.swap(file.handle, .monotonic);
        // Restore even when the script fails, or the rest of the suite would
        // write into a closed descriptor.
        defer _ = ioutil.global_stdout_fd.swap(saved_fd, .monotonic);

        try interp.testExpectScriptResult("", script);
    }

    return try tmp.dir.readFileAlloc(heap.global_io, "stdout", heap.global_gpa, .unlimited);
}

test "puts writes a line to stdout" {
    var interp = try common.testStart(testing.allocator);
    defer common.testFinish(&interp);

    const written = try captureStdout(&interp, "puts hello");
    defer heap.global_gpa.free(written);
    try testing.expectEqualStrings("hello\n", written);
}

test "puts -nonewline omits the trailing newline" {
    var interp = try common.testStart(testing.allocator);
    defer common.testFinish(&interp);

    const written = try captureStdout(&interp, "puts -nonewline hello");
    defer heap.global_gpa.free(written);
    try testing.expectEqualStrings("hello", written);
}

test "puts rejects an unknown option" {
    var interp = try common.testStart(testing.allocator);
    defer common.testFinish(&interp);

    try interp.testExpectScriptError(
        error.EvalError,
        "The second argument must be -nonewline",
        "puts -bogus hello",
    );
}

test "pid reports this process" {
    var interp = try common.testStart(testing.allocator);
    defer common.testFinish(&interp);

    var expected: [32]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&expected, "{}", .{std.os.linux.getpid()});
    try interp.testExpectScriptResult(rendered, "pid");
}

test "file splits a path into its parts" {
    var interp = try common.testStart(testing.allocator);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("/usr/lib", "file dirname /usr/lib/thing.so");
    try interp.testExpectScriptResult("thing.so", "file tail /usr/lib/thing.so");
    try interp.testExpectScriptResult("/usr/lib/thing", "file rootname /usr/lib/thing.so");
    // A path with no extension is its own root.
    try interp.testExpectScriptResult("/usr/lib/thing", "file rootname /usr/lib/thing");
    // A bare name has no directory, which Tcl reports as the current one.
    try interp.testExpectScriptResult(".", "file dirname thing.so");
}

test "file join builds a path from parts" {
    var interp = try common.testStart(testing.allocator);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("a/b/c", "file join a b c");
    try interp.testExpectScriptResult("a", "file join a");
}

test "file exists distinguishes present from absent paths" {
    var interp = try common.testStart(testing.allocator);
    defer common.testFinish(&interp);

    // These render as "true"/"false" rather than Tcl's "1"/"0", deliberately:
    // mixing booleans and numbers is an anti-pattern, so zicl keeps them
    // distinct. Tcl's boolean parsing accepts both spellings, so the difference
    // only shows when a script prints or string-compares the value.
    try interp.testExpectScriptResult("true", "file exists /");
    try interp.testExpectScriptResult("true", "file isdirectory /");
    try interp.testExpectScriptResult("false", "file exists /nonexistent-zicl-test-path");

    // The spelling does not leak into conditionals.
    try interp.testExpectScriptResult("yes", "if {[file exists /]} { return yes } else { return no }");
}

test "file tempfile creates a file and returns its path" {
    var interp = try common.testStart(testing.allocator);
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

test "file reports a usage error for a bad subcommand" {
    var interp = try common.testStart(testing.allocator);
    defer common.testFinish(&interp);

    try testing.expectError(error.EvalError, interp.testRunScript("file bogus /"));
}

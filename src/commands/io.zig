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
    var writer = stdout.writer(Heap.global_io, &buf);
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
    const Parser = objutil.SubcommandParser(Subcommands, &.{
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

    var det: objutil.ErrorDetails = undefined;
    const subcommand: Subcommands = try interp.wrapError(&det, Parser.parse(&det, args));

    switch (subcommand) {
        .exists => {
            const path = try args[2].getString();
            const exists = blk: {
                std.Io.Dir.accessAbsolute(Heap.global_io, path, .{}) catch |err| switch (err) {
                    error.FileNotFound => break :blk false,
                    else => {
                        try interp.setResultFormatted("could not access file: {s}", .{@errorName(err)});
                        return error.EvalError;
                    },
                };
                break :blk true;
            };
            try interp.setResultBoolean(exists);
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
            var path_parts: std.ArrayList([]const u8) = .empty;
            defer path_parts.deinit(Heap.global_gpa);
            for (args[2..]) |arg| {
                try path_parts.append(Heap.global_gpa, try arg.getString());
            }
            const joined = try std.Io.Dir.path.join(Heap.global_gpa, path_parts.items);
            defer Heap.global_gpa.free(joined);
            try interp.setResultString(joined);
        },
        .mkdir => {
            const path = try args[2].getString();
            std.Io.Dir.cwd().createDir(Heap.global_io, path, .default_dir) catch |err| {
                try interp.setResultFormatted("could not create directory: {s}", .{@errorName(err)});
                return error.EvalError;
            };
            interp.setEmptyResult();
        },
        .size => {
            const path = try args[2].getString();
            const stat = std.Io.Dir.cwd().statFile(Heap.global_io, path, .{}) catch |err| {
                try interp.setResultFormatted("could not stat file: {s}", .{@errorName(err)});
                return error.EvalError;
            };
            try interp.setResultInteger(@intCast(stat.size));
        },
        .readable => {
            const path = try args[2].getString();
            const readable = blk: {
                std.Io.Dir.accessAbsolute(Heap.global_io, path, .{ .read = true }) catch |err| switch (err) {
                    error.FileNotFound => break :blk false,
                    else => {
                        try interp.setResultFormatted("could not access file: {s}", .{@errorName(err)});
                        return error.EvalError;
                    },
                };
                break :blk true;
            };
            try interp.setResultBoolean(readable);
        },
        .isdirectory => {
            const path = try args[2].getString();
            const is_dir = blk: {
                const stat = std.Io.Dir.cwd().statFile(Heap.global_io, path, .{}) catch |err| switch (err) {
                    error.FileNotFound => break :blk false,
                    else => {
                        try interp.setResultFormatted("could not stat file: {s}", .{@errorName(err)});
                        return error.EvalError;
                    },
                };
                break :blk stat.kind == .directory;
            };
            try interp.setResultBoolean(is_dir);
        },
        .mtime => {
            const path = try args[2].getString();
            const stat = std.Io.Dir.cwd().statFile(Heap.global_io, path, .{}) catch |err| {
                try interp.setResultFormatted("could not stat file: {s}", .{@errorName(err)});
                return error.EvalError;
            };
            // Convert to millseconds first so we should fit within the f64's mantissa pretty well.
            const mtime_ms: f64 = @floatFromInt(stat.mtime.toMilliseconds());
            try interp.setResultFloat(mtime_ms / 1000.0);
        },
        .readlink => {
            const path = try args[2].getString();
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const len = std.Io.Dir.cwd().readLink(Heap.global_io, path, &buf) catch |err| {
                try interp.setResultFormatted("could not read link: {s}", .{@errorName(err)});
                return error.EvalError;
            };
            try interp.setResultString(buf[0..len]);
        },
        .tempfile => {
            const template = if (args.len > 2) try args[2].getString() else null;

            var path_buf: std.ArrayList(u8) = .empty;
            defer path_buf.deinit(Heap.global_gpa);

            if (template) |t| {
                try path_buf.appendSlice(Heap.global_gpa, t);
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
                try path_buf.appendSlice(Heap.global_gpa, tmpdir);
                if (!std.mem.endsWith(u8, path_buf.items, std.fs.path.sep_str)) {
                    try path_buf.append(Heap.global_gpa, std.fs.path.sep);
                }
                try path_buf.appendSlice(Heap.global_gpa, "tcl.tmp.");
            }

            const base_len = path_buf.items.len;
            const has_template = if (template) |val| std.mem.endsWith(u8, val, "XXXXXX") else false;
            const suffix_start = if (has_template) base_len - 6 else base_len;
            const suffix_len: usize = if (has_template) 6 else 8;

            if (!has_template) {
                try path_buf.resize(Heap.global_gpa, base_len + suffix_len);
            }

            const alnum = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
            var random_bytes: [8]u8 = undefined;

            var retries: u32 = 0;
            const max_retries = 100;
            while (retries < max_retries) : (retries += 1) {
                Heap.global_io.random(&random_bytes);

                for (0..suffix_len) |i| {
                    path_buf.items[suffix_start + i] = alnum[random_bytes[i] % alnum.len];
                }

                const file = std.Io.Dir.createFileAbsolute(Heap.global_io, path_buf.items, .{
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
                defer file.close(Heap.global_io);

                try interp.setResultString(path_buf.items);
                return;
            }

            try interp.setResultString("could not create a unique temporary file");
            return error.EvalError;
        },
    }
}

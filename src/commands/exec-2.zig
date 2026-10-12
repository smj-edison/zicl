const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const process = std.process;

const common = @import("common.zig");
const Value = common.Value;
const heap = common.heap;
const objects = common.objects;
const ErrorDetails = common.ErrorDetails;
const Interp = common.Interp;
const Shimmerable = common.Shimmerable;

const Capability = @import("../Capability.zig");
const capabilities = @import("../capabilities.zig");
const ioutil = @import("../ioutil.zig");
const io_commands = @import("io.zig");
const memutil = common.memutil;

const Threaded = @import("../vendor/Threaded.zig");

const FileAndCleanup = union(enum) {
    file_cap_close: *capabilities.File.Backing,
    file_cap_no_close: *capabilities.File.Backing,
    file_close: Io.File,
    file_no_close: Io.File,

    pub fn get(self: FileAndCleanup) Io.File {
        switch (self) {
            .file_cap_close => |cap| return cap.body,
            .file_cap_no_close => |cap| return cap.body,
            .file_close => |file| return file,
            .file_no_close => |file| return file,
        }
    }

    pub fn deinit(self: *FileAndCleanup) void {
        switch (self.*) {
            .file_cap_close => |cap| {
                cap.head.dropInFlight();
                cap.head.close();
            },
            .file_cap_no_close => |cap| {
                cap.head.dropInFlight();
            },
            .file_close => |file| {
                file.close(heap.global_io);
            },
            .file_no_close => {},
        }

        self.* = undefined;
    }
};

const Source = union(enum) {
    /// Consume from the previous stage of the pipeline.
    consume,
    /// Referenced and marked in-flight when the Source is created.
    file: FileAndCleanup,
    /// Global fd, such as stdin. Don't close when done.
    global_file: Io.File,

    pub fn deinit(source: *Source) void {
        switch (source.*) {
            .file => |*cap| cap.deinit(),
            .consume, .global_file => {},
        }
    }
};

const Sink = union(enum) {
    /// Capture output. This output is from [exec] when finished.
    capture,
    /// Forward to the next stage of the pipeline.
    forward,
    /// Used with stderr only. This redirects stderr into whatever
    /// stdout was specified as.
    use_stdout,
    /// Referenced and marked in-flight when the Sink is created.
    capability: FileCapAndCleanup,
    /// Global fd, such as stdout. Don't close when done.
    global_file: Io.File,

    pub fn deinit(sink: *Sink) void {
        switch (sink.*) {
            .capability => |*cap| cap.deinit(),
            .capture, .forward, .use_stdout, .global_file => {},
        }
    }
};

/// A stage represents one command in the pipeline, alongside
/// metadata with how that command should handle its IO.
const Stage = struct {
    /// Arguments to call the command with.
    args: [][]u8,
    stdin: Source,
    stdout: Sink,
    stderr: Sink,

    pub fn deinit(stage: *Stage) void {
        stage.stdin.deinit();
        stage.stdout.deinit();
        stage.stderr.deinit();
        for (stage.args) |arg| heap.global_gpa.free(arg);
        heap.global_gpa.free(stage.args);
    }
};

const Pipeline = struct {
    stages: []Stage,
    is_background_process: bool,
    split_stdout_and_stderr: bool,
    environ: heap.EnvironAndOwnership,

    pub fn deinit(pipeline: *Pipeline) void {
        for (pipeline.stages) |*stage| stage.deinit();
        heap.global_gpa.free(pipeline.stages);
        pipeline.environ.deinit();

        pipeline.* = undefined;
    }
};

/// Used in the `redirection_tokens` table.
const RedirectionFlags = struct {
    direction: union(enum) {
        stdin,
        stdout: struct {
            /// This stage's stderr shares whatever descriptor its stdout got (`>&`, `>>&`, `>&@`).
            stderr_uses_stdout: bool = false,
        },
        stderr,
    },
    payload_type: enum { handle, bytes, filename } = .filename,
    /// Open the target for appending rather than truncating (`>>`, `2>>`).
    append: bool = false,
};

const RedirectionTokenEntry = struct { []const u8, RedirectionFlags };
/// All accepted redirection combinations.
const unsorted_redirection_tokens = [_]RedirectionTokenEntry{
    .{ "<<", .{ .direction = .stdin, .payload_type = .bytes } },
    .{ "<@", .{ .direction = .stdin, .payload_type = .handle } },
    .{ "<", .{ .direction = .stdin } },

    .{ "2>>", .{ .direction = .stderr, .append = true } },
    .{ "2>@", .{ .direction = .stderr, .payload_type = .handle } },
    .{ "2>", .{ .direction = .stderr } },

    .{ ">>&", .{ .direction = .{ .stdout = .{ .stderr_uses_stdout = true } }, .append = true } },
    .{ ">>", .{ .direction = .{ .stdout = .{} }, .append = true } },
    .{ ">&@", .{ .direction = .{ .stdout = .{ .stderr_uses_stdout = true } }, .payload_type = .handle } },
    .{ ">@", .{ .direction = .{ .stdout = .{} }, .payload_type = .handle } },
    .{ ">&", .{ .direction = .{ .stdout = .{ .stderr_uses_stdout = true } } } },
    .{ ">", .{ .direction = .{ .stdout = .{} } } },
};

/// These need to be sorted by length, since we try the longest string first,
/// so we don't accidentally match on a shorter token when a longer one matched.
const sorted_redirection_tokens = blk: {
    var mapping = unsorted_redirection_tokens;
    @setEvalBranchQuota(100_000);
    std.mem.sort(RedirectionTokenEntry, &mapping, void, struct {
        fn lessThan(_: type, lhs: RedirectionTokenEntry, rhs: RedirectionTokenEntry) bool {
            return lhs.@"0".len > rhs.@"0".len;
        }
    }.lessThan);

    break :blk mapping;
};

fn parseRedirection(bytes: []const u8) ?struct { flags: RedirectionFlags, payload: []const u8 } {
    for (sorted_redirection_tokens) |token| {
        const token_bytes, const token_flags = token;
        if (std.mem.startsWith(u8, bytes, token_bytes)) {
            if (token.@"0".len == bytes.len) return .{ .flags = token_flags, .payload = &.{} };
            return .{ .flags = token_flags, .payload = bytes[token_bytes.len..] };
        }
    } else return null;
}

/// Create a self-deleting file in the default temp directory.
fn createTempInDefaultDir(environ: *const process.Environ.Map) !Io.File {
    const tempdir = try ioutil.openDefaultTempDir(heap.global_io, environ);
    defer tempdir.close(heap.global_io);
    return try ioutil.createSelfDeletingFile(tempdir, heap.global_io);
}

fn parseRedirectionPayload(
    interp: *Interp,
    environ: *const process.Environ.Map,
    flags: RedirectionFlags,
    payload: *Shimmerable,
) !FileCapAndCleanup {
    switch (flags.payload_type) {
        .handle => {
            if (try payload.equalsString("stdout")) {
                const file = try capabilities.File.createFromFile(ioutil.getStdout(), false);
                // Non-escaped capability, so this could only error if someone was iterating through
                // registered capabilities, and then somehow closed that capability.
                file.head.markInFlight() catch unreachable;
                return .{
                    .file = file,
                    // This is closing the capability, not the file (`openDescriptor` makes
                    // sure to create the capability with `capabilities.File.close_when_done`
                    // set to false).
                    .close_when_done = true,
                };
            } else if (try payload.equalsString("stderr")) {
                const file = try capabilities.File.createFromFile(ioutil.getStderr(), false);
                file.head.markInFlight() catch unreachable;
                return .{ .file = file, .close_when_done = true };
            } else if (try payload.equalsString("stdin")) {
                const file = try capabilities.File.createFromFile(Io.File.stdin(), false);
                file.head.markInFlight() catch unreachable;
                return .{ .file = file, .close_when_done = true };
            } else {
                // Parse it as a capability.
                const cap = try interp.getCapability(payload);
                var det: ErrorDetails = undefined;
                const backing = try interp.wrapError(&det, cap.getBacking(capabilities.File.Backing, &det));
                // We now call `takeReference` to own the capability independently of the
                // shimmered value. Note we don't need to mark it as in-flight, as
                // `getBacking` did that.
                _ = backing.head.takeReference();
                return .{
                    .file = backing,
                    // Lifetime of this capability is managed by the caller.
                    .close_when_done = false,
                };
            }
        },
        .filename => {
            const filename = try payload.getString();
            const file = try capabilities.File.open(filename, switch (flags.direction) {
                .stdin => .r,
                .stdout, .stderr => if (flags.append) .a else .w,
            });
            file.head.markInFlight() catch unreachable;
            return .{ .file = file, .close_when_done = true };
        },
        .bytes => {
            // We put this into a temp file instead of in a pipe, since we
            // could potentially block when both writing to the pipe and
            // also reading the output from the command, causing a deadlock.
            const tempfile = try createTempInDefaultDir(environ);
            errdefer tempfile.close(heap.global_io);
            try tempfile.writePositionalAll(heap.global_io, try payload.getString(), 0);

            const file = try capabilities.File.createFromFile(tempfile, true);
            file.head.markInFlight() catch unreachable;
            return .{ .file = file, .close_when_done = true };
        },
    }
}

fn parseStages(interp: *Interp, environ: *const std.process.Environ.Map, args: []Shimmerable) ![]Stage {
    var stages: std.ArrayList(Stage) = .empty;
    errdefer {
        for (stages.items) |*stage| stage.deinit();
        stages.deinit(heap.global_gpa);
    }

    // To match parity with bash, we accept redirections in any position,
    // even partway through a command. Once we hit `|` or `|&` though, we
    // start the next command.

    var stage_args: std.ArrayList([]u8) = .empty;
    defer {
        for (stage_args.items) |arg| heap.global_gpa.free(arg);
        stage_args.deinit(heap.global_gpa);
    }
    var stage_stdin: Source = blk: {
        const stdin_file = try capabilities.File.createFromFile(Io.File.stdin(), false);
        stdin_file.head.markInFlight() catch unreachable;
        break :blk .{ .file = .{ .file = stdin_file, .close_when_done = true } };
    };
    defer stage_stdin.deinit();
    var stage_stdout: Sink = .forward;
    defer stage_stdout.deinit();
    var stage_stderr: Sink = .capture;
    defer stage_stderr.deinit();

    var parsing_mode: enum { old, tip424 } = .old;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (index == 0 and try args[0].equalsString("|")) {
            parsing_mode = .tip424;
            continue;
        }

        if (parsing_mode == .tip424 and stage_args.items.len == 0) {
            // Grab the command args and keep going.
            const command_args = try interp.getList(&args[index]);
            if (command_args.items.len == 0) {
                return interp.setErrorInterned("didn't specify command to execute");
            }

            try stage_args.ensureUnusedCapacity(heap.global_gpa, command_args.items.len);
            for (command_args.items) |arg| {
                const duped_bytes = try heap.global_gpa.dupe(u8, try arg.getString());
                stage_args.appendAssumeCapacity(duped_bytes);
            }

            // We now know that `command_args.items.len > 0`, so this branch won't hit until
            // we start a new command.
            continue;
        }

        const is_pipe = try args[index].current().equalsString("|");
        const is_pipe_merge = try args[index].current().equalsString("|&");
        if (is_pipe or is_pipe_merge) {
            if (is_pipe_merge) {
                stage_stderr.deinit();
                stage_stderr = .use_stdout;
            }

            if (stage_args.items.len == 0) {
                return interp.setErrorInterned("didn't specify command to execute");
            }

            try stages.ensureUnusedCapacity(heap.global_gpa, 1);
            const taken_args = try stage_args.toOwnedSlice(heap.global_gpa);

            // Commit previous stage to the pipeline we're building.
            stages.appendAssumeCapacity(.{
                .args = taken_args,
                .stdin = stage_stdin,
                .stdout = stage_stdout,
                .stderr = stage_stderr,
            });
            assert(stage_args.items.len == 0); // `stage_args` was cleared by `toOwnedSlice`.
            stage_stdin = .consume;
            stage_stdout = .forward;
            stage_stderr = .capture;
            continue;
        }

        const arg_bytes = try args[index].getString();
        if (parseRedirection(arg_bytes)) |redirection| {
            var string_shim: Shimmerable = .{ .original = heap.interned_empty_string };
            defer string_shim.deinit();
            const redirection_payload = if (redirection.payload.len > 0) blk: {
                string_shim.original = try objects.String.newValue(redirection.payload);
                break :blk &string_shim;
            } else blk: {
                // If `trailing` is empty, it means that the argument redirection value
                // is the next parameter.
                index += 1;
                if (index >= args.len) return interp.setErrorFormatted("\"{s}\" missing redirection payload", .{arg_bytes});
                break :blk &args[index];
            };

            if (redirection.flags.payload_type == .handle and
                redirection.flags.direction == .stderr and
                try redirection_payload.equalsString("1"))
            {
                stage_stderr.deinit();
                stage_stderr = .use_stdout;
            } else {
                const redirection_file = try parseRedirectionPayload(interp, environ, redirection.flags, redirection_payload);
                switch (redirection.flags.direction) {
                    .stdin => {
                        stage_stdin.deinit();
                        stage_stdin = .{ .file = redirection_file };
                    },
                    .stdout => |details| {
                        stage_stdout.deinit();
                        stage_stdout = .{ .capability = redirection_file };
                        if (details.stderr_uses_stdout) {
                            stage_stderr.deinit();
                            stage_stderr = .use_stdout;
                        }
                    },
                    .stderr => {
                        stage_stderr.deinit();
                        stage_stderr = .{ .capability = redirection_file };
                    },
                }
            }
        } else if (parsing_mode == .tip424) {
            // Failed to parse the redirection, and we're also in TIP424 mode,
            // so give the user a nice error.
            return interp.setErrorFormatted("{s} is not a redirection (did you pass in a command parameter outside the command list?)", .{arg_bytes});
        } else {
            // Wasn't able to be parsed as a redirection, but we're in old mode,
            // so we'll consider this a parameter to the command.
            const duped_bytes = try heap.global_gpa.dupe(u8, try args[index].getString());
            errdefer heap.global_gpa.free(duped_bytes);
            try stage_args.append(heap.global_gpa, duped_bytes);
        }
    }

    if (stage_args.items.len == 0) return interp.setErrorInterned("didn't specify command to execute");
    try stages.append(heap.global_gpa, .{
        .args = try stage_args.toOwnedSlice(heap.global_gpa),
        .stdin = stage_stdin,
        .stdout = stage_stdout,
        .stderr = stage_stderr,
    });
    assert(stage_args.items.len == 0); // `stage_args` was cleared by `toOwnedSlice`.
    stage_stdin = .consume;
    stage_stdout = .forward;
    stage_stderr = .capture;

    // Now we do some final stage processing.

    // Can't forward on the last stage of the pipeline, so capture it is.
    const last = stages.items.len - 1;
    if (stages.items[last].stdout == .forward) stages.items[last].stdout = .capture;

    for (stages.items) |*stage| if (stage.stderr == .use_stdout) {
        // Forward stderr to stdout.
        switch (stage.stdout) {
            // Only ever used by `stage.stderr`.
            .use_stdout => unreachable,
            .capture => stage.stderr = .capture,
            .forward => stage.stderr = .forward,
            .capability => |cap| {
                var det: ErrorDetails = undefined;
                // Capability may have closed here since the user can provide us with an externally
                // managed capability. TODO don't just use "<unknown>".
                cap.file.head.markInFlight() catch return interp.wrapError(&det, Capability.staleError(&det, "<unknown>"));
                _ = cap.file.head.takeReference();

                stage.stderr.deinit();
                stage.stderr = .{
                    .capability = .{
                        .file = cap.file,
                        // Never close when done, since the other one will close it if applicable.
                        .close_when_done = false,
                    },
                };
            },
        }
    };

    return try stages.toOwnedSlice(heap.global_gpa);
}

fn buildEnvironFromDict(interp: *Interp, dict: *const objects.Dictionary) !process.Environ.Map {
    var map = process.Environ.Map.init(heap.global_gpa);
    errdefer map.deinit();

    var iter = dict.table.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.getString() catch unreachable;
        const value = try dict.items[entry.value_ptr.*].getString();
        if (!process.Environ.Map.validateKeyForPut(key)) {
            return interp.setErrorFormatted("\"{s}\" is not a valid environment variable name", .{key});
        }
        try map.put(key, value); // Copies strings.
    }
    return map;
}

/// A process returned from [exec] when [exec] is called with & at the end,
/// e.g. background mode. This is used by [wait] to wait for results.
const Process = struct {
    /// Processes currently only allow one place to wait on them, so once a
    /// thread starts waiting on this process it locks `wait_mutex`.
    wait_mutex: Io.Mutex = .init,
    waited: bool = false,
    /// Only use while `wait_mutex` is locked.
    stages: []Process.Stage,
    /// Result from the pipeline. Can be null if the output of the pipeline
    /// was redirected.
    stdout_capture: ?Io.File,
    /// Each stage's captured stderr, in stage order. Null for the stages
    /// where stderr wasn't captured.
    stderr_captures: []?Io.File = &.{},

    pub const Stage = union(enum) {
        child_process: process.Child,
        terminated: process.Child.Term,
    };
    pub const WaitError = error{AlreadyWaited} || process.Child.WaitError;

    /// Waits for every stage and reports how the overall pipeline ended.
    /// Kills/waits all processes in all cases excluding error.AlreadyWaited
    /// (since error.AlreadyWaited means that the process was already
    /// destroyed).
    pub fn wait(self: *Process) WaitError!process.Child.Term {
        if (!self.wait_mutex.tryLock(heap.global_io)) return error.AlreadyWaited;
        defer self.wait_mutex.unlock(heap.global_io);

        // Have all the stages terminated? If so, it means this pipeline
        // has already run.
        for (self.stages) |stage| {
            if (std.meta.activeTag(stage) == .alive) break;
        } else return error.AlreadyWaited;

        for (0.., self.stages) |i, *stage| switch (stage.*) {
            .child_process => |*stage_process| {
                const termination = stage_process.wait(heap.global_io) catch |err| {
                    // Kill the remaining stages (no need to kill the
                    // previous stages, since they already were waited on).
                    for (self.stages[i..]) |*to_kill| switch (to_kill.*) {
                        .child_process => |*to_kill_process| {
                            to_kill_process.kill(heap.global_io);
                            to_kill.* = .{ .terminated = .{ .signal = .TERM } };
                        },
                        .terminated => continue,
                    };
                    return err;
                };

                stage.* = .{ .terminated = termination };
            },
            .terminated => continue,
        };

        return getPipelineTermination(self.stages).termination;
    }

    pub fn deinit(self: *Process) void {
        // Kill all running tasks if the process hasn't been waited on yet.
        if (self.wait_mutex.tryLock(heap.global_io)) {
            defer self.wait_mutex.unlock(heap.global_io);
            for (self.stages) |*stage| switch (stage.*) {
                .child_process => |*stage_process| {
                    stage_process.kill(heap.global_io);
                    stage.* = .{ .terminated = .{ .signal = .TERM } };
                },
                .terminated => continue,
            };
        }

        for (self.stderr_captures) |capture| if (capture) |file| file.close(heap.global_io);
        if (self.stdout_capture) |file| file.close(heap.global_io);
        heap.global_gpa.free(self.stages);
        heap.global_gpa.free(self.stderr_captures);

        self.* = undefined;
    }

    /// Get the termination of the whole pipeline, following bash semantics:
    /// If no stages failed, then return the last stage's termination.
    /// Else a stage failed, so return the failed stage's termination instead.
    pub fn getPipelineTermination(stages: []const Process.Stage) struct { termination: process.Child.Term, stage: usize } {
        var index = stages.len;
        while (index > 0) {
            index -= 1;
            const termination = stages[index].termination.?;
            switch (termination) {
                .exited => |code| if (code != 0) {
                    return .{ .termination = termination, .index = index };
                },
                else => return .{ .termination = termination, .index = index },
            }
        }

        return .{ .termination = stages[stages.len - 1].termination.?, .stage = stages.len - 1 };
    }

    pub const Backing = struct {
        head: Capability.Head,
        body: Process,

        fn deinitBody(head: *Capability.Head) callconv(.c) void {
            const backing: *Backing = @fieldParentPtr("head", head);
            backing.body.deinit();
        }

        fn destroyBacking(head: *Capability.Head) callconv(.c) void {
            const backing: *Backing = @fieldParentPtr("head", head);
            heap.global_gpa.destroy(backing);
        }

        pub const vtable: Capability.Head.VTable = .{
            .deinit_body = deinitBody,
            .destroy_backing = destroyBacking,
            .name = "process",
        };
    };
};

const interned_childstatus = heap.InternedString.newValue("CHILDSTATUS");
const interned_childkilled = heap.InternedString.newValue("CHILDKILLED");
const interned_childsusp = heap.InternedString.newValue("CHILDSUSPENDED");
const interned_childunknown = heap.InternedString.newValue("CHILDUNKNOWN");
const interned_out = heap.InternedString.newValue("out");
const interned_err = heap.InternedString.newValue("err");
const interned_code = heap.InternedString.newValue("code");

/// Error message from process termination, or null if the process terminated
/// normally.
fn errorMessageFromTerm(term: process.Child.Term) !?[:0]u8 {
    switch (term) {
        .exited => |code| if (code == 0) return null,
        .signal => |sig| return objects.allocPrintZ("child killed by signal {d}", .{@intFromEnum(sig)}),
        .stopped => |sig| return objects.allocPrintZ("child suspended by signal {d}", .{@intFromEnum(sig)}),
        .unknown => {},
    }

    return try heap.global_gpa.dupeSentinel(u8, "child process exited abnormally", 0);
}

pub fn execCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    var split_stdout_and_stderr = false;
    var env_dict: ?*const objects.Dictionary = null;

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.startsWith(u8, try args[index].getString(), "-")) {
            if (try args[index].equalsString("--")) {
                index += 1;
                break;
            } else if (try args[index].equalsString("-split")) {
                split_stdout_and_stderr = true;
            } else if (try args[index].equalsString("-env")) {
                if (index + 1 >= args.len) return interp.setErrorInterned("env dictionary not provided");
                env_dict = try interp.getDict(&args[index + 1]);
                index += 1;
            } else {
                return interp.setErrorFormatted("unknown flag: {s}", .{try args[index].getString()});
            }
        } else break;
    }

    var args_to_use = args[index..];
    if (args_to_use.len < 1) return interp.setErrorInterned("didn't specify command to execute");
    const is_background_process = try args_to_use[args_to_use.len - 1].equalsString("&");
    args_to_use = if (is_background_process) args_to_use[0..(args_to_use.len - 1)] else args_to_use;
    if (args_to_use.len < 1) return interp.setErrorInterned("didn't specify command to execute");

    const process_capability = capability: {
        const cap_backing = try heap.global_gpa.create(Process.Backing);
        cap_backing.* = .{
            .head = .{ .vtable = &Process.Backing.vtable, .id = .not_set },
            .body = .{ .stages = &.{}, .stdout_capture = null },
        };
        var process_cap = try Capability.newTakingOwnership(&cap_backing.head);
        errdefer process_cap.head.closeAndDropReference();

        var pipeline: Pipeline = pipeline: {
            var environ: heap.EnvironAndOwnership = if (env_dict) |val|
                .{ .owned = try buildEnvironFromDict(interp, val) }
            else
                .{ .shared = heap.environ.get() };
            errdefer environ.deinit();

            const stages = parseStages(interp, environ.get(), args_to_use) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.EvalError => return error.EvalError,
                // Anything else is an IO error during setup.
                else => return interp.setErrorFormatted("couldn't set up redirections: {t}", .{err}),
            };
            // Take ownership of everything.
            break :pipeline .{
                .stages = stages,
                .is_background_process = is_background_process,
                .split_stdout_and_stderr = split_stdout_and_stderr,
                .environ = environ,
            };
        };
        defer pipeline.deinit();

        // Each process gets its own stderr tempfile, to avoid the stderr logs from being interleaved.
        var stderr_captures = try std.ArrayList(?Io.File).initCapacity(heap.global_gpa, pipeline.stages.len);
        defer stderr_captures.deinit(heap.global_gpa);
        defer for (stderr_captures.items) |item| if (item) |capture| capture.close(heap.global_io);
        for (pipeline.stages) |stage| {
            if (stage.stderr == .capture) {
                const capture = createTempInDefaultDir(pipeline.environ.get()) catch |err| {
                    return interp.setErrorFormatted("couldn't create a temporary file: {}", .{err});
                };
                stderr_captures.appendAssumeCapacity(capture);
            } else {
                stderr_captures.appendAssumeCapacity(null);
            }
        }

        // We also create a tempfile for stdout, to avoid a deadlock between us writing to the
        // process's stdin and reading from the process's stdout.
        const stdout_capture: ?Io.File = blk: {
            if (pipeline.stages[pipeline.stages.len - 1].stdout == .capture) {
                break :blk createTempInDefaultDir(pipeline.environ.get()) catch |err| {
                    return interp.setErrorFormatted("couldn't create a temporary file: {}", .{err});
                };
            } else break :blk null;
        };
        errdefer if (stdout_capture) |file| file.close(heap.global_io);

        // This will contain all the spawned stages.
        var proc_stages = try std.ArrayList(Process.Stage).initCapacity(heap.global_gpa, pipeline.stages.len);
        defer proc_stages.deinit(heap.global_gpa);
        defer for (proc_stages.items) |*stage| {
            stage.child_process.kill(heap.global_io);
            stage = .{ .terminated = .{ .signal = .TERM } };
        };

        var read_end_from_previous: ?Io.File = null;
        defer if (read_end_from_previous) |val| val.close(heap.global_io);
        for (pipeline.stages, 0..) |stage, i| {
            const pipe_files: ?[2]Io.File = blk: {
                // We only create a pipe pair if the next stage uses it.
                if (i == pipeline.stages.len - 1) break :blk null;
                if (pipeline.stages[i + 1].stdin == .consume) {
                    const pipe_fds = Threaded.pipe2(.{ .CLOEXEC = true }) catch |err|
                        return interp.setErrorFormatted("couldn't create pipe: {t}", .{err});
                    break :blk .{
                        Io.File{ .handle = pipe_fds[0], .flags = .{ .nonblocking = false } },
                        Io.File{ .handle = pipe_fds[1], .flags = .{ .nonblocking = false } },
                    };
                }
                break :blk null;
            };
            var read_end: ?Io.File = if (pipe_files) |files| files[0] else null;
            const write_end: ?Io.File = if (pipe_files) |files| files[1] else null;
            defer if (read_end) |file| file.close(heap.global_io);
            defer if (write_end) |file| file.close(heap.global_io);

            const stdin_io: process.SpawnOptions.StdIo = switch (stage.stdin) {
                .consume => .{ .file = read_end_from_previous.? },
                .file => |cap| .{ .file = cap.file.body.file },
            };

            const stdout_io: process.SpawnOptions.StdIo = switch (stage.stdout) {
                // Never used in `stage.stdout`.
                .use_stdout => unreachable,
                .forward => .{ .file = write_end.? },
                .capability => |cap| .{ .file = cap.file.body.file },
                .capture => .{ .file = stdout_capture.? },
            };

            const stderr_io: process.SpawnOptions.StdIo = switch (stage.stderr) {
                // Only used internally during parsing, so we shouldn't see this
                // intermetiate state.
                .use_stdout => unreachable,
                .forward => .{ .file = write_end.? },
                .capability => |cap| .{ .file = cap.file.body.file },
                .capture => .{ .file = stderr_captures.items[i].? },
            };

            const child = process.spawn(heap.global_io, .{
                .argv = stage.args,
                .stdin = stdin_io,
                .stdout = stdout_io,
                .stderr = stderr_io,
                .environ_map = pipeline.environ.get(),
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return interp.setErrorFormatted("couldn't exec \"{s}\": {}", .{ stage.args[0], err }),
            };
            proc_stages.appendAssumeCapacity(child);

            // The child holds its own copy now, so we can close the
            // read end on our side.
            if (read_end_from_previous) |file| file.close(heap.global_io);
            read_end_from_previous = read_end;
            read_end = null;
        }

        try proc_stages.shrinkAndFreePrecise(heap.global_gpa, proc_stages.items.len);
        try stderr_captures.shrinkAndFreePrecise(heap.global_gpa, stderr_captures.items.len);

        errdefer comptime unreachable;
        cap_backing.body.* = .{
            .stages = proc_stages.toOwnedSliceAssert(),
            .stdout_capture = stdout_capture,
            .stderr_captures = stderr_captures.toOwnedSliceAssert(),
        };
        break :capability process_cap;
    };

    if (is_background_process) {
        interp.setResultOwning(process_capability.asHead().asValue());
    } else {
        defer process_capability.head.closeAndDropReference();
    }

    // -- Collecting output. Nothing was a pipe, so there is no drain-before-
    // wait ordering to preserve: every child is reaped first, then each
    // capture file is read back from the start, in report order. --

    for (proc_stages) |*stage| {
        stage.termination = stage.child.wait(heap.global_io) catch |err|
            return interp.setErrorFormatted("error waiting for child: {t}", .{err});
    }

    var stdout_bytes: []u8 = &.{};
    errdefer if (stdout_bytes.len != 0) heap.global_gpa.free(stdout_bytes);
    if (stdout_capture) |file| {
        const len: usize = @intCast(file.length(heap.global_io) catch |err|
            return interp.setErrorFormatted("error reading from child: {t}", .{err}));
        stdout_bytes = heap.global_gpa.alloc(u8, len) catch return error.OutOfMemory;
        _ = file.readPositionalAll(heap.global_io, stdout_bytes, 0) catch |err|
            return interp.setErrorFormatted("error reading from child: {t}", .{err});
        file.close(heap.global_io);
        stdout_capture = null;
    }

    var stderr_parts: std.ArrayList(u8) = .empty;
    defer stderr_parts.deinit(heap.global_gpa);
    for (stderr_captures) |*slot| {
        const file = slot.* orelse continue;
        const len: usize = @intCast(file.length(heap.global_io) catch |err|
            return interp.setErrorFormatted("error reading from child: {t}", .{err}));
        const buffer = heap.global_gpa.alloc(u8, len) catch return error.OutOfMemory;
        defer heap.global_gpa.free(buffer);
        const got = file.readPositionalAll(heap.global_io, buffer, 0) catch |err|
            return interp.setErrorFormatted("error reading from child: {t}", .{err});
        stderr_parts.appendSlice(heap.global_gpa, buffer[0..got]) catch return error.OutOfMemory;
        slot.* = null;
        file.close(heap.global_io);
    }
    const stderr_bytes = try stderr_parts.toOwnedSlice(heap.global_gpa);
    errdefer heap.global_gpa.free(stderr_bytes);

    const outcome = Process.getPipelineTermination(proc_stages);

    if (pipeline.split_stdout_and_stderr) {
        // The parts are reported apart; nothing raises, since a caller asking
        // for them is asking to inspect the outcome. `code` renders a killed
        // stage as 128 plus its signal, the way a shell does.
        const code: i64 = switch (outcome.termination) {
            .exited => |exit_code| exit_code,
            .signal, .stopped => |sig| 128 + @as(i64, @intFromEnum(sig)),
            .unknown => 1,
        };
        const out_value = try objects.String.newValue(stdout_bytes);
        defer out_value.dropReference();
        const err_value = try objects.String.newValue(stderr_bytes);
        defer err_value.dropReference();
        const dict = try objects.Dictionary.new(&.{
            interned_out,  out_value,
            interned_err,  err_value,
            interned_code, objects.Integer.new(code),
        });
        interp.setResultOwning(dict.asHead().asValue());
    } else {
        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(heap.global_gpa);
        result.appendSlice(heap.global_gpa, stdout_bytes) catch return error.OutOfMemory;
        result.appendSlice(heap.global_gpa, stderr_bytes) catch return error.OutOfMemory;

        var message_buffer: [64]u8 = undefined;
        const abnormal = errorMessageFromTerm(outcome.termination, &message_buffer);
        // Dropped when the child said something itself, since its own
        // diagnostic is the better message.
        if (abnormal) |text| {
            if (stderr_bytes.len == 0) result.appendSlice(heap.global_gpa, text) catch return error.OutOfMemory;
        }

        try interp.setResultString(result.items);
        if (abnormal != null) {
            // Jim parity: the error code names the deciding child and how it
            // ended, for [catch]/[try] to dispatch on.
            const status: struct { heap.Value, i64 } = switch (outcome.termination) {
                .exited => |exit_code| .{ interned_childstatus, exit_code },
                .signal => |sig| .{ interned_childkilled, @intFromEnum(sig) },
                .stopped => |sig| .{ interned_childsusp, @intFromEnum(sig) },
                .unknown => |raw| .{ interned_childunknown, @intCast(raw) },
            };
            const pid_value = objects.Integer.new(@intCast(proc_stages[outcome.stage].pid));
            const list = try objects.List.new(&.{ status[0], objects.Integer.new(status[1]), pid_value });
            interp.pending_error_code.swap(list.asHead().asValue().takeReference());
            return error.EvalError;
        }
    }

    heap.global_gpa.free(proc_stages);
    heap.global_gpa.free(stderr_captures);
    if (stdout_bytes.len != 0) heap.global_gpa.free(stdout_bytes);
    heap.global_gpa.free(stderr_bytes);
}

/// [wait]: reports how a background pipeline ended, as a `{CHILDSTATUS pid
/// code}`-style list naming the stage that decided the outcome. With
/// `-split`, reports instead the `{out err code}` dict the pipeline was
/// started with `exec -split ... &` in order to stage. Either way, a
/// pipeline can only be waited on once.
pub fn waitCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    var split = false;
    var rest = args[1..];
    if (rest.len > 0 and (try rest[0].equalsString("-split"))) {
        split = true;
        rest = rest[1..];
    }
    if (rest.len < 1) return interp.setErrorInterned("expected a process");

    var det: ErrorDetails = undefined;
    const cap = try interp.wrapError(&det, Capability.shimmerFrom(&det, &rest[0]));
    const backing = try interp.wrapError(&det, cap.getBacking(Process.Backing, &det));
    defer backing.head.dropInFlight();

    if (split) {
        // Checked before waiting: a plain background pipeline inherited its
        // output, so there is nothing to read no matter when we look.
        var any_capture = backing.body.stdout_capture != null;
        for (backing.body.stderr_captures) |slot| {
            if (slot != null) any_capture = true;
        }
        if (!any_capture) return interp.setErrorInterned("process was not started with -split");
    }

    _ = backing.body.wait() catch |err| switch (err) {
        error.AlreadyWaited => return interp.setErrorInterned("process has already been waited on"),
        else => return interp.setErrorFormatted("error waiting for child: {t}", .{err}),
    };
    const outcome = Process.getPipelineTermination(backing.body.stages);

    const status: struct { heap.Value, i64 } = switch (outcome.termination) {
        .exited => |exit_code| .{ interned_childstatus, exit_code },
        .signal => |sig| .{ interned_childkilled, @intFromEnum(sig) },
        .stopped => |sig| .{ interned_childsusp, @intFromEnum(sig) },
        // Its own word, so a pipeline whose outcome was lost is not mistaken
        // for one that exited with whatever is in the raw wait status.
        .unknown => |raw| .{ interned_childunknown, @intCast(raw) },
    };
    const pid_value = objects.Integer.new(@intCast(backing.body.stages[outcome.stage].pid));

    if (split) {
        // Every child has been reaped, so the staged files are complete and
        // can be read from the start.
        var err_parts: std.ArrayList(u8) = .empty;
        defer err_parts.deinit(heap.global_gpa);
        var out_bytes: []u8 = &.{};
        defer heap.global_gpa.free(out_bytes);
        if (backing.body.stdout_capture) |file| {
            const len: usize = @intCast(file.length(heap.global_io) catch |err|
                return interp.setErrorFormatted("error reading from child: {t}", .{err}));
            out_bytes = heap.global_gpa.alloc(u8, len) catch return error.OutOfMemory;
            _ = file.readPositionalAll(heap.global_io, out_bytes, 0) catch |err|
                return interp.setErrorFormatted("error reading from child: {t}", .{err});
        }
        for (backing.body.stderr_captures) |slot| {
            const file = slot orelse continue;
            const len: usize = @intCast(file.length(heap.global_io) catch |err|
                return interp.setErrorFormatted("error reading from child: {t}", .{err}));
            const buffer = heap.global_gpa.alloc(u8, len) catch return error.OutOfMemory;
            defer heap.global_gpa.free(buffer);
            const got = file.readPositionalAll(heap.global_io, buffer, 0) catch |err|
                return interp.setErrorFormatted("error reading from child: {t}", .{err});
            err_parts.appendSlice(heap.global_gpa, buffer[0..got]) catch return error.OutOfMemory;
        }

        const code: i64 = switch (outcome.termination) {
            .exited => |exit_code| exit_code,
            .signal, .stopped => |sig| 128 + @as(i64, @intFromEnum(sig)),
            .unknown => 1,
        };
        const out_value = try objects.String.newValue(out_bytes);
        defer out_value.dropReference();
        const err_value = try objects.String.newValue(err_parts.items);
        defer err_value.dropReference();
        const dict = try objects.Dictionary.new(&.{
            interned_out,  out_value,
            interned_err,  err_value,
            interned_code, objects.Integer.new(code),
        });
        interp.setResultOwning(dict.asHead().asValue());
        backing.body.discardCaptures();
        return;
    }

    const list = try objects.List.new(&.{ status[0], objects.Integer.new(status[1]), pid_value });
    interp.setResultOwning(list.asHead().asValue());
    // A plain [wait] asked only how it ended, so anything staged goes.
    backing.body.discardCaptures();
}

const testing = std.testing;

/// Absolute paths throughout, so the tests exercise [exec2] rather than
/// whatever PATH the embedder happened to install.
const true_path = "/usr/bin/true";
const false_path = "/usr/bin/false";
const echo_path = "/usr/bin/echo";
const cat_path = "/bin/cat";
const sh_path = "/bin/sh";
const sort_path = "/usr/bin/sort";
const tr_path = "/usr/bin/tr";

fn testStartExec2(ta: std.mem.Allocator) !Interp {
    var interp = try common.testStart(ta);
    errdefer common.testFinish(&interp);
    // exec-2 is not the live [exec] yet; the tests drive it through aliases.
    try common.registerCommand(&interp, "exec2", execCmd, "?-split? ?--? command ?arg ...?", 1, null);
    try common.registerCommand(&interp, "wait2", waitCmd, "?-split? process", 1, 2);
    return interp;
}

fn testExec2Basics(ta: std.mem.Allocator) !void {
    var interp = try testStartExec2(ta);
    defer common.testFinish(&interp);

    // Raw results: exactly what the child wrote, newlines included.
    try interp.testExpectScriptResult("hello\n", "exec2 " ++ echo_path ++ " hello");
    try interp.testExpectScriptResult("a\nb\n", "exec2 " ++ echo_path ++ " a\\nb");

    // Pipelines, and a mid stage's stderr folded in stage order.
    try interp.testExpectScriptResult("hi\n", "exec2 " ++ echo_path ++ " hi | " ++ sort_path);
    try interp.testExpectScriptResult("from-first\n", "exec2 " ++ sh_path ++ " -c {echo from-first >&2} | " ++ cat_path);

    // `|&` and `2>@1` both send stderr wherever this stage's stdout goes.
    try interp.testExpectScriptResult("TO-PIPE\n", "exec2 " ++ sh_path ++ " -c {echo to-pipe >&2} |& " ++ tr_path ++ " a-z A-Z");
    try interp.testExpectScriptResult("merge\n", "exec2 " ++ sh_path ++ " -c {echo merge >&2} 2>@1 | " ++ cat_path);

    // The `<<` document is fed exactly: no trailing newline is added.
    try interp.testExpectScriptResult("inline", "exec2 " ++ cat_path ++ " << inline");
}

fn testExec2Files(ta: std.mem.Allocator) !void {
    var interp = try testStartExec2(ta);
    defer common.testFinish(&interp);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buffer[0..(try tmp.dir.realPath(heap.global_io, &path_buffer))];
    const out_path = try std.fmt.allocPrint(ta, "{s}/out.txt", .{dir_path});
    defer ta.free(out_path);

    const write_script = try std.fmt.allocPrint(ta, "exec2 " ++ echo_path ++ " out > {s}", .{out_path});
    defer ta.free(write_script);
    // Output went to the file, so the command itself reports nothing.
    try interp.testExpectScriptResult("", write_script);

    const read_script = try std.fmt.allocPrint(ta, "exec2 " ++ cat_path ++ " {s}", .{out_path});
    defer ta.free(read_script);
    try interp.testExpectScriptResult("out\n", read_script);
}

fn testExec2Abnormal(ta: std.mem.Allocator) !void {
    var interp = try testStartExec2(ta);
    defer common.testFinish(&interp);

    // The generic message only when the child said nothing itself.
    try interp.testExpectScriptError(error.EvalError, "child process exited abnormally", "exec2 " ++ false_path);
    // The child's own diagnostic wins, and the error code names it for
    // [catch]/[try]: `{CHILDSTATUS pid code}`.
    try interp.testExpectScriptError(error.EvalError, "no good\n", "exec2 " ++ sh_path ++ " -c {echo no good >&2; exit 3}");
    try interp.testExpectScriptResult("1", "catch {exec2 " ++ false_path ++ "} m o; string match {CHILDSTATUS * 1} [dict get $o -errorcode]");
    try interp.testExpectScriptResult("1", "catch {exec2 " ++ sh_path ++ " -c {exit 3}} m o; string match {CHILDSTATUS * 3} [dict get $o -errorcode]");
    // An earlier failure is not swallowed by a successful tail.
    try interp.testExpectScriptError(error.EvalError, "child process exited abnormally", "exec2 " ++ false_path ++ " | " ++ true_path);
    // A missing binary reports at exec time.
    try interp.testExpectScriptError(error.EvalError, "couldn't exec \"/nonexistent\": FileNotFound", "exec2 /nonexistent");
}

fn testExec2Split(ta: std.mem.Allocator) !void {
    var interp = try testStartExec2(ta);
    defer common.testFinish(&interp);

    // `-split` never raises; `code` carries the outcome instead, and the
    // parts are raw.
    try interp.testExpectScriptResult("out\n", "dict get [exec2 -split " ++ sh_path ++ " -c {echo out; echo err >&2}] out");
    try interp.testExpectScriptResult("err\n", "dict get [exec2 -split " ++ sh_path ++ " -c {echo out; echo err >&2}] err");
    try interp.testExpectScriptResult("0", "dict get [exec2 -split " ++ true_path ++ "] code");
    try interp.testExpectScriptResult("3", "dict get [exec2 -split " ++ sh_path ++ " -c {exit 3}] code");
}

fn testExec2Background(ta: std.mem.Allocator) !void {
    var interp = try testStartExec2(ta);
    defer common.testFinish(&interp);

    // Plain background: [wait] reports how it ended, once. The child is quiet
    // on purpose -- it inherits the redirect cell, which under the test runner
    // carries the protocol stream.
    try interp.testExpectScriptResult("1", "set p [exec2 " ++ true_path ++ " &]; string match {CHILDSTATUS * 0} [wait2 $p]");
    try interp.testExpectScriptError(error.EvalError, "process has already been waited on", "wait2 $p");

    // The split is opted into at [exec] and read at [wait]; captures go to
    // files, so these children may be as loud as they like.
    try interp.testExpectScriptResult("out\n", "set q [exec2 -split " ++ sh_path ++ " -c {echo out; echo err >&2} &]; dict get [wait2 -split $q] out");
    try interp.testExpectScriptResult("err\n", "set q [exec2 -split " ++ sh_path ++ " -c {echo out; echo err >&2} &]; dict get [wait2 -split $q] err");
    try interp.testExpectScriptResult("0", "set q [exec2 -split " ++ echo_path ++ " bg &]; dict get [wait2 -split $q] code");
    try interp.testExpectScriptError(error.EvalError, "process was not started with -split", "set r [exec2 " ++ true_path ++ " &]; wait2 -split $r");
}

test "exec2 basics" {
    try memutil.checkAllocationFailures(.exhaustive, testExec2Basics, .{});
}

test "exec2 files" {
    try memutil.checkAllocationFailures(.exhaustive, testExec2Files, .{});
}

test "exec2 abnormal exit" {
    try memutil.checkAllocationFailures(.exhaustive, testExec2Abnormal, .{});
}

test "exec2 split" {
    try memutil.checkAllocationFailures(.exhaustive, testExec2Split, .{});
}

test "exec2 background" {
    try memutil.checkAllocationFailures(.exhaustive, testExec2Background, .{});
}

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
            .file_cap_close => |cap| return cap.body.file,
            .file_cap_no_close => |cap| return cap.body.file,
            .file_close => |file| return file,
            .file_no_close => |file| return file,
        }
    }

    pub fn deinit(self: *FileAndCleanup) void {
        switch (self.*) {
            .file_cap_close => |cap| {
                cap.head.dropInFlight();
                cap.head.close();
                cap.head.dropReference();
            },
            .file_cap_no_close => |cap| {
                cap.head.dropInFlight();
                cap.head.dropReference();
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

    pub fn deinit(source: *Source) void {
        switch (source.*) {
            .file => |*cap| cap.deinit(),
            .consume => {},
        }
    }
};

const Sink = union(enum) {
    /// Capture output. This output is from [exec] when finished.
    capture,
    /// Forward to the next stage of the pipeline.
    forward,
    /// This redirects stderr into whatever stdout was specified as.
    /// Only set on stderr sinks.
    use_stdout,
    /// Referenced and marked in-flight when the Sink is created.
    file: FileAndCleanup,

    pub fn deinit(sink: *Sink) void {
        switch (sink.*) {
            .file => |*file| file.deinit(),
            .capture, .forward, .use_stdout => {},
        }
    }
};

/// A stage represents one command in the pipeline, alongside
/// metadata with how that command should handle its IO.
const Stage = struct {
    /// Arguments to call the command with, in the format that spawn expects.
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

        stage.* = undefined;
    }
};

const Pipeline = struct {
    stages: []Stage,
    is_background_process: bool,
    environ: heap.EnvironAndOwnership,

    pub fn deinit(pipeline: *Pipeline) void {
        for (pipeline.stages) |*stage| stage.deinit();
        heap.global_gpa.free(pipeline.stages);
        pipeline.environ.deinit();

        pipeline.* = undefined;
    }
};

/// Used in the `unsorted_redirection_tokens` table.
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
/// so we don't accidentally match on a shorter token when a longer one matches.
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
) !FileAndCleanup {
    switch (flags.payload_type) {
        .handle => {
            if (try payload.equalsString("stdout")) {
                return .{ .file_no_close = ioutil.getStdout() };
            } else if (try payload.equalsString("stderr")) {
                return .{ .file_no_close = ioutil.getStderr() };
            } else if (try payload.equalsString("stdin")) {
                return .{ .file_no_close = Io.File.stdin() };
            } else {
                // Parse it as a capability.
                const cap = try interp.getCapability(payload);
                var det: ErrorDetails = undefined;
                const backing = try interp.wrapError(&det, cap.getBacking(capabilities.File.Backing, &det));
                // We now call `takeReference` to own the capability independently of the
                // shimmered value. Note we don't need to mark it as in-flight, as
                // `getBacking` did that.
                _ = backing.head.takeReference();

                // Closing this capability is managed by the caller, so we shouldn't close
                // when we no are longer using it.
                return .{ .file_cap_no_close = backing };
            }
        },
        .filename => {
            const filename = try payload.getString();
            const file = try capabilities.File.openFileMode(
                std.Io.Dir.cwd(),
                filename,
                switch (flags.direction) {
                    .stdin => .r,
                    .stdout, .stderr => if (flags.append) .a else .w,
                },
            );
            return .{ .file_close = file };
        },
        .bytes => {
            // We put this into a temp file instead of in a pipe, since we
            // could potentially block when both writing to the pipe and
            // also reading the output from the command, causing a deadlock.
            const tempfile = try createTempInDefaultDir(environ);
            errdefer tempfile.close(heap.global_io);
            // Write positionally to avoid seeking.
            try tempfile.writePositionalAll(heap.global_io, try payload.getString(), 0);

            return .{ .file_close = tempfile };
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
    var stage_stdin: Source = .{ .file = .{ .file_no_close = Io.File.stdin() } };
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
                // We hit `2>1`.
                stage_stderr.deinit();
                stage_stderr = .use_stdout;
            } else {
                const redirection_file = try parseRedirectionPayload(interp, environ, redirection.flags, redirection_payload);
                switch (redirection.flags.direction) {
                    .stdin => {
                        // Note that this may change `stage_stdin` from .consume to .file,
                        // even while the previous stage has its stdout set to .forward.
                        // This situation will be handled by the process spawning loop,
                        // so see it for details.
                        stage_stdin.deinit();
                        stage_stdin = .{ .file = redirection_file };
                    },
                    .stdout => |details| {
                        stage_stdout.deinit();
                        stage_stdout = .{ .file = redirection_file };
                        if (details.stderr_uses_stdout) {
                            stage_stderr.deinit();
                            stage_stderr = .use_stdout;
                        }
                    },
                    .stderr => {
                        stage_stderr.deinit();
                        stage_stderr = .{ .file = redirection_file };
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
    try stages.ensureUnusedCapacity(heap.global_gpa, 1);

    stages.appendAssumeCapacity(.{
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
            .file => |file| {
                switch (file) {
                    .file_cap_close, .file_cap_no_close => |cap| {
                        // Capability may have closed here since the user can provide us with an externally
                        // managed capability. TODO don't just use "<unknown>".
                        var det: ErrorDetails = undefined;
                        cap.head.markInFlight() catch return interp.wrapError(&det, Capability.staleError(&det, "<unknown>"));
                        _ = cap.head.takeReference();

                        stage.stderr.deinit();
                        // Never close when done, since the other one will close it if applicable.
                        stage.stderr = .{ .file = .{ .file_cap_no_close = cap } };
                    },
                    .file_close, .file_no_close => |io_file| {
                        stage.stderr.deinit();
                        // Never close when done, since the other one will close it if applicable.
                        stage.stderr = .{ .file = .{ .file_no_close = io_file } };
                    },
                }
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
///
/// The capability is the whole handle: there is no pid table and nothing reaps a
/// child on its own. A script waits for the pipeline or closes it, and anything
/// left over is closed by `Capability.deinitGlobals` at shutdown. That is the
/// same bargain as a file handle, and it is why [exec] hands back a capability
/// rather than a pid, which is forgeable and goes stale into whatever process
/// the system next gives that number to.
const Process = struct {
    /// Processes currently only allow one place to wait on them, so once a
    /// thread starts waiting on this process it locks `wait_mutex`.
    wait_mutex: Io.Mutex = .init,
    /// Guards every stage's `termination`, so [pid] can read them while a
    /// [wait] holds `wait_mutex` for as long as the pipeline runs.
    termination_mutex: Io.Mutex = .init,
    waited: bool = false,
    /// See `Stage` for which lock each field needs.
    stages: []Process.Stage,
    /// Result from the pipeline. Can be null if the output of the pipeline
    /// was redirected.
    stdout_capture: ?Io.File,
    /// Each stage's captured stderr, in stage order. Null for the stages
    /// where stderr wasn't captured.
    stderr_captures: []?Io.File = &.{},

    pub const Stage = struct {
        /// Only use while `wait_mutex` is locked.
        child: process.Child,
        /// The error code names the stage that decided the pipeline's
        /// outcome, but reaping a child clears `child.id`.
        pid: process.Child.Id,
        /// How the child ended, or null while it hasn't been reaped. Written
        /// only while holding both `wait_mutex` and `termination_mutex`, so
        /// holding either is enough to read it.
        termination: ?process.Child.Term = null,
    };

    /// For readers that don't hold `wait_mutex`, such as [pid].
    pub fn getTermination(self: *Process, stage_index: usize) ?process.Child.Term {
        self.termination_mutex.lockUncancelable(heap.global_io);
        defer self.termination_mutex.unlock(heap.global_io);
        return self.stages[stage_index].termination;
    }

    /// The caller holds `wait_mutex`, having just reaped the stage's `child`.
    fn setTermination(self: *Process, stage_index: usize, termination: process.Child.Term) void {
        self.termination_mutex.lockUncancelable(heap.global_io);
        defer self.termination_mutex.unlock(heap.global_io);
        self.stages[stage_index].termination = termination;
    }

    pub const WaitError = error{AlreadyWaited} || process.Child.WaitError;

    /// Waits for every stage and reports how the overall pipeline ended.
    /// Kills/waits all processes in all cases excluding error.AlreadyWaited
    /// (since error.AlreadyWaited means that the process was already
    /// destroyed).
    pub fn wait(self: *Process) WaitError!process.Child.Term {
        if (!self.wait_mutex.tryLock()) return error.AlreadyWaited;
        defer self.wait_mutex.unlock(heap.global_io);

        // Have all the stages terminated? If so, it means this pipeline
        // has already run.
        for (self.stages) |*stage| {
            if (stage.termination == null) break;
        } else return error.AlreadyWaited;

        for (0.., self.stages) |i, *stage| {
            if (stage.termination != null) continue;
            const termination = stage.child.wait(heap.global_io) catch |err| {
                // Kill the remaining stages (no need to kill the
                // previous stages, since they already were waited on).
                for (i.., self.stages[i..]) |kill_index, *to_kill| {
                    if (to_kill.termination != null) continue;
                    to_kill.child.kill(heap.global_io);
                    self.setTermination(kill_index, .{ .signal = .TERM });
                }
                return err;
            };
            self.setTermination(i, termination);
        }

        return self.getPipelineTermination().termination;
    }

    pub fn deinit(self: *Process) void {
        // Kill all running tasks if the process hasn't been waited on yet.
        if (self.wait_mutex.tryLock()) {
            defer self.wait_mutex.unlock(heap.global_io);
            for (0.., self.stages) |i, *stage| {
                if (stage.termination != null) continue;
                stage.child.kill(heap.global_io);
                self.setTermination(i, .{ .signal = .TERM });
            }
        }

        for (self.stderr_captures) |capture| if (capture) |file| file.close(heap.global_io);
        if (self.stdout_capture) |file| file.close(heap.global_io);
        heap.global_gpa.free(self.stages);
        heap.global_gpa.free(self.stderr_captures);

        self.* = undefined;
    }

    pub const Outcome = struct {
        termination: process.Child.Term,
        /// Index of the stage that `termination` came from.
        stage: usize,
    };

    /// Get the termination of the whole pipeline, following bash semantics:
    /// If no stages failed, then return the last stage's termination.
    /// Else a stage failed, so return the failed stage's termination instead.
    /// Every stage must have been reaped.
    pub fn getPipelineTermination(self: *Process) Outcome {
        self.termination_mutex.lockUncancelable(heap.global_io);
        defer self.termination_mutex.unlock(heap.global_io);

        const stages = self.stages;
        var index = stages.len;
        while (index > 0) {
            index -= 1;
            const termination = stages[index].termination.?;
            switch (termination) {
                .exited => |code| if (code != 0) {
                    return .{ .termination = termination, .stage = index };
                },
                else => return .{ .termination = termination, .stage = index },
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

const interned_childstatus = heap.InternedString.newValue("ChildStatus");
const interned_childkilled = heap.InternedString.newValue("ChildKilled");
const interned_childsusp = heap.InternedString.newValue("ChildSuspended");
const interned_childunknown = heap.InternedString.newValue("ChildUnknown");
const interned_out = heap.InternedString.newValue("out");
const interned_err = heap.InternedString.newValue("err");
const interned_code = heap.InternedString.newValue("code");
const interned_zicl = heap.InternedString.newValue("Zicl");
const interned_io = heap.InternedString.newValue("Io");

/// Reports a failed system call. The result becomes `what` followed by the
/// error's name, and the error code becomes `{Zicl Io <name>}`.
/// error.OutOfMemory is propagated rather than reported.
fn osError(interp: *Interp, err: anyerror, comptime what: []const u8, args: anytype) Interp.Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    const name = heap.InternedString.newValue(@errorName(err));
    return interp.setErrorWithCode(&.{ interned_zicl, interned_io, name }, what ++ ": {t}", args ++ .{err});
}

/// Writes a finished pipeline's captured output to `stdout` and `stderr`,
/// with every stage's stderr in stage order. Every stage must have exited,
/// or the captures may be incomplete. Returns error.WriteFailed when either
/// writer fails, for the caller to interpret.
fn readCaptures(
    interp: *Interp,
    body: *const Process,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) (Interp.Error || error{WriteFailed})!void {
    // `File.reader` reads positionally from offset 0, since the child shares
    // the file's offset.
    if (body.stdout_capture) |file| {
        var file_reader = file.reader(heap.global_io, &.{});
        _ = file_reader.interface.streamRemaining(stdout) catch |err| switch (err) {
            error.WriteFailed => return error.WriteFailed,
            error.ReadFailed => return osError(interp, file_reader.err.?, "error reading from child", .{}),
        };
    }

    for (body.stderr_captures) |slot| {
        const file = slot orelse continue;
        var file_reader = file.reader(heap.global_io, &.{});
        _ = file_reader.interface.streamRemaining(stderr) catch |err| switch (err) {
            error.WriteFailed => return error.WriteFailed,
            error.ReadFailed => return osError(interp, file_reader.err.?, "error reading from child", .{}),
        };
    }
}

/// Sets the result of a finished pipeline: the `{out err code}` dict when
/// `split`, and otherwise its output, raising when any stage ended
/// abnormally. Both [exec] and [wait] report this way.
fn reportResult(interp: *Interp, body: *Process, split: bool) Interp.Error!void {
    var stdout_bytes: Io.Writer.Allocating = .init(heap.global_gpa);
    defer stdout_bytes.deinit();
    var stderr_bytes: Io.Writer.Allocating = .init(heap.global_gpa);
    defer stderr_bytes.deinit();
    readCaptures(interp, body, &stdout_bytes.writer, &stderr_bytes.writer) catch |err| switch (err) {
        // An `Io.Writer.Allocating` only fails to write when it fails to grow.
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    const stdout = stdout_bytes.written();
    const stderr = stderr_bytes.written();

    const outcome = body.getPipelineTermination();
    if (split) return setSplitResult(interp, outcome.termination, stdout, stderr);

    const succeeded = switch (outcome.termination) {
        .exited => |exit_code| exit_code == 0,
        else => false,
    };
    if (succeeded) return interp.setResultFormatted("{s}{s}", .{ stdout, stderr });

    const code = childStatus(body.stages, outcome);
    // Like Tcl, say how the child ended only when it explained nothing itself,
    // since its own diagnostic is the better message.
    if (stderr.len == 0) {
        return interp.setErrorWithCode(&code, "{s}{f}", .{ stdout, TermMessage{ .term = outcome.termination } });
    }
    return interp.setErrorWithCode(&code, "{s}{s}", .{ stdout, stderr });
}

/// Sets the result to the `{out err code}` dict reported by `-split`.
fn setSplitResult(interp: *Interp, termination: process.Child.Term, stdout: []const u8, stderr: []const u8) Interp.Error!void {
    // The parts are reported apart; nothing raises, since a caller asking
    // for them is asking to inspect the outcome. `code` renders a killed
    // stage as 128 plus its signal, the way a shell does.
    const code: i64 = switch (termination) {
        .exited => |exit_code| exit_code,
        .signal, .stopped => |sig| 128 + @as(i64, @intFromEnum(sig)),
        .unknown => 1,
    };
    const out_value = try objects.String.newValue(stdout);
    defer out_value.dropReference();
    const err_value = try objects.String.newValue(stderr);
    defer err_value.dropReference();
    const dict = try objects.Dictionary.new(&.{
        interned_out,  out_value,
        interned_err,  err_value,
        interned_code, objects.Integer.new(code),
    });
    interp.setResultOwning(dict.asHead().asValue());
}

/// The `{ChildStatus pid code}`-style triple naming the stage that decided
/// the pipeline's outcome, modeled on Jim's, for [catch]/[try] to dispatch on.
fn childStatus(stages: []const Process.Stage, outcome: Process.Outcome) [3]Value {
    const kind: Value, const detail: i64 = switch (outcome.termination) {
        .exited => |exit_code| .{ interned_childstatus, exit_code },
        .signal => |sig| .{ interned_childkilled, @intFromEnum(sig) },
        .stopped => |sig| .{ interned_childsusp, @intFromEnum(sig) },
        // Its own word, so a pipeline whose outcome was lost is not mistaken
        // for one that exited with whatever is in the raw wait status.
        .unknown => |raw| .{ interned_childunknown, raw },
    };
    return .{ kind, objects.Integer.new(stages[outcome.stage].pid), objects.Integer.new(detail) };
}

/// Formats, with `{f}`, how a child that ended abnormally ended.
const TermMessage = struct {
    term: process.Child.Term,

    pub fn format(message: TermMessage, writer: *Io.Writer) Io.Writer.Error!void {
        switch (message.term) {
            .signal => |sig| try writer.print("child killed by signal {d}", .{@intFromEnum(sig)}),
            .stopped => |sig| try writer.print("child suspended by signal {d}", .{@intFromEnum(sig)}),
            .exited, .unknown => try writer.writeAll("child process exited abnormally"),
        }
    }
};

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
        const process_cap = try Capability.newTakingOwnership(&cap_backing.head);
        errdefer {
            process_cap.close();
            process_cap.asHead().dropReference();
        }

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
                else => return osError(interp, err, "couldn't set up redirections", .{}),
            };
            // Take ownership of everything.
            break :pipeline .{
                .stages = stages,
                .is_background_process = is_background_process,
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
                const capture = createTempInDefaultDir(pipeline.environ.get()) catch |err|
                    return osError(interp, err, "couldn't create a temporary file", .{});
                stderr_captures.appendAssumeCapacity(capture);
            } else {
                stderr_captures.appendAssumeCapacity(null);
            }
        }

        // We also create a tempfile for stdout, to avoid a deadlock between us writing to the
        // process's stdin and reading from the process's stdout.
        const stdout_capture: ?Io.File = blk: {
            if (pipeline.stages[pipeline.stages.len - 1].stdout == .capture) {
                break :blk createTempInDefaultDir(pipeline.environ.get()) catch |err|
                    return osError(interp, err, "couldn't create a temporary file", .{});
            } else break :blk null;
        };
        errdefer if (stdout_capture) |file| file.close(heap.global_io);

        // This will contain all the spawned stages.
        var proc_stages = try std.ArrayList(Process.Stage).initCapacity(heap.global_gpa, pipeline.stages.len);
        defer proc_stages.deinit(heap.global_gpa);
        defer for (proc_stages.items) |*stage| stage.child.kill(heap.global_io);

        var read_end_from_previous: ?Io.File = null;
        defer if (read_end_from_previous) |val| val.close(heap.global_io);
        for (pipeline.stages, 0..) |stage, i| {
            const pipe_files: ?[2]Io.File = blk: {
                // Create a pipe whenever either side of the pipe is used. If
                // this stage forwards but the next stage doesn't consume, the
                // read end is closed one the next stage spawns, so this stage
                // will die from SIGPIPE if it writes. Conversely, if the next
                // stage consumes but this stage doesn't forward, the write end
                // is closed right after this stage spawns, so the next stage
                // will read EOF. This matches how bash handles piping.

                const forwards = stage.stdout == .forward or stage.stderr == .forward;
                const next_consumes = i < pipeline.stages.len - 1 and pipeline.stages[i + 1].stdin == .consume;
                if (forwards or next_consumes) {
                    const pipe_fds = Threaded.pipe2(.{ .CLOEXEC = true }) catch |err|
                        return osError(interp, err, "couldn't create pipe", .{});
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
                .file => |file| .{ .file = file.get() },
            };

            const stdout_io: process.SpawnOptions.StdIo = switch (stage.stdout) {
                // Never used in `stage.stdout`.
                .use_stdout => unreachable,
                .forward => .{ .file = write_end.? },
                .file => |file| .{ .file = file.get() },
                .capture => .{ .file = stdout_capture.? },
            };

            const stderr_io: process.SpawnOptions.StdIo = switch (stage.stderr) {
                // Only used internally during parsing, so we shouldn't see this
                // intermetiate state.
                .use_stdout => unreachable,
                .forward => .{ .file = write_end.? },
                .file => |file| .{ .file = file.get() },
                .capture => .{ .file = stderr_captures.items[i].? },
            };

            const child = process.spawn(heap.global_io, .{
                .argv = stage.args,
                .stdin = stdin_io,
                .stdout = stdout_io,
                .stderr = stderr_io,
                .environ_map = pipeline.environ.get(),
            }) catch |err| return osError(interp, err, "couldn't exec \"{s}\"", .{stage.args[0]});
            proc_stages.appendAssumeCapacity(.{ .child = child, .pid = child.id.? });

            // The child holds its own copy now, so we can close the read end in
            // our process.
            if (read_end_from_previous) |file| file.close(heap.global_io);
            read_end_from_previous = read_end;
            read_end = null;
        }

        try proc_stages.shrinkAndFreePrecise(heap.global_gpa, proc_stages.items.len);
        try stderr_captures.shrinkAndFreePrecise(heap.global_gpa, stderr_captures.items.len);

        errdefer comptime unreachable;
        cap_backing.body = .{
            .stages = proc_stages.toOwnedSliceAssert(),
            .stdout_capture = stdout_capture,
            .stderr_captures = stderr_captures.toOwnedSliceAssert(),
        };
        break :capability process_cap;
    };

    if (is_background_process) {
        interp.setResultOwning(process_capability.asHead().asValue());
        return;
    }
    // The capability never escapes a foreground [exec], so closing it here
    // kills anything still running and closes the capture files.
    defer {
        process_capability.close();
        process_capability.asHead().dropReference();
    }

    var det: ErrorDetails = undefined;
    const backing = try interp.wrapError(&det, process_capability.getBacking(Process.Backing, &det));
    defer backing.head.dropInFlight();
    const body = &backing.body;

    _ = body.wait() catch |err| return osError(interp, err, "error waiting for child", .{});
    return reportResult(interp, body, split_stdout_and_stderr);
}

/// [wait]: reports a background pipeline's result exactly as a foreground
/// [exec] would have, with `-split` choosing the `{out err code}` dict.
/// Waiting closes the process, so a pipeline can only be waited on once.
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
    // A pipeline can only be waited on once, so the process is closed however
    // this ends. Our in-flight mark keeps the capture files open until we're
    // done reading them, after which closing cleans them up.
    defer @constCast(cap).close();

    _ = backing.body.wait() catch |err| switch (err) {
        error.AlreadyWaited => return interp.setErrorInterned("process has already been waited on"),
        else => return osError(interp, err, "error waiting for child", .{}),
    };
    return reportResult(interp, &backing.body, split);
}

/// [pid]
///
/// With no arguments, this process. With a process capability, the pids of its
/// stages, for reaching a child through something other than the capability, a
/// signal being the usual reason. A stage already waited for contributes
/// nothing, its number having stopped meaning anything. A pid that does come
/// back may be reaped before the caller can use it, a race inherent to naming a
/// process by number rather than by capability.
pub fn pidCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    if (args.len == 1) {
        interp.setResultInteger(std.os.linux.getpid());
        return;
    }

    var det: ErrorDetails = undefined;
    const cap = try interp.wrapError(&det, Capability.shimmerFrom(&det, &args[1]));
    const backing = try interp.wrapError(&det, cap.getBacking(Process.Backing, &det));
    defer backing.head.dropInFlight();
    const body = &backing.body;

    var values: std.ArrayList(Value) = .empty;
    defer values.deinit(heap.local_arena);
    for (0.., body.stages) |i, *stage| {
        if (body.getTermination(i) == null) try values.append(heap.local_arena, objects.Integer.new(stage.pid));
    }

    const list = try objects.List.new(values.items);
    interp.setResultOwning(list.asHead().asValue());
}

pub fn registerCommands(interp: *Interp) !void {
    try common.registerCommand(interp, "exec", execCmd, "?-split? ?-env dict? ?--? ?|? command ?arg ...?", 1, null);
    try common.registerCommand(interp, "wait", waitCmd, "?-split? process", 1, 2);
    try common.registerCommand(interp, "pid", pidCmd, "?process?", 0, 1);
}

const testing = std.testing;

fn testExecBasics(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Raw results: exactly what the child wrote, newlines included.
    try interp.testExpectScriptResult("hello\n", "exec echo hello");
    try interp.testExpectScriptResult("a\nb\n", "exec echo a\\nb");

    // Pipelines, and a mid stage's stderr folded in stage order.
    try interp.testExpectScriptResult("hi\n", "exec echo hi | sort");
    try interp.testExpectScriptResult("from-first\n", "exec sh -c {echo from-first >&2} | cat");

    // `|&` and `2>@1` both send stderr wherever this stage's stdout goes.
    try interp.testExpectScriptResult("TO-PIPE\n", "exec sh -c {echo to-pipe >&2} |& tr a-z A-Z");
    try interp.testExpectScriptResult("merge\n", "exec sh -c {echo merge >&2} 2>@1 | cat");

    // The `<<` document is fed exactly: no trailing newline is added.
    try interp.testExpectScriptResult("inline", "exec cat << inline");
}

fn testExecFiles(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buffer[0..(try tmp.dir.realPath(heap.global_io, &path_buffer))];
    const out_path = try std.fmt.allocPrint(ta, "{s}/out.txt", .{dir_path});
    defer ta.free(out_path);

    const write_script = try std.fmt.allocPrint(ta, "exec echo out > {s}", .{out_path});
    defer ta.free(write_script);
    // Output went to the file, so the command itself reports nothing.
    try interp.testExpectScriptResult("", write_script);

    const read_script = try std.fmt.allocPrint(ta, "exec cat {s}", .{out_path});
    defer ta.free(read_script);
    try interp.testExpectScriptResult("out\n", read_script);
}

fn testExecAbnormal(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // The generic message only when the child said nothing itself.
    try interp.testExpectScriptError(error.EvalError, "child process exited abnormally", "exec false");
    // The child's own diagnostic wins, and the error code names it for
    // [catch]/[try]: `{ChildStatus pid code}`.
    try interp.testExpectScriptError(error.EvalError, "no good\n", "exec sh -c {echo no good >&2; exit 3}");
    try interp.testExpectScriptResult("true", "catch {exec false} m o; string match {ChildStatus * 1} [dict get $o -errorcode]");
    try interp.testExpectScriptResult("true", "catch {exec sh -c {exit 3}} m o; string match {ChildStatus * 3} [dict get $o -errorcode]");
    // An earlier failure is not swallowed by a successful tail.
    try interp.testExpectScriptError(error.EvalError, "child process exited abnormally", "exec false | true");
    // A missing binary reports at exec time.
    try interp.testExpectScriptError(error.EvalError, "couldn't exec \"/nonexistent\": FileNotFound", "exec /nonexistent");
    try interp.testExpectScriptResult("Zicl Io FileNotFound", "catch {exec /nonexistent} m o; dict get $o -errorcode");
}

fn testExecSplit(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // `-split` never raises; `code` carries the outcome instead, and the
    // parts are raw.
    try interp.testExpectScriptResult("out\n", "dict get [exec -split sh -c {echo out; echo err >&2}] out");
    try interp.testExpectScriptResult("err\n", "dict get [exec -split sh -c {echo out; echo err >&2}] err");
    try interp.testExpectScriptResult("0", "dict get [exec -split true] code");
    try interp.testExpectScriptResult("3", "dict get [exec -split sh -c {exit 3}] code");
}

fn testExecBackground(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // [wait] reports what a foreground [exec] would have. Output is captured
    // to files either way, so these children may be as loud as they like.
    try interp.testExpectScriptResult("out\n", "set p [exec sh -c {echo out} &]; wait $p");
    // Waiting closed it.
    try interp.testExpectScriptResult("true", "catch {wait $p} m; string match {*is stale} $m");

    // A failure raises from [wait], and still closes the process.
    try interp.testExpectScriptResult("true", "set f [exec false &]; catch {wait $f} m o; string match {ChildStatus * 1} [dict get $o -errorcode]");
    try interp.testExpectScriptResult("true", "catch {wait $f} m; string match {*is stale} $m");

    // A background pipeline chooses `-split` at [wait].
    try interp.testExpectScriptResult("out\n", "set q [exec sh -c {echo out; echo err >&2} &]; set split [wait -split $q]; dict get $split out");
    try interp.testExpectScriptResult("err\n", "dict get $split err");
    try interp.testExpectScriptResult("3", "set q [exec sh -c {exit 3} &]; set split [wait -split $q]; dict get $split code");
}

fn testExecSigpipe(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Ignoring SIGPIPE in the parent checks that children start with it reset
    // to the default. Otherwise [yes] gets EPIPE, and may never exit. This
    // comes after `common.testStart`, since that installs `Threaded`'s own
    // SIGPIPE handler.
    const posix = std.posix;
    const ignore: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    var old: posix.Sigaction = undefined;
    posix.sigaction(.PIPE, &ignore, &old);
    defer posix.sigaction(.PIPE, &old, null);

    // Tcl parity: a writer killed by SIGPIPE is a failure, even when the
    // reader stopped on purpose.
    try interp.testExpectScriptResult("true", "catch {exec yes | head -n 1} m o; string match {ChildKilled * 13} [dict get $o -errorcode]");
}

fn testExecListGrammar(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Nothing inside a list is an operator, so a redirection character can be an
    // ordinary argument. This is the one thing the classic grammar cannot do.
    try interp.testExpectScriptResult(">\n", "exec | {echo >}");
    try interp.testExpectScriptResult("| &\n", "exec | {echo {|} &}");

    // A list built by the script runs without {*}, since the list is the argv.
    try interp.testExpectScriptResult("a b\n", "set cmd [list echo a b]; exec | $cmd");

    // The leading `|` only opts into the grammar; a `|` between stages still
    // separates them the same way it does in the classic grammar.
    try interp.testExpectScriptResult("a\nb\nc\n", "exec | {sh -c {echo c; echo a; echo b; echo a}} | {sort -u}");

    // A word that is neither a list nor a redirection is named rather than run.
    try interp.testExpectScriptError(
        error.EvalError,
        "hello is not a redirection (did you pass in a command parameter outside the command list?)",
        "exec | {echo} hello",
    );
    try interp.testExpectScriptError(error.EvalError, "didn't specify command to execute", "exec | {}");
}

fn testExecRedirectsInput(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buffer[0..(try tmp.dir.realPath(heap.global_io, &path_buffer))];

    const write_script = try std.fmt.allocPrint(ta, "exec echo fed > {s}/in.txt", .{dir_path});
    defer ta.free(write_script);
    try interp.testExpectScriptResult("", write_script);

    // Separated and attached operands mean the same thing.
    const separated_script = try std.fmt.allocPrint(ta, "exec cat < {s}/in.txt", .{dir_path});
    defer ta.free(separated_script);
    try interp.testExpectScriptResult("fed\n", separated_script);
    const attached_script = try std.fmt.allocPrint(ta, "exec cat <{s}/in.txt", .{dir_path});
    defer ta.free(attached_script);
    try interp.testExpectScriptResult("fed\n", attached_script);

    try interp.testExpectScriptResult("3\n", "exec sh -c {wc -c} << abc");
}

fn testExecEnv(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // `-env` replaces the child's whole environment.
    try interp.testExpectScriptResult("only", "exec -env {ZICL_TEST only} sh -c {echo -n $ZICL_TEST}");
    try interp.testExpectScriptResult("", "exec -env {} sh -c {echo -n $ZICL_TEST}");
}

fn testExecMalformed(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptError(error.EvalError, "\">\" missing redirection payload", "exec echo hi >");
    // Nothing but switches leaves no command behind, whichever grammar follows.
    try interp.testExpectScriptError(error.EvalError, "didn't specify command to execute", "exec -split");
    // A stage built entirely of redirections has no argv of its own.
    try interp.testExpectScriptError(error.EvalError, "didn't specify command to execute", "exec < /dev/null");
    try interp.testExpectScriptError(error.EvalError, "didn't specify command to execute", "exec cat |");
    // An unknown option is refused rather than run, since the alternative is
    // spawning something the script did not name.
    try interp.testExpectScriptError(error.EvalError, "unknown flag: -nope", "exec -nope echo hi");
    // A word that begins with '-' is indistinguishable from an option, so it is
    // refused as one until `--` says otherwise.
    try interp.testExpectScriptError(error.EvalError, "unknown flag: -n hi", "exec {-n hi}");
    try interp.testExpectScriptResult("-nope\n", "exec -- echo -nope");
}

fn testExecCloseAndPid(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    var expected: [32]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&expected, "{}", .{std.os.linux.getpid()});
    try interp.testExpectScriptResult(rendered, "pid");

    // A pipeline that outlives the [pid] call, so there is something to report.
    try interp.testExpectScriptResult("2", "set p [exec sh -c {sleep 30} | cat &]; llength [pid $p]");

    // Closing has to end a child that is still running. Without the kill this
    // would block for the sleep.
    try interp.testExpectScriptResult("", "close $p");
    try interp.testExpectScriptResult("true", "catch {pid $p} m; string match {*is stale} $m");
}

test "exec basics" {
    try memutil.checkAllocationFailures(.exhaustive, testExecBasics, .{});
}

test "exec files" {
    try memutil.checkAllocationFailures(.exhaustive, testExecFiles, .{});
}

test "exec abnormal exit" {
    try memutil.checkAllocationFailures(.exhaustive, testExecAbnormal, .{});
}

test "exec split" {
    try memutil.checkAllocationFailures(.exhaustive, testExecSplit, .{});
}

test "exec background" {
    try memutil.checkAllocationFailures(.exhaustive, testExecBackground, .{});
}

test "exec sigpipe" {
    try memutil.checkAllocationFailures(.exhaustive, testExecSigpipe, .{});
}

test "exec list grammar" {
    try memutil.checkAllocationFailures(.exhaustive, testExecListGrammar, .{});
}

test "exec redirects input" {
    try memutil.checkAllocationFailures(.exhaustive, testExecRedirectsInput, .{});
}

test "exec env" {
    try memutil.checkAllocationFailures(.exhaustive, testExecEnv, .{});
}

test "exec malformed" {
    try memutil.checkAllocationFailures(.exhaustive, testExecMalformed, .{});
}

test "exec close and pid" {
    try memutil.checkAllocationFailures(.exhaustive, testExecCloseAndPid, .{});
}

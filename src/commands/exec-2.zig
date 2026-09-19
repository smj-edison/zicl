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

/// Stores a file capability, as well as how to deinit the capability
/// when no longer in use.
const FileCapAndCleanup = struct {
    file: *capabilities.File.Backing,
    close_when_done: bool,

    pub fn deinit(cap_and_cleanup: *FileCapAndCleanup) void {
        const head = &cap_and_cleanup.file.head;
        head.dropInFlight();
        if (cap_and_cleanup.close_when_done) head.close();
        head.dropReference();

        cap_and_cleanup.* = undefined;
    }
};

const Source = union(enum) {
    /// Consume from the previous stage of the pipeline.
    consume,
    /// Referenced and marked in-flight when the Source is created.
    capability: FileCapAndCleanup,

    pub fn deinit(source: *Source) void {
        switch (source.*) {
            .capability => |*cap| cap.deinit(),
            .consume => {},
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

    pub fn deinit(sink: *Sink) void {
        switch (sink.*) {
            .capability => |*cap| cap.deinit(),
            .capture, .forward, .use_stdout => {},
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
    environ: process.Environ.Map,

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

fn parseStages(interp: *Interp, args: []Shimmerable) ![]Stage {
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
        break :blk .{ .capability = .{ .file = stdin_file, .close_when_done = true } };
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
                const redirection_file = try parseRedirectionPayload(interp, redirection.flags, redirection_payload);
                switch (redirection.flags.direction) {
                    .stdin => {
                        stage_stdin.deinit();
                        stage_stdin = .{ .capability = redirection_file };
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
            // Stdout is never `.use_stdout`; only stderr is pointed at it.
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
    /// If the process was created in split mode (by calling [exec] with `-split`),
    /// we capture the output in this file.
    stdout_capture: ?Io.File = null,
    /// Each stage's captured stderr, in stage order. `null` when the stage
    /// wasn't set to .capture.
    stderr_captures: []?Io.File = &.{},

    pub const Stage = struct {
        process: process.Child.Id,
        state: State,

        pub const State = union(enum) {
            alive: process.Child.Id,
            terminated: process.Child.Term,
        };
    };
    pub const WaitError = error{AlreadyWaited} || process.Child.WaitError;

    /// Waits for every stage and reports how the overall pipeline ended.
    pub fn wait(self: *Process) WaitError!process.Child.Term {
        if (!self.state_mutex.tryLock(heap.global_io)) return error.AlreadyWaited;
        defer self.state_mutex.unlock(heap.global_io);

        for (self.stages) |*stage| {
            // Already had its termination type recorded.
            if (stage.termination != null) continue;
            const termination = try stage.child.wait(heap.global_io);
            self.state_mutex.lockUncancelable(heap.global_io);
            stage.termination = termination;
            self.state_mutex.unlock(heap.global_io);
        }

        self.mutex.lockUncancelable(heap.global_io);
        const pipeline_termination = getPipelineTermination(self.stages).termination;
        self.mutex.unlock(heap.global_io);
        return pipeline_termination;
    }

    /// Get the pids of each of the stages, written into `out`. `out` must
    /// be the length of the number of stages in the process. If a stage
    /// has already completed, this will set that stage's id to be null
    /// in lieu of its now non-existant pid.
    pub fn pids(self: *Process, out: []?process.Child.Id) void {
        self.mutex.lockUncancelable(heap.global_io);
        defer self.mutex.unlock(heap.global_io);
        assert(out.len == self.stages.len);
        for (self.stages, out) |*stage, *item| {
            item.* = if (stage.termination != null) null else stage.pid;
        }
    }

    /// Closes and forgets every staged capture, discarding whatever they
    /// collected. Idempotent.
    pub fn discardCaptures(self: *Process) void {
        for (self.stderr_captures) |*slot| {
            if (slot.*) |file| {
                file.close(heap.global_io);
                slot.* = null;
            }
        }
        if (self.stdout_capture) |file| {
            file.close(heap.global_io);
            self.stdout_capture = null;
        }
    }

    /// Kills every still-running stage. `Child.kill` reports no status but
    /// does reap, so one is recorded: a reaped stage without a `term` is one
    /// `wait` can neither collect nor describe.
    pub fn killAll(self: *Process) void {
        for (self.stages) |*stage| {
            if (stage.termination != null) continue;
            stage.child.kill(heap.global_io);
            stage.termination = .{ .signal = .TERM };
        }
    }

    /// The termination of the whole pipeline, following bash semantics:
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

    /// Takes ownership of the stages and captures: every failure path cleans
    /// them up here, so the call is all-or-nothing for the caller.
    pub fn new(self: *Process) error{OutOfMemory}!*Capability {
        const cap_backing = heap.global_gpa.create(Backing) catch |err| {
            self.killAll();
            self.discardCaptures();
            heap.global_gpa.free(self.stages);
            heap.global_gpa.free(self.stderr_captures);
            return err;
        };
        // From assignment on, the backing owns everything; if publication
        // then fails, `newTakingOwnership` tears it all down.
        cap_backing.* = .{
            .head = .{ .vtable = &Backing.vtable, .id = .not_set },
            .body = self.*,
        };
        return try Capability.newTakingOwnership(&cap_backing.head);
    }

    pub const Backing = struct {
        head: Capability.Head,
        body: Process,

        /// Kills whatever is still running and discards the captures, since a
        /// closed capability can no longer be named and nothing could ever
        /// wait for its children or read what they wrote.
        fn deinitBody(head: *Capability.Head) callconv(.c) void {
            const backing: *Backing = @fieldParentPtr("head", head);
            backing.body.killAll();
            backing.body.discardCaptures();
        }

        fn destroyBacking(head: *Capability.Head) callconv(.c) void {
            const backing: *Backing = @fieldParentPtr("head", head);
            heap.global_gpa.free(backing.body.stages);
            heap.global_gpa.free(backing.body.stderr_captures);
            heap.global_gpa.destroy(backing);
        }

        pub const vtable: Capability.Head.VTable = .{
            .deinit_body = deinitBody,
            .destroy_backing = destroyBacking,
            .name = "process",
        };
    };
};

/// The words [wait] and the error code share for how a child ended, and the
/// keys of the `-split` dict.
const interned_childstatus = heap.InternedString.newValue("CHILDSTATUS");
const interned_childkilled = heap.InternedString.newValue("CHILDKILLED");
const interned_childsusp = heap.InternedString.newValue("CHILDSUSPENDED");
const interned_childunknown = heap.InternedString.newValue("CHILDUNKNOWN");
const interned_out = heap.InternedString.newValue("out");
const interned_err = heap.InternedString.newValue("err");
const interned_code = heap.InternedString.newValue("code");

/// The text reported for a child that did not exit cleanly, or null when it
/// did. Rendered into `buffer`.
fn abnormalExitMessage(term: process.Child.Term, buffer: []u8) ?[]const u8 {
    return switch (term) {
        .exited => |code| if (code == 0) null else "child process exited abnormally",
        .signal => |sig| std.fmt.bufPrint(
            buffer,
            "child killed by signal {d}",
            .{@intFromEnum(sig)},
        ) catch "child killed by signal",
        .stopped => |sig| std.fmt.bufPrint(
            buffer,
            "child suspended by signal {d}",
            .{@intFromEnum(sig)},
        ) catch "child suspended by signal",
        .unknown => "child process exited abnormally",
    };
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

    var pipeline: Pipeline = blk: {
        var environ = if (env_dict) |val| try buildEnvironFromDict(interp, val) else try heap.environ.clone(heap.global_gpa);
        errdefer environ.deinit();

        const stages = parseStages(interp, args_to_use) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.EvalError => return error.EvalError,
            // Anything left is an I/O error out of a redirection setup.
            else => return interp.setErrorFormatted("couldn't set up redirections: {t}", .{err}),
        };
        // Take ownership of everything.
        break :blk .{
            .stages = stages,
            .is_background_process = is_background_process,
            .split_stdout_and_stderr = split_stdout_and_stderr,
            .environ = environ,
        };
    };
    defer pipeline.deinit();

    const stage_count = pipeline.stages.len;

    var handed_over = false;
    const proc_stages = try heap.global_gpa.alloc(Process.Stage, stage_count);
    errdefer if (!handed_over) heap.global_gpa.free(proc_stages);
    // `child` and `pid` are filled in as each spawn succeeds; `term` starts
    // null so the cleanup ladder can tell a live stage from a reaped one.
    for (proc_stages) |*slot| slot.* = .{ .child = undefined, .pid = undefined };

    const stderr_captures = try heap.global_gpa.alloc(?Io.File, stage_count);
    errdefer if (!handed_over) heap.global_gpa.free(stderr_captures);
    @memset(stderr_captures, null);
    errdefer if (!handed_over) for (stderr_captures) |slot| {
        if (slot) |file| file.close(heap.global_io);
    };

    // The last stage's captured stdout, staged to a temp file for the same
    // reason the stderr captures are: a file never blocks the child, so the
    // parent can wait first and read everything back afterwards, positionally
    // and in order.
    var stdout_capture: ?Io.File = null;
    errdefer if (!handed_over) if (stdout_capture) |file| file.close(heap.global_io);

    var spawned_count: usize = 0;
    errdefer if (!handed_over) for (proc_stages[0..spawned_count]) |*stage| {
        if (stage.termination != null) continue;
        stage.child.kill(heap.global_io);
        stage.termination = .{ .signal = .TERM };
    };

    // Background output is inherited unless the caller opted into `-split`,
    // which stages captures to files instead: nobody drains a pipe in the
    // background, and a child blocked writing into one would never exit.
    const capturing = !pipeline.is_background_process or pipeline.split_stdout_and_stderr;

    // The read end this stage's stdin comes from, handed to the next spawn.
    // Error paths leave whatever has not been handed over yet; success leaves
    // this null, so one function-level defer covers both.
    var next_stdin: ?Io.File = null;
    defer if (next_stdin) |file| file.close(heap.global_io);

    for (pipeline.stages, 0..) |stage, i| {
        const last = i + 1 == stage_count;

        // The pipe into the next stage, created before the spawn so this
        // stage's stdout -- and, merged, its stderr -- has a write end to be
        // dup2'd onto. The child's dup2 owns the write end from the spawn on;
        // the parent keeping its copy would mean the next stage never sees
        // EOF, so the defer closes it whether the spawn succeeded or not.
        const pipe_fds = if (!last) Threaded.pipe2(.{ .CLOEXEC = true }) catch |err|
            return interp.setErrorFormatted("couldn't create pipe: {t}", .{err}) else null;
        defer if (pipe_fds) |fds|
            (Io.File{ .handle = fds[1], .flags = .{ .nonblocking = false } }).close(heap.global_io);

        // Nothing extra: a captured stdout is a temp file the child writes
        // and the parent reads back after the wait, never a pipe end.

        const stdin_io: process.SpawnOptions.StdIo = switch (stage.stdin) {
            // Only a stage after the first consumes; `.?` doubles as the
            // assertion that the parse half keeps that invariant.
            .consume => .{ .file = next_stdin.? },
            .capability => |cap| .{ .file = cap.file.body.file },
        };

        const stdout_io: process.SpawnOptions.StdIo = switch (stage.stdout) {
            // The epilogue resolves every stderr `.use_stdout` before we get
            // here, and stdout itself is never set to it.
            .use_stdout => unreachable,
            .forward => .{ .file = .{ .handle = pipe_fds.?[1], .flags = .{ .nonblocking = false } } },
            .capability => |cap| .{ .file = cap.file.body.file },
            .capture => if (capturing) blk: {
                stdout_capture = createTempInDefaultDir() catch |err|
                    return interp.setErrorFormatted("couldn't create a temporary file: {t}", .{err});
                break :blk .{ .file = stdout_capture.? };
            } else .{ .file = ioutil.getStdout() }, // through the redirect cell, like [puts]
        };

        const stderr_io: process.SpawnOptions.StdIo = switch (stage.stderr) {
            // The epilogue turned `.use_stdout` into one of these, where
            // "wherever stdout goes" had become concrete.
            .use_stdout => unreachable,
            // The very descriptor stdout got, so the streams share one open
            // file description and interleave the way the child wrote them.
            .forward => stdout_io,
            .capability => |cap| .{ .file = cap.file.body.file },
            .capture => if (capturing) blk: {
                stderr_captures[i] = createTempInDefaultDir() catch |err|
                    return interp.setErrorFormatted("couldn't create a temporary file: {t}", .{err});
                break :blk .{ .file = stderr_captures[i].? };
            } else .{ .file = ioutil.getStderr() },
        };

        const child = process.spawn(heap.global_io, .{
            .argv = stage.args,
            .stdin = stdin_io,
            .stdout = stdout_io,
            .stderr = stderr_io,
            .environ_map = &pipeline.environ,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return interp.setErrorFormatted("couldn't exec \"{s}\": {t}", .{ stage.args[0], err }),
        };
        proc_stages[i] = .{ .child = child, .pid = child.id.? };
        spawned_count += 1;

        // The child holds its own copy now, so the parent's read end of the
        // pipe it consumes is only keeping the number warm.
        if (next_stdin) |file| file.close(heap.global_io);
        next_stdin = if (pipe_fds) |fds|
            .{ .handle = fds[0], .flags = .{ .nonblocking = false } }
        else
            null;
    }

    if (pipeline.is_background_process) {
        var proc = Process{
            .stages = proc_stages,
            .stdout_capture = stdout_capture,
            .stderr_captures = stderr_captures,
        };
        // Every failure path inside `new` cleans up itself, so the error
        // ladder above has to stand down.
        handed_over = true;
        const cap = try proc.new();
        interp.setResultOwning(cap.asHead().asValue());
        return;
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
        const abnormal = abnormalExitMessage(outcome.termination, &message_buffer);
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

//! [exec] and [wait].
//!
//! Following TIP 424, a stage is told from its redirections by position rather
//! than by what its words look like. Every stage is exactly one list, which is
//! its argv, and the words after it up to the next `|` are its redirections.
//!
//! ```
//! exec {echo >}                          ;# ">" is an argument, not an operator
//! exec {cc -c foo.c} 2> errors.txt
//! exec {cat} < in.txt | {sort -u} > out.txt
//! exec $argv                             ;# argv is already a list
//! ```
//!
//! Output follows Jim: stderr is folded into the result and only an abnormal
//! exit raises, so `[exec {cc ...}]` hands back compiler warnings rather than
//! throwing on them. `-split` reports the parts separately instead, and does not
//! raise, so a failure can be inspected rather than caught.

const std = @import("std");

const common = @import("common.zig");
const heap = common.heap;
const objects = common.objects;
const ErrorDetails = common.ErrorDetails;
const Interp = common.Interp;
const Shimmerable = common.Shimmerable;
const registerCommand = common.registerCommand;
const memutil = common.memutil;

const Capability = @import("../Capability.zig");
const capabilities = @import("../capabilities.zig");
const ioutil = @import("../ioutil.zig");
const io_commands = @import("io.zig");

const File = std.Io.File;
const process = std.process;

/// The most stages one [exec] can spawn, bounded so that [pid] can snapshot
/// them into a fixed array.
pub const max_pipeline_stages = 64;

// -- The parsed form of an [exec] invocation. --

/// Where the first stage's stdin comes from.
const Source = union(enum) {
    inherit,
    path: []const u8,
    /// `<<text`, held as the literal bytes to feed the child.
    text: []const u8,
    file: File,
};

/// Where a stream ends up.
const Sink = union(enum) {
    /// Read back into the [exec] result.
    capture,
    /// The parent's own stream, which is where an unredirected background child
    /// writes: there is nobody left to read a pipe once [exec] has returned.
    inherit,
    path: struct { bytes: []const u8, append: bool },
    file: File,
};

const Stage = struct {
    argv: []const []const u8,
    /// Per stage rather than per pipeline, so that `exec {a} 2> a.log | {b} 2>
    /// b.log` can separate the two.
    stderr: Sink = .capture,
    /// Set by a following `|&`: this stage's stderr joins the pipe to the next
    /// stage rather than being collected with the rest.
    stderr_to_pipe: bool = false,
    /// Set by `>&` or `>>&`: this stage's stderr goes to the very descriptor its
    /// stdout does. Opening the sink twice would give each stream its own file
    /// offset, and whichever wrote second would overwrite the other.
    stderr_to_stdout: bool = false,
};

/// One `{cmd} | {cmd} | {cmd}` chain plus its redirections. A plain
/// `exec {cat}` is a one-stage pipeline, not a separate case.
const Pipeline = struct {
    stages: []Stage,
    stdin: Source = .inherit,
    stdout: Sink = .capture,
    /// Which stage carried the `>`, so that one written anywhere but the end of
    /// the pipeline can be refused once the whole thing has been read.
    stdout_stage: ?usize = null,
    background: bool = false,
    split: bool = false,
};

/// Returns the operand of a redirection. `attached` is whatever followed the
/// operator in the same word; when it is empty the operand is the next word
/// instead and `index` advances past it, which is `> file` against `>file`.
fn takeOperand(
    interp: *Interp,
    args: []Shimmerable,
    index: *usize,
    attached: []const u8,
    operator: []const u8,
) Interp.Error![]const u8 {
    if (attached.len > 0) return attached;
    index.* += 1;
    if (index.* >= args.len) {
        return interp.setErrorFormatted("can't specify \"{s}\" as last word in command", .{operator});
    }
    return try args[index.*].getString();
}

/// Resolves the operand of an `@` redirection to an open file. Takes a file
/// capability or one of the three standard stream names, checking `direction`,
/// what the child will do with it, against how a capability was opened.
fn resolveHandle(interp: *Interp, name: []const u8, direction: enum { read, write }) Interp.Error!File {
    // Read straight out of the redirect cell. `ioutil`'s lock only orders
    // writers that go through it, and the child writes on a dup of its own, so
    // taking the lock here would order nothing.
    if (std.mem.eql(u8, name, "stdout")) {
        return .{ .handle = ioutil.global_stdout_fd.load(.monotonic), .flags = .{ .nonblocking = false } };
    }
    if (std.mem.eql(u8, name, "stderr")) {
        return .{ .handle = ioutil.global_stderr_fd.load(.monotonic), .flags = .{ .nonblocking = false } };
    }
    if (std.mem.eql(u8, name, "stdin")) {
        return .{ .handle = std.posix.STDIN_FILENO, .flags = .{ .nonblocking = false } };
    }

    // Shimmered through a temporary, because the name may be a slice out of the
    // middle of a word (`>@<zicl://...>`) rather than a word of its own.
    const named = try objects.String.newValue(name);
    defer named.release();
    var shim: Shimmerable = .{ .original = named };
    defer shim.discardChanges();

    var det: ErrorDetails = undefined;
    const cap = try interp.wrapError(&det, Capability.shimmerFrom(&det, &shim));
    const backing = try interp.wrapError(&det, cap.getBacking(capabilities.File.Backing, &det));

    // Caught here because the child would instead fail on its first read or
    // write, naming neither the handle nor the redirection.
    const usable = switch (backing.body.mode) {
        .r => direction == .read,
        .w => direction == .write,
        .@"r+", .@"w+" => true,
    };
    if (!usable) return interp.setErrorFormatted(
        "capability \"{s}\" was opened with mode {t}, so a child cannot {t} it",
        .{ name, backing.body.mode, direction },
    );

    return backing.body.file;
}

/// Parses `args[1..]` into a `Pipeline`. Everything the result points at is
/// either a slice of an argument's string rep or an allocation in
/// `heap.local_arena`, so it needs no freeing.
fn parse(interp: *Interp, args: []Shimmerable) Interp.Error!Pipeline {
    var pipeline: Pipeline = .{ .stages = &.{} };

    var rest = args[1..];

    // A stage list renders as its own text, so one whose command begins with '-'
    // is indistinguishable from an option and is refused as one; `--` is how it
    // gets through. Guessing would run a mistyped option as a command.
    while (rest.len > 0) {
        const word = try rest[0].getString();
        if (word.len == 0 or word[0] != '-') break;
        rest = rest[1..];
        if (std.mem.eql(u8, word, "--")) break;
        if (std.mem.eql(u8, word, "-split")) {
            pipeline.split = true;
            continue;
        }
        return interp.setErrorFormatted("bad option \"{s}\": must be -split or --", .{word});
    }

    if (rest.len > 0 and std.mem.eql(u8, try rest[rest.len - 1].getString(), "&")) {
        pipeline.background = true;
        rest = rest[0 .. rest.len - 1];
    }

    if (rest.len == 0) {
        return interp.setErrorFormatted("didn't specify command to execute", .{});
    }

    var stages: std.ArrayList(Stage) = .empty;

    // Alternates: one word as argv, then redirections until a `|` starts the
    // next stage.
    var index: usize = 0;
    while (true) {
        const argv = try wordsOf(interp, &rest[index]);
        if (argv.len == 0) {
            return interp.setErrorFormatted("didn't specify command to execute", .{});
        }
        var stage: Stage = .{ .argv = argv };
        index += 1;

        const stage_index = stages.items.len;
        var last = true;
        while (index < rest.len) : (index += 1) {
            const word = try rest[index].getString();
            if (std.mem.eql(u8, word, "|") or std.mem.eql(u8, word, "|&")) {
                if (index == rest.len - 1) {
                    return interp.setErrorFormatted("illegal use of | or |& in command", .{});
                }
                if (std.mem.eql(u8, word, "|&")) {
                    if (stage.stderr != .capture) {
                        return interp.setErrorFormatted("can't redirect a stage's stderr and also send it down the pipe with |&", .{});
                    }
                    stage.stderr_to_pipe = true;
                }
                last = false;
                index += 1;
                break;
            }
            try parseRedirection(interp, &pipeline, &stage, rest, &index, word, stage_index);
        }

        try stages.append(heap.local_arena, stage);
        if (last) break;
        if (stages.items.len >= max_pipeline_stages) {
            return interp.setErrorFormatted("too many stages in pipeline", .{});
        }
    }

    pipeline.stages = try stages.toOwnedSlice(heap.local_arena);

    // Only the last stage's stdout leaves the pipeline, so honouring a `>`
    // written next to an earlier one would redirect a different stage than the
    // script pointed at.
    if (pipeline.stdout_stage) |stage_index| {
        if (stage_index != pipeline.stages.len - 1) {
            return interp.setErrorFormatted("can only redirect output out of the last stage of a pipeline", .{});
        }
    }

    // A background child handed a pipe nobody drains fills it and wedges, so
    // what the script did not redirect goes to the parent's own streams.
    if (pipeline.background) {
        if (pipeline.split) {
            return interp.setErrorFormatted("-split cannot be used with a background pipeline", .{});
        }
        if (pipeline.stdout == .capture) pipeline.stdout = .inherit;
        for (pipeline.stages) |*stage| {
            if (stage.stderr == .capture) stage.stderr = .inherit;
        }
    }

    return pipeline;
}

/// Splits a stage's word into its argv. Read as a Tcl list, which is what makes
/// `exec {echo >}` mean what it says: nothing inside a list is an operator.
fn wordsOf(interp: *Interp, shim: *Shimmerable) Interp.Error![]const []const u8 {
    const list = try interp.getList(shim);

    const argv = try heap.local_arena.alloc([]const u8, list.items.len);
    for (list.items, argv) |item, *slot| slot.* = try item.getString();
    return argv;
}

/// Parses one redirection word into `pipeline` or `stage`, where `stage_index`
/// is the stage it was written next to. Output redirection is only recorded:
/// whether a stage is the last one is not known until the whole pipeline has
/// been read, so `parse` checks that afterwards.
fn parseRedirection(
    interp: *Interp,
    pipeline: *Pipeline,
    stage: *Stage,
    rest: []Shimmerable,
    index: *usize,
    word: []const u8,
    stage_index: usize,
) Interp.Error!void {
    if (word.len > 0 and word[0] == '<') {
        if (stage_index != 0) {
            return interp.setErrorFormatted("can only redirect input into the first stage of a pipeline", .{});
        }
        if (pipeline.stdin != .inherit) {
            return interp.setErrorFormatted("can't redirect input twice", .{});
        }
        var operand = word[1..];
        var kind: enum { path, text, file } = .path;
        if (operand.len > 0 and operand[0] == '<') {
            kind = .text;
            operand = operand[1..];
        } else if (operand.len > 0 and operand[0] == '@') {
            kind = .file;
            operand = operand[1..];
        }
        const target = try takeOperand(interp, rest, index, operand, word);
        pipeline.stdin = switch (kind) {
            .path => .{ .path = target },
            .text => .{ .text = target },
            .file => .{ .file = try resolveHandle(interp, target, .read) },
        };
        return;
    }

    if (word.len > 1 and word[0] == '2' and word[1] == '>') {
        if (stage.stderr != .capture) {
            return interp.setErrorFormatted("can't redirect a stage's stderr twice", .{});
        }
        var operand = word[2..];
        var append = false;
        var handle = false;
        if (operand.len > 0 and operand[0] == '>') {
            append = true;
            operand = operand[1..];
        }
        if (operand.len > 0 and operand[0] == '@') {
            handle = true;
            operand = operand[1..];
        }
        const target = try takeOperand(interp, rest, index, operand, word);
        stage.stderr = if (handle)
            .{ .file = try resolveHandle(interp, target, .write) }
        else
            .{ .path = .{ .bytes = target, .append = append } };
        return;
    }

    if (word.len > 0 and word[0] == '>') {
        if (pipeline.stdout_stage != null) {
            return interp.setErrorFormatted("can't redirect output twice", .{});
        }
        var operand = word[1..];
        var append = false;
        var also_stderr = false;
        var handle = false;
        if (operand.len > 0 and operand[0] == '>') {
            append = true;
            operand = operand[1..];
        }
        if (operand.len > 0 and operand[0] == '&') {
            also_stderr = true;
            operand = operand[1..];
        }
        if (operand.len > 0 and operand[0] == '@') {
            handle = true;
            operand = operand[1..];
        }
        const target = try takeOperand(interp, rest, index, operand, word);
        pipeline.stdout = if (handle)
            .{ .file = try resolveHandle(interp, target, .write) }
        else
            .{ .path = .{ .bytes = target, .append = append } };
        pipeline.stdout_stage = stage_index;
        if (also_stderr) {
            if (stage.stderr != .capture) {
                return interp.setErrorFormatted("can't redirect a stage's stderr twice", .{});
            }
            stage.stderr_to_stdout = true;
        }
        return;
    }

    return interp.setErrorFormatted("\"{s}\" is not a redirection: a stage's arguments belong in its list", .{word});
}

// -- Running a pipeline. --

/// A spawned pipeline, with whatever the parent still has to drain.
const Spawned = struct {
    stages: []capabilities.Process.Stage,
    /// Read ends the parent owns, in the order their contents are reported:
    /// the last stage's stdout first when it was captured, then the stderr of
    /// each capturing stage in stage order.
    capture: []File,
    /// Whether `capture[0]` is stdout rather than the first stage's stderr.
    stdout_captured: bool,
    /// The `<<` document's staging file, deleted once the children hold it.
    temp_path: ?[:0]u8,
};

/// Translates a `Source` into the first stage's stdin, recording anything opened
/// here in `to_close` for the parent to drop once the children hold theirs.
fn openSource(
    interp: *Interp,
    source: Source,
    to_close: *std.ArrayList(File),
    temp_path: *?[:0]u8,
) Interp.Error!process.SpawnOptions.StdIo {
    return switch (source) {
        .inherit => .inherit,
        .file => |file| .{ .file = file },
        .path => |path| blk: {
            const file = std.Io.Dir.cwd().openFile(heap.global_io, path, .{ .mode = .read_only }) catch |err| {
                return interp.setErrorFormatted("couldn't read file \"{s}\": {t}", .{ path, err });
            };
            errdefer file.close(heap.global_io);
            try to_close.append(heap.local_arena, file);
            break :blk .{ .file = file };
        },
        // Staged through a file rather than written down a pipe: the parent
        // cannot write the document and drain the children at once, so one past
        // the pipe buffer would deadlock against a child blocked writing output.
        .text => |text| blk: {
            var temp = io_commands.createTempFile(null) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return interp.setErrorFormatted("couldn't create a temporary file: {t}", .{err}),
            };
            // Recorded before anything else can fail, so every path out of here
            // unlinks the file.
            temp_path.* = temp.path;
            errdefer temp.file.close(heap.global_io);
            try to_close.append(heap.local_arena, temp.file);

            var buffer: [1024]u8 = undefined;
            var writer = temp.file.writerStreaming(heap.global_io, &buffer);
            writeDocument(&writer, text) catch |err| {
                return interp.setErrorFormatted("couldn't write a temporary file: {t}", .{err});
            };

            break :blk .{ .file = temp.file };
        },
    };
}

/// Writes the `<<` document and rewinds, so the child reads it from the start.
/// No trailing newline is added: `exec {cat} << foo` feeds exactly three bytes.
fn writeDocument(writer: *File.Writer, text: []const u8) !void {
    try writer.interface.writeAll(text);
    try writer.interface.flush();
    try writer.seekTo(0);
}

/// Translates a `Sink` into a child's stdout or stderr, recording anything
/// opened here in `to_close` for the parent to drop once the children hold
/// theirs.
fn openSink(
    interp: *Interp,
    sink: Sink,
    which: enum { stdout, stderr },
    to_close: *std.ArrayList(File),
) Interp.Error!process.SpawnOptions.StdIo {
    return switch (sink) {
        // Through zicl's redirect cell rather than `.inherit`, so a child writes
        // wherever [puts] would. Plain inheritance would send it to the real
        // descriptor, past an embedder that had redirected stdout.
        .inherit => .{ .file = switch (which) {
            .stdout => .{ .handle = ioutil.global_stdout_fd.load(.monotonic), .flags = .{ .nonblocking = false } },
            .stderr => .{ .handle = ioutil.global_stderr_fd.load(.monotonic), .flags = .{ .nonblocking = false } },
        } },
        .file => |file| .{ .file = file },
        .capture => .pipe,
        .path => |target| blk: {
            const opened = (if (target.append)
                io_commands.openForAppend(target.bytes, false)
            else
                std.Io.Dir.cwd().createFile(heap.global_io, target.bytes, .{})) catch |err| {
                return interp.setErrorFormatted("couldn't write file \"{s}\": {t}", .{ target.bytes, err });
            };
            errdefer opened.close(heap.global_io);
            try to_close.append(heap.local_arena, opened);
            break :blk .{ .file = opened };
        },
    };
}

/// Removes a `<<` document's staging file and frees its path. A failed unlink is
/// dropped, since by then the children hold the file and there is nobody left to
/// report it to.
fn deleteTempFile(path: [:0]u8) void {
    std.Io.Dir.deleteFileAbsolute(heap.global_io, path) catch {};
    heap.global_gpa.free(path);
}

/// Takes a pipe end out of a `Child`, making the parent its owner. `Child.wait`
/// and `Child.kill` close whatever ends are still attached, so an end held past
/// the wait has to be detached first or it would be closed twice.
fn takePipe(slot: *?File) File {
    const file = slot.*.?;
    slot.* = null;
    return file;
}

/// The interned name of the `env` variable, so [exec] reads the script's
/// environment the same way every other variable is read.
const interned_env = heap.InternedString.newValue("env");

/// Build a `process.Environ.Map` based on a local `env`'s variable's contents.
fn buildEnviron(interp: *Interp) Interp.Error!?process.Environ.Map {
    var name_shim: Shimmerable = .{ .original = interned_env };
    defer name_shim.discardChanges();
    const env_value = (try interp.getVariable(&name_shim)).asValue() orelse return null;

    var det: ErrorDetails = undefined;
    var dict_shim: Shimmerable = .{ .original = env_value };
    defer dict_shim.discardChanges();
    const dict = try interp.wrapError(&det, objects.Dictionary.shimmerFrom(&det, &dict_shim));

    var map = process.Environ.Map.init(heap.global_gpa);
    errdefer map.deinit();
    // `put` copies each string into the map, so the slices from `getString` can
    // be temporary: a primitive renders into the thread arena, an object hands
    // back its cached string rep.
    var i: usize = 0;
    while (i + 1 < dict.items.len) : (i += 2) {
        const key = try dict.items[i].getString();
        const val = try dict.items[i + 1].getString();
        if (!process.Environ.Map.validateKeyForPut(key)) {
            return interp.setErrorFormatted("\"{s}\" is not a valid environment variable name", .{key});
        }
        try map.put(key, val);
    }
    return map;
}

/// Spawns every stage, wiring each one's stdout to the next one's stdin. On
/// return the parent holds only the descriptors in the result, which is what
/// lets the read ends see EOF once the children exit.
fn spawnPipeline(
    interp: *Interp,
    pipeline: Pipeline,
    environ_map: ?*const process.Environ.Map,
) Interp.Error!Spawned {
    var to_close: std.ArrayList(File) = .empty;
    defer for (to_close.items) |file| file.close(heap.global_io);

    var spawned: Spawned = .{
        .stages = &.{},
        .capture = &.{},
        .stdout_captured = pipeline.stdout == .capture,
        .temp_path = null,
    };
    errdefer if (spawned.temp_path) |path| deleteTempFile(path);

    const stdin_io = try openSource(interp, pipeline.stdin, &to_close, &spawned.temp_path);
    const stdout_io = try openSink(interp, pipeline.stdout, .stdout, &to_close);

    const count = pipeline.stages.len;
    const stages = try heap.global_gpa.alloc(capabilities.Process.Stage, count);
    errdefer heap.global_gpa.free(stages);

    // Held per stage rather than appended as they are spawned, since spawning
    // runs backwards and the result is reported in stage order.
    var stdout_end: ?File = null;
    errdefer if (stdout_end) |file| file.close(heap.global_io);
    const stderr_ends = try heap.local_arena.alloc(?File, count);
    @memset(stderr_ends, null);
    errdefer for (stderr_ends) |end| if (end) |file| file.close(heap.global_io);

    var started: usize = 0;
    errdefer for (stages[count - started ..]) |*stage| stage.kill();

    // The write end of the pipe into the stage spawned just before this one,
    // owned by the parent until the stage feeding it has been spawned.
    var downstream: ?File = null;
    errdefer if (downstream) |file| file.close(heap.global_io);

    // Back to front, which is what makes `|&` expressible: a stage sending both
    // streams down one pipe needs that pipe's _write_ end, and `.pipe` only ever
    // leaves the parent the end the child does not use. So asking the downstream
    // stage for a piped stdin yields the descriptor the upstream stage writes to.
    var i = count;
    while (i > 0) {
        i -= 1;
        const stage = pipeline.stages[i];
        const last = i == count - 1;

        const stage_stdout: process.SpawnOptions.StdIo =
            if (downstream) |file| .{ .file = file } else stdout_io;
        const stage_stdin: process.SpawnOptions.StdIo = if (i == 0) stdin_io else .pipe;
        // Both forms of merging hand over the very descriptor stdout got, so the
        // streams share one file offset and interleave as the child wrote them.
        const stage_stderr = if (stage.stderr_to_pipe or stage.stderr_to_stdout)
            stage_stdout
        else
            try openSink(interp, stage.stderr, .stderr, &to_close);

        const new_child = process.spawn(heap.global_io, .{
            .argv = stage.argv,
            .stdin = stage_stdin,
            .stdout = stage_stdout,
            .stderr = stage_stderr,
            .environ_map = environ_map,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return interp.setErrorFormatted("couldn't exec \"{s}\": {t}", .{ stage.argv[0], err }),
        };
        // Copied out because `Child.wait` clears the one in the `Child`, and
        // [pid] has to keep answering for a stage that is still running.
        stages[i] = .{ .child = new_child, .pid = new_child.id.? };
        const child = &stages[i].child;
        started += 1;

        // The child holds its own copy now, so the parent's would only keep the
        // downstream stage from ever seeing EOF.
        if (downstream) |file| {
            file.close(heap.global_io);
            downstream = null;
        }
        if (i > 0) downstream = takePipe(&child.stdin);

        if (last and spawned.stdout_captured) stdout_end = takePipe(&child.stdout);
        const merged = stage.stderr_to_pipe or stage.stderr_to_stdout;
        if (!merged and stage.stderr == .capture) {
            stderr_ends[i] = takePipe(&child.stderr);
        }
    }

    if (spawned.temp_path) |path| {
        // Every child holds an open descriptor by now, so the bytes stay
        // readable once the name is gone.
        deleteTempFile(path);
        spawned.temp_path = null;
    }

    var capture: std.ArrayList(File) = .empty;
    try capture.ensureTotalCapacity(heap.local_arena, count + 1);
    if (stdout_end) |file| capture.appendAssumeCapacity(file);
    for (stderr_ends) |end| if (end) |file| capture.appendAssumeCapacity(file);

    spawned.stages = stages;
    spawned.capture = capture.items;
    return spawned;
}

// -- Collecting output. --

/// Storage for a `MultiReader` over a number of files only known at runtime.
/// `MultiReader.Buffer(n)` fixes the count at comptime, which a pipeline of any
/// length cannot, so its layout is built by hand: the `Streams` header followed
/// by one `Context` and one `Operation.Storage` per file.
const StreamStorage = struct {
    bytes: []align(alignment) u8,

    const Context = File.MultiReader.Context;
    const Storage = std.Io.Operation.Storage;
    const alignment = @max(@alignOf(File.MultiReader.Streams), @alignOf(Context), @alignOf(Storage));

    fn contextsStart() usize {
        return std.mem.alignForward(usize, @sizeOf(File.MultiReader.Streams), @alignOf(Context));
    }

    fn sizeFor(count: usize) usize {
        const contexts_end = contextsStart() + count * @sizeOf(Context);
        return std.mem.alignForward(usize, contexts_end, @alignOf(Storage)) + count * @sizeOf(Storage);
    }

    fn init(count: usize) !StreamStorage {
        return .{ .bytes = try heap.local_arena.alignedAlloc(u8, .fromByteUnits(alignment), sizeFor(count)) };
    }

    fn streams(self: StreamStorage, count: usize) *File.MultiReader.Streams {
        // The `Streams` accessors align forward from the header's own address
        // rather than from an offset, so they only agree with `sizeFor` because
        // the allocation is aligned to at least what they ask for.
        const result: *File.MultiReader.Streams = @ptrCast(self.bytes.ptr);
        result.len = @intCast(count);
        return result;
    }
};

/// Reads every file in `files` to EOF at once, writing each one's bytes into
/// `out` for the caller to own. Reading them one after another would deadlock: a
/// child filling the pipe we are not reading blocks forever, and it has to exit
/// before the pipe we are reading gives us EOF.
fn drainAll(files: []const File, out: [][]u8) !void {
    std.debug.assert(files.len > 0);

    const storage = try StreamStorage.init(files.len);
    var multi_reader: File.MultiReader = undefined;
    multi_reader.init(heap.global_gpa, heap.global_io, storage.streams(files.len), files);
    defer multi_reader.deinit();

    try multi_reader.fillRemaining(.none);
    try multi_reader.checkAnyError();

    var filled: usize = 0;
    errdefer for (out[0..filled]) |slice| heap.global_gpa.free(slice);
    while (filled < files.len) : (filled += 1) {
        out[filled] = try multi_reader.toOwnedSlice(filled);
    }
}

/// The text reported for a child that did not exit cleanly, or null when it did.
/// Rendered into `buffer`.
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

/// Drops one trailing newline, and only one, so output that really did end in a
/// blank line keeps it.
fn withoutTrailingNewline(bytes: []const u8) []const u8 {
    if (bytes.len > 0 and bytes[bytes.len - 1] == '\n') return bytes[0 .. bytes.len - 1];
    return bytes;
}

/// What a foreground pipeline produced.
const Collected = struct {
    /// Owned slices, in `Spawned.capture` order.
    parts: [][]u8,
    stdout: []const u8,
    /// The stderr of every stage, concatenated in stage order.
    stderr: []u8,
    term: process.Child.Term,

    fn deinit(self: *Collected) void {
        for (self.parts) |part| heap.global_gpa.free(part);
        heap.global_gpa.free(self.stderr);
    }
};

/// Drains every captured stream, then waits for every stage. In that order: a
/// child cannot exit while blocked writing into a pipe nobody has emptied.
fn collect(interp: *Interp, spawned: *Spawned) Interp.Error!Collected {
    const parts = try heap.local_arena.alloc([]u8, spawned.capture.len);
    @memset(parts, &.{});

    if (spawned.capture.len > 0) {
        drainAll(spawned.capture, parts) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return interp.setErrorFormatted("error reading from child: {t}", .{err}),
        };
    }
    errdefer for (parts) |part| heap.global_gpa.free(part);

    for (spawned.capture) |file| file.close(heap.global_io);
    spawned.capture = &.{};

    const stdout: []const u8 = if (spawned.stdout_captured) parts[0] else "";
    const stderr_parts = parts[@intFromBool(spawned.stdout_captured)..];

    var stderr: std.ArrayList(u8) = .empty;
    errdefer stderr.deinit(heap.global_gpa);
    for (stderr_parts) |part| try stderr.appendSlice(heap.global_gpa, part);

    for (spawned.stages) |*stage| {
        _ = stage.wait() catch |err| {
            return interp.setErrorFormatted("error waiting for child: {t}", .{err});
        };
    }

    return .{
        .parts = parts,
        .stdout = stdout,
        .stderr = try stderr.toOwnedSlice(heap.global_gpa),
        .term = capabilities.Process.pipelineTerm(spawned.stages),
    };
}

/// Turns a finished pipeline into the interpreter result, returning
/// `error.EvalError` when any stage exited abnormally. The result is set either
/// way, since a failed child's output is the error message.
fn reportResult(interp: *Interp, pipeline: Pipeline, collected: *const Collected) Interp.Error!void {
    if (pipeline.split) return reportSplitResult(interp, collected);

    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(heap.global_gpa);
    try result.appendSlice(heap.global_gpa, collected.stdout);
    try result.appendSlice(heap.global_gpa, collected.stderr);

    var message_buffer: [64]u8 = undefined;
    const abnormal = abnormalExitMessage(collected.term, &message_buffer);

    // Dropped when the child said something itself, since its own diagnostic is
    // the better message.
    if (abnormal) |text| {
        if (collected.stderr.len == 0) try result.appendSlice(heap.global_gpa, text);
    }

    try interp.setResultString(withoutTrailingNewline(result.items));
    if (abnormal != null) return error.EvalError;
}

/// Builds the `-split` dict. A failing child raises nothing here, since a caller
/// asking for the parts apart is asking to inspect the outcome; `code` reports
/// it instead, rendering a killed stage as 128 plus its signal as a shell does.
fn reportSplitResult(interp: *Interp, collected: *const Collected) Interp.Error!void {
    const out_value = try objects.String.newValue(withoutTrailingNewline(collected.stdout));
    defer out_value.release();
    const err_value = try objects.String.newValue(withoutTrailingNewline(collected.stderr));
    defer err_value.release();

    const code: i64 = switch (collected.term) {
        .exited => |exit_code| exit_code,
        .signal, .stopped => |sig| 128 + @as(i64, @intFromEnum(sig)),
        .unknown => 1,
    };

    const dict = try objects.Dictionary.new(&.{
        interned_out,  out_value,
        interned_err,  err_value,
        interned_code, objects.Integer.new(code),
    });
    interp.setResultOwning(dict.asHead().asValue());
}

const interned_out = heap.InternedString.newValue("out");
const interned_err = heap.InternedString.newValue("err");
const interned_code = heap.InternedString.newValue("code");

/// Hands the children to a capability and reports it.
fn reportBackground(interp: *Interp, spawned: *Spawned) Interp.Error!void {
    // `parse` turns captured sinks into inherited ones for a background
    // pipeline, so there is nothing to drain.
    std.debug.assert(spawned.capture.len == 0);

    const cap = try capabilities.Process.new(spawned.stages);
    spawned.stages = &.{};
    interp.setResultOwning(cap.asHead().asValue());
}

// -- Commands. --

/// [exec]
pub fn execCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const pipeline = try parse(interp, args);

    var env_map = try buildEnviron(interp);
    defer if (env_map) |*map| map.deinit();

    var spawned = try spawnPipeline(interp, pipeline, if (env_map) |*map| map else null);
    defer {
        for (spawned.capture) |file| file.close(heap.global_io);
        // Anything still listed was never handed to a capability, so `collect`
        // or the errdefer below has reaped it and only the memory is left.
        heap.global_gpa.free(spawned.stages);
    }
    errdefer for (spawned.stages) |*stage| stage.kill();

    if (pipeline.background) return reportBackground(interp, &spawned);

    var collected = try collect(interp, &spawned);
    defer collected.deinit();
    return reportResult(interp, pipeline, &collected);
}

/// [wait], reporting how a background pipeline ended as a `{CHILDSTATUS code}`
/// style list. Waiting twice reports the same thing.
pub fn waitCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    var det: ErrorDetails = undefined;
    const cap = try interp.wrapError(&det, Capability.shimmerFrom(&det, &args[1]));
    const backing = try interp.wrapError(&det, cap.getBacking(capabilities.Process.Backing, &det));

    const term = backing.body.wait() catch |err| {
        return interp.setErrorFormatted("error waiting for child: {t}", .{err});
    };

    const status: struct { heap.Value, i64 } = switch (term) {
        .exited => |code| .{ interned_childstatus, code },
        .signal => |sig| .{ interned_childkilled, @intFromEnum(sig) },
        .stopped => |sig| .{ interned_childsusp, @intFromEnum(sig) },
        // Its own word, so a pipeline whose outcome was lost is not mistaken for
        // one that exited with whatever is in the raw wait status.
        .unknown => |raw| .{ interned_childunknown, @intCast(raw) },
    };

    const list = try objects.List.new(&.{ status[0], objects.Integer.new(status[1]) });
    interp.setResultOwning(list.asHead().asValue());
}

const interned_childstatus = heap.InternedString.newValue("CHILDSTATUS");
const interned_childkilled = heap.InternedString.newValue("CHILDKILLED");
const interned_childsusp = heap.InternedString.newValue("CHILDSUSP");
const interned_childunknown = heap.InternedString.newValue("CHILDUNKNOWN");

pub fn registerCommands(interp: *Interp) !void {
    try registerCommand(interp, "exec", execCmd, "?-split? ?--? command ?arg ...?", 1, null, null);
    try registerCommand(interp, "wait", waitCmd, "process", 1, 1, null);
}

const testing = std.testing;

/// Absolute paths throughout, so the tests exercise [exec] rather than whatever
/// PATH the embedder happened to install.
const true_path = "/usr/bin/true";
const false_path = "/usr/bin/false";
const echo_path = "/usr/bin/echo";
const cat_path = "/bin/cat";
const sh_path = "/bin/sh";
const sort_path = "/usr/bin/sort";
const env_path = "/usr/bin/env";

test "exec captures stdout" {
    const ta = testing.allocator;
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("hello", "exec {" ++ echo_path ++ " hello}");
    // One trailing newline goes, and only one.
    try interp.testExpectScriptResult("a\nb", "exec {" ++ echo_path ++ " a\\nb}");
}

test "exec takes its command as a list" {
    const ta = testing.allocator;
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Nothing inside a list is an operator, so a redirection character can be an
    // ordinary argument.
    try interp.testExpectScriptResult(">", "exec {" ++ echo_path ++ " >}");
    try interp.testExpectScriptResult("| &", "exec {" ++ echo_path ++ " {|} &}");

    // A list built by the script runs without {*}, since the list is the argv.
    try interp.testExpectScriptResult("a b", "set cmd [list " ++ echo_path ++ " a b]\nexec $cmd");

    // A word that is neither a list nor a redirection is named rather than run.
    try interp.testExpectScriptError(
        error.EvalError,
        "\"hello\" is not a redirection: a stage's arguments belong in its list",
        "exec {" ++ echo_path ++ "} hello",
    );
}

test "exec resolves a bare command name" {
    const ta = testing.allocator;
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // The one test without an absolute path. A bare name is resolved against
    // PATH from the `Io`'s environment block, which is empty unless the embedder
    // fills it in, and one that forgets sees every such [exec] fail.
    try interp.testExpectScriptResult("resolved", "exec {echo resolved}");
}

test "exec passes the env dict to the child" {
    const ta = testing.allocator;
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // `env` is the dict of environment variables the child sees, the way Tcl's
    // `::env` works. Setting it replaces the child's whole environment, so a
    // script that wants to change what a child sees changes `env`.
    try interp.testExpectScriptResult("ZICL_TEST=only", "set env {ZICL_TEST only}\nexec {" ++ env_path ++ "}");

    // It is read afresh each call, so a later [exec] sees a later value.
    try interp.testExpectScriptResult("ZICL_TEST=again", "set env {ZICL_TEST again}\nexec {" ++ env_path ++ "}");

    // A child that reads a variable out of its environment gets the dict's value.
    try interp.testExpectScriptResult(
        "only",
        "set env {ZICL_TEST only}\nexec {" ++ sh_path ++ " -c {echo -n $ZICL_TEST}}",
    );
}

test "exec reports abnormal exit" {
    const ta = testing.allocator;
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("0", "catch { exec {" ++ true_path ++ "} }");
    try interp.testExpectScriptResult("1", "catch { exec {" ++ false_path ++ "} }");
    // A child that says nothing gets the generic explanation.
    try interp.testExpectScriptError(
        error.EvalError,
        "child process exited abnormally",
        "exec {" ++ false_path ++ "}",
    );
}

test "exec folds stderr into the result" {
    const ta = testing.allocator;
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Where Tcl 8 would raise. A script reading compiler warnings out of
    // `[exec $cc ...]` depends on this.
    try interp.testExpectScriptResult(
        "out\nerr",
        "exec {" ++ sh_path ++ " -c {echo out; echo err >&2}}",
    );

    // Sending stderr elsewhere takes it back out of the result.
    try interp.testExpectScriptResult(
        "out",
        "exec {" ++ sh_path ++ " -c {echo out; echo err >&2}} 2> /dev/null",
    );
}

test "exec splits the streams on request" {
    const ta = testing.allocator;
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult(
        "out err 0",
        "set r [exec -split {" ++ sh_path ++ " -c {echo out; echo err >&2}}]\n" ++
            "list [dict get $r out] [dict get $r err] [dict get $r code]",
    );

    // A failure is reported rather than raised, which is the point of asking.
    try interp.testExpectScriptResult(
        "bad 3",
        "set r [exec -split {" ++ sh_path ++ " -c {echo bad >&2; exit 3}}]\n" ++
            "list [dict get $r err] [dict get $r code]",
    );
}

test "exec prefers the child's own diagnostic" {
    const ta = testing.allocator;
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // A child that explained itself keeps its own message, since the generic one
    // would only push the useful text further from the reader.
    try interp.testExpectScriptError(
        error.EvalError,
        "no good",
        "exec {" ++ sh_path ++ " -c {echo no good >&2; exit 3}}",
    );
}

test "exec runs a pipeline" {
    const ta = testing.allocator;
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult(
        "a\nb\nc",
        "exec {" ++ sh_path ++ " -c {echo c; echo a; echo b; echo a}} | {" ++ sort_path ++ " -u}",
    );

    // Every stage's stderr is collected, in stage order.
    try interp.testExpectScriptResult(
        "from-second\nfrom-first",
        "exec {" ++ sh_path ++ " -c {echo from-first >&2}} | {" ++ sh_path ++ " -c {echo from-second}}",
    );

    // Redirecting one stage's stderr leaves the other's alone, which a single
    // shared stderr could not express.
    try interp.testExpectScriptResult(
        "kept",
        "exec {" ++ sh_path ++ " -c {echo dropped >&2}} 2> /dev/null | " ++
            "{" ++ sh_path ++ " -c {echo kept >&2}}",
    );

    // A stage failing anywhere fails the pipeline, even when the last one
    // succeeded.
    try interp.testExpectScriptResult(
        "1",
        "catch { exec {" ++ false_path ++ "} | {" ++ true_path ++ "} }",
    );
}

test "exec merges a stage's stderr into the pipe" {
    const ta = testing.allocator;
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // `|&` sends the stage's stderr down the pipe, so the next stage reads it
    // rather than it being collected.
    try interp.testExpectScriptResult(
        "TO-PIPE",
        "exec {" ++ sh_path ++ " -c {echo to-pipe >&2}} |& {" ++ sh_path ++ " -c {tr a-z A-Z}}",
    );
}

test "exec redirects to a file" {
    const ta = testing.allocator;
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buffer[0..(try tmp.dir.realPath(heap.global_io, &path_buffer))];
    const path = try std.fmt.allocPrint(ta, "{s}/out.txt", .{dir_path});
    defer ta.free(path);

    const script = try std.fmt.allocPrint(ta,
        \\exec {{{s} written}} > {s}
        \\exec {{{s} more}} >> {s}
        \\exec {{{s} {s}}}
    , .{ echo_path, path, echo_path, path, cat_path, path });
    defer ta.free(script);

    // Redirected away, so only the final [cat] reports anything, and appending
    // kept what a second `>` would have truncated.
    try interp.testExpectScriptResult("written\nmore", script);
}

test "exec merges stderr into a redirected stdout" {
    const ta = testing.allocator;
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buffer[0..(try tmp.dir.realPath(heap.global_io, &path_buffer))];
    const path = try std.fmt.allocPrint(ta, "{s}/both.txt", .{dir_path});
    defer ta.free(path);

    // Both streams have to land on one descriptor. Opening the file once per
    // stream would give each its own offset, and the second writer would start
    // back at the beginning.
    const script = try std.fmt.allocPrint(ta,
        \\exec {{{s} -c {{echo aaaaaaaa; echo bb >&2}}}} >& {s}
        \\exec {{{s} {s}}}
    , .{ sh_path, path, cat_path, path });
    defer ta.free(script);

    try interp.testExpectScriptResult("aaaaaaaa\nbb", script);
}

test "exec redirects from a file and a document" {
    const ta = testing.allocator;
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buffer[0..(try tmp.dir.realPath(heap.global_io, &path_buffer))];
    const path = try std.fmt.allocPrint(ta, "{s}/in.txt", .{dir_path});
    defer ta.free(path);

    const script = try std.fmt.allocPrint(ta,
        \\exec {{{s} fed}} > {s}
        \\list [exec {{{s}}} < {s}] [exec {{{s}}} <{s}]
    , .{ echo_path, path, cat_path, path, cat_path, path });
    defer ta.free(script);

    // Separated and attached operands mean the same thing.
    try interp.testExpectScriptResult("fed fed", script);

    // A `<<` document is fed verbatim, with no newline added.
    try interp.testExpectScriptResult("inline", "exec {" ++ cat_path ++ "} << inline");
    try interp.testExpectScriptResult(
        "3",
        "exec {" ++ sh_path ++ " -c {wc -c}} << abc",
    );
}

test "exec runs in the background" {
    const ta = testing.allocator;
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // The capability stands in for the output, which nobody is there to read.
    const cap = try interp.testRunScript("set p [exec {" ++ true_path ++ "} &]");
    try testing.expect(std.mem.indexOf(u8, try cap.getString(), "/process/") != null);

    // Asking twice reports the same thing rather than failing on a child that
    // has already been collected.
    try interp.testExpectScriptResult("CHILDSTATUS 0", "wait $p");
    try interp.testExpectScriptResult("CHILDSTATUS 0", "wait $p");
    try interp.testExpectScriptResult("", "close $p");
}

test "pid reports a running pipeline" {
    const ta = testing.allocator;
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // A pipeline that outlives the [pid] call, so there is something to report.
    _ = try interp.testRunScript("set p [exec {" ++ sh_path ++ " -c {sleep 30}} | {" ++ cat_path ++ "} &]");

    const pids = try interp.testRunScript("pid $p");
    var iter = std.mem.splitScalar(u8, try pids.getString(), ' ');
    var count: usize = 0;
    while (iter.next()) |rendered| : (count += 1) {
        try testing.expect(try std.fmt.parseInt(i64, rendered, 10) > 0);
    }
    try testing.expectEqual(@as(usize, 2), count);

    try interp.testExpectScriptResult("", "close $p");

    // Reaped stages report nothing, since the system is free to hand those
    // numbers to something else. Waiting rather than closing, since a closed
    // capability stops resolving and would report staleness instead.
    try interp.testExpectScriptResult(
        "",
        "set done [exec {" ++ true_path ++ "} &]\nwait $done\npid $done",
    );
    try interp.testExpectScriptResult("", "close $done");
}

test "closing a background pipeline reaps it" {
    const ta = testing.allocator;
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Closing has to end a child that is still running. Without the kill this
    // would block for the sleep.
    const cap = (try interp.testRunScript("set p [exec {" ++ sh_path ++ " -c {sleep 30}} &]")).borrow();
    defer cap.release();
    try interp.testExpectScriptResult("", "close $p");

    // The name stops resolving once closed, so [wait] reports it as unknown
    // rather than as something that knows it was closed.
    const stale_message = try std.fmt.allocPrint(
        ta,
        "capability \"{s}\" is stale",
        .{try cap.getString()},
    );
    defer ta.free(stale_message);
    try interp.testExpectScriptError(error.EvalError, stale_message, "wait $p");
}

test "background output follows the redirect cell" {
    const ta = testing.allocator;
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(heap.global_io, "stdout", .{});
    {
        defer file.close(heap.global_io);
        const saved_fd = ioutil.global_stdout_fd.swap(file.handle, .monotonic);
        defer _ = ioutil.global_stdout_fd.swap(saved_fd, .monotonic);

        // Waiting is what makes this deterministic: the child has exited and
        // flushed by the time the file is read.
        try interp.testExpectScriptResult(
            "CHILDSTATUS 0",
            "set p [exec {" ++ echo_path ++ " backgrounded} &]\nwait $p",
        );
        try interp.testExpectScriptResult("", "close $p");
    }

    const written = try tmp.dir.readFileAlloc(heap.global_io, "stdout", heap.global_gpa, .unlimited);
    defer heap.global_gpa.free(written);
    try testing.expectEqualStrings("backgrounded\n", written);
}

test "exec reports malformed invocations" {
    const ta = testing.allocator;
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptError(
        error.EvalError,
        "can't specify \">\" as last word in command",
        "exec {" ++ echo_path ++ " hi} >",
    );
    try interp.testExpectScriptError(
        error.EvalError,
        "didn't specify command to execute",
        "exec {}",
    );
    try interp.testExpectScriptError(
        error.EvalError,
        "illegal use of | or |& in command",
        "exec {" ++ cat_path ++ "} |",
    );
    try interp.testExpectScriptError(
        error.EvalError,
        "can only redirect input into the first stage of a pipeline",
        "exec {" ++ echo_path ++ " hi} | {" ++ cat_path ++ "} < /dev/null",
    );
    // Only the last stage's stdout leaves the pipeline, so a `>` written next to
    // an earlier stage is refused rather than quietly redirecting a later one.
    try interp.testExpectScriptError(
        error.EvalError,
        "can only redirect output out of the last stage of a pipeline",
        "exec {" ++ echo_path ++ " hi} > /dev/null | {" ++ cat_path ++ "}",
    );
    try interp.testExpectScriptError(
        error.EvalError,
        "can't redirect output twice",
        "exec {" ++ echo_path ++ " hi} > /dev/null > /dev/null",
    );
    try interp.testExpectScriptError(
        error.EvalError,
        "can't redirect a stage's stderr twice",
        "exec {" ++ echo_path ++ " hi} 2> /dev/null 2> /dev/null",
    );
    // An unknown option is refused rather than run, since the alternative is
    // spawning something the script did not name.
    try interp.testExpectScriptError(
        error.EvalError,
        "bad option \"-nope\": must be -split or --",
        "exec -nope {" ++ echo_path ++ " hi}",
    );
    // A stage whose own command begins with '-' is indistinguishable from an
    // option, so it is refused as one until `--` says otherwise.
    try interp.testExpectScriptError(
        error.EvalError,
        "bad option \"-n hi\": must be -split or --",
        "exec {-n hi}",
    );
    try interp.testExpectScriptResult("-nope", "exec -- {" ++ echo_path ++ " -nope}");
}

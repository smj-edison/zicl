const std = @import("std");
const testing = std.testing;
const debug = std.debug;
const options = @import("options");

const memutil = @import("memutil.zig");
const ioutil = @import("ioutil.zig");
const objects = @import("objects.zig");
const heap = @import("heap.zig");
const Object = heap.Object;
const Value = heap.Value;

/// Heap-allocated to avoid blowing up the stack.
threadlocal var debugging_buffer: if (options.trace_mem) []u8 else void = undefined;
threadlocal var debugging_gpa: if (options.trace_mem) memutil.RingBufferAllocator else void = undefined;
/// Use this for debugging objects (traces, etc) that can afford to leak.
threadlocal var debug_gpa: std.mem.Allocator = undefined;
threadlocal var thread_initialized: bool = false;

const LogInfo = union(enum) {
    alloc,
    incr_ref_count: struct { new_ref_count: u32 },
    decr_ref_count: struct { new_ref_count: u32 },
    invalidate_rep,
    invalidate_string: struct { was: []u8 },
    set_string: struct { set_to: []u8 },
    free,
};
const LogEntry = struct {
    /// We assume that the memory containing the entry is zero-initialized,
    /// hence `initialized` will read as false. We need this because `debug_log`
    /// is being filled from multiple threads simultaneously, and a thread could
    /// be partway through filling the log entry before crashing, and we don't
    /// want to read a partially filled entry.
    initialized: std.atomic.Value(bool),
    ptr: *Object,
    sequence_number: u64,
    info: LogInfo,
    addrs: [if (options.capture_stack_trace) 32 else 0]usize,
    stack_trace: std.debug.StackTrace,
};
var debug_log: if (options.trace_mem) [1024 * 1024]LogEntry else void = undefined;
var next_debug_location: std.atomic.Value(usize) = .init(0);
var alloc_count: std.atomic.Value(isize) = .init(0);

pub fn deinit() void {
    if (options.trace_mem) {
        for (debug_log[0..next_debug_location.load(.monotonic)]) |*entry| {
            entry.initialized = .init(false);
        }
        next_debug_location.store(0, .monotonic);
    }
}

pub fn initThread() !void {
    if (thread_initialized) return;

    if (options.trace_mem) {
        debugging_buffer = try std.heap.page_allocator.alloc(u8, 16 * 1024 * 1024);
        debugging_gpa = memutil.RingBufferAllocator.init(debugging_buffer);
        debug_gpa = debugging_gpa.allocator();
    }

    thread_initialized = true;
}

pub fn deinitThread() void {
    if (!thread_initialized) return;
    thread_initialized = false;

    if (options.trace_mem) {
        std.heap.page_allocator.free(debugging_buffer);
    }
}

/// Copy `bytes` into this thread's ring buffer so a log entry can hold onto
/// string content that outlives the object it came from (the object may be
/// freed, or the string replaced, before the log is ever read). The ring
/// buffer wraps rather than growing, so an old copy can be overwritten by a
/// later trace on the same thread -- acceptable for debugging output, never
/// used for anything load-bearing. Only call under `options.trace_mem`.
pub inline fn dupeForTrace(bytes: []const u8) []u8 {
    if (options.trace_mem) {
        return debug_gpa.dupe(u8, bytes) catch &.{};
    } else {
        return &.{};
    }
}

pub inline fn globalTrace(ptr: *Object, info: LogInfo) void {
    if (options.trace_mem) {
        if (std.meta.activeTag(info) == .alloc) {
            _ = alloc_count.fetchAdd(1, .monotonic);
        } else if (std.meta.activeTag(info) == .free) {
            _ = alloc_count.fetchSub(1, .monotonic);
        }

        const slot = next_debug_location.fetchAdd(1, .monotonic);
        const stack_trace: std.debug.StackTrace = if (options.capture_stack_trace)
            std.debug.captureCurrentStackTrace(.{ .first_address = @returnAddress() }, &debug_log[slot].addrs)
        else
            .{ .return_addresses = &.{}, .skipped = .unknown };
        debug_log[slot].ptr = ptr;
        debug_log[slot].sequence_number = ptr.sequence_number;
        debug_log[slot].info = info;
        debug_log[slot].stack_trace = stack_trace;
        debug_log[slot].initialized.store(true, .release);
    }
}

/// Render one log entry as a single line: what happened, plus enough of the
/// payload (new refcount, string content) to read the history without
/// re-deriving it from surrounding entries.
fn formatLogInfo(writer: *std.Io.Writer, entry: *const LogEntry) !void {
    try writer.print("seq={d} ", .{entry.sequence_number});
    switch (entry.info) {
        .alloc => try writer.writeAll("alloc"),
        .free => try writer.writeAll("free"),
        .incr_ref_count => |v| try writer.print("incrRefCount (now {d})", .{v.new_ref_count}),
        .decr_ref_count => |v| try writer.print("decrRefCount (now {d})", .{v.new_ref_count}),
        .invalidate_rep => try writer.writeAll("invalidateInternalRep"),
        .invalidate_string => |v| try writer.print("invalidateString (was \"{s}\")", .{v.was}),
        .set_string => |v| try writer.print("setString (\"{s}\")", .{v.set_to}),
    }
}

pub const LeakResult = struct {
    pub const ObjectLogs = struct {
        /// We split up all of the entries based on their object address.
        entries: std.ArrayList(*const LogEntry),
        /// Not all log entries end with being leaked at the end.
        leaked: bool,
    };

    arena: ?std.heap.ArenaAllocator,
    object_logs: std.AutoHashMapUnmanaged(*const Object, ObjectLogs),
    nodes: std.AutoHashMapUnmanaged(*const anyopaque, memutil.GraphWalker.Node),
    edges: std.ArrayList(memutil.GraphWalker.Edge),

    pub fn deinit(result: *LeakResult) void {
        if (result.arena) |arena| arena.deinit();
    }

    /// Render the leak graph as a dot digraph. Object nodes are joined against
    /// `object_logs` to mark which are actually leaked (we can't assume a node
    /// in the graph is a leak just because we reached it -- the true roots
    /// aren't known, so every object is checked). Non-object nodes (slices,
    /// tables, hashes) have no log entry and are rendered as-is; synthetic
    /// field-nodes render as scalar leaves.
    pub fn dumpDot(result: *const LeakResult, writer: *std.Io.Writer) !void {
        try writer.writeAll("digraph leaks {\n");
        try writer.writeAll("  node [shape=record];\n");
        try writer.writeAll("  rankdir=LR;\n");

        var it = result.nodes.iterator();
        while (it.next()) |entry| {
            const addr = entry.key_ptr.*;
            const node = entry.value_ptr.*;
            const id = @intFromPtr(addr);

            if (node.is_synthetic) {
                try writer.print("  \"{x}\" [label=", .{id});
                try writeEscaped(writer, node.as_string orelse node.type_name);
                try writer.writeAll("];\n");
                continue;
            }

            // Object nodes carry the static `@typeName(Object)` literal; the
            // runtime type comes from the live header's vtable.
            if (std.mem.eql(u8, node.type_name, @typeName(Object))) {
                const obj: *const Object = @ptrCast(@alignCast(addr));
                try writer.print(
                    "  \"{x}\" [label=\"{s} | ref={d} | ptr=0x{x}\",style=filled,fillcolor=lightpink];\n",
                    .{ id, obj.vtable.name, obj.getRefCount(), @intFromPtr(obj) },
                );
                continue;
            }

            // Raw heap allocation (slice, table, hash). No object log entry.
            try writer.print("  \"{x}\" [label=", .{id});
            if (node.as_string) |s| {
                try writeEscaped(writer, s);
            } else {
                try writeEscaped(writer, node.type_name);
            }
            try writer.writeAll(",style=filled,fillcolor=lightblue];\n");
        }

        for (result.edges.items) |edge| {
            try writer.print("  \"{x}\" -> \"{x}\" [label=", .{
                @intFromPtr(edge.from), @intFromPtr(edge.to),
            });
            try writeEscaped(writer, edge.field_name);
            try writer.writeAll("];\n");
        }

        try writer.writeAll("}\n");
    }

    /// Print the operation history of each leaked object: every logged
    /// event (alloc, free, refcount change, string set, ...) with its stack
    /// trace. The graph shows _what_ is leaking and how it's reachable; this
    /// shows _why_ -- the sequence of refcount operations that left the object
    /// alive, each tagged with where it happened. The two together isolate
    /// refcounting bugs that a graph alone can't.
    pub fn dumpDetails(result: *const LeakResult, terminal: std.Io.Terminal) !void {
        const writer = terminal.writer;

        // We go through twice, once to print the summary, and the second time
        // to print the details.
        try writer.writeAll("==== Leak summary ====\n");

        var it = result.object_logs.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.leaked) continue;
            const obj = entry.key_ptr.*;
            if (obj.maybeGetString()) |bytes| {
                try writer.print("  leaked addr=0x{x} with value \"{s}\"\n", .{ @intFromPtr(obj), bytes });
            } else {
                try writer.print("  leaked addr=0x{x} (no string value)\n", .{@intFromPtr(obj)});
            }
        }

        try writer.writeAll("\n==== Leak details ====\n");

        it = result.object_logs.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.leaked) continue;
            const obj = entry.key_ptr.*;

            for (entry.value_ptr.entries.items) |log_entry| {
                try writer.print("\n\nTrace for addr=0x{x}: ", .{@intFromPtr(obj)});
                try formatLogInfo(writer, log_entry);
                try writer.writeByte('\n');
                try std.debug.writeStackTrace(&log_entry.stack_trace, terminal);
            }
            try writer.writeAll("\n");
        }
    }

    /// Write `s` as a dot-escaped string body (quotes, backslashes, and
    /// newlines escaped). Object/string content is arbitrary, so escaping
    /// matters -- a stray `"` in a Tcl string would otherwise break the dot.
    fn writeEscaped(writer: *std.Io.Writer, s: []const u8) !void {
        try writer.writeByte('"');
        for (s) |c| switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '{' => try writer.writeAll("\\{"),
            '}' => try writer.writeAll("\\}"),
            '<' => try writer.writeAll("\\<"),
            else => try writer.writeByte(c),
        };
        try writer.writeByte('"');
    }
};
pub fn captureLeaks() !LeakResult {
    if (options.trace_mem) {
        // It's unsafe to use `global_gpa`, since that's the allocator we're
        // checking leaks against right now. Hence, we use `external_arena` for
        // all our tracing needs.
        var external_arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer external_arena_allocator.deinit();
        const external_arena = external_arena_allocator.allocator();

        // We now sort out the combined log into individual object logs.
        var object_logs: std.AutoHashMapUnmanaged(*const Object, LeakResult.ObjectLogs) = .empty;

        for (debug_log[0..next_debug_location.load(.monotonic)]) |*log_entry| {
            // Make sure this entry was fully initialized, else we'll ignore it.
            if (log_entry.initialized.load(.acquire) == false) continue;

            const entry = object_logs.getOrPut(external_arena, log_entry.ptr) catch @panic("OOM");
            if (!entry.found_existing) entry.value_ptr.* = .{ .entries = .empty, .leaked = false };

            entry.value_ptr.entries.append(external_arena, log_entry) catch @panic("OOM");

            // We need to figure out whether this entry is an object or not.
            // The address may have been reused by another structure, but we
            // know if it was allocated and not freed as an object, it's an
            // object.
            if (std.meta.activeTag(log_entry.info) == .alloc) {
                entry.value_ptr.leaked = true;
            } else if (std.meta.activeTag(log_entry.info) == .free) {
                entry.value_ptr.leaked = false;
            }
        }

        // Next, figure out which objects ended up leaking.
        var leaked_objects: std.ArrayList(*const Object) = .empty;
        var iter = object_logs.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.leaked) {
                leaked_objects.append(external_arena, entry.key_ptr.*) catch @panic("OOM");
            }
        }

        var walker = memutil.GraphWalker.empty;
        const struct_iter = walker.promote(external_arena);
        for (leaked_objects.items) |leaked_object| {
            struct_iter.followUnparentedNode(Object, leaked_object) catch @panic("OOM");
        }

        return .{
            .object_logs = object_logs,
            .arena = external_arena_allocator,
            .nodes = walker.nodes,
            .edges = walker.edges,
        };
    } else {
        return .{ .arena = null, .object_logs = .empty, .nodes = .empty, .edges = .empty };
    }
}

pub const CrossthreadViolation = struct {
    /// The crossthread object that holds a reference to `child`.
    parent: *const Object,
    /// The non-crossthread object `parent` shouldn't be able to reach.
    child: *const Object,
    field_name: []const u8,
};

/// Walks the live object graph (same roots as `captureLeaks`) looking for an
/// edge from a crossthread object into a non-crossthread one -- the
/// invariant `Object.makeCrossthread` is supposed to establish for the whole
/// subgraph it marks. A hit here means some object reached a crossthread
/// parent without going through `makeCrossthread` (a raw field assignment
/// that bypassed it, a mutation that happened before marking finished on
/// another thread, etc).
const CrossthreadChecker = struct {
    violations: std.ArrayList(CrossthreadViolation) = .empty,
    /// Same role as `GraphWalker.nodes`: bounds the walk to one expansion per
    /// node regardless of how many parents reach it, so a shared child in a
    /// large live graph doesn't get re-walked once per parent.
    visited: std.AutoHashMapUnmanaged(*const anyopaque, void) = .empty,

    const vtable: memutil.StructIterator.VTable = .{ .visit_node = visitNode };

    fn promote(self: *CrossthreadChecker, arena: std.mem.Allocator) memutil.StructIterator {
        return .{ .ptr = self, .vtable = &vtable, .arena = arena };
    }

    fn asObject(info: *const memutil.StructIterator.NodeInfo) ?*const Object {
        if (info.is_synthetic) return null;
        if (!std.mem.eql(u8, info.type_name, @typeName(Object))) return null;
        return @ptrCast(@alignCast(info.node));
    }

    fn visitNode(
        ctx: memutil.StructIterator,
        info: *const memutil.StructIterator.NodeInfo,
        edge_coming_from: ?[]const u8,
    ) memutil.StructIterator.Error!void {
        const self: *CrossthreadChecker = @ptrCast(@alignCast(ctx.ptr));

        if (info.parent_info) |parent_info| {
            if (asObject(parent_info)) |parent_obj| {
                if (asObject(info)) |child_obj| {
                    if (parent_obj.metadata.cross_thread and !child_obj.metadata.cross_thread) {
                        try self.violations.append(ctx.arena, .{
                            .parent = parent_obj,
                            .child = child_obj,
                            .field_name = edge_coming_from orelse "?",
                        });
                    }
                }
            }
        }

        // Same expand-once dispatch as GraphWalker.visitNode -- edges into an
        // already-visited node are still recorded above (that's the whole
        // check), only re-expanding its children is skipped.
        if (self.visited.contains(info.node)) return;
        try self.visited.put(ctx.arena, info.node, {});

        if (info.enumerate_struct_c) |c_fn| {
            var walker: memutil.StructIterator.CEnumerateContext = .{ .ctx = ctx, .info = info };
            if (c_fn(&walker, info.node) != 0) return error.OutOfMemory;
        } else if (info.enumerate_struct) |follow_fn| {
            try follow_fn(ctx, info);
        }
    }
};

pub const CrossthreadCheckResult = struct {
    arena: ?std.heap.ArenaAllocator,
    violations: std.ArrayList(CrossthreadViolation),

    pub fn deinit(result: *CrossthreadCheckResult) void {
        if (result.arena) |arena| arena.deinit();
    }

    pub fn dump(result: *const CrossthreadCheckResult, writer: *std.Io.Writer) !void {
        if (result.violations.items.len == 0) {
            try writer.writeAll("No crossthread violations found.\n");
            return;
        }
        for (result.violations.items) |v| {
            try writer.print(
                "VIOLATION: {s} 0x{x} (crossthread) -- field \"{s}\" --> {s} 0x{x} (NOT crossthread)\n",
                .{ v.parent.vtable.name, @intFromPtr(v.parent), v.field_name, v.child.vtable.name, @intFromPtr(v.child) },
            );
        }
    }
};

/// Root the walk from every object the log currently shows as
/// allocated-but-not-yet-freed -- i.e. every live object at the moment this
/// is called, not just ones reachable from a particular container -- and
/// check each edge for the crossthread invariant. Call this any time
/// (mid-run at a breakpoint, or from `dumpCrossthreadCheck` via gdb); it only
/// reads the log that's always being written, so unlike the old
/// message/stack-trace tracing it adds nothing to the hot allocation path.
pub fn checkCrossthreadInvariant() !CrossthreadCheckResult {
    if (options.trace_mem) {
        var external_arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer external_arena_allocator.deinit();
        const external_arena = external_arena_allocator.allocator();

        // Net alloc-minus-free per pointer, not a replay of `.alloc`/`.free`
        // in array-index order: slots are handed out in thread-local batches
        // (see `local_next_debug_location`), so index order no longer tracks
        // real chronological order across threads -- a thread can log a
        // `.free` at a low index long after another thread's `.alloc` landed
        // at a high one. A net count is order-independent and still correct
        // under address reuse (alloc, free, alloc-again nets to +1 = live).
        var net_count: std.AutoHashMapUnmanaged(*const Object, i32) = .empty;
        for (debug_log[0..next_debug_location.load(.monotonic)]) |*log_entry| {
            if (log_entry.initialized.load(.acquire) == false) continue;
            const entry = net_count.getOrPut(external_arena, log_entry.ptr) catch @panic("OOM");
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += switch (std.meta.activeTag(log_entry.info)) {
                .alloc => @as(i32, 1),
                .free => @as(i32, -1),
                else => @as(i32, 0),
            };
        }

        var checker: CrossthreadChecker = .{};
        const struct_iter = checker.promote(external_arena);
        var live_iter = net_count.iterator();
        while (live_iter.next()) |entry| {
            if (entry.value_ptr.* <= 0) continue;
            struct_iter.followUnparentedNode(Object, entry.key_ptr.*) catch @panic("OOM");
        }

        return .{ .arena = external_arena_allocator, .violations = checker.violations };
    } else {
        return .{ .arena = null, .violations = .empty };
    }
}

pub fn dumpCrossthreadCheck() !void {
    var result = try checkCrossthreadInvariant();
    defer result.deinit();

    const stderr = ioutil.getStderr();
    var buffer: [256]u8 = undefined;
    var writer = stderr.writer(heap.global_io, &buffer);
    try result.dump(&writer.interface);
    try writer.flush();
}

/// Callable straight from gdb (`call zicl_dumpCrossthreadCheck()`) once
/// stopped -- runs `checkCrossthreadInvariant` and prints any violations to
/// stderr. Safe to call repeatedly; unlike `Zicl_LeakCheckAll` it never
/// frees anything, so it doesn't leave the interpreter unusable afterward.
export fn zicl_dumpCrossthreadCheck() void {
    if (!options.trace_mem) return;
    dumpCrossthreadCheck() catch {};
}

/// Capture any leaked objects and dump the leak graph to stderr as dot.
/// Intended to be called from `heap.testFinish` (and similar teardown) so
/// every test that leaks objects gets introspection for free. Quiet when
/// there are no leaks.
pub fn dumpLeaks() !void {
    var leaked = try captureLeaks();
    defer leaked.deinit();
    if (leaked.nodes.count() == 0) return;

    const stderr = ioutil.getStderr();
    var buffer: [256]u8 = undefined;
    var writer = stderr.writer(heap.global_io, &buffer);
    try leaked.dumpDot(&writer.interface);
    const terminal: std.Io.Terminal = .{
        .writer = &writer.interface,
        .mode = .no_color,
    };
    try leaked.dumpDetails(terminal);
    try writer.flush();
}

/// Re-entrancy guard for `dumpLastTouchedTrace`. The dump itself runs in panic
/// context, so if it panics (a write through a bad pointer, a poisoned object we
/// accidentally dereferenced, ...) Zig re-enters the panic handler, which calls
/// us again. Without this guard that's an infinite loop. With it, the recursive
/// call sees the flag already set and bails out, letting `defaultPanic` abort.
var dump_in_progress: std.atomic.Value(bool) = .init(false);

/// Dump the operation history of the most recently touched object, plus a few
/// recent log entries for context. This is hooked into Zig's panic path (see
/// `heap.dumpLastTouchedTrace`, called from the panic handlers in
/// `test_runner.zig` and `libzicl.zig`), so a use-after-free or refcount bug
/// that crashes the interpreter prints, alongside Zig's own stack trace, the
/// sequence of alloc/takeReference/dropReference/free events (each with its
/// stack trace) that led up to the dangling access.
///
/// The last-touched object is the prime suspect -- its trace tends to end in
/// the operation that left it dangling (a `Freed` while a dict/table still holds
/// a raw reference, an unmatched `takeReference`, etc.). We never dereference the
/// object pointer here: it may already be freed and poisoned, and reading
/// through it would crash the dumper. The log entries keep their own copies of
/// the address and message, which is all we read.
///
/// `fd` is the destination. A negative fd means "no destination" and is ignored
/// -- callers must pass a real fd (the test runner passes 2, `libzicl` passes
/// the locked stderr handle). The panic handlers already hold whatever stderr
/// locking they need, so this function does no locking of its own.
pub fn dumpLastTouchedTrace(fd: i32) void {
    if (!options.trace_mem) return;
    if (fd < 0) return;
    // Swap-to-set: if the old value was already true, we're re-entered from a
    // panic inside the dump -- bail out rather than recurse.
    if (dump_in_progress.swap(true, .acq_rel)) return;
    defer dump_in_progress.store(false, .release);

    var file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writerStreaming(heap.global_io, &buffer);
    const writer: *std.Io.Writer = &file_writer.interface;
    const terminal: std.Io.Terminal = .{
        .writer = writer,
        .mode = std.Io.Terminal.Mode.detect(heap.global_io, file, false, false) catch .no_color,
    };
    defer file_writer.interface.flush() catch {};

    const entries = next_debug_location.load(.monotonic);
    if (entries == 0) {
        writer.print("(no operations logged)\n", .{}) catch {};
        return;
    }

    // Recent context: the last ~15 entries, regardless of object, so the
    // immediate lead-up to the crash is visible even if the last-touched object
    // isn't the one that faulted. Also tracks which object the very last
    // initialized entry touched, so the full per-object trace below is for
    // the actual last-touched object rather than whatever happens to be at
    // the highest slot (a thread can still be mid-write to a higher slot).
    writer.print("== Recent operations summary (last 15) ==\n", .{}) catch {};
    const start = entries -| 15;
    var last_touched: ?*const Object = null;
    var j: usize = start;
    while (j < entries) : (j += 1) {
        const entry = &debug_log[j];
        if (!entry.initialized.load(.acquire)) continue;
        writer.print("  [{:>2}] addr=0x{x} ", .{ j - start, @intFromPtr(entry.ptr) }) catch {};
        formatLogInfo(writer, entry) catch {};
        writer.writeByte('\n') catch {};
        last_touched = entry.ptr;
    }

    const target = last_touched orelse return;
    writer.print("\n== Full trace for last-touched object addr=0x{x} ==\n", .{@intFromPtr(target)}) catch {};
    j = 0;
    while (j < entries) : (j += 1) {
        const entry = &debug_log[j];
        if (!entry.initialized.load(.acquire)) continue;
        if (entry.ptr != target) continue;
        writer.print("  [{d}] addr=0x{x} ", .{ j, @intFromPtr(entry.ptr) }) catch {};
        formatLogInfo(writer, entry) catch {};
        writer.writeByte('\n') catch {};
        std.debug.writeStackTrace(&entry.stack_trace, terminal) catch {};
    }
}

/// Callable straight from gdb (`call dumpTraceForObject(addr, verbose)`).
/// Prints every logged event for the object at `addr`, in log order; with
/// `verbose` also prints each event's stack trace. We never dereference
/// `addr` -- it's compared as a raw pointer value against `entry.ptr`, so
/// this is safe to call even on a dangling/freed address.
export fn dumpTraceForObject(addr: usize, verbose: bool) void {
    if (!options.trace_mem) return;

    const entries = next_debug_location.load(.monotonic);
    if (entries == 0) {
        ioutil.debug("(no operations logged)\n", .{});
        return;
    }

    const stderr = ioutil.getStderr();
    var buffer: [256]u8 = undefined;
    var file_writer = stderr.writer(heap.global_io, &buffer);
    const writer: *std.Io.Writer = &file_writer.interface;
    const terminal: std.Io.Terminal = .{ .writer = writer, .mode = .no_color };
    defer writer.flush() catch {};

    var counter: usize = 0;
    for (debug_log[0..entries], 0..) |*entry, j| {
        if (!entry.initialized.load(.acquire)) continue;
        if (@intFromPtr(entry.ptr) != addr) continue;

        writer.print("  [{:>2}] idx={d} ", .{ counter, j }) catch {};
        formatLogInfo(writer, entry) catch {};
        writer.writeByte('\n') catch {};
        if (verbose) std.debug.writeStackTrace(&entry.stack_trace, terminal) catch {};
        counter += 1;
    }

    if (counter == 0) {
        writer.print("(no entries for addr=0x{x})\n", .{addr}) catch {};
    }
}

test "leak" {
    try heap.testStart(testing.allocator, testing.io);
    defer heap.testFinish();

    // Leak a String on purpose, then check the leak dump for the leaked pointer.
    const obj = try objects.String.newObject("hello");
    defer obj.dropReference(); // Note, we do the leak check before this gets released.

    var leaked = try captureLeaks();
    defer leaked.deinit();

    var aw = std.Io.Writer.Allocating.init(heap.global_gpa);
    defer aw.deinit();
    try leaked.dumpDot(&aw.writer);
    const terminal: std.Io.Terminal = .{ .writer = &aw.writer, .mode = .no_color };
    try leaked.dumpDetails(terminal);
    const rendered = try aw.toOwnedSlice();
    defer heap.global_gpa.free(rendered);

    const needle = try std.fmt.allocPrint(heap.global_gpa, "\"{x}\"", .{@intFromPtr(obj)});
    defer heap.global_gpa.free(needle);
    try testing.expect(std.mem.indexOf(u8, rendered, needle) != null);
}

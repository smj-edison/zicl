const std = @import("std");
const testing = std.testing;
const options = @import("options");

const memutil = @import("memutil.zig");
const ioutil = @import("ioutil.zig");
const objects = @import("objects.zig");
const heap = @import("heap.zig");
const Object = heap.Object;
const Value = heap.Value;

threadlocal var debugging_buffer: if (options.trace_mem) [16 * 1024 * 1024]u8 else void = undefined;
threadlocal var debugging_gpa: if (options.trace_mem) memutil.RingBufferAllocator else void = undefined;
/// Use this for debugging objects (traces, etc) that can afford to leak.
threadlocal var debug_gpa: std.mem.Allocator = undefined;

const LogCategory = enum {
    alloc,
    free,
    other,
};
const LogEntry = struct {
    /// We assume that the memory containing the entry is zero-initialized.
    initialized: std.atomic.Value(bool),
    value: Value,
    addrs: [32]usize,
    stack_trace: std.debug.StackTrace,
    category: LogCategory,
    message: []u8,
};
var debug_log: if (options.trace_mem) [1024 * 1024]LogEntry else void = undefined;
var next_debug_location: std.atomic.Value(usize) = .init(0);
var alloc_count: std.atomic.Value(isize) = .init(0);

pub fn init() void {
    if (options.trace_mem) {
        debugging_gpa = memutil.RingBufferAllocator.init(debugging_buffer[0..]);
        debug_gpa = debugging_gpa.allocator();
    }
}

pub fn deinit() void {
    if (options.trace_mem) {
        for (debug_log[0..next_debug_location.load(.monotonic)]) |*entry| {
            entry.initialized = .init(false);
        }
        alloc_count.store(0, .monotonic);
        next_debug_location.store(0, .monotonic);
    }
}

pub inline fn globalTrace(category: LogCategory, value: Value, comptime fmt: []const u8, args: anytype) void {
    if (options.trace_mem) {
        if (category == .alloc) {
            _ = alloc_count.fetchAdd(1, .monotonic);
        } else if (category == .free) {
            _ = alloc_count.fetchSub(1, .monotonic);
        }

        const slot = next_debug_location.fetchAdd(1, .monotonic);
        const st = std.debug.captureCurrentStackTrace(.{ .first_address = @returnAddress() }, &debug_log[slot].addrs);
        debug_log[slot].category = category;
        debug_log[slot].stack_trace = st;
        debug_log[slot].value = value;
        debug_log[slot].message = std.fmt.allocPrint(debug_gpa, fmt, args) catch unreachable;
        debug_log[slot].initialized.store(true, .release);
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
        try writer.writeAll("  node [shape=box];\n");
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
            // runtime type comes from the live header's vtable. The pointer
            // identity of the comptime literal is the tenuous-but-stable
            // signal that this is an Object node.
            if (node.type_name.ptr == @typeName(Object).ptr) {
                const obj: *const Object = @ptrCast(@alignCast(addr));
                try writer.print(
                    "  \"{x}\" [label=\"{s}\\nref={d}\",style=filled,fillcolor=lightgrey];\n",
                    .{ id, obj.vtable.name, obj.getRefCount() },
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
            try writer.writeAll("];\n");
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
    pub fn dumpDetails(result: *const LeakResult, writer: *std.Io.Writer) !void {
        const terminal: std.Io.Terminal = .{ .writer = writer, .mode = .escape_codes };

        var it = result.object_logs.iterator();
        var printed: usize = 0;
        while (it.next()) |entry| {
            if (!entry.value_ptr.leaked) continue;
            const obj = entry.key_ptr.*;
            printed += 1;

            // Read the string rep only if it's already cached, generating one
            // would mutate through the const object pointer, which a leak dump
            // must never do. `getStringDetails` is const-safe.
            const str: []const u8 = switch (obj.getStringDetails()) {
                .special => |special| special.getString(),
                .normal => |normal| normal,
                .none => "<no string rep>",
            };
            try writer.print("== Trace for {s} ref={d} addr={x} \"{s}\" ==\n", .{
                obj.vtable.name, obj.getRefCount(), @intFromPtr(obj), str,
            });

            for (entry.value_ptr.entries.items) |log_entry| {
                try writer.print("  [{s}] {s}\n", .{ @tagName(log_entry.category), log_entry.message });
                std.debug.writeStackTrace(&log_entry.stack_trace, terminal) catch {};
            }
            try writer.writeAll("\n");
        }

        if (printed == 0) try writer.writeAll("(no leaked objects with traces)\n");
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
            else => try writer.writeByte(c),
        };
        try writer.writeByte('"');
    }
};
pub fn captureLeaks() !LeakResult {
    if (options.trace_mem) {
        // Don't do expensive leak checks unless the allocation count is off.
        if (alloc_count.load(.monotonic) == 0) {
            return .{ .arena = null, .object_logs = .empty, .nodes = .empty, .edges = .empty };
        }

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

            const ptr = log_entry.value.asPtr() orelse continue; // Only track values with pointers.
            const entry = object_logs.getOrPut(external_arena, ptr) catch @panic("OOM");
            if (!entry.found_existing) entry.value_ptr.* = .{ .entries = .empty, .leaked = false };

            entry.value_ptr.entries.append(external_arena, log_entry) catch @panic("OOM");

            // We need to figure out whether this entry is an object or not.
            // The address may have been reused by another structure, but we
            // know if it was allocated and not freed as an object, it's an
            // object.
            if (log_entry.category == .alloc) {
                entry.value_ptr.leaked = true;
            } else if (log_entry.category == .free) {
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

/// Capture any leaked objects and dump the leak graph to stderr as dot.
/// Intended to be called from `heap.testFinish` (and similar teardown) so
/// every test that leaks objects gets introspection for free. Quiet when
/// there are no leaks.
pub fn dumpLeaks() !void {
    var leaked = try captureLeaks();
    defer leaked.deinit();
    if (leaked.nodes.count() == 0) return;

    const stderr = ioutil.lockStderr();
    defer ioutil.unlockStderr();
    var buffer: [256]u8 = undefined;
    var writer = stderr.writer(heap.global_io, &buffer);
    try leaked.dumpDot(&writer.interface);
    try leaked.dumpDetails(&writer.interface);
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
/// sequence of alloc/borrow/release/free events (each with its stack trace)
/// that led up to the dangling access.
///
/// The last-touched object is the prime suspect -- its trace tends to end in
/// the operation that left it dangling (a `Freed` while a dict/table still holds
/// a raw reference, an unmatched `borrow`, etc.). We never dereference the
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
    const terminal: std.Io.Terminal = .{ .writer = writer, .mode = .escape_codes };
    defer file_writer.interface.flush() catch {};

    const n = next_debug_location.load(.monotonic);
    if (n == 0) {
        writer.print("(no operations logged)\n", .{}) catch {};
        return;
    }

    // Find the last initialized entry -- the most recent operation. Its object
    // is the "last touched" object, our prime suspect.
    var last_index: ?usize = null;
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        if (debug_log[i].initialized.load(.acquire)) {
            last_index = i;
            break;
        }
    }
    if (last_index == null) {
        writer.print("(no initialized log entries)\n", .{}) catch {};
        return;
    }
    const last_entry = &debug_log[last_index.?];
    const last_ptr = last_entry.value.asPtr();

    // Recent context: the last ~15 entries, regardless of object, so the
    // immediate lead-up to the crash is visible even if the last-touched object
    // isn't the one that faulted.
    writer.print("== Recent operations (last 15) ==\n", .{}) catch {};
    {
        var j: usize = if (n >= 15) n - 15 else 0;
        while (j < n) : (j += 1) {
            const e = &debug_log[j];
            if (!e.initialized.load(.acquire)) continue;
            const eptr = e.value.asPtr();
            writer.print("  [{s}] addr=0x{x} {s}\n", .{
                @tagName(e.category),
                if (eptr) |p| @intFromPtr(p) else 0,
                e.message,
            }) catch {};
        }
    }

    // Full trace of the last-touched object: every logged event for its
    // address, in order, each with its stack trace. This is the depth that
    // isolates refcount bugs -- you see every borrow/release and where it
    // happened, ending in the operation that left it dangling.
    if (last_ptr) |ptr| {
        writer.print("\n== Full trace for last-touched object addr=0x{x} ==\n", .{@intFromPtr(ptr)}) catch {};
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const e = &debug_log[k];
            if (!e.initialized.load(.acquire)) continue;
            const eptr = e.value.asPtr() orelse continue;
            if (eptr != ptr) continue;
            writer.print("  [{s}] {s}\n", .{ @tagName(e.category), e.message }) catch {};
            std.debug.writeStackTrace(&e.stack_trace, terminal) catch {};
        }
    } else {
        writer.print("\n(last operation had no object pointer)\n", .{}) catch {};
    }
}

test "leak" {
    try heap.testStart(testing.allocator, testing.io);
    defer heap.testFinish();

    // Leak a String on purpose; `testFinish` calls `dumpLeaks`, which should
    // dump the leak graph to stderr as dot.
    const obj = try objects.String.newObject("hello");
    try dumpLeaks();
    // const rendered_ptr = try std.fmt.allocPrint(testing.allocator, "{x}", .{@intFromPtr(obj)});
    // rendered_ptr
    // try testing.expect(std.mem.indexOf(comptime T: type, haystack: []const T, needle: []const T))
    obj.release();
}

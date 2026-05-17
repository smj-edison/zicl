const std = @import("std");
const testing = std.testing;
const Heap = @import("Heap.zig");
const Handle = Heap.Handle;
const OptionalHandle = Heap.OptionalHandle;
const objutil = @import("objutil.zig");
const pcre2 = @import("pcre2");

fn pcreMalloc(size: usize, userdata: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = userdata;

    const total_size = @sizeOf(usize) + size;
    const ptr = Heap.global_gpa.rawAlloc(total_size, .of(usize), @returnAddress()) orelse return null;

    @as(*usize, @ptrCast(@alignCast(ptr))).* = total_size;
    return ptr + @sizeOf(usize);
}

fn pcreFree(ptr: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    if (ptr) |val| {
        const base = @as([*]u8, @ptrCast(val)) - @sizeOf(usize);
        const total_size = @as(*usize, @ptrCast(@alignCast(base))).*;
        Heap.global_gpa.rawFree(base[0..total_size], .of(usize), @returnAddress());
    }
}

pub var pcre2_ctx: *pcre2.pcre2_general_context_8 = undefined;
pub fn initGlobals() !void {
    pcre2_ctx = pcre2.pcre2_general_context_create_8(pcreMalloc, pcreFree, null) orelse return error.OutOfMemory;
}

pub fn deinitGlobals() void {
    pcre2.pcre2_general_context_free_8(pcre2_ctx);
}

pub fn buildIndexPair(start: i64, end: i64) !Handle {
    // PCRE2 gives us half-open ranges [start, end). Tcl uses inclusive
    // indices [start, end].
    const inclusive_end = if (start == -1) -1 else end - 1;
    const start_handle = try objutil.newInteger(Heap.local_heap, start);
    errdefer start_handle.decrRefCount();
    const end_handle = try objutil.newInteger(Heap.local_heap, inclusive_end);
    errdefer end_handle.decrRefCount();
    const list = try objutil.newList(&.{ start_handle, end_handle });
    start_handle.decrRefCount();
    end_handle.decrRefCount();
    return list;
}

pub fn matchToList(
    subject: []const u8,
    ovector: [*]usize,
    ovector_count: u32,
    opt_indices: bool,
) !Handle {
    const list = try objutil.newListWithCapacity(ovector_count);
    errdefer list.decrRefCount();

    for (0..ovector_count) |idx| {
        const start = ovector[idx * 2];
        const end = ovector[idx * 2 + 1];

        var item: Handle = undefined;
        if (start == std.math.maxInt(usize)) {
            if (opt_indices) {
                item = try buildIndexPair(-1, -1);
            } else {
                item = Heap.local_heap.emptyHandle();
            }
        } else {
            if (opt_indices) {
                item = try buildIndexPair(@intCast(start), @intCast(end));
            } else {
                const capture = subject[start..end];
                item = try objutil.newString(capture);
            }
        }
        defer item.decrRefCount();

        objutil.listAppendAssumeCapacity(list, item.dupOrRef());
    }

    return list;
}

fn regexMemStressTest(ta: std.mem.Allocator) !void {
    _ = try Heap.testStart(ta, testing.io);
    defer Heap.testFinish();

    const pattern = "hello, (\\w+)";
    const subject = "hello, world";

    var error_code: c_int = 0;
    var error_offset: usize = 0;

    const compile_ctx = pcre2.pcre2_compile_context_create_8(pcre2_ctx);
    defer pcre2.pcre2_compile_context_free_8(compile_ctx);
    const re = pcre2.pcre2_compile_8(
        pattern.ptr,
        pattern.len,
        pcre2.PCRE2_UTF,
        &error_code,
        &error_offset,
        compile_ctx,
    ) orelse return error.OutOfMemory;
    defer pcre2.pcre2_code_free_8(re);

    const match_data = pcre2.pcre2_match_data_create_from_pattern_8(re, null) orelse return error.OutOfMemory;
    defer pcre2.pcre2_match_data_free_8(match_data);

    const match_ctx = pcre2.pcre2_match_context_create_8(pcre2_ctx) orelse return error.OutOfMemory;
    defer pcre2.pcre2_match_context_free_8(match_ctx);
    const rc = pcre2.pcre2_match_8(
        re,
        subject.ptr,
        subject.len,
        0,
        0,
        match_data,
        match_ctx,
    );
    if (rc == pcre2.PCRE2_ERROR_NOMEMORY) return error.OutOfMemory;

    // rc is the number of capture groups plus one (the full match).
    try std.testing.expectEqual(2, rc);

    const ovector = pcre2.pcre2_get_ovector_pointer_8(match_data);
    try std.testing.expect(ovector != null);

    // ovector pairs are [start, end) byte offsets.
    // Full match: "hello, world" -> [0, 12)
    try std.testing.expectEqual(0, ovector[0]);
    try std.testing.expectEqual(12, ovector[1]);

    // Group 1: "world" -> [7, 12)
    try std.testing.expectEqual(7, ovector[2]);
    try std.testing.expectEqual(12, ovector[3]);
}

test "pcre2 compile and match" {
    try testing.checkAllAllocationFailures(testing.allocator, regexMemStressTest, .{});
}

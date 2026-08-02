const std = @import("std");
const testing = std.testing;

const pcre2 = @import("pcre2");

const memutil = @import("memutil.zig");
const StructIterator = memutil.StructIterator;
const strutil = @import("strutil.zig");
const heap = @import("heap.zig");
const Object = heap.Object;
const Value = heap.Value;
const objects = @import("objects.zig");
const String = objects.String;
const ErrorDetails = objects.ErrorDetails;
const Shimmerable = objects.Shimmerable;
const Interp = @import("Interp.zig");

pub const Regexp = struct {
    regexp: *pcre2.pcre2_code_8,
    compile_options: u32,

    pub fn shimmerFrom(det: ?*ErrorDetails, shim: *Shimmerable, compile_opts: u32) !*const Regexp {
        if (shim.current().asType(Regexp)) |regexp| {
            if (regexp.compile_options == compile_opts) return regexp;
        }

        const pattern = try shim.current().getString();

        var err_code: c_int = 0;
        var err_offset: usize = 0;
        const compile_ctx = pcre2.pcre2_compile_context_create_8(pcre2_ctx) orelse return error.OutOfMemory;
        defer pcre2.pcre2_compile_context_free_8(compile_ctx);

        const compiled = pcre2.pcre2_compile_8(
            pattern.ptr,
            pattern.len,
            compile_opts,
            &err_code,
            &err_offset,
            compile_ctx,
        ) orelse {
            if (err_code == pcre2.PCRE2_ERROR_NOMEMORY) return error.OutOfMemory;
            if (det) |details| {
                var buf: [256]u8 = undefined;
                const msg_len = pcre2.pcre2_get_error_message_8(err_code, &buf, buf.len);
                const msg = buf[0..@intCast(msg_len)];
                details.* = .{ .message = try heap.global_gpa.dupeSentinel(u8, msg, 0) };
            }
            return error.BadRegexp;
        };

        const as_regexp = try shim.prepareToShimmer(Regexp);
        as_regexp.* = .{
            .regexp = compiled,
            .compile_options = compile_opts,
        };

        return as_regexp;
    }

    fn freeInternalRep(obj: *Object) void {
        const as_regexp = obj.asType(Regexp).?;
        pcre2.pcre2_code_free_8(as_regexp.regexp);
    }

    fn enumerateStruct(obj: *const Object, ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const regexp = obj.asTypeConst(Regexp).?;
        try ctx.followNode(pcre2.pcre2_code_8, info, "regexp", regexp.regexp);
    }

    pub const vtable: Object.VTable = .{
        .duplicate = Object.duplicateStringOnly,
        .update_string = null,
        .free_internal_rep = freeInternalRep,
        .make_crossthread = null,
        .enumerate_struct = enumerateStruct,
        .name = @typeName(Regexp),
    };
};

fn pcreMalloc(size: usize, userdata: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = userdata;

    const total_size = @sizeOf(usize) + size;
    const ptr = heap.global_gpa.rawAlloc(total_size, .of(usize), @returnAddress()) orelse return null;

    @as(*usize, @ptrCast(@alignCast(ptr))).* = total_size;
    return ptr + @sizeOf(usize);
}

fn pcreFree(ptr: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    if (ptr) |val| {
        const base = @as([*]u8, @ptrCast(val)) - @sizeOf(usize);
        const total_size = @as(*usize, @ptrCast(@alignCast(base))).*;
        heap.global_gpa.rawFree(base[0..total_size], .of(usize), @returnAddress());
    }
}

pub var pcre2_match_ctx: *pcre2.pcre2_match_context_8 = undefined;
pub var pcre2_ctx: *pcre2.pcre2_general_context_8 = undefined;
pub fn initGlobals() !void {
    pcre2_ctx = pcre2.pcre2_general_context_create_8(pcreMalloc, pcreFree, null) orelse return error.OutOfMemory;
    errdefer pcre2.pcre2_general_context_free_8(pcre2_ctx);
    pcre2_match_ctx = pcre2.pcre2_match_context_create_8(pcre2_ctx) orelse return error.OutOfMemory;
    errdefer pcre2.pcre2_match_context_free_8(pcre2_match_ctx);
}

pub fn deinitGlobals() void {
    pcre2.pcre2_general_context_free_8(pcre2_ctx);
    pcre2_ctx = undefined;
    pcre2.pcre2_match_context_free_8(pcre2_match_ctx);
    pcre2_match_ctx = undefined;
}

pub fn doesStringMatch(det: ?*ErrorDetails, re: *pcre2.struct_pcre2_real_code_8, bytes: []const u8) !bool {
    const match_data = pcre2.pcre2_match_data_create_from_pattern_8(re, pcre2_ctx) orelse return error.OutOfMemory;
    defer pcre2.pcre2_match_data_free_8(match_data);

    const return_code = pcre2.pcre2_match_8(re, bytes.ptr, bytes.len, 0, 0, match_data, pcre2_match_ctx);
    if (return_code == pcre2.PCRE2_ERROR_NOMATCH) return false;
    if (return_code == pcre2.PCRE2_ERROR_NOMEMORY) return error.OutOfMemory;
    if (return_code < 0) {
        if (det) |details| {
            var buf: [256]u8 = undefined;
            const msg_len = pcre2.pcre2_get_error_message_8(return_code, &buf, buf.len);
            details.* = .{ .message = try heap.global_gpa.dupeSentinel(u8, buf[0..@intCast(msg_len)], 0) };
        }
        return error.RegexError;
    }

    return true;
}

fn regexMemStressTest(ta: std.mem.Allocator) !void {
    _ = try heap.testStart(ta, testing.io);
    defer heap.testFinish();

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

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

pub fn createIndexPair(start: i64, end: i64) !Value {
    const start_value = try objects.Integer.new(start);
    defer start_value.release();
    const end_value = try objects.Integer.new(end);
    defer end_value.release();
    const indices_list = try objects.List.new(&.{ start_value, end_value });
    return indices_list.asHead().asValue();
}

pub fn matchToList(
    subject: []const u8,
    ovector: []usize,
    opt_indices: bool,
) !*objects.List {
    const list = try objects.List.newWithCapacity(&.{}, ovector.len);
    errdefer list.asHead().release();

    var pair_idx: usize = 0;
    while (pair_idx < ovector.len) : (pair_idx += 2) {
        const start = ovector[pair_idx];
        const end = ovector[pair_idx + 1];

        if (start == std.math.maxInt(usize)) {
            if (opt_indices) {
                list.appendAssumeCapacityOwning(try createIndexPair(-1, -1));
            } else {
                list.appendAssumeCapacityOwning(heap.interned_empty_string);
            }
        } else {
            if (opt_indices) {
                list.appendAssumeCapacityOwning(try createIndexPair(start, end));
            } else {
                const capture = subject[start..end];
                list.appendAssumeCapacityOwning(try objects.String.newValue(capture));
            }
        }
    }

    return list;
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

pub fn regexpCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    var opt_nocase = false;
    var opt_all = false;
    var opt_inline = false;
    var opt_indices = false;
    var opt_expanded = false;
    var opt_line = false;
    var opt_linestop = false;
    var opt_lineanchor = false;
    var opt_start: i64 = 0;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (try args[i].current().equalsString("-nocase")) {
            opt_nocase = true;
        } else if (try args[i].current().equalsString("-all")) {
            opt_all = true;
        } else if (try args[i].current().equalsString("-inline")) {
            opt_inline = true;
        } else if (try args[i].current().equalsString("-indices")) {
            opt_indices = true;
        } else if (try args[i].current().equalsString("-expanded")) {
            opt_expanded = true;
        } else if (try args[i].current().equalsString("-line")) {
            opt_line = true;
        } else if (try args[i].current().equalsString("-linestop")) {
            opt_linestop = true;
        } else if (try args[i].current().equalsString("-lineanchor")) {
            opt_lineanchor = true;
        } else if (try args[i].current().equalsString("-start")) {
            i += 1;
            if (i >= args.len) return error.WrongUsage;
            opt_start = try interp.getInteger(&args[i]);
        } else if (try args[i].current().equalsString("--")) {
            i += 1;
            break;
        } else {
            break;
        }
    }

    const remaining = args[i..];
    if (remaining.len < 2) return error.WrongUsage;
    if (opt_inline and remaining.len > 2) return error.WrongUsage;

    var compile_opts: u32 = pcre2.PCRE2_UTF | pcre2.PCRE2_UCP | pcre2.PCRE2_DOTALL;
    if (opt_nocase) compile_opts |= pcre2.PCRE2_CASELESS;
    if (opt_expanded) compile_opts |= pcre2.PCRE2_EXTENDED;
    if (opt_line or opt_lineanchor) compile_opts |= pcre2.PCRE2_MULTILINE;
    if (opt_line or opt_linestop) compile_opts &= ~@as(u32, pcre2.PCRE2_DOTALL);

    const regexp_arg = &remaining[0];
    var det: objects.ErrorDetails = undefined;
    const regexp = try interp.wrapError(&det, Regexp.shimmerFrom(&det, regexp_arg, compile_opts));

    const subject = try remaining[1].getString();
    const match_vars = remaining[2..];

    const match_data = pcre2.pcre2_match_data_create_from_pattern_8(regexp.regexp, pcre2_ctx) orelse return error.OutOfMemory;
    defer pcre2.pcre2_match_data_free_8(match_data);

    var start_offset: usize = 0;
    var skip_match = false;
    if (opt_start != 0) {
        const cp_len = try String.getCodepointLength(&remaining[1]);
        var start_cp_idx = opt_start;
        if (start_cp_idx < 0) {
            start_cp_idx += @as(i64, @intCast(cp_len)) + 1;
        }
        if (start_cp_idx <= 0) {
            start_offset = 0;
        } else if (start_cp_idx > cp_len) {
            skip_match = true;
        } else {
            start_offset = strutil.cpIndex(subject, @intCast(start_cp_idx)) orelse subject.len;
        }
    }

    var match_opts: u32 = 0;
    if (start_offset > 0) match_opts |= pcre2.PCRE2_NOTBOL;

    var result_list: ?*objects.List = null;
    if (opt_inline and opt_all) result_list = try objects.List.new(&.{});
    errdefer if (result_list) |val| val.asHead().release();

    var match_count: usize = 0;

    if (!skip_match) while (true) {
        if (start_offset > subject.len) break;
        const return_code = pcre2.pcre2_match_8(
            regexp.regexp,
            subject.ptr,
            subject.len,
            start_offset,
            match_opts,
            match_data,
            pcre2_match_ctx,
        );
        if (return_code == pcre2.PCRE2_ERROR_NOMATCH) break;
        if (return_code == pcre2.PCRE2_ERROR_NOMEMORY) return error.OutOfMemory;
        if (return_code < 0) {
            var buf: [256]u8 = undefined;
            const msg_len = pcre2.pcre2_get_error_message_8(return_code, &buf, buf.len);
            const msg = buf[0..@intCast(msg_len)];
            try interp.setResultString(msg);
            return error.EvalError;
        }

        match_count += 1;

        const ovector_count = pcre2.pcre2_get_ovector_count_8(match_data) * 2;
        const ovector = pcre2.pcre2_get_ovector_pointer_8(match_data)[0..ovector_count];

        if (opt_inline) {
            if (opt_all) {
                const match_list = try matchToList(subject, ovector, opt_indices);
                defer match_list.decrRefCount();
                const match_len = objects.listLength(match_list);
                var result_list_handle = result_list.?;
                for (0..match_len) |j| {
                    const item = objects.listItemNoFollow(match_list, @intCast(j));
                    _ = try interp.listAppendInPlace(&result_list_handle, item);
                }
                result_list = result_list_handle;
            } else {
                const list = try matchToList(subject, ovector, opt_indices);
                interp.setResultOwning(list);
                return;
            }
        } else {
            try setRegexpCaptureVars(interp, subject, match_data, match_vars, opt_indices);
        }

        if (!opt_all) break;

        const match_end = ovector[1];
        const match_start = ovector[0];
        if (match_end == match_start) {
            start_offset = match_start + 1;
        } else {
            start_offset = match_end;
        }
        match_opts |= pcre2.PCRE2_NOTBOL;
    };

    if (opt_inline) {
        if (opt_all) {
            interp.setResultOwning(result_list.?);
        } else {
            interp.setEmptyResult();
        }
    } else {
        if (opt_all) {
            try interp.setResultInteger(@intCast(match_count));
        } else {
            try interp.setResultBoolean(match_count > 0);
        }
    }
}

fn setRegexpCaptureVars(
    interp: *Interp,
    subject: []const u8,
    match_data: *pcre2.pcre2_match_data_8,
    match_vars: []Shimmerable,
    opt_indices: bool,
) Interp.Error!void {
    if (match_vars.len == 0) return;

    const ovector = pcre2.pcre2_get_ovector_pointer_8(match_data);
    const ovector_count = pcre2.pcre2_get_ovector_count_8(match_data);

    for (match_vars, 0..) |*var_name, idx| {
        if (idx < ovector_count) {
            const start = ovector[idx * 2];
            const end = ovector[idx * 2 + 1];
            if (start == std.math.maxInt(usize)) {
                if (opt_indices) {
                    const indices_list = try createIndexPair(-1, -1);
                    defer indices_list.release();
                    try interp.setVariable(var_name, indices_list);
                } else {
                    try interp.setVariable(var_name, heap.interned_empty_string);
                }
            } else {
                if (opt_indices) {
                    const indices_list = try createIndexPair(start, end);
                    defer indices_list.release();
                    try interp.setVariable(var_name, indices_list);
                } else {
                    const capture = subject[start..end];
                    const capture_value = try objects.String.new(capture);
                    defer capture_value.asHead().release();
                    try interp.setVariable(var_name, capture_value);
                }
            }
        } else {
            if (opt_indices) {
                const pair = try createIndexPair(-1, -1);
                defer pair.release();
                try interp.setVariable(var_name, pair);
            } else {
                try interp.setVariable(var_name, heap.interned_empty_string);
            }
        }
    }
}

pub fn regsubCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    var opt_nocase = false;
    var opt_all = false;
    var opt_expanded = false;
    var opt_line = false;
    var opt_linestop = false;
    var opt_lineanchor = false;
    var opt_start: i64 = 0;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (try args[i].current().equalsString("-nocase")) {
            opt_nocase = true;
        } else if (try args[i].current().equalsString("-all")) {
            opt_all = true;
        } else if (try args[i].current().equalsString("-expanded")) {
            opt_expanded = true;
        } else if (try args[i].current().equalsString("-line")) {
            opt_line = true;
        } else if (try args[i].current().equalsString("-linestop")) {
            opt_linestop = true;
        } else if (try args[i].current().equalsString("-lineanchor")) {
            opt_lineanchor = true;
        } else if (try args[i].current().equalsString("-start")) {
            i += 1;
            if (i >= args.len) return error.WrongUsage;
            opt_start = try interp.getInteger(&args[i]);
        } else if (try args[i].current().equalsString("--")) {
            i += 1;
            break;
        } else {
            break;
        }
    }

    const remaining = args[i..];
    if (remaining.len != 3 and remaining.len != 4) return error.WrongUsage;

    var compile_opts: u32 = pcre2.PCRE2_UTF | pcre2.PCRE2_UCP | pcre2.PCRE2_DOTALL;
    if (opt_nocase) compile_opts |= pcre2.PCRE2_CASELESS;
    if (opt_expanded) compile_opts |= pcre2.PCRE2_EXTENDED;
    if (opt_line or opt_lineanchor) compile_opts |= pcre2.PCRE2_MULTILINE;
    if (opt_line or opt_linestop) compile_opts &= ~@as(u32, pcre2.PCRE2_DOTALL);

    const regexp_arg = &remaining[0];
    var det: objects.ErrorDetails = undefined;
    const regexp = try interp.wrapError(&det, Regexp.shimmerFrom(&det, regexp_arg, compile_opts));

    const pattern_str = try regexp_arg.current().getString();

    const subject = try remaining[1].current().getString();
    const sub_spec = try remaining[2].current().getString();

    const match_data = pcre2.pcre2_match_data_create_from_pattern_8(regexp.regexp, null) orelse return error.OutOfMemory;
    defer pcre2.pcre2_match_data_free_8(match_data);

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(heap.global_gpa);

    var src_pos: usize = 0;
    var start_offset: usize = 0;
    if (opt_start != 0) {
        const cp_len = try String.getCodepointLength(&remaining[1]);
        var start_char_idx = opt_start;
        if (start_char_idx < 0) {
            start_char_idx += @as(i64, @intCast(cp_len)) + 1;
        }
        if (start_char_idx <= 0) {
            start_offset = 0;
        } else if (start_char_idx > cp_len) {
            start_offset = subject.len;
        } else {
            start_offset = strutil.cpIndex(subject, @intCast(start_char_idx)) orelse subject.len;
        }
        try result.appendSlice(heap.global_gpa, subject[0..start_offset]);
        src_pos = start_offset;
    }

    var match_opts: u32 = 0;
    if (start_offset > 0) match_opts |= pcre2.PCRE2_NOTBOL;

    var match_count: usize = 0;

    while (true) {
        if (start_offset > subject.len) break;
        const rc = pcre2.pcre2_match_8(regexp.regexp, subject.ptr, subject.len, start_offset, match_opts, match_data, null);
        if (rc == pcre2.PCRE2_ERROR_NOMATCH) break;
        if (rc == pcre2.PCRE2_ERROR_NOMEMORY) return error.OutOfMemory;
        if (rc < 0) {
            var buf: [256]u8 = undefined;
            const msg_len = pcre2.pcre2_get_error_message_8(rc, &buf, buf.len);
            const msg = buf[0..@intCast(msg_len)];
            try interp.setResultString(msg);
            return error.EvalError;
        }

        match_count += 1;

        const ovector = pcre2.pcre2_get_ovector_pointer_8(match_data);
        const ovector_count = pcre2.pcre2_get_ovector_count_8(match_data);

        const match_start = ovector[0];
        const match_end = ovector[1];

        try result.appendSlice(heap.global_gpa, subject[src_pos..match_start]);
        try applySubstitution(&result, subject, ovector, ovector_count, sub_spec);

        src_pos = match_end;
        start_offset = match_end;

        if (!opt_all) break;

        if (match_end == match_start) {
            if (pattern_str.len > 0 and pattern_str[0] == '^') {
                match_opts |= pcre2.PCRE2_NOTBOL;
                // Don't advance; next iteration will try same position with NOTBOL.
            } else {
                const char_len = strutil.cpIndex(subject[src_pos..], 1) orelse 0;
                if (char_len == 0) break;
                try result.appendSlice(heap.global_gpa, subject[src_pos .. src_pos + char_len]);
                src_pos += char_len;
                start_offset = src_pos;
                match_opts |= pcre2.PCRE2_NOTBOL;
            }
        } else {
            if (start_offset >= subject.len) break;
            match_opts |= pcre2.PCRE2_NOTBOL;
        }
    }

    try result.appendSlice(heap.global_gpa, subject[src_pos..]);
    try result.append(heap.global_gpa, 0); // Null sentinel.
    const substituted = try result.toOwnedSlice(heap.global_gpa);
    const substituted_str = blk: {
        errdefer heap.global_gpa.free(substituted);
        break :blk try String.newOwning(substituted[0 .. substituted.len - 1 :0]);
    };
    defer substituted_str.asHead().release();

    if (remaining.len == 4) {
        try interp.setVariable(&remaining[3], substituted_str.asHead().asValue());
        try interp.setResultInteger(@intCast(match_count));
    } else {
        interp.setResult(substituted_str.asHead().asValue());
    }
}

fn applySubstitution(
    result: *std.ArrayList(u8),
    subject: []const u8,
    ovector: [*]usize,
    ovector_count: u32,
    sub_spec: []const u8,
) !void {
    var j: usize = 0;
    while (j < sub_spec.len) : (j += 1) {
        const c = sub_spec[j];
        if (c == '&') {
            if (ovector_count > 0 and ovector[0] != std.math.maxInt(usize)) {
                try result.appendSlice(heap.global_gpa, subject[ovector[0]..ovector[1]]);
            }
        } else if (c == '\\') {
            if (j + 1 < sub_spec.len) {
                j += 1;
                const next_c = sub_spec[j];
                if (next_c >= '0' and next_c <= '9') {
                    const idx = next_c - '0';
                    if (idx < ovector_count and ovector[idx * 2] != std.math.maxInt(usize)) {
                        const start = ovector[idx * 2];
                        const end = ovector[idx * 2 + 1];
                        try result.appendSlice(heap.global_gpa, subject[start..end]);
                    }
                } else if (next_c == '\\' or next_c == '&') {
                    try result.append(heap.global_gpa, next_c);
                } else {
                    try result.append(heap.global_gpa, '\\');
                    try result.append(heap.global_gpa, next_c);
                }
            } else {
                try result.append(heap.global_gpa, '\\');
            }
        } else {
            try result.append(heap.global_gpa, c);
        }
    }
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

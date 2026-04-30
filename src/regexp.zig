const std = @import("std");
const unicode = std.unicode;
const strutil = @import("stringutil.zig");
const Heap = @import("Heap.zig");

// --- C API declarations ---
pub const regmatch_t = extern struct {
    rm_so: c_int,
    rm_eo: c_int,
};

pub const regex_t = extern struct {
    re_nsub: c_int,
    cflags: c_int,
    err: c_int,
    regstart: c_int,
    reganch: c_int,
    regmust: c_int,
    regmlen: c_int,
    program: ?[*]c_int,
    exp: ?[*:0]u8,
    regparse: ?[*:0]const u8,
    p: c_int,
    proglen: c_int,
    eflags: c_int,
    start: ?[*:0]const u8,
    reginput: ?[*:0]const u8,
    regbol: ?[*:0]const u8,
    pmatch: ?[*]regmatch_t,
    nmatch: c_int,
};

pub const REG_EXTENDED: c_int = 0;
pub const REG_ICASE: c_int = 2;
pub const REG_NEWLINE_ANCHOR: c_int = 4;
pub const REG_NEWLINE_STOP: c_int = 8;
pub const REG_NEWLINE: c_int = REG_NEWLINE_ANCHOR | REG_NEWLINE_STOP;
pub const REG_NOTBOL: c_int = 16;
pub const REG_EXPANDED: c_int = 32;

pub const RegResult = enum(c_int) {
    NOERROR,
    NOMATCH,
    BADPAT,
    ERR_NULL_ARGUMENT,
    ERR_UNKNOWN,
    ERR_TOO_BIG,
    ERR_NOMEM,
    ERR_TOO_MANY_PAREN,
    ERR_UNMATCHED_PAREN,
    ERR_UNMATCHED_BRACES,
    ERR_BAD_COUNT,
    ERR_JUNK_ON_END,
    ERR_OPERAND_COULD_BE_EMPTY,
    ERR_NESTED_COUNT,
    ERR_INTERNAL,
    ERR_COUNT_FOLLOWS_NOTHING,
    ERR_INVALID_ESCAPE,
    ERR_CORRUPTED,
    ERR_NULL_CHAR,
    ERR_UNMATCHED_BRACKET,
    ERR_NUM,
};

pub extern fn zicl_regcomp(preg: *regex_t, regex: [*:0]const u8, cflags: c_int) RegResult;
pub extern fn zicl_regexec(preg: *regex_t, string: [*:0]const u8, nmatch: usize, pmatch: [*]regmatch_t, eflags: c_int) RegResult;
pub extern fn zicl_regerror(errcode: c_int, preg: *const regex_t, errbuf: [*]u8, errbuf_size: usize) usize;
pub extern fn zicl_regfree(preg: *regex_t) void;

// These functions create an interface layer for "regexp.c".
export fn ziclcompat_utf8_tounicode(bytes: [*:0]const u8, uc: *c_int) c_int {
    bad_char: {
        switch (unicode.utf8ByteSequenceLength(bytes[0]) catch break :bad_char) {
            1 => {
                uc.* = bytes[0];
                return 1;
            },
            2 => {
                if ((bytes[1] & 0xC0) != 0x80) break :bad_char;
                uc.* = unicode.utf8Decode2(bytes[0..2].*) catch break :bad_char;
                return 2;
            },
            3 => {
                // Check that continuation bytes are correct.
                if ((bytes[1] & 0xC0) != 0x80 or (bytes[2] & 0xC0) != 0x80) break :bad_char;
                uc.* = unicode.utf8Decode3(bytes[0..3].*) catch break :bad_char;
                return 3;
            },
            4 => {
                if ((bytes[1] & 0xC0) != 0x80 or (bytes[2] & 0xC0) != 0x80 or (bytes[3] & 0xC0) != 0x80) break :bad_char;
                uc.* = unicode.utf8Decode4(bytes[0..4].*) catch break :bad_char;
                return 4;
            },
            else => unreachable,
        }
    }

    uc.* = bytes[0]; // Match Jim's implementation of passing through the bad character's byte.
    return 1;
}

export fn ziclcompat_utf8_upper(uc: c_int) c_int {
    return strutil.toUpper(@intCast(uc));
}

export fn ziclcompat_utf8_charlen(c: c_int) c_int {
    // Gotta love sign extension for signed chars.
    if ((c & 0x80) == 0) return 1;
    if ((c & 0xe0) == 0xc0) return 2;
    if ((c & 0xf0) == 0xe0) return 3;
    if ((c & 0xf8) == 0xf0) return 4;
    return 1;
}

export fn ziclcompat_utf8_index(s: [*:0]const u8, n: c_int) c_int {
    const bytes = std.mem.span(s);
    const index = strutil.cpIndexUtf8(bytes, @intCast(n)) orelse return -1;
    return @intCast(index);
}

export fn ziclcompat_utf8_getchars(buf: [*]u8, cp: c_int) c_int {
    return unicode.utf8Encode(@intCast(cp), buf[0..4]) catch {
        @memcpy(buf[0..3], &unicode.replacement_character_utf8);
        return 3;
    };
}

export fn ziclcompat_malloc(n: usize) ?[*]u8 {
    const new = Heap.global_gpa.alloc(u8, n) catch return null;
    return new.ptr;
}

export fn ziclcompat_realloc(ptr: ?[*]u8, last_len: usize, new_len: usize) ?*anyopaque {
    std.debug.assert(last_len > 0);
    std.debug.assert(new_len > 0);

    const new = Heap.global_gpa.realloc(ptr.?[0..last_len], new_len) catch return null;
    return new.ptr;
}

export fn ziclcompat_free(ptr: ?[*]u8, len: usize) void {
    Heap.global_gpa.free(ptr.?[0..len]);
}

export fn ziclcompat_strdup(s: ?[*:0]const u8) ?[*:0]u8 {
    const new = Heap.global_gpa.dupeSentinel(u8, std.mem.span(s.?), 0) catch return null;
    return new.ptr;
}

const testing = std.testing;

test "regex simple match" {
    Heap.global_gpa = testing.allocator;
    defer Heap.global_gpa = undefined;

    var preg: regex_t = undefined;
    const err = zicl_regcomp(&preg, "hello", REG_EXTENDED);
    try testing.expectEqual(.NOERROR, @as(RegResult, err));

    var pmatch: [1]regmatch_t = undefined;
    const exec_err = zicl_regexec(&preg, "hello world", 1, &pmatch, 0);
    try testing.expectEqual(.NOERROR, exec_err);
    try testing.expectEqual(0, pmatch[0].rm_so);
    try testing.expectEqual(5, pmatch[0].rm_eo);

    zicl_regfree(&preg);
}

test "regex no match" {
    Heap.global_gpa = testing.allocator;
    defer Heap.global_gpa = undefined;

    var preg: regex_t = undefined;
    try testing.expectEqual(.NOERROR, zicl_regcomp(&preg, "xyz", REG_EXTENDED));

    var pmatch: [1]regmatch_t = undefined;
    try testing.expectEqual(.NOMATCH, zicl_regexec(&preg, "abc", 1, &pmatch, 0));

    zicl_regfree(&preg);
}

test "regex case insensitive" {
    Heap.global_gpa = testing.allocator;
    defer Heap.global_gpa = undefined;

    var preg: regex_t = undefined;
    try testing.expectEqual(.NOERROR, zicl_regcomp(&preg, "Hello", REG_ICASE));

    var pmatch: [1]regmatch_t = undefined;
    try testing.expectEqual(.NOERROR, zicl_regexec(&preg, "HELLO", 1, &pmatch, 0));
    try testing.expectEqual(@as(c_int, 0), pmatch[0].rm_so);
    try testing.expectEqual(@as(c_int, 5), pmatch[0].rm_eo);

    zicl_regfree(&preg);
}

test "regex capture group" {
    Heap.global_gpa = testing.allocator;
    defer Heap.global_gpa = undefined;

    var preg: regex_t = undefined;
    try testing.expectEqual(.NOERROR, zicl_regcomp(&preg, "h(e)llo", REG_EXTENDED));

    var pmatch: [2]regmatch_t = undefined;
    try testing.expectEqual(.NOERROR, zicl_regexec(&preg, "hello", 2, &pmatch, 0));
    try testing.expectEqual(@as(c_int, 0), pmatch[0].rm_so); // full match
    try testing.expectEqual(@as(c_int, 5), pmatch[0].rm_eo);
    try testing.expectEqual(@as(c_int, 1), pmatch[1].rm_so); // group 1
    try testing.expectEqual(@as(c_int, 2), pmatch[1].rm_eo);

    zicl_regfree(&preg);
}

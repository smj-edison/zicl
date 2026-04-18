const std = @import("std");
const Allocator = std.mem.Allocator;
const utf8Encode = std.unicode.utf8Encode;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const uucode = @import("uucode");

const use_utf8 = @import("options").use_utf8;

const StringFlags = packed struct(u32) {
    case_insensitive: bool = false,
    charset_scan: bool = false,
    _padding: u30 = 0,
};

const Codepoint = if (use_utf8) u21 else u8;

pub fn checkAllAscii(bytes: []const u8, check: fn (u8) bool) bool {
    for (bytes) |char| {
        if (!check(char)) return false;
    } else return true;
}

pub fn isGraph(c: u8) bool {
    return std.ascii.isPrint(c) and c != 0x20;
}

pub fn isPunct(c: u8) bool {
    _ = std.mem.indexOfScalar(u8, "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~", c) orelse return false;
    return true;
}

fn toTitlecaseUtf8(cp: u21) u21 {
    return uucode.get(.simple_titlecase_mapping, cp);
}

fn toUppercaseUtf8(cp: u21) u21 {
    return uucode.get(.simple_uppercase_mapping, cp);
}

fn toLowercaseUtf8(cp: u21) u21 {
    return uucode.get(.simple_lowercase_mapping, cp);
}

pub const toTitle = if (use_utf8) toTitlecaseUtf8 else std.ascii.toUpper;
pub const toUpper = if (use_utf8) toUppercaseUtf8 else std.ascii.toUpper;
pub const toLower = if (use_utf8) toLowercaseUtf8 else std.ascii.toLower;

/// Conditional uppercase
fn condUpper(cp: Codepoint, enabled: bool) Codepoint {
    if (enabled) {
        return toUpper(cp);
    } else {
        return cp;
    }
}

test "Conditional uppercase" {
    try expectEqual('A', condUpper('a', true));
    try expectEqual('a', condUpper('a', false));
    try expectEqual('/', condUpper('/', true));
}

const AsciiIterator = struct {
    bytes: []const u8,
    i: usize = 0,

    const Self = @This();

    pub fn init(bytes: []const u8) Self {
        return .{
            .bytes = bytes,
        };
    }

    pub fn next(self: *Self) ?u8 {
        if (self.i >= self.bytes.len) return null;

        const cp = self.bytes[self.i];
        self.i += 1;

        return cp;
    }

    pub fn peek(self: Self) ?u8 {
        var it = self;
        return it.next();
    }
};

/// Iterate over codepoints
pub const Iterator = if (use_utf8) uucode.utf8.Iterator else AsciiIterator;

/// lexographical comparision of codepoints
pub fn compare(a: []const u8, b: []const u8, case_insensitive: bool) std.math.Order {
    var a_iter = Iterator.init(a);
    var b_iter = Iterator.init(b);

    while (true) {
        const a_cp = condUpper(a_iter.next(), case_insensitive);
        const b_cp = condUpper(b_iter.next(), case_insensitive);

        if (a_cp != null and b_cp != null) {
            const order = std.math.order(u21, a_cp.?, b_cp.?);
            if (order != .eq) return order;
        } else {
            if (a_cp == null and b_cp != null) return .lt;
            if (a_cp == null and b_cp == null) return .eq;
            if (a_cp != null and b_cp == null) return .gt;
        }
    }

    return .eq;
}

pub fn cpIndexUtf8(str: []const u8, index: usize) ?usize {
    if (index >= str.len) return null;

    var iter = Iterator.init(str);

    var cp_index: usize = 0;
    while (cp_index < index) {
        _ = iter.next() orelse return null;
        cp_index += 1;
    }

    return iter.i;
}

pub fn cpIndexAscii(str: []const u8, index: usize) ?usize {
    if (index >= str.len) return null;
    return index;
}

/// get the byte index based on codepoint index
pub const cpIndex = if (use_utf8) cpIndexUtf8 else cpIndexAscii;

test "codepoint index" {
    try expectEqual(cpIndex("hello", 3), 3);
    if (use_utf8) try expectEqual(cpIndex("⇧hello", 3), 5);
}

fn codepointLengthAscii(str: []const u8) usize {
    return str.len;
}

fn codepointLengthUtf8(str: []const u8) usize {
    var len: usize = 0;

    var iter = Iterator.init(str);
    while (iter.next()) |_| {
        len += 1;
    }

    return len;
}

/// Get the length of the string in codepoints
pub const codepointLength = if (use_utf8) codepointLengthUtf8 else codepointLengthUtf8;

pub fn strlenUtf8(str: []const u8) usize {
    var iter = Iterator.init(str);
    var count = 0;

    while (iter.next()) {
        count += 1;
    }

    return count;
}

pub fn strlenAscii(str: []const u8) usize {
    return str.len;
}

/// get the string length in codepoints
const strlen = if (use_utf8) strlenUtf8 else strlenAscii;

/// Finds the location of a codepoint
pub fn findCodepoint(str: []const u8, cp: u21) ?usize {
    var iter = Iterator.init(str);

    var idx: usize = 0;
    while (iter.next()) |cp_to_check| {
        if (cp == cp_to_check) {
            return idx;
        }

        idx = iter.i;
    }

    return null;
}

/// Returns the new left-most index in bytes, after trimming. Returns 0
/// if there was nothing to trim.
pub fn trimLeft(str: []const u8, trim_chars: []u8) usize {
    var iter = Iterator.init(str);

    outer: while (iter.next()) |cp_to_check| {
        // Check this codepoint against all the trim_chars codepoints
        var trim_char_iter = Iterator.init(trim_chars);
        while (trim_char_iter.next()) |check_against| {
            if (cp_to_check == check_against) {
                continue :outer;
            }
        } else break;
    }

    return iter.i;
}

fn reverseNext(iter: *Iterator) ?Codepoint {
    if (use_utf8) {
        while (iter.i > 0) {
            iter.i -= 1;

            if (iter.bytes[iter.i] & 0x80 == 0) {
                // Normal character
                return iter.bytes[iter.i];
            } else if (iter.bytes[iter.i] & 0xC0 == 0x80) {
                // Partway through a code point, keep going backwards
            } else if (iter.bytes[iter.i] & 0xE0 == 0xC0) {
                // Two byte codepoint
                if (iter.bytes.len - iter.i > 2) {
                    return std.unicode.utf8Decode2(iter.bytes[iter.i..(iter.i + 2)]);
                } else return 0xFFFD; // 0xFFFD = replacement character
            } else if (iter.bytes[iter.i] & 0xF0 == 0xE0) {
                // Three byte codepoint
                if (iter.bytes.len - iter.i > 3) {
                    return std.unicode.utf8Decode3(iter.bytes[iter.i..(iter.i + 3)]);
                } else return 0xFFFD;
            } else if (iter.bytes[iter.i] & 0xF8 == 0xF0) {
                // Four byte codepoint
                if (iter.bytes.len - iter.i > 4) {
                    return std.unicode.utf8Decode4(iter.bytes[iter.i..(iter.i + 4)]);
                } else return 0xFFFD;
            } else return 0xFFFD; // 0xFFFD = replacement character
        } else return null;
    } else {
        if (iter.i > 0) {
            iter.i -= 1;
            return iter.bytes[iter.i];
        } else return null;
    }
}

/// Returns the new length in bytes, after trimming. `trim_chars` can be
/// utf8-encoded codepoints.
pub fn trimRight(str: []const u8, trim_chars: []const u8) usize {
    var iter = Iterator.init(str);
    iter.i = str.len;

    var len = iter.i;
    outer: while (reverseNext(iter)) |cp_to_check| : (len = iter.i) {
        // Check this codepoint against all the trim_chars codepoints
        var trim_char_iter = Iterator.init(trim_chars);
        while (trim_char_iter.next()) |check_against| {
            if (cp_to_check == check_against) {
                continue :outer;
            }
        } else break;
    }

    return len;
}

/// pattern points to a string like "[^a-z\ub5]"
///
/// The pattern may contain trailing chars, which are ignored.
///
/// The pattern is matched against unicode char 'c'.
///
/// If StringFlags.case_insensitive, case is ignored when matching.
/// If StringFlags.charset_scan, the considers ^ and ] special at the start
/// of the charset, per scan, rather than glob/string match.
///
/// If the unicode char 'c' matches that set, returns a pointer to the ']' character,
/// or the null character if the ']' is missing.
///
/// Returns null on no match.
pub fn charsetMatch(pattern: []const u8, cp: Codepoint, flags: StringFlags) ?usize {
    // inverted = if it starts with ^
    var inverted = false;
    var found_match = false;

    var pattern_iter = Iterator.init(pattern);

    const to_check = condUpper(cp, flags.case_insensitive);

    if (flags.charset_scan) {
        if (pattern_iter.peek() == '^') {
            inverted = true;
            _ = pattern_iter.next(); // advance iterator
        }

        // Special case. If the first char is ']', it is part of the set
        if (pattern_iter.peek() == ']') {
            if (cp == ']') {
                found_match = true;
            }
            _ = pattern_iter.next(); // advance iterator
        }
    }

    while (pattern_iter.next()) |pattern_cp| {
        if (pattern_cp == ']') {
            pattern_iter.i -= 1;
            break;
        }

        var check_against: ?Codepoint = null;

        // Exact match
        if (pattern_cp == '\\') {
            if (pattern_iter.next()) |unwrapped| {
                check_against = condUpper(unwrapped, flags.case_insensitive);
            }
        } else {
            // Is this a range? e.g. [a-z]
            if (pattern_iter.peek() == '-') {
                const start_cp = condUpper(pattern_cp, flags.case_insensitive);
                _ = pattern_iter.next(); // skip -
                const end_cp = condUpper(
                    pattern_iter.next() orelse continue,
                    flags.case_insensitive,
                );

                // Handle reversed range too
                if ((to_check >= start_cp and to_check <= end_cp) or
                    (to_check >= end_cp and to_check <= start_cp))
                {
                    found_match = true;
                }
                continue;
            }

            check_against = condUpper(pattern_cp, flags.case_insensitive);
        }

        if (check_against != null and check_against == to_check) {
            found_match = true;
        }
    }

    if (inverted) {
        found_match = !found_match;
    }

    return if (found_match) pattern_iter.i else null;
}

test "charsetMatch" {
    try expect(charsetMatch("a-z", 'c', .{}) == 3);
    try expect(charsetMatch("a-z", 'C', .{}) == null);
    try expect(charsetMatch("a-z", 'C', .{ .case_insensitive = true }) == 3);
    try expect(charsetMatch("a-", 'c', .{}) == null);
    try expect(charsetMatch("", 'c', .{}) == null);
    try expect(charsetMatch("^", '^', .{}) == 1);
    try expect(charsetMatch("^", '^', .{ .charset_scan = true }) == 1);
    try expect(charsetMatch("^a", 'a', .{ .charset_scan = true }) == null);
}

/// Glob-style pattern matching.
pub fn globMatch(pattern: []const u8, str: []const u8, case_insensitive: bool) bool {
    var pattern_iter = Iterator.init(pattern);
    var string_iter = Iterator.init(str);

    while (pattern_iter.next()) |pattern_cp| {
        switch (pattern_cp) {
            '*' => {
                // keep advancing until it's not an asterisk
                while (pattern_iter.peek() == '*') {
                    _ = pattern_iter.next(); // advance iterator
                }

                if (pattern_iter.i >= pattern.len) {
                    // guaranteed match, as there's nothing after the asterisk to check
                    return true;
                }

                while (string_iter.i < str.len) {
                    // Recursive call - Does the remaining pattern match anywhere?
                    if (globMatch(pattern[pattern_iter.i..], str[string_iter.i..], case_insensitive)) {
                        return true; // match
                    }
                    _ = string_iter.next(); // advance iterator
                }

                return false; // no match
            },
            '?' => {
                _ = string_iter.next(); // advance iterator
            },
            '[' => {
                const to_check = string_iter.next() orelse return false;
                if (pattern_iter.i >= pattern.len) break;

                const result = charsetMatch(
                    pattern[pattern_iter.i..],
                    to_check,
                    .{ .case_insensitive = case_insensitive },
                );
                if (result == null) return false;

                const bracket_length = result.?;
                pattern_iter.i += bracket_length;
                if (pattern_iter.i >= pattern.len) break;
            },
            else => {
                var check_against: Codepoint = undefined;
                if (pattern_cp == '\\') {
                    check_against = condUpper(
                        pattern_iter.next() orelse '\\',
                        case_insensitive,
                    );
                } else {
                    check_against = condUpper(pattern_cp, case_insensitive);
                }

                const to_check = condUpper(
                    string_iter.next() orelse return false,
                    case_insensitive,
                );
                if (check_against != to_check) return false;
            },
        }

        if (string_iter.i >= str.len) {
            // keep advancing until it's not an asterisk
            while (pattern_iter.peek() == '*') {
                _ = pattern_iter.next();
            }
        }
    }

    // did we reach the end of both?
    return (string_iter.i >= str.len) and (pattern_iter.i >= pattern.len);
}

test "glob match" {
    try expect(globMatch("any?hing", "ANYTHING", true));
    try expect(!globMatch("any?hing", "ANYTHING", false));
}

pub fn findFirstOccurrence(searching_for: []const u8, searching_in: []const u8, cp_index: usize) ?usize {
    if (searching_for.len > searching_in.len or cp_index > searching_in.len) {
        return null;
    }

    var searching_in_iter = Iterator.init(searching_in);
    searching_in_iter.i = cpIndex(searching_in, cp_index) orelse return null;

    while (true) : (_ = searching_in_iter.next()) {
        _ = searching_in_iter.peek() orelse return null;
        if (searching_in_iter.bytes.len - searching_in_iter.i < searching_for.len) {
            return null;
        }

        const searching_in_slice =
            searching_in[searching_in_iter.i .. searching_in_iter.i + searching_for.len];
        if (std.mem.eql(u8, searching_for, searching_in_slice)) {
            return searching_in_iter.i;
        }
    }

    return null;
}

test "Find first occurrence" {
    try expectEqual(findFirstOccurrence("world", "hello world world", 0), 6);
    try expectEqual(findFirstOccurrence("wold", "hello world", 0), null);
    try expectEqual(findFirstOccurrence("world", "hello world", 6), 6);
    try expectEqual(findFirstOccurrence("world", "hello world", 7), null);
}

pub fn findLastOccurrence(searching_for: []const u8, searching_in: []const u8) ?usize {
    if (searching_for.len > searching_in.len) {
        return null;
    }

    var idx = searching_in.len - searching_for.len;
    while (true) {
        if (std.mem.eql(u8, searching_for, searching_in[idx .. idx + searching_for.len])) {
            return idx;
        }

        if (idx == 0) return null;
        idx -= 1;
    }
}

test "Find last occurrence" {
    try expectEqual(findLastOccurrence("world", "hello world world"), 12);
    try expectEqual(findLastOccurrence("world", "hello"), null);
}

pub fn hexDigitValue(c: u8) ?u4 {
    if (c >= '0' and c <= '9')
        return @intCast(c - '0');
    if (c >= 'a' and c <= 'f')
        return @intCast(c - 'a' + 10);
    if (c >= 'A' and c <= 'F')
        return @intCast(c - 'A' + 10);
    return null;
}

pub fn isHexDigit(c: u8) bool {
    _ = hexDigitValue(c) orelse return false;
    return true;
}

fn octalDigitValue(c: u8) ?u3 {
    if (c >= '0' and c <= '7')
        return @intCast(c - '0');
    return null;
}

/// Perform Tcl escape substitution of 'source', storing the result
/// string into 'dest'. The escaped string is guaranteed to
/// be the same length or shorter than the source string.
/// slen is the length of the string at 'source'.
///
/// The function returns the length of the resulting string.
pub fn removeEscaping(source: []const u8, dest: []u8) usize {
    var i: usize = 0;
    var dest_i: usize = 0;

    while (i < source.len) {
        switch (source[i]) {
            '\\' => {
                if (i + 1 < source.len) {
                    i += 1;
                    switch (source[i]) {
                        'a' => {
                            dest[dest_i] = 0x7;
                        },
                        'b' => {
                            dest[dest_i] = 0x8;
                        },
                        'f' => {
                            dest[dest_i] = 0xC;
                        },
                        'n' => {
                            dest[dest_i] = '\n';
                        },
                        'r' => {
                            dest[dest_i] = '\r';
                        },
                        't' => {
                            dest[dest_i] = '\t';
                        },
                        'u', 'U', 'x' => {
                            const sequence_start = i;

                            // A unicode or hex sequence.
                            // \x Expect 1-2 hex chars and convert to hex.
                            // \u Expect 1-4 hex chars and convert to utf-8.
                            // \U Expect 1-8 hex chars and convert to utf-8.
                            // \u{NNN} supports 1-6 hex chars and convert to utf-8.
                            // An invalid sequence means simply the escaped char.
                            var max_chars: usize = 2;
                            if (source[i] == 'U') {
                                max_chars = 8;
                            } else if (source[i] == 'u') {
                                if (i + 1 < source.len and source[i + 1] == '{') {
                                    max_chars = 6;
                                    i += 1; // skip to brace
                                } else {
                                    max_chars = 4;
                                }
                            }

                            i += 1;
                            const hex_start = i;

                            var codepoint: u21 = 0;
                            while (i < source.len and i - hex_start < max_chars) : (i += 1) {
                                const hex = hexDigitValue(source[i]);
                                if (hex) |unwrapped| {
                                    codepoint = (codepoint << 4) | unwrapped;
                                } else break;
                            }

                            if (source[hex_start - 1] == '{') {
                                // Did any of the following happen:
                                // 1. Never advanced, do to invalid characters or EOF
                                // 2. Codepoint is too large to represent
                                // 3. Didn't end with '}'
                                if (i - hex_start == 0 or codepoint > 0x1fffff or
                                    (i < source.len and source[i] != '}'))
                                {
                                    // If so, reset cursor
                                    i = sequence_start;
                                } else {
                                    // Skip closing brace
                                    i += 1;
                                }
                            }

                            if (i - hex_start != 0) {
                                // Got a valid sequence, so insert
                                if (source[sequence_start] == 'x') {
                                    dest[dest_i] = @intCast(codepoint);
                                    dest_i += 1;
                                } else {
                                    dest_i += utf8Encode(codepoint, dest[dest_i..]) catch blk: {
                                        break :blk utf8Encode(0xFFFD, dest[dest_i..]) catch unreachable;
                                    };
                                }
                                continue;
                            }

                            // Not a valid codepoint, just an escaped char
                            dest[dest_i] = source[i];
                        },
                        'v' => {
                            dest[dest_i] = 0xB;
                        },
                        0x0 => {
                            dest[dest_i] = '\\';
                        },
                        '\n' => {
                            // Replace all spaces and tabs after backslash newline with a single space
                            i += 1;
                            dest[dest_i] = ' ';
                            while (i < source.len and (source[i] == ' ' or source[i] == '\t')) {
                                i += 1;
                            }
                        },
                        '0'...'7' => {
                            const result = blk: {
                                const first = octalDigitValue(source[i]).?;
                                var codepoint: u8 = @intCast(first);

                                i += 1;
                                if (i == source.len) break :blk codepoint;
                                if (octalDigitValue(source[i])) |second| {
                                    codepoint = (@as(u8, @intCast(codepoint)) << 3) | second;
                                } else break :blk codepoint;

                                i += 1;
                                if (i == source.len) break :blk codepoint;
                                if (octalDigitValue(source[i])) |third| {
                                    codepoint = (@as(u8, @intCast(codepoint)) << 3) | third;
                                }

                                break :blk codepoint;
                            };

                            dest[dest_i] = result;
                        },
                        else => {
                            dest[dest_i] = source[i];
                        },
                    }
                } else {
                    dest[dest_i] = source[i];
                }
            },
            else => {
                dest[dest_i] = source[i];
            },
        }

        i += 1;
        dest_i += 1;
    }

    return dest_i;
}

test "Tcl escape" {
    var alloc = std.heap.page_allocator;
    try testEscape(&alloc, "A B C D E \n",
        \\\x41 \102 \u43 \u{44} \E \n
    );
}

fn testEscape(alloc: *std.mem.Allocator, expected: []const u8, to_escape: []const u8) !void {
    const write_into = alloc.alloc(u8, to_escape.len) catch @panic("Can't allocate for test");
    defer alloc.free(write_into);

    const len = removeEscaping(to_escape, write_into);
    try expectEqualSlices(u8, expected, write_into[0..len]);
}

pub const QuotingType = enum(u8) { bare, brace, escape };
pub fn calculateNeededQuotingType(str: []const u8) QuotingType {
    // Empty string needs to be represented in braces
    if (str.len == 0) return QuotingType.brace;

    // Whether it's possible to represent the string without
    // braces or escaping
    var bare_string_possible = true;
    var brace_level: i64 = 0;
    var bracket_level: i64 = 0;

    if (str[0] == '"' or str[0] == '{') {
        // Not possible because we began with characters that are impossible
        // to represent without braces or escaping
        bare_string_possible = false;
    } else {
        var return_bare = true;
        for (str) |char| {
            switch (char) {
                ' ', '$', '"', '[', ']', ';', '\\', '\r', '\n', '\t', 12, 11 => {
                    bare_string_possible = false;
                    return_bare = false;
                    break;
                },
                '{', '}' => {
                    return_bare = false;
                    break;
                },
                else => {},
            }
        }

        if (return_bare) return QuotingType.bare;
    }

    // Check for any characters that we can't represent
    var i: usize = 0;
    while (i < str.len) : (i += 1) {
        switch (str[i]) {
            '{' => {
                brace_level += 1;
            },
            '}' => {
                brace_level -= 1;
                if (brace_level < 0) {
                    // Unbalanced braces, so the only possible way is escaping
                    return QuotingType.escape;
                }
            },
            '[' => {
                bracket_level += 1;
            },
            ']' => {
                bracket_level -= 1;
            },
            '\\' => {
                if (i + 1 < str.len) {
                    if (str[i + 1] == '\n') {
                        // This is a bit of an odd condition, but escaped
                        // newlines cannot be accurately represented in braces,
                        // as they'll be replaced with a single space. Hence,
                        // we better go with escaping.
                        return QuotingType.escape;
                    } else {
                        // skip the escaped character
                        i += 1;
                    }
                }
            },
            else => {},
        }
    }

    if (bracket_level < 0) {
        // Unbalanced brackets
        return QuotingType.escape;
    }

    if (brace_level == 0) {
        // Braces are balanced, so we can definitely represent it in braces.
        // We'll also attempt to represent it as a bare string.
        if (!bare_string_possible) {
            // The string started with characters that are impossible to
            // represent as a bare string, so braces it is.
            return QuotingType.brace;
        }

        // Last attempt at a bare string.
        for (str) |char| {
            switch (char) {
                ' ', '$', '"', '[', ']', ';', '\\', '\r', '\n', '\t', 12, 11 => {
                    // All of these characters can't be in a bare string, so braces
                    // it is.
                    return QuotingType.brace;
                },
                else => {},
            }
        }

        return QuotingType.bare;
    }

    // Braces weren't balanced, so we better use an escaped string
    return QuotingType.escape;
}

pub fn quoteSize(quoting_type: QuotingType, str_len: usize) usize {
    switch (quoting_type) {
        .bare => return str_len,
        .brace => return str_len + 2,
        .escape => return str_len * 2,
    }
}

/// Returns the amount written to dest
pub fn quoteString(quoting_type: QuotingType, src: []const u8, dest: []u8, escape_first_pound: bool) usize {
    switch (quoting_type) {
        .bare => {
            @memmove(dest[0..src.len], src);
            return src.len;
        },
        .brace => {
            dest[0] = '{';
            dest[1 + src.len] = '}';
            @memmove(dest[1..][0..src.len], src);
            return src.len + 2;
        },
        .escape => {
            var i: usize = 0;
            var j: usize = 0;

            if (escape_first_pound and src.len > 0 and src[0] == '#') {
                dest[j] = '\\';
                j += 1;
                dest[j] = '#';
                j += 1;

                i += 1;
            }

            while (i < src.len) {
                switch (src[i]) {
                    ' ', '$', '"', '[', ']', '{', '}', ';', '\\' => {
                        dest[j] = '\\';
                        j += 1;
                        dest[j] = src[i];
                    },
                    '\n' => {
                        dest[j] = '\\';
                        j += 1;
                        dest[j] = 'n';
                    },
                    '\r' => {
                        dest[j] = '\\';
                        j += 1;
                        dest[j] = 'r';
                    },
                    '\t' => {
                        dest[j] = '\\';
                        j += 1;
                        dest[j] = 't';
                    },
                    12 => {
                        dest[j] = '\\';
                        j += 1;
                        dest[j] = 'f';
                    },
                    11 => {
                        dest[j] = '\\';
                        j += 1;
                        dest[j] = 'v';
                    },
                    else => {
                        dest[j] = src[i];
                    },
                }

                i += 1;
                j += 1;
            }

            return j;
        },
    }
}

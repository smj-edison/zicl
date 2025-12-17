const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const testing = std.testing;

const options = @import("options");
const stringutil = @import("stringutil.zig");
const expr_parse = @import("expr_parse.zig");
const memutil = @import("memutil.zig");
const Heap = @import("Heap.zig");
const Tokenizer = @import("Tokenizer.zig");
const Handle = Heap.Handle;

pub const Error = std.mem.Allocator.Error || error{
    BadIndex,
    NotMutable,
    BadEnumVariant,
    BadBoolean,
    BadDict,
    BadInteger,
    IntegerOverflow,
    DivisionByZero,
    NegativeDenominator,
    BadFloat,
    ParseError,
};

pub const ErrorDetails = struct {
    message: Handle,
    index: ?u32 = null,
};

pub fn shimmerToString(handle: *Handle) !void {
    if (handle.peek().tag == .string) return;

    const obj = handle.peek();
    _ = try Heap.getString(handle.*); // Ensure string representation

    try Heap.prepareToShimmer(handle);
    obj.tag = .string;
    obj.body = .{
        .string = .{
            .utf8_length = 0,
            // Don't know the utf-8 length yet.
            .length_determined = false,
        },
    };
}

pub fn getCodepointLength(handle: *Handle) !usize {
    shimmerToString(handle);

    const obj = handle.peek();
    const bytes = try Heap.getString(handle);

    if (obj.tag == .string) {
        // See if we already calculated the utf8 length
        if (obj.str.is_ptr) {
            // LongString stores the utf8 length in the string body
            const long_string = Heap.LongString.fromInt(obj.str.u.ptr);
            if (long_string.utf8_length) |utf8_length| {
                return utf8_length;
            } else {
                const utf8_length = stringutil.codepointLength(bytes);
                long_string.utf8_length = utf8_length; // cache utf8 length
                return utf8_length;
            }
        } else {
            if (obj.body.string.length_determined) {
                return obj.body.string.utf8_length;
            } else {
                const utf8_length = stringutil.codepointLength(bytes);
                obj.body.string.utf8_length = utf8_length; // cache utf8 length
                obj.body.string.length_determined = true;
                return utf8_length;
            }
        }
    } else unreachable;
}

/// Copies provided string.
pub fn newString(heap: *Heap, bytes: []const u8) !Handle {
    var handle = try heap.createObject();
    errdefer handle.release();

    try Heap.setString(handle, bytes);
    try shimmerToString(&handle);
    return handle;
}

pub fn newStringFmt(heap: *Heap, comptime fmt: []const u8, args: anytype) !Handle {
    const new_count = std.fmt.count(fmt, args);
    const str = try newStringToFill(heap, new_count);
    const written = std.fmt.bufPrint(Heap.getStringMut(str) catch unreachable, fmt, args) catch return error.OutOfMemory;
    assert(written.len == new_count);

    return str;
}

pub fn newStringToFill(heap: *Heap, len: usize) !Handle {
    const handle = try heap.createObject();
    errdefer handle.release();

    if (len < Heap.LongString.split_point) {
        const new_str = try heap.createString(@intCast(len));
        const new_str_end = new_str + @as(u32, @intCast(len));
        @memset(heap.getHeapString(new_str, new_str_end), 0);

        // New object, so we can set directly
        handle.peek().str = .{
            .u = .{
                .str = .{ .index = new_str, .len = @intCast(len) },
            },
            .is_ptr = false,
        };
    } else {
        // create new string
        const new_str = try heap.gpa.allocSentinel(u8, len, 0);
        errdefer heap.gpa.free(new_str);
        @memset(new_str, 0);
        const did_take = try heap.setLongString(handle.index, .{ .normal = new_str });
        assert(did_take);
    }

    return handle;
}

/// Copies provided string.
pub fn newStringWithCodepointLen(heap: *Heap, bytes: [:0]const u8, cp_length: usize) !Handle {
    const handle = try heap.createObject();
    Heap.setString(handle, bytes);
    shimmerToString(handle);

    const obj = handle.peek();
    switch (Heap.getStringDetails(handle)) {
        .long => |long_str| {
            long_str.utf8_length = cp_length;
        },
        .normal => {
            obj.body.string.* = .{
                .utf8_length = cp_length,
                .length_determined = true,
            };
        },
        .empty => {
            obj.body.string = .{
                .utf8_length = 0,
                .length_determined = true,
            };
        },
        .null => unreachable,
    }

    return handle;
}

pub fn setStringFromEscaped(handle: Handle, escaped: []const u8) !void {
    // Unescaped must be equal or shorter than escaped version
    const unescaped = try handle.getHeap().gpa.allocSentinel(u8, escaped.len, 0);
    errdefer handle.getHeap().gpa.free(unescaped);
    const written = stringutil.removeEscaping(escaped, unescaped);
    unescaped[written] = 0; // null terminator

    const did_set = try handle.getHeap().setNormalString(handle.index, unescaped[0..written]);
    if (did_set) {
        handle.getHeap().gpa.free(unescaped);
    } else {
        // Too large for normal string, so we'll try setting as a long string.
        const did_take = try handle.getHeap().setLongString(
            handle.index,
            .{ .different_capacity = .{
                .string = unescaped[0..written :0],
                .original_capacity = unescaped.len,
            } },
        );
        if (!did_take) handle.getHeap().gpa.free(unescaped);
    }
}

pub fn globMatch(pattern: Handle, to_check: Handle, case_insensitive: bool) !bool {
    const pattern_str = try Heap.getString(pattern);
    const to_check_str = try Heap.getString(to_check);

    return stringutil.globMatch(pattern_str, to_check_str, case_insensitive);
}

pub fn compare(a: Handle, b: Handle, case_insensitive: bool) !std.math.Order {
    const a_str = try Heap.getString(a);
    const b_str = try Heap.getString(b);

    return stringutil.compare(a_str, b_str, case_insensitive);
}

// Integer related functions
pub fn newInteger(heap: *Heap, value: i64) !Handle {
    const handle = try heap.createObject();
    handle.peek().tag = .integer;
    handle.peek().body.integer = value;
    return handle;
}

pub fn integerOverflowError(det: ?*ErrorDetails, value: ?[]const u8) error{ OutOfMemory, IntegerOverflow } {
    if (det) |details| {
        if (value) |val| {
            details.* = .{
                .message = try newStringFmt(Heap.local_heap, "integer value \"{s}\" too big to be represented", .{val}),
            };
        } else {
            details.* = .{
                .message = try newString(Heap.local_heap, "integer overflow"),
            };
        }
    }
    return error.IntegerOverflow;
}

pub fn integerOverflowErrorWithWide(det: ?*ErrorDetails, value: i128) error{ OutOfMemory, IntegerOverflow } {
    if (det) |details| details.* = .{
        .message = try newStringFmt(Heap.local_heap, "integer value \"{}\" too big to be represented", .{value}),
    };
    return error.IntegerOverflow;
}

pub fn integerGetNoShimmer(det: ?*ErrorDetails, handle: Handle) !i64 {
    if (handle.peek().tag == .integer) return handle.peek().body.integer;

    const bytes = try Heap.getString(handle);
    if (std.fmt.parseInt(i64, bytes, 10)) |integer| {
        return integer;
    } else |err| switch (err) {
        error.InvalidCharacter => {
            if (det) |details| details.* = .{
                .message = try newStringFmt(Heap.local_heap, "expected integer but got \"{s}\"", .{bytes}),
            };
            return error.BadInteger;
        },
        error.Overflow => {
            return integerOverflowError(det, bytes);
        },
    }
}

pub fn shimmerToInteger(det: ?*ErrorDetails, handle: *Handle) !void {
    if (handle.peek().tag == .integer) return;

    const integer = try integerGetNoShimmer(det, handle.*);

    try Heap.prepareToShimmer(handle);
    handle.peek().tag = .integer;
    handle.peek().body.integer = integer;
}

pub fn integerGet(det: ?*ErrorDetails, handle: *Handle) !i64 {
    try shimmerToInteger(det, handle);
    return handle.peek().body.integer;
}

// Float related functions.
pub fn newFloat(value: f64) !Handle {
    const handle = try Heap.local_heap.createObject();
    handle.peek().tag = .float;
    handle.peek().body.float = value;
    return handle;
}

pub fn floatGetNoShimmer(det: ?*ErrorDetails, handle: Handle) !f64 {
    if (handle.peek().tag == .float) return handle.peek().body.float;

    const bytes = try Heap.getString(handle);
    if (std.fmt.parseFloat(f64, bytes)) |float| {
        return float;
    } else |err| switch (err) {
        error.InvalidCharacter => {
            if (det) |details| details.* = .{
                .message = try newStringFmt(Heap.local_heap, "expected floating-point number but got \"{s}\"", .{bytes}),
            };
            return error.BadFloat;
        },
    }
}

pub fn shimmerToFloat(det: ?*ErrorDetails, handle: *Handle) !void {
    if (handle.peek().tag == .float) return;

    const value = try floatGetNoShimmer(det, handle.*);

    try Heap.prepareToShimmer(handle);
    handle.peek().tag = .float;
    handle.peek().body.float = value;
}

///////////////////////////////
//  Index related functions  //

/// `start` is inclusive, `end` is exclusive. (Note, this is different from tcl's
/// convention, where both are inclusive. `fromObjects` accounts for this when
/// running the conversion).
pub const Range = struct {
    start: usize,
    end: usize,

    pub fn fromObjects(det: ?*ErrorDetails, list_len: usize, start: *Handle, end: *Handle) !Range {
        const start_idx = try getIndex(start, det);
        const end_idx = try getIndex(end, det);

        return fromIndexes(list_len, .{
            .start = start_idx,
            .end = end_idx,
        });
    }

    /// This properly accounts for both `start` and `end` being inclusive, per tcl convention.
    pub fn fromIndexes(list_len: usize, start_index: Heap.ListIndex, end_index: Heap.ListIndex) Range {
        var start = start_index.asAbsoluteIndex(list_len);
        var end = end_index.asAbsoluteIndex(list_len);

        if (start > end) return .{ .start = 0, .end = 0 };

        // End is inclusive, so we'll switch it to exclusive. We had to do it here, however,
        // otherwise `start > end` wouldn't catch a start of 0 and an end of -1.
        end += 1;

        if (start < 0) start = 0;
        if (end > list_len) end = list_len;

        return .{
            .start = @intCast(start),
            .end = @intCast(end),
        };
    }
};

/// Sets the details to a bad index message, and returns error.BadIndex.
fn badIndexError(det: ?*ErrorDetails, handle: Handle) !void {
    if (det) |details| details.* = .{
        .message = try newStringFmt("bad index \"{f}\": must be intexpr or end?[+-]intexpr?", .{handle}),
    };

    return Error.BadIndex;
}

/// Shimmers to an index representation.
pub fn shimmerToIndex(det: ?*ErrorDetails, handle: *Handle) !void {
    if (handle.peek().tag == .index) return;

    const bytes = try Heap.getString(handle);
    const obj = handle.peek();

    Heap.prepareToShimmer(handle);
    obj.tag = .index;

    // Does it start with "end"? If so, it might be end+5, or end-2, etc
    if (bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], "end")) {
        if (bytes.len >= 4) {
            if (bytes[3] != '+' or bytes[3] != '-') return badIndexError(det, handle);

            const index_offset = std.fmt.parseInt(i33, bytes[3..], 10) catch return badIndexError(det, handle);
            obj.body.index = .{ .u = .{ .end_offset = index_offset }, .is_end = true };
        }

        obj.body.index = Heap.ListIndex.end;
    } else {
        const index = std.fmt.parseInt(u32, bytes, 10) catch {
            return badIndexError(det, handle);
        };
        obj.body.index = index;
    }
}

pub fn getIndex(det: ?*ErrorDetails, handle: *Handle) !Heap.ListIndex {
    const obj = handle.peek();

    // Fast case: if it's an integer or float, we can quickly cast it (don't
    // shimmer though, as it'll probably still be used for its original purpose)
    if (obj.tag == .integer) {
        if (obj.body.integer < 0) return badIndexError(det, handle);
        if (obj.body.integer > std.math.maxInt(u32)) return badIndexError(det, handle);

        return .{ .u = .{ .index = @intCast(obj.body.integer) }, .is_end = false };
    } else if (obj.tag == .float) {
        const value = obj.body.float;

        if (std.math.isNan(value)) return badIndexError(det, handle);
        if (value < 0) return badIndexError(det, handle);
        if (value > std.math.maxInt(u32)) return badIndexError(det, handle);

        return .{ .u = .{ .index = @intFromFloat(obj.body.integer) }, .is_end = false };
    }

    try shimmerToIndex(det, handle);
    return obj.body.index;
}

/// Creates a substring of the passed in string. Used in `[string range]`.
pub fn stringRange(det: ?*ErrorDetails, str: *Handle, start: *Handle, end: *Handle) !Handle {
    const codepoint_len = try getCodepointLength(str);
    const bytes = Heap.getString(str);

    const unchecked_range = try Range.fromObjects(det, codepoint_len, start, end);
    if (unchecked_range) |range| {
        // cpIndex is generic across ascii or utf8.
        const byte_start = stringutil.cpIndex(bytes, range.start);
        const byte_end = stringutil.cpIndex(bytes, range.end);

        return try newStringWithCodepointLen(
            bytes[byte_start..byte_end],
            range.end - range.start,
        );
    } else {
        // Invalid range, so we'll just pass through the string.
        return try newStringWithCodepointLen(bytes, codepoint_len);
    }
}

/// Removes from `start` to `end`, optionally inserting `to_insert`.
pub fn stringReplace(str: *Handle, start: *Handle, end: *Handle, to_insert: ?Handle) !Handle {
    const codepoint_len = try getCodepointLength(str);
    const bytes = Heap.getString(str.*);

    const unchecked_range = try Range.fromObjects(codepoint_len, start, end);

    if (unchecked_range) |range| {
        // cpIndex is generic across ascii or utf8.
        const byte_start = stringutil.cpIndex(bytes, range.start);
        const byte_end = stringutil.cpIndex(bytes, range.end);

        // Is there anything to insert?
        if (to_insert) |unwrapped| {
            const to_insert_bytes = try Heap.getString(unwrapped);

            // Figure out how long the new string needs to be
            const up_to_range_len = byte_start;
            const to_insert_len = to_insert_bytes.len;
            // Tcl ranges are inclusive, so `- 1` is needed.
            const after_range_len = bytes.len - byte_end - 1;

            const new_str = newStringToFill(up_to_range_len + to_insert_len + after_range_len);
            const new_bytes = Heap.getStringMut(new_str) catch |err| {
                switch (err) {
                    // empty strings aren't mutable, so we'll just return the empty string
                    Error.NotMutable => return new_str,
                    Error.OutOfMemory => return err,
                }
            };

            @memcpy(new_bytes[0..up_to_range_len], bytes[0..up_to_range_len]);
            @memcpy(new_bytes[up_to_range_len..][0..to_insert_len], to_insert_bytes);
            @memcpy(new_bytes[(up_to_range_len + to_insert_len)..], bytes[(byte_end + 1)..]);

            return new_str;
        } else {
            // Figure out how long the new string needs to be.
            const up_to_range_len = byte_start;
            // Tcl ranges are inclusive, so `- 1` is needed.
            const after_range_len = bytes.len - byte_end - 1;

            const new_str = newStringToFill(up_to_range_len + after_range_len);
            const new_bytes = Heap.getStringMut(new_str) catch |err| {
                switch (err) {
                    // empty strings aren't mutable, so we'll just return the empty string
                    Error.NotMutable => return new_str,
                    Error.OutOfMemory => return err,
                }
            };

            @memcpy(new_bytes[0..up_to_range_len], bytes[0..up_to_range_len]);
            @memcpy(new_bytes[up_to_range_len..], bytes[(byte_end + 1)..]);

            return new_str;
        }
    } else {
        // Invalid range, so we'll just pass through the string.
        return try newStringWithCodepointLen(bytes, codepoint_len);
    }
}

/// Upper/lower/title case conversion.
pub fn stringCaseConversion(str: Handle, mode: enum { upper, lower, title }) !Handle {
    const bytes = try Heap.getString(str);

    if (options.use_utf8) {
        // Go through once to calculate the length
        var new_len: usize = 0;
        var iter = stringutil.Iterator.init(bytes);
        var is_first_char = true;
        while (iter.next()) |cp| {
            const converted = blk: {
                switch (mode) {
                    .upper => break :blk stringutil.toUpper(cp),
                    .lower => break :blk stringutil.toLower(cp),
                    .title => {
                        if (is_first_char) {
                            break :blk stringutil.toTitle(cp);
                        } else {
                            break :blk stringutil.toLower(cp);
                        }
                    },
                }
            };

            new_len += std.unicode.utf8ByteSequenceLength(converted);
            is_first_char = false;
        }

        const new_str = try newStringToFill(new_len);
        const new_bytes = try Heap.getStringMut(new_str) catch |err| {
            switch (err) {
                // empty strings aren't mutable, so we'll just return the empty string
                Error.NotMutable => return new_str,
                Error.OutOfMemory => return err,
            }
        };

        // Now go through and write all the bytes
        iter = stringutil.Iterator.init(bytes);
        var written: usize = 0;
        is_first_char = true;
        while (iter.next()) |cp| {
            const converted = blk: {
                switch (mode) {
                    .upper => break :blk stringutil.toUpper(cp),
                    .lower => break :blk stringutil.toLower(cp),
                    .title => {
                        if (is_first_char) {
                            break :blk stringutil.toTitle(cp);
                        } else {
                            break :blk stringutil.toLower(cp);
                        }
                    },
                }
            };
            written += std.unicode.utf8Encode(converted, new_bytes[written..]) catch unreachable;

            is_first_char = false;
        }
    } else {
        const new_len = bytes.len;
        const new_str = try newStringToFill(new_len);
        const new_bytes = try Heap.getStringMut(new_str) catch |err| {
            switch (err) {
                // Empty strings aren't mutable, so we'll just return the empty string.
                Error.NotMutable => return new_str,
                Error.OutOfMemory => return err,
            }
        };

        for (bytes, new_bytes) |old_char, *new_char| {
            if (mode == .upper) {
                new_char.* = stringutil.toUpper(old_char);
            } else {
                new_char.* = stringutil.toLower(old_char);
            }
        }

        return new_str;
    }
}

/// Creates a new string if there was anything to trim.
pub fn stringTrimLeft(str: Handle, trim_chars: Handle) !Handle {
    const bytes = try Heap.getString(str);
    const trim_chars_bytes = try Heap.getString(trim_chars);

    const start = stringutil.trimLeft(bytes, trim_chars_bytes);

    if (start == 0) {
        return str;
    } else {
        return try newString(bytes[start..]);
    }
}

/// Creates a new string if there was anything to trim.
pub fn stringTrimRight(str: Handle, trim_chars: Handle) !Handle {
    const bytes = try Heap.getString(str);
    const trim_chars_bytes = try Heap.getString(trim_chars);

    const end = stringutil.trimRight(bytes, trim_chars_bytes);

    if (end == bytes.len) {
        return str;
    } else {
        return try newString(bytes[0..end]);
    }
}

/// Creates a new string if there was anything to trim.
pub fn stringTrim(str: Handle, trim_chars: Handle) !Handle {
    const bytes = try Heap.getString(str);
    const trim_chars_bytes = try Heap.getString(trim_chars);

    const start = stringutil.trimLeft(bytes, trim_chars_bytes);
    const end = stringutil.trimRight(bytes, trim_chars_bytes);

    if (start == 0 and end == bytes.len) {
        return str;
    } else {
        return try newString(bytes[start..end]);
    }
}

//////////////////////////////
//  Enum related functions  //

/// Enum names joined by ", "
pub fn enumNames(comptime T: type) []const u8 {
    return comptime blk: {
        var result: []const u8 = @tagName(std.enums.values(T)[0]);
        for (std.enums.values(T)[1..]) |value| {
            result = &(result[0..].* ++ ", ".* ++ @tagName(value).*);
        }

        break :blk result;
    };
}

pub fn EnumMapping(comptime T: type) type {
    comptime {
        const values = std.enums.values(T);

        // Fill out the mapping
        var entries: [values.len]struct { []const u8, T } = undefined;
        for (values, &entries) |value, *entry| {
            entry.* = .{ @tagName(value), value };
        }

        // Create the table
        return struct {
            pub const StaticStringMap = std.StaticStringMap(T);

            map: StaticStringMap = StaticStringMap.initComptime(entries),
        };
    }
}

pub fn TclEnum(comptime T: type, enum_name: []const u8) type {
    return struct {
        pub const variants = T;
        pub const map = (EnumMapping(T){}).map;
        pub const names = enumNames(T);

        pub fn get(det: ?*ErrorDetails, value: *Handle) !T {
            // TODO PERF we can optimize this by shimmering the value to an "enum" type,
            // where the enum type has a u48 storing the hash of enum_name and a u16 for
            // which variant it is, by index.
            const bytes = try Heap.getString(value.*);
            const variant = map.get(bytes);
            if (variant) |unwrapped| {
                return unwrapped;
            } else {
                if (det) |details| details.* = .{
                    .message = try newStringFmt(Heap.local_heap, "bad {s} \"{f}\": must be {s}", .{ enum_name, value.*, names }),
                };

                return Error.BadEnumVariant;
            }
        }
    };
}

test "tcl enum" {
    const Things = enum { foo, bar, baz };
    const map = (EnumMapping(Things){}).map;
    const names = enumNames(Things);
    try testing.expectEqual(Things.foo, map.get("foo"));
    try testing.expectEqualSlices(u8, "foo, bar, baz", names);
}

/// Runs a string check based on requested class.
pub fn stringIs(det: ?*ErrorDetails, str: *Handle, class_to_check: *Handle, strict: bool) !bool {
    const Class = TclEnum(enum {
        integer,
        alpha,
        alnum,
        ascii,
        digit,
        double,
        lower,
        upper,
        space,
        xdigit,
        control,
        print,
        graph,
        punct,
        boolean,
    }, "class");

    const class = try Class.get(det, class_to_check);

    const bytes = try Heap.getString(str.*);
    if (bytes.len == 0) {
        return !strict;
    }

    switch (class) {
        .integer => {
            _ = std.fmt.parseInt(i64, bytes, 0) catch return false;
            return true;
        },
        .double => {
            _ = std.fmt.parseFloat(f64, bytes) catch return false;
            return true;
        },
        .boolean => {
            _ = getBoolean(null, str) catch return false;
            return true;
        },
        .alpha => return stringutil.checkAllAscii(bytes, std.ascii.isAlphabetic),
        .alnum => return stringutil.checkAllAscii(bytes, std.ascii.isAlphanumeric),
        .ascii => return stringutil.checkAllAscii(bytes, std.ascii.isAscii),
        .digit => return stringutil.checkAllAscii(bytes, std.ascii.isDigit),
        .lower => return stringutil.checkAllAscii(bytes, std.ascii.isLower),
        .upper => return stringutil.checkAllAscii(bytes, std.ascii.isUpper),
        .space => return stringutil.checkAllAscii(bytes, std.ascii.isWhitespace),
        .xdigit => return stringutil.checkAllAscii(bytes, stringutil.isHexDigit),
        .control => return stringutil.checkAllAscii(bytes, std.ascii.isControl),
        .print => return stringutil.checkAllAscii(bytes, std.ascii.isPrint),
        .graph => return stringutil.checkAllAscii(bytes, stringutil.isGraph),
        .punct => return stringutil.checkAllAscii(bytes, stringutil.isPunct),
    }
}

fn testStringIs(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    const heap = try Heap.testStart(ta);

    var str = try newString(heap, "abcdefg");
    defer str.release();
    var str2 = try newString(heap, "abcdefg123");
    defer str2.release();
    var class = try newString(heap, "alpha");
    defer class.release();
    var bad_class = try newString(heap, "bad_class");
    defer bad_class.release();
    var details: ErrorDetails = undefined;

    try testing.expectEqual(true, try stringIs(&details, &str, &class, false));
    try testing.expectEqual(false, try stringIs(&details, &str2, &class, false));
    const err = stringIs(&details, &str, &bad_class, false);
    if (err == Error.OutOfMemory) return Error.OutOfMemory;
    try testing.expectError(Error.BadEnumVariant, err);
    try testing.expectEqualStrings(
        "bad class \"bad_class\": must be integer, alpha, alnum, ascii, digit, " ++
            "double, lower, upper, space, xdigit, control, print, graph, punct, boolean",
        try Heap.getString(details.message),
    );
    details.message.release();
}

test "string is" {
    try testing.checkAllAllocationFailures(testing.allocator, testStringIs, .{});
}

pub fn convertTokenizerError(heap: *Heap, err: Tokenizer.Error) error{OutOfMemory}!ErrorDetails {
    switch (err) {
        error.CharactersAfterCloseBrace => {
            return .{ .message = try newString(heap, "extra characters after close-brace") };
        },
        error.MissingCloseBrace => {
            return .{ .message = try newString(heap, "missing close-brace") };
        },
        error.MissingCloseBracket => {
            return .{ .message = try newString(heap, "unmatched \"[\"") };
        },
        error.MissingCloseQuote => {
            return .{ .message = try newString(heap, "missing quote") };
        },
        error.TrailingBackslash => {
            return .{ .message = try newString(heap, "no character after \\") };
        },
        error.DictSugarInExpression => {
            return .{ .message = try newString(heap, "dict sugar in expression") };
        },
        error.FunctionMissingParentheses => {
            return .{ .message = try newString(heap, "function missing parentheses") };
        },
        error.NotOperator => {
            return .{ .message = try newString(heap, "not operator") };
        },
        error.NotNumber => {
            return .{ .message = try newString(heap, "not number") };
        },
        error.NotVariable => unreachable,
    }
}

pub fn listUninitializedNew(len: u32) !Handle {
    // `1 +` to make space for the list's head
    const list_index = try Heap.local_heap.createObjects(1 + len);
    const list_head = Heap.local_heap.getLocalObject(list_index);

    list_head.* = .{
        .str = Heap.Object.null_string,
        .tag = .list,
        .body = .{
            .list = .{
                .len = len,
            },
        },
    };

    return Heap.local_heap.getHandle(list_index);
}

pub fn listNew(handles: []const Handle) !Handle {
    const list = try listUninitializedNew(@intCast(handles.len));
    errdefer list.release();

    const new_items = listItems(list);

    for (handles, new_items) |handle, *item| {
        item.* = try Heap.local_heap.duplicateOrReference(handle);
    }

    return list;
}

/// If shimmering, it creates the object in the calling heap
pub fn shimmerToList(det: ?*ErrorDetails, handle: *Handle) !void {
    if (handle.peek().tag == .list) return;

    const obj = handle.peek();
    const obj_heap = handle.getHeap();

    // Optimise dict -> list for object with no string rep.
    if (obj.tag == .dict and Heap.getStringDetails(handle.*) == .null) {
        // Only need to ensure it's shimmerable in this case, since
        // in the other case we duplicate it anyways.
        const metadata = &obj_heap.getExtraData(obj.body.dict).dict;
        const len = metadata.len; // copy

        try Heap.prepareToShimmer(handle);

        // Because both lists and dicts store their values directly after,
        // we can just swap out the head to convert to a list.
        obj.* = .{
            .str = Heap.Object.null_string,
            .tag = .list,
            .body = .{
                .list = .{ .len = len },
            },
        };
    } else {
        // No need to duplicate the handle if it can't shimmer, we have to create
        // a new object anyways.

        // Try to preserve information about filename / line number.
        const source_info: ?SourceInfo = getSourceInfo(handle.*);
        var file_name: ?Handle = null;
        var line_no: u32 = 1;
        if (source_info) |info| {
            line_no = info.line_no;

            if (info.file_name) |unwrapped| {
                file_name = unwrapped;
                _ = unwrapped.reference(); // Increment ref count.
            }
        }
        defer if (file_name) |unwrapped| unwrapped.release();

        const str = try Heap.getString(handle.*);
        var parser = Tokenizer.init(str, line_no);

        // Figure out how many tokens there are, so we can create the correct list size
        // in the heap.
        var tokens: std.ArrayList(Tokenizer.Token) = .empty;
        defer tokens.deinit(Heap.local_heap.gpa);

        while (true) {
            const next_token = parser.nextListToken() catch |err| {
                if (det) |details| details.* = try convertTokenizerError(Heap.local_heap, err);
                return err;
            };
            switch (next_token.tag) {
                .simple_string, .escaped_string => {
                    try tokens.append(Heap.local_heap.gpa, next_token);
                },
                .end_of_file => break,
                else => {
                    // Skip any line breaks or word breaks.
                },
            }
        }

        // TODO PERF: reuse the object backing if it was allocated with more than one object.
        const new_list = try listUninitializedNew(@intCast(tokens.items.len));
        errdefer new_list.release();

        for (tokens.items, 0..) |token, i| {
            const item = listItem(new_list, @intCast(i));

            if (token.tag == .simple_string) {
                // Normal string, so no escaping needed.
                try Heap.setString(item, str[token.loc.start..token.loc.end]);
            } else {
                // Needs escaping. We'll create another string to copy the escaped string into.
                try setStringFromEscaped(item, str[token.loc.start..token.loc.end]);
            }

            if (source_info) |info| {
                try setSourceInfo(item, .{
                    .file_name = info.file_name,
                    .line_no = token.loc.line_no,
                });
            }
        }

        const old_handle = handle.*;
        handle.* = new_list;
        old_handle.release();
    }
}

pub fn listLengthRaw(list: Handle) u32 {
    assert(list.peek().tag == .list);

    return list.peek().body.list.len;
}

pub fn listLength(det: ?*ErrorDetails, list: *Handle) !u32 {
    try shimmerToList(det, list);

    return list.peek().body.list.len;
}

fn collectionItem(handle: Handle, index: u32, len: u32) Heap.Handle {
    const obj = handle.peek();
    assert(obj.tag == .list or obj.tag == .dict);

    if (index < len) {
        const elem: Heap.Handle = .{
            .index = handle.index + 1 + index,
            .heap = handle.heap,
        };

        if (elem.peek().tag == .reference) {
            return elem.peek().body.reference;
        } else {
            return elem;
        }
    } else @panic("Element out of bounds");
}

pub fn collectionItems(handle: Handle, len: u32) []Heap.Object {
    const list = handle.peek();
    assert(list.tag == .list or list.tag == .dict);

    return handle.getHeap().objectSlice(handle.index + 1, handle.index + 1 + len);
}

/// Returns whether a reindex is needed.
fn setCollectionLength(handle: *Handle, new_len: u32) !bool {
    const obj = handle.peek();

    const current_len = blk: {
        switch (obj.tag) {
            .list => break :blk obj.body.list.len,
            .dict => break :blk handle.getHeap().getExtraData(obj.body.dict).dict.len,
            else => unreachable,
        }
    };

    // We can only do these quick changes if the collection is not shared.
    if (handle.canModify()) {
        // No need to realloc if we're shrinking.
        if (new_len <= current_len) {
            // Be sure to free the abandoned objects when we shrink.
            const freed_count = current_len - new_len;
            for (0..freed_count) |to_free| {
                const to_free_handle = listItem(handle.*, @intCast(current_len - freed_count + to_free));
                if (obj.tag == .dict and @mod(to_free, 2) == 0) {
                    // If a dict, be sure to remove the keys from the table.
                    _ = handle.getHeap().getExtraData(obj.body.dict).dict.table.remove(to_free_handle);
                }

                to_free_handle.invalidateBody();
                to_free_handle.invalidateString();
            }

            switch (obj.tag) {
                .list => obj.body.list.len = new_len,
                .dict => handle.getHeap().getExtraData(obj.body.dict).dict.len = new_len,
                else => unreachable,
            }

            return false;
        }

        // Even if there's not enough length, there may be enough capacity.
        const capacity = memutil.getOrderSize(handle.getMetadata().order) - 1; // -1 for list head
        if (new_len <= capacity) {
            switch (obj.tag) {
                .list => obj.body.list.len = new_len,
                .dict => handle.getHeap().getExtraData(obj.body.dict).dict.len = new_len,
                else => unreachable,
            }

            return false;
        }
    }

    // We've exhausted all other options, so we'll need to make a new collection.
    const new_handle = switch (obj.tag) {
        .list => try listUninitializedNew(new_len),
        .dict => try dictUninitializedNew(new_len),
        else => unreachable,
    };
    errdefer Heap.freeObject(new_handle);
    const new_items = collectionItems(new_handle, new_len);

    // Why `Heap.local_heap.heapId() != handle.heap`? Because we can't steal the old collection's
    // objects if they reference another heap's strings.
    if (!handle.canModify() or Heap.local_heap.heapId() != handle.heap) {
        // If the collection is shared, we need to duplicate all the items.
        for (0.., new_items) |i, *new_item| {
            new_item.* = try Heap.duplicateOrReference(
                Heap.local_heap,
                collectionItem(handle.*, @intCast(i), current_len),
            );
        }

        const old_handle = handle.*;
        handle.* = new_handle;
        old_handle.release();
    } else {
        // If the collection isn't shared, we can move the objects over without
        // any duplication.
        const old_items = collectionItems(handle.*, current_len);
        for (old_items, new_items[0..old_items.len]) |old_item, *new_item| {
            new_item.* = old_item;
        }

        // Free the old collection without running destructors (because the objects are
        // still in use, as we just transferred them). However, for dicts we still need
        // to free the extra data.
        if (handle.peek().tag == .dict) {
            const old_dict_metadata = &handle.getHeap().getExtraData(handle.peek().body.dict).dict;
            old_dict_metadata.table.deinit(handle.getHeap().gpa);
            handle.getHeap().destroyExtraData(handle.peek().body.dict);
        }
        Heap.freeObjectBacking(handle.*);
        handle.* = new_handle;
    }

    if (handle.peek().tag == .dict) return true;
    return false;
}

/// Assumes provided handle is a list.
pub fn listItem(handle: Handle, index: u32) Handle {
    const list = handle.peek();
    assert(list.tag == .list);

    return collectionItem(handle, index, list.body.list.len);
}

/// Assumes handle is a list.
pub fn listItems(handle: Handle) []Heap.Object {
    const list = handle.peek();
    assert(list.tag == .list);

    return handle.getHeap().objects.items(.object)[(handle.index + 1)..][0..list.body.list.len];
}

pub fn listAppendObject(det: ?*ErrorDetails, handle: *Handle, item: Heap.Object) !u32 {
    try shimmerToList(det, handle);
    _ = try setCollectionLength(handle, handle.peek().body.list.len + 1);

    const list = handle.peek();
    const index = list.body.list.len - 1;

    listItems(handle.*)[index] = item;

    return index;
}

pub fn listAppend(det: ?*ErrorDetails, handle: *Handle, item: Handle) !Handle {
    try shimmerToList(det, handle);
    _ = try setCollectionLength(handle, handle.peek().body.list.len + 1);

    const list = handle.peek();
    const index = list.body.list.len - 1;

    listItems(handle.*)[index] = try handle.getHeap().duplicateOrReference(item);

    return handle.getHeap().getHandle(index);
}

fn testLists(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    const heap = try Heap.testStart(ta);

    var det: ErrorDetails = undefined;

    // Simple case: two objects in a list
    const obj1 = try newString(heap, "object 1");
    defer obj1.release();
    const obj2 = try newString(heap, "object 2");
    defer obj2.release();
    var list1 = try listNew(&.{ obj1, obj2 });
    defer list1.release();

    const items = listItems(list1);
    try testing.expectEqual(2, items.len);
    // The object should have been copied when being moved into the list
    try testing.expect(obj1.peek().str != items[0].str);
    // But it should have an identical string
    try testing.expectEqualStrings("object 1", try Heap.getString(listItem(list1, 0)));

    const to_append = try newString(heap, "appended item");
    defer to_append.release();

    _ = try listAppend(&det, &list1, to_append);
    try testing.expectEqualStrings("appended item", try Heap.getString(listItem(list1, 2)));

    var string_list = try newString(heap,
        \\item1 {item 2} item\ 3
    );
    defer string_list.release();

    const old_string_list_handle = string_list;
    try shimmerToList(&det, &string_list);
    try testing.expect(old_string_list_handle != string_list);
    try testing.expectEqualStrings("item1", try Heap.getString(listItem(string_list, 0)));
    try testing.expectEqualStrings("item 2", try Heap.getString(listItem(string_list, 1)));
    try testing.expectEqualStrings("item 3", try Heap.getString(listItem(string_list, 2)));
}

test "lists" {
    try testing.checkAllAllocationFailures(testing.allocator, testLists, .{});
}

pub fn shimmerToDict(det: ?*ErrorDetails, handle: *Handle) !void {
    if (handle.peek().tag == .dict) return;

    // Getting the list length will also shimmer it to a list.
    const len = try listLength(det, handle);
    if (@mod(len, 2) == 1) {
        // Unmatched key.
        if (det) |details| details.* = .{
            .message = try newString(Heap.local_heap, "missing value to go with key"),
        };
        return Error.BadDict;
    }

    const handle_heap = handle.getHeap();

    const metadata_index = try handle_heap.createExtraData();
    errdefer handle_heap.destroyExtraData(metadata_index);

    const metadata = handle_heap.getExtraData(metadata_index);
    metadata.* = .{
        .dict = .{
            .len = len,
            .table = .empty,
        },
    };

    // Populate the hash table _before_ updating the object.
    // This way if `put` fails, the errdefer will cleanly destroy the extra data.
    var pair: u32 = 0;
    while (pair < len) : (pair += 2) {
        const key: Heap.Handle = .{
            .index = handle.index + 1 + pair,
            .heap = handle.heap,
        };
        try metadata.dict.table.put(handle_heap.gpa, key, pair + 1);
    }

    // Only after the hash table is populated do we update the object.

    // Because both lists and dicts store their values directly after,
    // we can just swap out the head to convert to a dict.
    handle.peek().* = .{
        .str = Heap.Object.null_string,
        .tag = .dict,
        .body = .{
            .dict = metadata_index,
        },
    };
}

pub fn dictItems(handle: Handle) []Heap.Object {
    const obj = handle.peek();
    const obj_heap = handle.getHeap();

    assert(obj.tag == .dict);

    const len = obj_heap.getExtraData(obj.body.dict).dict.len;
    return handle.getHeap().objects.items(.object)[(handle.index + 1)..][0..len];
}

pub fn dictItem(handle: Handle, index: u32) Handle {
    const dict = handle.peek();
    assert(dict.tag == .dict);
    const metadata = &handle.getHeap().getExtraData(dict.body.dict).dict;

    return collectionItem(handle, index, metadata.len);
}

pub fn dictItemLengthRaw(handle: Handle) u32 {
    assert(handle.peek().tag == .dict);
    return handle.getHeap().getExtraData(handle.peek().body.dict).dict.len;
}

pub fn dictPairLengthRaw(handle: Handle) u32 {
    assert(handle.peek().tag == .dict);
    return handle.getHeap().getExtraData(handle.peek().body.dict).dict.len / 2;
}

/// Length in pairs (total length / 2).
pub fn dictPairLength(det: ?*ErrorDetails, handle: *Handle) !u32 {
    try shimmerToDict(det, handle);
    return dictPairLengthRaw(handle.*);
}

pub fn dictUninitializedNew(len: u32) !Handle {
    assert(@mod(len, 2) == 0);

    // `1 +` to make space for the dict's head.
    const dict_index = try Heap.local_heap.createObjects(1 + len);
    errdefer Heap.freeObjectBacking(Heap.local_heap.getHandle(dict_index));
    const dict_metadata = try Heap.local_heap.createExtraData();
    errdefer Heap.local_heap.destroyExtraData(dict_metadata);

    Heap.local_heap.getExtraData(dict_metadata).* = .{
        .dict = .{
            .table = .empty,
            .len = len,
        },
    };

    const dict_head = Heap.local_heap.getLocalObject(dict_index);
    dict_head.* = .{
        .str = Heap.Object.null_string,
        .tag = .dict,
        .body = .{
            .dict = dict_metadata,
        },
    };

    return Heap.local_heap.getHandle(dict_index);
}

/// Caller is responsible that `handles` has handles.len % 2 == 0.
pub fn newDict(heap: *Heap, handles: []const Handle) !Handle {
    const dict = try dictUninitializedNew(@intCast(handles.len));
    errdefer dict.release();

    const new_items = dictItems(dict);

    for (handles, new_items) |handle, *item| {
        item.* = try Heap.duplicateOrReference(heap, handle);
    }

    try dictReindex(dict, null);

    return dict;
}

/// Panics if not a dict, or if it can't shimmer.
pub fn dictReindex(handle: Handle, up_to: ?usize) !void {
    assert(handle.canShimmer());
    const obj = handle.peek();
    assert(obj.tag == .dict);
    const dict = &handle.getHeap().getExtraData(obj.body.dict).dict;
    assert(dict.len % 2 == 0);

    dict.table.clearRetainingCapacity();
    // Reset the table if we run into an error. Better than leaving
    // it in a bad state.
    errdefer dict.table.clearAndFree(handle.getHeap().gpa);

    // This properly accounts for duplicate dictionary entries,
    // as it'll just overwrite it with the second `dict.put`.
    var pair: u32 = 0;
    while (pair < (up_to orelse dict.len)) : (pair += 2) {
        const key: Handle = dictItem(handle, pair);
        // Make sure key has a string rep.
        _ = try Heap.getString(key);
        // Point to `pair + 1`, e.g. the value following the key.
        try dict.table.put(handle.getHeap().gpa, key, pair + 1);
    }
}

pub fn dictLookupRaw(dict: Handle, key: Handle) error{OutOfMemory}!?Handle {
    assert(dict.peek().tag == .dict);
    // Make sure key has a string representation, as table.get isn't allowed to fail.
    _ = try Heap.getString(key);

    const dict_heap = dict.getHeap();
    const metadata = &dict_heap.getExtraData(dict.peek().body.dict).dict;

    if (metadata.table.get(key)) |value_offset| {
        return dictItem(dict, value_offset);
    } else return null;
}

fn dictHasDuplicatesRaw(handle: Handle) bool {
    const dict_obj = handle.peek();
    const dict_heap = handle.getHeap();
    const metadata = &dict_heap.getExtraData(dict_obj.body.dict).dict;

    assert(metadata.table.size * 2 <= metadata.len);
    return metadata.table.size * 2 != metadata.len;
}

/// Removes duplicate entries. Assumes handle is a dict. If the caller needs to track
/// a key/value as it gets rearranged, set `to_track`. The result will be its new index,
/// unless it was removed.
fn dictRemoveDuplicates(handle: *Handle, to_track: ?u32) !?u32 {
    var metadata = &handle.getHeap().getExtraData(handle.peek().body.dict).dict;

    assert(handle.peek().tag == .dict);
    try Heap.prepareForModification(handle);

    const dict_obj = handle.peek();
    const dict_heap = handle.getHeap();
    metadata = &dict_heap.getExtraData(dict_obj.body.dict).dict;

    var to_track_new_location: ?u32 = null;

    if (metadata.table.size * 2 != metadata.len) {
        const items = dictItems(handle.*);
        var pair_index: u32 = 0;

        while (pair_index < metadata.len / 2) : (pair_index += 1) {
            const key_index = pair_index * 2;
            const value_index = key_index + 1;
            const key_handle = dictItem(handle.*, key_index);
            const value_handle = dictItem(handle.*, value_index);

            // Make sure key has a string representation, as table.get isn't allowed to fail.
            _ = try Heap.getString(key_handle);
            if (metadata.table.get(key_handle).? != value_index) {
                key_handle.peek().tag = .marked;
                value_handle.peek().tag = .marked;
            }
        }

        // Why mark all the handles before later removing them? Because the hash map
        // requires all the keys and values to not move, and we use the hash map
        // to see what pairs need to be removed.
        var removed: u32 = 0;
        pair_index = 0;
        while (pair_index < metadata.len / 2) : (pair_index += 1) {
            const key_index = pair_index * 2;
            const value_index = key_index + 1;
            const key_handle = dictItem(handle.*, key_index);
            const value_handle = dictItem(handle.*, value_index);

            if (key_handle.peek().tag == .marked) {
                removed += 1;

                // We have to invalidate the string here, and not earlier, because
                // the hash map `.get()` uses the string rep of the keys.
                key_handle.invalidateString();
                key_handle.invalidateBody(); // sets tag to .none
                value_handle.invalidateString();
                value_handle.invalidateBody(); // sets tag to .none
            } else if (removed > 0) {
                // There was a pair removed at some point, so we need to shift this pair backwards.
                const new_key_index = (pair_index - removed) * 2;
                const new_value_index = new_key_index + 1;

                if (key_index == to_track) to_track_new_location = new_key_index;
                if (value_index == to_track) to_track_new_location = new_value_index;

                items[new_key_index] = items[key_index];
                items[new_value_index] = items[value_index];
            } else {
                if (key_index == to_track) to_track_new_location = key_index;
                if (value_index == to_track) to_track_new_location = value_index;
            }
        }

        // "zero" out the removed items.
        for ((metadata.len - removed * 2)..metadata.len) |to_zero| {
            items[to_zero] = .{
                .str = Heap.Object.null_string,
                .tag = .none,
                .body = undefined,
            };
        }

        metadata.len -= removed * 2;
    } else {
        to_track_new_location = to_track;
    }

    try dictReindex(handle.*, null);

    return to_track_new_location;
}

/// Takes ownership of `value`, including error cases. Returns a handle to the new value's location.
/// `value` must be in `Heap.local_heap`.
pub fn dictPutObject(handle: *Handle, key: Handle, value: Heap.Object) !Heap.Handle {
    assert(handle.peek().tag == .dict);

    // Copy on write logic.
    const old_dict: ?Heap.Handle = blk: {
        if (handle.canModify()) {
            break :blk null;
        } else {
            const old = handle.*;
            handle.* = try Heap.local_heap.duplicate(handle.*);
            break :blk old;
        }
    };
    // The old dict needs to be released at the very end, because `key` may come from the old dict.
    defer if (old_dict) |val| val.release();

    handle.invalidateString();

    assert(handle.heap == Heap.local_heap.heapId());
    var metadata = &Heap.local_heap.getExtraData(handle.peek().body.dict).dict;

    const value_index: u32 = blk: {
        // If we hit OOM at some point, we need to be sure to roll back the new value.
        errdefer {
            var value_mut = value;
            value_mut.deinitBodySingle(Heap.local_heap);
        }

        // Ensure `original_key` has a string rep.
        _ = try Heap.getString(key);
        // Does the key already exist?
        if (metadata.table.get(key)) |existing_value| {
            // Key exists, so replace the value in place.
            const value_handle = dictItem(handle.*, existing_value);
            value_handle.invalidateBoth();
            value_handle.peek().* = value;

            break :blk existing_value;
        } else {
            // Need to copy the key string here, because it may become invalidated when
            // calling `ensureTotalCapacity`.
            const key_dup_str = try Heap.local_heap.duplicateObjString(key);
            errdefer key_dup_str.deinit(Heap.local_heap);

            const new_length = metadata.len + 2;

            // Key doesn't exist, so append both key and value.
            const new_key_index = metadata.len;
            const new_value_index = metadata.len + 1;
            const reindex_needed = try setCollectionLength(handle, new_length);
            // `handle` may change after updating the length, so we better reload
            // the metadata pointer.
            metadata = &Heap.local_heap.getExtraData(handle.peek().body.dict).dict;
            try metadata.table.ensureTotalCapacity(Heap.local_heap.gpa, new_length / 2);

            const new_key_handle = dictItem(handle.*, new_key_index);
            const new_value_handle = dictItem(handle.*, new_value_index);

            assert(new_key_handle.heap == Heap.local_heap.heapId());
            assert(Heap.local_heap.exchangeString(new_key_handle.index, Heap.Object.null_string, key_dup_str));

            // Reindex after we've added the new key (not the value though, because we might
            // accidentally double-free the new value).
            if (reindex_needed) {
                // dictReindex could still fail if one of the objects doesn't have a string rep.
                try dictReindex(handle.*, null);
            } else {
                metadata.table.putAssumeCapacity(new_key_handle, new_value_index);
            }

            new_value_handle.peek().* = value;
            break :blk new_value_index;
        }
    };

    // Because we mutated the dictionary, we need to remove any duplicates.
    if (dictHasDuplicatesRaw(handle.*)) {
        const new_value_index = (try dictRemoveDuplicates(handle, value_index)).?;
        return dictItem(handle.*, new_value_index);
    }

    return dictItem(handle.*, value_index);
}

pub fn dictPut(handle: *Handle, key: Handle, value: Handle) !Heap.Handle {
    return dictPutObject(handle, key, try Heap.local_heap.duplicateOrReference(value));
}

fn testDicts(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    const heap = try Heap.testStart(ta);

    const key1 = try newString(heap, "foo");
    defer key1.release();
    const value1 = try newString(heap, "1");
    defer value1.release();
    const key2 = try newString(heap, "bar");
    defer key2.release();
    const value2 = try newString(heap, "2");
    defer value2.release();

    const dict1 = try newDict(heap, &.{ key1, value1, key2, value2 });
    defer dict1.release();

    const good_key = try newString(heap, "foo");
    defer good_key.release();
    const bad_key = try newString(heap, "bogus");
    defer bad_key.release();

    try testing.expectEqualStrings("1", try Heap.getString((try dictLookupRaw(dict1, good_key)).?));
    try testing.expectEqual(null, try dictLookupRaw(dict1, bad_key));

    // Dict with duplicate entries testing.
    var dict_with_duplicates = try newString(heap, "foo 5 bar 10 foo 15");
    defer dict_with_duplicates.release();
    const dup_len = try dictPairLength(null, &dict_with_duplicates);

    try testing.expectEqual(3, dup_len);
    // When a duplicate key is queried, it should point to the last corrisponding value.
    try testing.expectEqualStrings("15", try Heap.getString((try dictLookupRaw(dict_with_duplicates, key1)).?));

    _ = try dictRemoveDuplicates(&dict_with_duplicates, null);
    try testing.expectEqual(2, dictPairLengthRaw(dict_with_duplicates));

    // Dict put testing.
    var dict_for_put = try newDict(heap, &.{ key1, value1, key2, value2 });
    defer dict_for_put.release();
    const key3 = try newString(heap, "baz");
    defer key3.release();
    const value3 = try newString(heap, "3");
    defer value3.release();

    try testing.expectEqual(2, dictPairLengthRaw(dict_for_put));
    _ = try dictPut(&dict_for_put, key2, value3);
    try testing.expectEqual(2, dictPairLengthRaw(dict_for_put));

    _ = try dictPut(&dict_for_put, key3, value3);
    try testing.expectEqual(3, dictPairLengthRaw(dict_for_put));
    try testing.expectEqualStrings("3", try Heap.getString((try dictLookupRaw(dict_for_put, key3)).?));

    // Test dict edge cases.
    var dict_edge_cases = try newDict(heap, &.{ key1, value1, key2, value2 });
    defer dict_edge_cases.release();
    // Try using a value as a key, and a key as the value while not shared (this is to check
    // that this handles using internal objects correctly).
    assert(dict_edge_cases.canModify());
    _ = try dictPut(&dict_edge_cases, dictItem(dict_edge_cases, 1), dictItem(dict_edge_cases, 2));
    try testing.expectEqualStrings("bar", try Heap.getString((try dictLookupRaw(dict_edge_cases, value1)).?));

    // Try aliasing a key by using it as key and value.
    _ = try dictPut(&dict_edge_cases, dictItem(dict_edge_cases, 0), dictItem(dict_edge_cases, 0));
    try testing.expectEqualStrings("foo", try Heap.getString((try dictLookupRaw(dict_edge_cases, key1)).?));

    // Try aliasing a value by using it as key and value.
    _ = try dictPut(&dict_edge_cases, dictItem(dict_edge_cases, 3), dictItem(dict_edge_cases, 3));
    try testing.expectEqualStrings("2", try Heap.getString((try dictLookupRaw(dict_edge_cases, value2)).?));
}

test "dicts" {
    try testing.checkAllAllocationFailures(testing.allocator, testDicts, .{});
}

pub const SourceInfo = struct {
    file_name: ?Handle,
    line_no: u32,
};

/// .file_name will become invalid if the file name object's string becomes invalid.
/// Does not borrow the file_name object, so be sure to borrow shimmering the handle.
pub fn getSourceInfo(handle: Handle) ?SourceInfo {
    const obj = handle.peek();
    if (obj.tag != .source) return null;

    const file_name_handle = handle.getHeap().getHandle(obj.body.source.file_name_obj);
    const file_name = if (file_name_handle.index != 0) file_name_handle else null;

    return .{
        .file_name = file_name,
        .line_no = obj.body.source.line_no,
    };
}

/// `handle` must be able to shimmer.
pub fn setSourceInfo(handle: Handle, source_info: SourceInfo) !void {
    assert(handle.canShimmer());

    const ref = handle.peek();
    ref.tag = .source;
    ref.body.source.line_no = source_info.line_no;

    if (source_info.file_name) |file_name| {
        var same_heap_file_name = file_name;

        if (same_heap_file_name.heap != handle.heap) {
            same_heap_file_name = try Heap.local_heap.duplicate(same_heap_file_name);
        } else {
            // Make sure to increment the ref count.
            same_heap_file_name.incrRefCount();
        }

        // This should be true, as Heap.ensureShimmerable will make sure it's in our heap.
        assert(handle.heap == same_heap_file_name.heap);

        ref.body.source.file_name_obj = same_heap_file_name.index;
    } else {
        ref.body.source.file_name_obj = Heap.null_object_idx;
    }
}

fn testSourceInfo(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    const heap = try Heap.testStart(ta);

    var obj = try heap.createObject();
    defer obj.release();

    const file_name = try newString(heap, "test_file.tcl");
    defer file_name.release();

    try setSourceInfo(obj, .{ .file_name = file_name, .line_no = 42 });

    // Verify the object has the source tag
    const ref = obj.peek();
    try testing.expectEqual(.source, ref.tag);
    try testing.expectEqual(@as(u32, 42), ref.body.source.line_no);

    const info = getSourceInfo(obj);
    try testing.expectEqualSlices(u8, "test_file.tcl", try Heap.getString(info.?.file_name.?));
    try testing.expectEqual(@as(u32, 42), info.?.line_no);

    const obj2 = try newString(heap, "hello");
    defer obj2.release();

    const empty_info = getSourceInfo(obj2);
    try testing.expect(empty_info == null);
}

test "source info" {
    try testing.checkAllAllocationFailures(testing.allocator, testSourceInfo, .{});
}

var next_script_id = 1;

////////////////////////////////
//  Script related functions  //

/// Not threadsafe.
pub fn parseScript(det: ?*ErrorDetails, handle: Handle) !Heap.ParsedScript {
    // Get source info, or use defaults.
    const source_info: SourceInfo = if (getSourceInfo(handle)) |info| info else .{
        .file_name = null,
        .line_no = 1,
    };

    // Parse all the tokens of the script, handling any errors that come up.

    const bytes = try Heap.getString(handle);
    var parser = Tokenizer.init(bytes, source_info.line_no);

    // Set up tokens list (to be added to).
    var tokens = try std.ArrayList(Tokenizer.Token).initCapacity(Heap.local_heap.gpa, bytes.len / 8);
    defer tokens.deinit(Heap.local_heap.gpa);

    // Used to ignore the first token if it's .command_separator (effectively
    // trimming any starting whitespace)
    var is_trimming = true;
    // Add all tokens to the list, handling any errors that may come up.
    while (true) {
        const next_token = parser.nextScriptToken();
        if (next_token) |token| {
            switch (token.tag) {
                .command_separator, .word_separator => {
                    if (!is_trimming) try tokens.append(Heap.local_heap.gpa, token);
                },
                .end_of_file => {
                    try tokens.append(Heap.local_heap.gpa, token);
                    break;
                },
                else => {
                    is_trimming = false;
                    try tokens.append(Heap.local_heap.gpa, token);
                },
            }
        } else |err| {
            if (det) |details| {
                details.* = try convertTokenizerError(Heap.local_heap, err);
                if (parser.error_details) |parser_details| {
                    details.index = parser_details.index;
                }
            }
            return err;
        }

        is_trimming = false;
    }

    if (options.token_debugging) {
        for (tokens.items, 0..) |token, i| {
            std.debug.print("[{: >3}@{: >3}]  .{s: <20}  \"{s}\"\n", .{
                i,
                token.loc.line_no,
                @tagName(token.tag),
                bytes[token.loc.start..token.loc.end],
            });
        }
    }

    // +1 for the first ".script_command".
    const new_token_capacity: u32 = @intCast(tokens.items.len + 1);

    // Initialize the Heap-stored list that will contain the corrisponding value for each token.
    var new_token_values = try listUninitializedNew(new_token_capacity);
    errdefer new_token_values.release();
    // Set length to 0 so we can just call listAppend().
    _ = try setCollectionLength(&new_token_values, 0);

    var new_token_tags = try std.ArrayList(Tokenizer.Token.Tag).initCapacity(Heap.local_heap.gpa, new_token_capacity);
    errdefer new_token_tags.deinit(Heap.local_heap.gpa);

    // Be sure to append the first .script_command token.
    try new_token_tags.append(Heap.local_heap.gpa, .start_of_command);
    _ = try listAppendObject(det, &new_token_values, .{
        .str = Heap.Object.null_string,
        .tag = .script_command,
        .body = .{
            .script_command = .{
                .line = source_info.line_no,
                .arg_count = 0, // Set later.
            },
        },
    });

    // The current script line's token index.
    var script_command_idx: usize = 0;
    // The number of arguments for this command.
    var command_arg_count: u32 = 0;
    var i: usize = 0;
    var last_i: usize = 0;
    while (i < tokens.items.len) {
        // Skip any leading separators.
        while (tokens.items[i].tag == .word_separator) i += 1;

        // Look ahead to see when the next separator is.
        var arg_token_count: usize = 0;
        var found_expansion: bool = false;
        while (i + arg_token_count < tokens.items.len) : (arg_token_count += 1) {
            switch (tokens.items[i + arg_token_count].tag) {
                .argument_expansion => found_expansion = true,
                .command_separator, .word_separator, .end_of_file => break,
                else => {},
            }
        }

        // We'll only reach here if the current token is .command_separator or .end_of_file, because
        // word_token_count counts all tokens except those (well, and it doesn't count .word_separator,
        // but that's ruled out at the beginning when we skipped leading separators).
        if (arg_token_count == 0) {
            listItems(new_token_values)[script_command_idx].body.script_command.arg_count = command_arg_count;

            if (tokens.items[i].tag == .end_of_file) {
                break; // Don't append a .script_command for EOF
            }

            i += 1; // Skip command separator.

            // Start a new command.
            command_arg_count = 0;
            try new_token_tags.append(Heap.local_heap.gpa, .start_of_command);
            script_command_idx = try listAppendObject(det, &new_token_values, .{
                .str = Heap.Object.null_string,
                .tag = .script_command,
                .body = .{ .script_command = .{ .line = tokens.items[i].loc.line_no, .arg_count = 0 } },
            });

            continue;
        }

        // Append the start of the word (only if necessary).
        if (found_expansion or arg_token_count > 1) {
            if (found_expansion) {
                try new_token_tags.append(Heap.local_heap.gpa, .argument_expansion);
            } else {
                try new_token_tags.append(Heap.local_heap.gpa, .start_of_word);
            }

            _ = try listAppendObject(det, &new_token_values, .{
                .str = Heap.Object.null_string,
                .tag = .integer,
                .body = .{
                    .integer = @intCast(arg_token_count),
                },
            });
        }

        command_arg_count += 1;

        // Now append the tokens to the new list, escaping as necessary.
        for (i..(i + arg_token_count)) |token_idx| {
            const token = tokens.items[token_idx];

            const str_handle = blk: {
                switch (token.tag) {
                    .argument_expansion => break :blk null,
                    .escaped_string => {
                        try new_token_tags.append(Heap.local_heap.gpa, .simple_string);
                        const str_idx = try listAppendObject(
                            det,
                            &new_token_values,
                            .{ .str = Heap.Object.null_string, .tag = .none, .body = undefined },
                        );

                        const item_handle = listItem(new_token_values, str_idx);
                        try setStringFromEscaped(item_handle, bytes[token.loc.start..token.loc.end]);

                        break :blk item_handle;
                    },
                    else => {
                        try new_token_tags.append(Heap.local_heap.gpa, token.tag);
                        const str_idx = try listAppendObject(
                            det,
                            &new_token_values,
                            .{ .str = Heap.Object.null_string, .tag = .none, .body = undefined },
                        );

                        const item_handle = listItem(new_token_values, str_idx);
                        try Heap.setString(item_handle, bytes[token.loc.start..token.loc.end]);

                        break :blk item_handle;
                    },
                }
            };

            if (str_handle) |token_str| {
                try setSourceInfo(token_str, .{
                    .file_name = source_info.file_name,
                    .line_no = token.loc.line_no,
                });
            }
        }

        // Be sure to advance our index to the next word.
        i += arg_token_count;

        last_i = i;
    }

    // Increment reference count to file name, if not null.
    if (source_info.file_name) |file_name| _ = file_name.reference();
    const parsed_script: Heap.ParsedScript = .{
        .tags = new_token_tags,
        .values = new_token_values,
        .first_line = source_info.line_no,
        .file_name_obj = source_info.file_name,
    };
    if (options.token_debugging) parsed_script.printTokens();

    return parsed_script;
}

fn testScriptParsing(ta: std.mem.Allocator) !void {
    const heap = try Heap.testStart(ta);
    defer Heap.testFinish();

    const script1 = try newString(heap,
        \\ set x 5
        \\ set y $x[set x]
    );
    defer script1.release();
    var parsed = try parseScript(null, script1);
    defer parsed.deinit(heap);

    const tokens = parsed.tags.items;
    const values = listItems(parsed.values);

    // set x 5
    try testing.expectEqual(.start_of_command, tokens[0]);
    try testing.expectEqual(1, values[0].body.script_command.line);
    try testing.expectEqual(3, values[0].body.script_command.arg_count);
    try expectEqualToken(&parsed, 1, .simple_string, "set");
    try expectEqualToken(&parsed, 2, .simple_string, "x");
    try expectEqualToken(&parsed, 3, .simple_string, "5");

    try testing.expectEqual(.start_of_command, tokens[4]);
    try testing.expectEqual(2, values[4].body.script_command.line);
    try testing.expectEqual(3, values[4].body.script_command.arg_count);
    try expectEqualToken(&parsed, 5, .simple_string, "set");
    try expectEqualToken(&parsed, 6, .simple_string, "y");
    try testing.expectEqual(.start_of_word, tokens[7]);
    try testing.expectEqual(2, values[7].body.integer);
    try expectEqualToken(&parsed, 8, .variable_subst, "x");
    try expectEqualToken(&parsed, 9, .command_subst, "set x");
}

test "script parsing" {
    try testing.checkAllAllocationFailures(testing.allocator, testScriptParsing, .{});
}

pub fn shimmerToScript(det: ?*ErrorDetails, handle: *Handle) !void {
    // Figure out whether the provided object already has a script id, or if we need to
    // generate a new one.
    const script_info = blk: {
        if (handle.peek().tag == .script) {
            const script = handle.peek().body.script;
            break :blk .{ script.id, false };
        } else {
            break :blk .{ try Heap.ScriptId.next(), true };
        }
    };
    const script_id = script_info.@"0";
    const using_new_id = script_info.@"1";
    errdefer if (using_new_id) script_id.retire();

    if (Heap.local_heap.parsed_scripts.get(script_id.index)) |existing_script| {
        if (existing_script.generation == script_id.generation) {
            // Object is already a script, it exists as parsed in our heap,
            // and it's the correct generation. No need to reparse!
            return;
        } else {
            // Wrong generation, so free the old one before overwriting (later in code).
            var script_as_mut = existing_script.script;
            script_as_mut.deinit(Heap.local_heap);
            // Be sure to remove it, in case we hit an error before we have the chance
            // to overwrite it.
            _ = Heap.local_heap.parsed_scripts.remove(script_id.index);
        }
    } else {
        // We don't have this script in our heap, so keep going to generate it.
    }

    var parsed = parseScript(det, handle.*) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ParseError,
    };
    errdefer parsed.deinit(Heap.local_heap);

    try Heap.local_heap.parsed_scripts.put(Heap.local_heap.gpa, script_id.index, .{
        .script = parsed,
        .generation = script_id.generation,
    });

    try Heap.prepareToShimmer(handle);
    const obj = handle.peek();
    obj.body.script = .{ .id = script_id };
    obj.tag = .script;
}

pub fn getScript(det: ?*ErrorDetails, handle: *Handle) !Heap.ParsedScript {
    try shimmerToScript(det, handle);
    assert(handle.peek().tag == .script);

    const script_id = handle.peek().body.script.id;
    const script_and_generation = Heap.local_heap.parsed_scripts.get(script_id.index).?;
    assert(script_and_generation.generation == script_id.generation);

    return script_and_generation.script;
}

fn testScriptShimmering(ta: std.mem.Allocator) !void {
    const heap = try Heap.testStart(ta);
    defer Heap.testFinish();

    const old_script_id = blk: {
        var old_script = try newString(heap,
            \\ set foo 5
            \\ set y $foo[set foo]
        );
        defer old_script.release();

        const parsed_script = try getScript(null, &old_script);
        const script1_id = old_script.peek().body.script.id;
        try testing.expectEqualSlices(Tokenizer.Token.Tag, &[_]Tokenizer.Token.Tag{
            .start_of_command,
            .simple_string,
            .simple_string,
            .simple_string,
            .start_of_command,
            .simple_string,
            .simple_string,
            .start_of_word,
            .variable_subst,
            .command_subst,
        }, parsed_script.tags.items);

        break :blk script1_id;
    };

    var new_script = try newString(heap, "set x 5");
    defer new_script.release();

    try shimmerToScript(null, &new_script);
    const new_script_id = new_script.peek().body.script.id;

    // Make sure the new script recycles the old script's index.
    try testing.expectEqual(old_script_id.index, new_script_id.index);
    try testing.expect(old_script_id.generation != new_script_id.generation);
}

test "script shimmering" {
    try testing.checkAllAllocationFailures(testing.allocator, testScriptShimmering, .{});
}

fn expectEqualToken(script: *const Heap.ParsedScript, index: u32, tag: Tokenizer.Token.Tag, value: []const u8) !void {
    try testing.expectEqual(tag, script.tags.items[index]);
    try testing.expectEqualStrings(value, try Heap.getString(listItem(script.values, index)));
}

pub fn shimmerToExpression(det: ?*ErrorDetails, handle: *Handle) !void {
    // Figure out whether the provided object already has a script id, or if we need to
    // generate a new one.
    const expr_info = blk: {
        if (handle.peek().tag == .expr) {
            const expr = handle.peek().body.expr;
            // We didn't create a new script id here.
            break :blk .{ expr.id, false };
        } else {
            break :blk .{ try Heap.ScriptId.next(), true };
        }
    };
    const expr_id = expr_info.@"0";
    const using_new_id = expr_info.@"1";
    errdefer if (using_new_id) expr_id.retire();

    // Check if this expression is already parsed in this heap.
    if (Heap.local_heap.parsed_exprs.get(expr_id.index)) |existing_expr| {
        if (existing_expr.generation == expr_id.generation) {
            // Object is already an expression, it exists as parsed in our heap,
            // and it's the correct generation. No need to reparse!
            return;
        } else {
            // Wrong generation, so free the old one before overwriting (later in code).
            var expr_as_mut = existing_expr.expr;
            expr_as_mut.deinit(Heap.local_heap.gpa);
            // Be sure to remove it, in case we hit an error before we have the chance
            // to overwrite it.
            _ = Heap.local_heap.parsed_scripts.remove(expr_id.index);
        }
    } else {
        // We don't have this expression in our heap, so keep going to generate it.
    }

    const source_info: SourceInfo = getSourceInfo(handle.*) orelse .{ .file_name = null, .line_no = 1 };
    const file_name = try Handle.borrowOptional(source_info.file_name);
    errdefer if (file_name) |val| val.release();
    const line_no = source_info.line_no;

    try Heap.prepareToShimmer(handle);

    // Parse all the tokens of the expr, handling any errors that come up.
    const bytes = try Heap.getString(handle.*);
    var tokenizer = Tokenizer.init(bytes, line_no);
    var tokens = std.MultiArrayList(Tokenizer.Token).empty;
    defer tokens.deinit(Heap.local_heap.gpa);
    while (true) {
        const next_token = tokenizer.nextExpressionToken();
        if (next_token) |token| {
            try tokens.append(Heap.local_heap.gpa, token);
            if (token.tag == .end_of_file) break;
        } else |err| if (det) |details| {
            details.* = try convertTokenizerError(Heap.local_heap, err);
            if (tokenizer.error_details) |parser_details| {
                details.index = parser_details.index;
            }
            return err;
        }
    }

    if (tokens.len == 0) {
        if (det) |details| details.* = .{
            .message = try newString(Heap.local_heap, "empty expression"),
        };
        return error.ParseError;
    }

    // Next, go ahead and parse the expression from the tokens.
    var parsed: Heap.ParsedExpression = blk: {
        var parser = expr_parse.Parse.init(Heap.local_heap, file_name, bytes, tokens.slice());
        errdefer parser.deinit();
        if (parser.parseExpr()) |root_node| {
            break :blk .{ .nodes = parser.nodes, .root_node = root_node.? };
            // Note we don't deinit parser here, since we take ownership.
        } else |err| {
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ParseError => {
                    if (det) |details| {
                        var aw = std.Io.Writer.Allocating.init(Heap.local_heap.gpa);
                        errdefer aw.deinit();
                        const err_details = parser.err.?;
                        parser.renderError(err_details, &aw.writer) catch return error.OutOfMemory;
                        const rendered_error = try aw.toOwnedSlice();
                        defer Heap.local_heap.gpa.free(rendered_error);
                        const err_on_heap = try newString(Heap.local_heap, rendered_error);
                        errdefer err_on_heap.release();

                        details.* = .{
                            .message = err_on_heap,
                            .index = err_details.sourceIndex(&parser),
                        };
                    }
                    return error.ParseError;
                },
            }
        }
    };
    errdefer parsed.deinit(Heap.local_heap.gpa);

    try Heap.local_heap.parsed_exprs.put(Heap.local_heap.gpa, expr_id.index, .{
        .expr = parsed,
        .generation = expr_id.generation,
    });

    handle.peek().tag = .expr;
    handle.peek().body = .{
        .expr = .{ .id = expr_id },
    };
}

pub fn getExpression(det: ?*ErrorDetails, handle: *Handle) !Heap.ParsedExpression {
    try shimmerToExpression(det, handle);
    assert(handle.peek().tag == .script);

    const expr_id = handle.peek().body.script.id;
    const expr_and_generation = Heap.local_heap.parsed_exprs.get(expr_id.index).?;
    assert(expr_and_generation.generation == expr_id.generation);

    return expr_and_generation.expr;
}

fn testExpressions(ta: std.mem.Allocator) !void {
    const heap = try Heap.testStart(ta);
    defer Heap.testFinish();

    var expr1 = try newString(heap, "1 + 2 * 3 + 4");
    defer expr1.release();

    try shimmerToExpression(null, &expr1);

    const expr_id = expr1.peek().body.expr.id;
    const parsed = heap.parsed_exprs.get(expr_id.index).?;

    try testing.expectEqual(.add, parsed.expr.nodes.get(@intFromEnum(parsed.expr.root_node)).tag);
}

test "expressions" {
    try testing.checkAllAllocationFailures(testing.allocator, testExpressions, .{});
}

pub fn shimmerToBoolean(det: ?*ErrorDetails, handle: *Handle) !void {
    const Mapping = std.StaticStringMap(bool).initComptime(Tokenizer.boolean_mapping);

    const bytes = try Heap.getString(handle.*);
    const new_value = Mapping.get(bytes) orelse {
        if (det) |details| details.* = .{
            .message = try newStringFmt(
                Heap.local_heap,
                "expected boolean but got \"{f}\"",
                .{handle},
            ),
        };
        return Error.BadBoolean;
    };

    try Heap.prepareToShimmer(handle);
    const ref = handle.peek();
    ref.tag = .bool;
    ref.body.bool = new_value;
}

pub fn getBoolean(det: ?*ErrorDetails, handle: *Handle) !bool {
    try shimmerToBoolean(det, handle);
    return handle.peek().body.bool;
}

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const testing = std.testing;

const options = @import("options");
const stringutil = @import("stringutil.zig");
const expr_parse = @import("expr_parse.zig");
const memutil = @import("memutil.zig");
const Tokenizer = @import("Tokenizer.zig");
const Heap = @import("Heap.zig");
const Handle = Heap.Handle;
const OptionalHandle = Heap.OptionalHandle;

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
    MissingDictKey,
};

pub const ErrorDetails = struct {
    message: Handle,
    index: ?u32 = null,
};

/// If the object changed locations, `new_handle` will be non-null.
pub fn shimmerToString(provided_handle: Handle, new_handle: *OptionalHandle) !void {
    if (provided_handle.peek().tag == .string) return;
    errdefer new_handle.swapWithNull();

    try Heap.ensureShimmerableOrDup(provided_handle, new_handle);
    const handle = new_handle.orElse(provided_handle);

    try handle.prepareToShimmer();
    handle.peek().tag = .string;
    handle.peek().body = .{
        .string = .{
            .utf8_length = 0,
            // Don't know the utf-8 length yet.
            .length_determined = false,
        },
    };
}

pub fn getCodepointLength(provided_handle: Handle, new_handle: *OptionalHandle) !usize {
    errdefer new_handle.swapWithNull();

    try shimmerToString(provided_handle, new_handle);
    const handle = new_handle.orElse(provided_handle);

    assert(handle.peek().tag == .string);

    // See if we already calculated the utf8 length.
    switch (Heap.getStringDetails(handle)) {
        .long => |long_str| {
            const current_len = long_str.getUtf8Length();
            if (current_len != std.math.maxInt(u64)) return current_len;

            // String length hasn't been computed yet, so compute now.
            const utf8_length = stringutil.codepointLength(long_str.getString());
            long_str.setUtf8Length(utf8_length); // Cache utf8 length.
            return utf8_length;
        },
        .normal => {
            if (handle.peek().body.string.length_determined) {
                return handle.peek().body.string.utf8_length;
            } else {
                const bytes = try Heap.getString(handle);
                const utf8_length = stringutil.codepointLength(bytes);
                handle.peek().body.string = .{
                    .utf8_length = utf8_length, // Cache utf8 length.
                    .length_determined = true,
                };
                return utf8_length;
            }
        },
        .empty => 0,
        .null => unreachable,
    }
}

/// Copies provided string.
pub fn newString(heap: *Heap, bytes: []const u8) !Handle {
    var handle = try heap.createObject();
    errdefer handle.decrRefCount();

    try Heap.setString(handle, bytes);
    var new_handle: OptionalHandle = .none;
    try shimmerToString(handle, &new_handle);
    assert(new_handle == .none);

    return handle;
}

pub fn newStringFmt(heap: *Heap, comptime fmt: []const u8, args: anytype) !Handle {
    const new_count = std.fmt.count(fmt, args);
    const str = try newStringToFill(heap, new_count);
    // Don't try setting the string of an empty object.
    if (str == heap.emptyObject()) return str;

    const written = std.fmt.bufPrint(Heap.getStringMut(str) catch unreachable, fmt, args) catch return error.OutOfMemory;
    assert(written.len == new_count);

    return str;
}

pub fn newStringToFill(heap: *Heap, len: usize) !Handle {
    if (len == 0) return heap.emptyObject();

    const handle = try heap.createObject();
    errdefer handle.decrRefCount();

    if (len < Heap.LongString.split_point) {
        const new_str = try heap.createString(@intCast(len));
        const new_str_end = new_str + @as(u32, @intCast(len));
        @memset(heap.getHeapString(new_str, new_str_end), 0);

        // New object, so we can set directly.
        handle.peek().str = .{
            .u = .{
                .str = .{ .index = new_str, .len = @intCast(len) },
            },
            .is_ptr = false,
        };
    } else {
        // Create new string.
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

    handle.peek().tag = .string;

    switch (Heap.getStringDetails(handle)) {
        .long => |long_str| {
            long_str.setUtf8Length(cp_length);
            handle.peek().body = undefined;
        },
        .normal => {
            handle.peek().body.string.* = .{
                .utf8_length = cp_length,
                .length_determined = true,
            };
        },
        .empty => {
            handle.peek().body.string = .{
                .utf8_length = 0,
                .length_determined = true,
            };
        },
        .null => unreachable,
    }

    return handle;
}

pub fn setStringFromEscaped(handle: Handle, escaped: []const u8) !void {
    // Unescaped will be equal or shorter than escaped version.
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

/// If the object changed locations, new_handle will be non-null.
pub fn shimmerToInteger(det: ?*ErrorDetails, provided_handle: Handle, new_handle: *OptionalHandle) !void {
    if (provided_handle.peek().tag == .integer) return;
    errdefer new_handle.swapWithNull();

    try Heap.ensureShimmerableOrDup(provided_handle, new_handle);
    const handle = new_handle.orElse(provided_handle);

    const value: i64 = try integerGetNoShimmer(det, handle);

    try handle.prepareToShimmer();
    handle.peek().tag = .integer;
    handle.peek().body.integer = value;
}

pub fn integerGet(det: ?*ErrorDetails, provided_handle: Handle, new_handle: *OptionalHandle) !i64 {
    try shimmerToInteger(det, provided_handle, new_handle);
    const handle = new_handle.orElse(provided_handle);
    return handle.peek().body.integer;
}

// Float related functions.
pub fn newFloat(heap: *Heap, value: f64) !Handle {
    const handle = try heap.createObject();
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

pub fn shimmerToFloat(det: ?*ErrorDetails, provided_handle: Handle, new_handle: *OptionalHandle) !void {
    if (provided_handle.peek().tag == .float) return null;
    errdefer new_handle.swapWithNull();

    try Heap.ensureShimmerableOrDup(provided_handle, new_handle);
    const handle = new_handle.orElse(provided_handle);

    const value = try floatGetNoShimmer(det, handle);
    handle.prepareToShimmer();
    handle.peek().tag = .float;
    handle.peek().body.float = value;
}

///////////////////////////////
//  Index related functions  //

/// `start` is inclusive, `end` is exclusive. (Note, this is different from tcl's
/// convention, where both are inclusive. `fromIndexes` accounts for this when
/// running the conversion).
pub const Range = struct {
    start: usize,
    end: usize,

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

    return error.BadIndex;
}

/// Shimmers to an index representation.
pub fn shimmerToIndex(det: ?*ErrorDetails, provided_handle: Handle, new_handle: *OptionalHandle) !void {
    if (provided_handle.peek().tag == .index) return null;
    errdefer new_handle.swapWithNull();

    try Heap.ensureShimmerableOrDup(provided_handle, new_handle);
    const handle = new_handle.orElse(provided_handle);

    const bytes = try Heap.getString(handle);

    const index: Heap.ListIndex = blk: {
        // Does it start with "end"? If so, it might be end+5, or end-2, etc
        if (bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], "end")) {
            if (bytes.len >= 4) {
                if (bytes[3] != '+' or bytes[3] != '-') return badIndexError(det, handle);

                const index_offset = std.fmt.parseInt(i33, bytes[3..], 10) catch return badIndexError(det, handle);
                break :blk .{
                    .u = .{ .end_offset = index_offset },
                    .is_end = true,
                };
            }

            break :blk Heap.ListIndex.end;
        } else {
            break :blk std.fmt.parseInt(u32, bytes, 10) catch return badIndexError(det, handle);
        }
    };

    handle.prepareToShimmer();
    handle.peek().tag = .index;
    handle.peek().index = index;

    return new_handle;
}

pub fn getIndex(det: ?*ErrorDetails, handle: Handle, new_handle: *OptionalHandle) !Heap.ListIndex {
    // Fast case: if it's an integer or float, we can quickly cast it (don't
    // shimmer though, as it'll probably still be used for its original purpose)
    if (handle.peek().tag == .integer) {
        const integer = handle.peek().body.integer;
        if (integer < 0) return badIndexError(det, handle);
        if (integer > std.math.maxInt(u32)) return badIndexError(det, handle);

        return .{ .u = .{ .index = @intCast(integer) }, .is_end = false };
    } else if (handle.peek().tag == .float) {
        const float = handle.peek().body.float;

        if (std.math.isNan(float)) return badIndexError(det, handle);
        if (float < 0) return badIndexError(det, handle);
        if (float > std.math.maxInt(u32)) return badIndexError(det, handle);

        return .{ .u = .{ .index = @intFromFloat(float) }, .is_end = false };
    }

    errdefer new_handle.swapWithNull();
    try shimmerToIndex(det, handle, new_handle);

    return new_handle.orElse(handle).peek().body.index;
}

/// Creates a substring of the passed in string. Used in `[string range]`.
pub fn stringRange(
    det: ?*ErrorDetails,
    str: Handle,
    start: Handle,
    new_start: *OptionalHandle,
    end: Handle,
    new_end: *OptionalHandle,
) !Handle {
    errdefer new_start.swapWithNull();
    errdefer new_end.swapWithNull();

    const codepoint_len = try getCodepointLength(str);
    const bytes = Heap.getString(str);

    const start_index = try getIndex(det, start, new_start);
    const end_index = try getIndex(det, end, new_end);

    const range = try Range.fromIndexes(det, codepoint_len, start_index, end_index);

    // cpIndex is generic across ASCII and UTF-8.
    const byte_start = stringutil.cpIndex(bytes, range.start);
    const byte_end = stringutil.cpIndex(bytes, range.end);

    return try newStringWithCodepointLen(
        bytes[byte_start..byte_end],
        range.end - range.start,
    );
}

/// Removes from `start` to `end`, optionally inserting `to_insert`.
pub fn stringReplace(
    det: ?*ErrorDetails,
    str: Handle,
    start: Handle,
    new_start: *OptionalHandle,
    end: Handle,
    new_end: *OptionalHandle,
    to_insert: OptionalHandle,
) Handle {
    errdefer new_start.swapWithNull();
    errdefer new_end.swapWithNull();

    const codepoint_len = try getCodepointLength(str);
    const bytes = Heap.getString(str.*);

    const start_index = try getIndex(det, start, new_start);
    const end_index = try getIndex(det, end, new_end);

    const range = try Range.fromIndexes(det, codepoint_len, start_index, end_index);

    const byte_start = stringutil.cpIndex(bytes, range.start);
    const byte_end = stringutil.cpIndex(bytes, range.end);

    const replaced: Handle = blk: {
        // Is there anything to insert?
        if (to_insert) |val| {
            const to_insert_bytes = try Heap.getString(val);

            // Figure out how long the new string needs to be.
            const up_to_range_len = byte_start;
            const to_insert_len = to_insert_bytes.len;
            // Tcl ranges are inclusive, so `- 1` is needed.
            const after_range_len = bytes.len - byte_end - 1;

            const new_str = newStringToFill(up_to_range_len + to_insert_len + after_range_len);
            const new_bytes = Heap.getStringMut(new_str) catch |err| {
                switch (err) {
                    error.NotMutable => {
                        // Empty strings aren't mutable, so we'll just return the empty string.
                        assert(new_str.peek().str == Heap.Object.empty_string);
                        break :blk new_str;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                }
            };

            @memcpy(new_bytes[0..up_to_range_len], bytes[0..up_to_range_len]);
            @memcpy(new_bytes[up_to_range_len..][0..to_insert_len], to_insert_bytes);
            @memcpy(new_bytes[(up_to_range_len + to_insert_len)..], bytes[(byte_end + 1)..]);

            break :blk new_str;
        } else {
            // Figure out how long the new string needs to be.
            const up_to_range_len = byte_start;
            // Tcl ranges are inclusive, so `- 1` is needed.
            const after_range_len = bytes.len - byte_end - 1;

            const new_str = try newStringToFill(up_to_range_len + after_range_len);
            const new_bytes = Heap.getStringMut(new_str) catch |err| {
                switch (err) {
                    error.NotMutable => {
                        // Empty strings aren't mutable, so we'll just return the empty string.
                        assert(new_str.peek().str == Heap.Object.empty_string);
                        break :blk new_str;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                }
            };

            @memcpy(new_bytes[0..up_to_range_len], bytes[0..up_to_range_len]);
            @memcpy(new_bytes[up_to_range_len..], bytes[(byte_end + 1)..]);

            break :blk new_str;
        }
    };

    return .{
        .new_start = new_start,
        .new_end = new_end,
        .replaced = replaced,
    };
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
        errdefer new_str.decrRefCount();
        const new_bytes = try Heap.getStringMut(new_str) catch |err| switch (err) {
            error.NotMutable => {
                // Empty strings aren't mutable, so we'll just return the empty string.
                assert(new_str.peek().str == Heap.Object.empty_string);
                return new_str;
            },
        };

        // Now go through and write all the bytes.
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
        const new_bytes = try Heap.getStringMut(new_str) catch |err| switch (err) {
            // Empty strings aren't mutable, so we'll just return the empty string.
            error.NotMutable => {
                assert(new_str.peek().str == Heap.Object.empty_string);
                return new_str;
            },
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

/// Creates a new string if there was anything to trim, else passes `str` through.
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

/// Creates a new string if there was anything to trim, else passes `str` through.
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

        pub fn get(det: ?*ErrorDetails, provided_handle: Handle, new_handle: *OptionalHandle) !T {
            errdefer new_handle.swapWithNull();
            try Heap.ensureShimmerableOrDup(provided_handle, new_handle);
            const handle = new_handle.orElse(provided_handle);

            // TODO PERF we can optimize this by shimmering the value to an "enum" type,
            // where the enum type has a u48 storing the hash of enum_name and a u16 for
            // which variant it is, by index.
            const bytes = try Heap.getString(handle);
            const variant = map.get(bytes);
            if (variant) |val| {
                return val;
            } else {
                if (det) |details| details.* = .{
                    .message = try newStringFmt(Heap.local_heap, "bad {s} \"{f}\": must be {s}", .{ enum_name, handle, names }),
                };

                return error.BadEnumVariant;
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

/// Runs a string check based on requested class. `class_to_check` must be shimmerable.
pub fn stringIs(
    det: ?*ErrorDetails,
    str: Handle,
    class_to_check: Handle,
    new_class_to_check: *OptionalHandle,
    strict: bool,
) !bool {
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

    errdefer new_class_to_check.swapWithNull();
    const class = try Class.get(det, class_to_check, new_class_to_check);

    const bytes = try Heap.getString(str);
    if (bytes.len == 0) return !strict;

    return switch (class) {
        .integer => blk: {
            _ = integerGetNoShimmer(null, str) catch break :blk false;
            break :blk true;
        },
        .double => blk: {
            _ = floatGetNoShimmer(null, str) catch break :blk false;
            break :blk true;
        },
        .boolean => blk: {
            _ = getBoolean(null, str, new_class_to_check) catch break :blk false;
            break :blk true;
        },
        .alpha => stringutil.checkAllAscii(bytes, std.ascii.isAlphabetic),
        .alnum => stringutil.checkAllAscii(bytes, std.ascii.isAlphanumeric),
        .ascii => stringutil.checkAllAscii(bytes, std.ascii.isAscii),
        .digit => stringutil.checkAllAscii(bytes, std.ascii.isDigit),
        .lower => stringutil.checkAllAscii(bytes, std.ascii.isLower),
        .upper => stringutil.checkAllAscii(bytes, std.ascii.isUpper),
        .space => stringutil.checkAllAscii(bytes, std.ascii.isWhitespace),
        .xdigit => stringutil.checkAllAscii(bytes, stringutil.isHexDigit),
        .control => stringutil.checkAllAscii(bytes, std.ascii.isControl),
        .print => stringutil.checkAllAscii(bytes, std.ascii.isPrint),
        .graph => stringutil.checkAllAscii(bytes, stringutil.isGraph),
        .punct => stringutil.checkAllAscii(bytes, stringutil.isPunct),
    };
}

fn testStringIs(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    const heap = try Heap.testStart(ta);

    var str = try newString(heap, "abcdefg");
    defer str.decrRefCount();
    var str2 = try newString(heap, "abcdefg123");
    defer str2.decrRefCount();
    var class = try newString(heap, "alpha");
    defer class.decrRefCount();
    var bad_class = try newString(heap, "bad_class");
    defer bad_class.decrRefCount();
    var det: ErrorDetails = undefined;

    var new_class: Heap.OptionalHandle = .none;
    defer if (new_class.toHandle()) |val| val.decrRefCount();
    try testing.expectEqual(true, try stringIs(null, str, class, &new_class, false));
    try testing.expectEqual(false, try stringIs(null, str2, class, &new_class, false));
    const err = stringIs(&det, str, bad_class, &new_class, false);
    if (err == error.OutOfMemory) return error.OutOfMemory;
    try testing.expectError(error.BadEnumVariant, err);
    try testing.expectEqualStrings(
        "bad class \"bad_class\": must be integer, alpha, alnum, ascii, digit, " ++
            "double, lower, upper, space, xdigit, control, print, graph, punct, boolean",
        try Heap.getString(det.message),
    );
    det.message.decrRefCount();
}

test "string is" {
    try testing.checkAllAllocationFailures(testing.allocator, testStringIs, .{});
}

pub fn convertTokenizerError(heap: *Heap, err: Tokenizer.Error) error{OutOfMemory}!ErrorDetails {
    const message = switch (err) {
        error.CharactersAfterCloseBrace => try newString(heap, "extra characters after close-brace"),
        error.MissingCloseBrace => try newString(heap, "missing close-brace"),
        error.MissingCloseBracket => try newString(heap, "unmatched \"[\""),
        error.MissingCloseQuote => try newString(heap, "missing quote"),
        error.TrailingBackslash => try newString(heap, "no character after \\"),
        error.DictSugarInExpression => try newString(heap, "dict sugar in expression"),
        error.FunctionMissingParentheses => try newString(heap, "function missing parentheses"),
        error.NotOperator => try newString(heap, "not operator"),
        error.NotNumber => try newString(heap, "not number"),
        error.NotVariable => unreachable,
    };

    return .{ .message = message };
}

pub fn newListWithCapacity(capacity: u32) !Handle {
    // `1 +` to make space for the list's head
    const list_index = try Heap.local_heap.createObjects(1 + capacity);
    const list_head = Heap.local_heap.getLocalObject(list_index);

    list_head.* = .{
        .str = Heap.Object.null_string,
        .tag = .list,
        .body = .{
            .list = .{
                .len = 0,
            },
        },
    };

    return Heap.local_heap.getHandle(list_index);
}

pub fn newList(handles: []const Handle) !Handle {
    const list = try newListWithCapacity(@intCast(handles.len));
    errdefer list.decrRefCount();
    list.peek().body.list.len = @intCast(handles.len);

    const new_items = listItems(list);
    for (handles, new_items) |handle, *item| {
        item.* = try Heap.local_heap.dupOrReference(handle);
    }

    return list;
}

/// `handle` must be shimmerable. Returns a new object if the list had to move.
pub fn shimmerToList(det: ?*ErrorDetails, provided_handle: Handle, new_handle: *OptionalHandle) !void {
    if (provided_handle.peek().tag == .list) return;
    errdefer new_handle.swapWithNull();

    // Optimise dict -> list.
    if (provided_handle.peek().tag == .dict) {
        // Only need to ensure it's shimmerable in this case, since
        // in the other case we duplicate it anyways.
        const len = provided_handle.peek().body.dict.len;

        try Heap.ensureMutableOrDup(provided_handle, new_handle);
        const handle = new_handle.orElse(provided_handle);

        // Make sure to mark all the keys as mutable before switching to a list.
        var pair_index: u32 = 0;
        while (pair_index < len) : (pair_index += 2) {
            const key = collectionItem(handle, pair_index, len);
            key.getMetadata().mutable = true;
        }

        try handle.prepareToShimmer();
        // Because both lists and dicts store their values directly after,
        // we can just swap out the head to convert to a list.
        handle.peek().* = .{
            .str = Heap.Object.null_string,
            .tag = .list,
            .body = .{
                .list = .{ .len = len },
            },
        };

        return;
    } else {
        // No need to duplicate the handle if it can't shimmer, we have to create
        // a new object anyways.

        // Try to preserve information about filename / line number.
        const source_info: ?SourceInfo = getSourceInfo(provided_handle);
        var file_name: OptionalHandle = .none;
        var line_no: u32 = 1;
        if (source_info) |info| {
            line_no = info.line_no;
            file_name = info.file_name.borrowOptional();
        }
        file_name.swapWithNull();

        const str = try Heap.getString(provided_handle);
        var parser = Tokenizer.init(str, line_no);

        // Figure out how many tokens there are, so we can create the correct list size
        // in the heap.file_name
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

        // TODO PERF reuse the object backing if it was allocated with more than one object.
        const new_list = try newListWithCapacity(@intCast(tokens.items.len));
        new_list.peek().body.list.len = @intCast(tokens.items.len);
        new_handle.swapRef(new_list);

        for (tokens.items, 0..) |token, i| {
            const item = listItem(new_list, @intCast(i));

            if (token.tag == .simple_string) {
                // Normal string, so no escaping needed.
                try Heap.setString(item, str[token.loc.start..token.loc.end]);
            } else {
                // Needs escaping. We'll create another string to copy the escaped string into.
                try setStringFromEscaped(item, str[token.loc.start..token.loc.end]);
            }

            try setSourceInfo(item, .{ .file_name = file_name, .line_no = token.loc.line_no });
        }
    }
}

pub fn listLengthRaw(list: Handle) u32 {
    assert(list.peek().tag == .list);

    return list.peek().body.list.len;
}

pub fn listLength(det: ?*ErrorDetails, provided_list: Handle, new_list: *OptionalHandle) !u32 {
    errdefer new_list.swapWithNull();

    try shimmerToList(det, provided_list, new_list);
    return new_list.orElse(provided_list).peek().body.list.len;
}

pub fn followIfRef(handle: Handle) Handle {
    if (handle.peek().tag == .reference) return handle.peek().body.reference;
    return handle;
}

fn collectionItem(handle: Handle, index: u32, len: u32) Handle {
    const obj = handle.peek();
    handle.assert(obj.tag == .list or obj.tag == .dict);
    handle.assert(index < len);

    return .{
        .index = handle.index + 1 + index,
        .heap = handle.heap,
    };
}

fn collectionItemFollowRefs(handle: Handle, index: u32, len: u32) Heap.Handle {
    const obj = handle.peek();
    assert(obj.tag == .list or obj.tag == .dict);

    if (index < len) {
        const elem: Heap.Handle = .{
            .index = handle.index + 1 + index,
            .heap = handle.heap,
        };

        return followIfRef(elem);
    } else @panic("Element out of bounds");
}

pub fn collectionItems(handle: Handle, len: u32) []Heap.Object {
    const list = handle.peek();
    assert(list.tag == .list or list.tag == .dict);

    return handle.getHeap().objectSlice(handle.index + 1, handle.index + 1 + len);
}

/// The reason this returns a new object instead of having a `new_handle` parameter is
/// that we need to prevent a situation where `provided_handle` and the theoretical
/// `new_handle` alias, as that would lead to UAF.
fn setCollectionLength(provided_handle: Handle, new_len: u32) !OptionalHandle {
    const current_len = blk: {
        switch (provided_handle.peek().tag) {
            .list => break :blk provided_handle.peek().body.list.len,
            .dict => break :blk provided_handle.peek().body.dict.len,
            else => unreachable,
        }
    };

    // If it's the same length, no need to do anything.
    if (current_len == new_len) return .none;

    new_collection_needed: {
        // We can only do these quick changes if the collection can mutate in-place.
        if (!provided_handle.canMutate()) break :new_collection_needed;

        // No need to realloc if we're shrinking.
        if (new_len < current_len) {
            // We need to check if any of the abandoned items are shared. If so, we'll need to
            // split this collection and create a new one.
            const freed_count = current_len - new_len;
            for (0..freed_count) |to_free| {
                const to_free_handle = listItem(provided_handle, @intCast(current_len - freed_count + to_free));
                if (to_free_handle.isShared()) break :new_collection_needed;
            }

            // Be sure to free the abandoned items when we shrink.
            for (0..freed_count) |to_free| {
                const to_free_handle = collectionItem(provided_handle, @intCast(current_len - freed_count + to_free), current_len);
                // If a dict, be sure to remove the keys from the table.
                if (provided_handle.peek().tag == .dict and @mod(to_free, 2) == 0) {
                    if (dictGetMetadata(provided_handle).table) |*table| {
                        _ = table.remove(to_free_handle);
                    }
                    // Also mark keys as mutable again.
                    to_free_handle.getMetadata().mutable = true;
                }

                to_free_handle.invalidateBoth();
            }

            switch (provided_handle.peek().tag) {
                .list => provided_handle.peek().body.list.len = new_len,
                .dict => provided_handle.peek().body.dict.len = new_len,
                else => unreachable,
            }

            return .none;
        } else {
            // Even if there's not enough length, there may be enough capacity.
            const capacity = memutil.getOrderSize(provided_handle.getMetadata().order) - 1; // -1 for list head
            if (new_len <= capacity) {
                switch (provided_handle.peek().tag) {
                    .list => provided_handle.peek().body.list.len = new_len,
                    .dict => provided_handle.peek().body.dict.len = new_len,
                    else => unreachable,
                }

                return .none;
            }
        }
    }

    // We've exhausted all other options, so we'll need to make a new collection.
    const new_handle = switch (provided_handle.peek().tag) {
        .list => try newListWithCapacity(new_len),
        .dict => try newDictWithCapacity(new_len),
        else => unreachable,
    };
    errdefer new_handle.decrRefCount();
    const new_items = collectionItems(new_handle, new_len);

    if (provided_handle.canMutate()) {
        var found_shared_items = false;

        // If the collection isn't shared, we can move the objects over to the new
        // collection without any duplication.
        for (new_items[0..current_len], 0..) |*new_item, i| {
            const old_item = collectionItem(provided_handle, @intCast(i), current_len);
            // However, if an item within the list was shared, we can't move it, we instead have to reference
            // it. (Why not use `item_handle.reference()`? Because that would create one too many references
            // as the list already has one ref count for owning the item.)
            if (old_item.isShared()) {
                found_shared_items = true;
                new_item.* = old_item.referenceTakeOwnership();
            } else {
                new_item.* = old_item.peek().*;
                // Be sure to "zero" out the old item after we steal it.
                old_item.peek().* = .{
                    .str = Heap.Object.null_string,
                    .tag = .none,
                    .body = undefined,
                };
                old_item.trace("Object stolen", .{});
            }
        }

        if (found_shared_items) {
            // Because we found shared items, we can't free the backing directly, as that would
            // free an item that someone else is currently referencing. Instead, we'll split the
            // allocation, and free all non-shared objects.
            provided_handle.getHeap().splitAlloc(provided_handle.index, 0);

            for (0..current_len) |i| {
                const item_handle: Handle = collectionItem(provided_handle, @intCast(i), current_len);

                // Only free the backing of non-shared objects, so we don't release the backing of a shared item.
                // Why only a backing free? Because the non-shared objectes were moved to the new collection.
                if (item_handle.isShared()) {
                    // If this was a dict, and a key was marked as not mutable, we need to be sure to undo that.
                    // This is fine to do on list items, since they're already mutable.
                    item_handle.getMetadata().mutable = true;
                } else {
                    Heap.freeObjectBacking(item_handle);
                }
            }
        }

        // We don't free the collection here, since that would violate the caller's expectations.
        // But, we still don't want anyone using this incredibly broken object, so we'll set
        // it to .invalid.

        // We don't invalidate the old body, as that would double-free the collection items.
        // Hence, we have to manually handle freeing the old table.
        if (provided_handle.peek().tag == .dict) {
            dictInvalidateTable(provided_handle);
            provided_handle.getHeap().destroyExtraData(provided_handle.peek().body.dict.extra_data);
        }
        provided_handle.invalidateString();
        provided_handle.peek().tag = .invalid;
        provided_handle.peek().body = undefined;

        switch (new_handle.peek().tag) {
            .dict => new_handle.peek().body.dict.len = new_len,
            .list => new_handle.peek().body.list.len = new_len,
            else => unreachable,
        }
    } else {
        // If the collection is shared, we need to duplicate all the items.
        for (0.., new_items) |i, *new_item| {
            new_item.* = try Heap.local_heap.dupOrReference(
                collectionItemFollowRefs(provided_handle, @intCast(i), current_len),
            );
        }

        switch (new_handle.peek().tag) {
            .dict => new_handle.peek().body.dict.len = new_len,
            .list => new_handle.peek().body.list.len = new_len,
            else => unreachable,
        }
    }

    return new_handle.toOptional();
}

/// Assumes provided handle is a list.
pub fn listItem(handle: Handle, index: u32) Handle {
    const list = handle.peek();
    assert(list.tag == .list);

    return collectionItem(handle, index, list.body.list.len);
}

/// Assumes provided handle is a list.
pub fn listItemFollowRefs(handle: Handle, index: u32) Handle {
    const list = handle.peek();
    assert(list.tag == .list);

    return collectionItemFollowRefs(handle, index, list.body.list.len);
}

/// Assumes handle is a list.
pub fn listItems(handle: Handle) []Heap.Object {
    const list = handle.peek();
    assert(list.tag == .list);

    return handle.getHeap().objects.items(.object)[(handle.index + 1)..][0..list.body.list.len];
}

/// Returns a new list if the list had to move.
pub fn listSetObject(det: ?*ErrorDetails, provided_list: Handle, index: u32, value: Heap.Object) !?Handle {
    const length_result = try listLength(det, provided_list);
    var new_list: ?Handle = length_result.new_handle;
    errdefer if (new_list) |val| val.decrRefCount();
    if (index > length_result.len) return error.OutOfBounds;

    const mutatable_list: ?Handle = blk: {
        if (!provided_list.canMutate() or listItem(provided_list, index).isShared()) {
            break :blk try provided_list.getHeap().duplicate(provided_list);
        }
        break :blk null;
    };
    Handle.swapRefIfNew(&new_list, mutatable_list);

    const list = new_list orelse provided_list;

    // We know that this index is now safe to modify.
    const item = listItem(list, index);
    assert(!item.isShared());

    item.invalidateBoth();
    item.peek().* = value;

    return new_list;
}

pub fn listAppendObject(det: ?*ErrorDetails, provided_list: Handle, new_list: *OptionalHandle, item: Heap.Object) !u32 {
    errdefer new_list.swapWithNull();

    const len = try listLength(det, provided_list, new_list);
    const resize_result = try setCollectionLength(new_list.orElse(provided_list), len + 1);
    new_list.swapRefIfNew(resize_result.new_handle);

    const list = new_list.orElse(provided_list);
    const index = list.peek().body.list.len - 1;
    listItems(list)[index] = item;

    return index;
}

pub fn listAppend(det: ?*ErrorDetails, provided_list: Handle, new_list: *OptionalHandle, item: Handle) !Handle {
    errdefer new_list.swapWithNull();
    const item_obj = try provided_list.getHeap().dupOrReference(item);
    const index = try listAppendObject(det, provided_list, new_list, item_obj);
    return listItem(new_list.orElse(provided_list), index);
}

fn testLists(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    const heap = try Heap.testStart(ta);

    var det: ErrorDetails = undefined;

    // Simple case: two objects in a list
    const obj1 = try newString(heap, "object 1");
    defer obj1.decrRefCount();
    const obj2 = try newString(heap, "object 2");
    defer obj2.decrRefCount();
    var list1 = try newList(&.{ obj1, obj2 });
    defer list1.decrRefCount();

    const items = listItems(list1);
    try testing.expectEqual(2, items.len);
    // The object should have been copied when being moved into the list
    try testing.expect(obj1.peek() != &items[0]);
    // But it should have an identical string
    try testing.expectEqualStrings("object 1", try Heap.getString(listItem(list1, 0)));

    const to_append = try newString(heap, "appended item");
    defer to_append.decrRefCount();

    var new_list: OptionalHandle = .none;
    _ = try listAppend(&det, list1, &new_list, to_append);
    list1.swapAndClear(&new_list);
    try testing.expectEqualStrings("appended item", try Heap.getString(listItem(list1, 2)));

    var string_list = try newString(heap,
        \\item1 {item 2} item\ 3
    );
    defer string_list.decrRefCount();

    try shimmerToList(&det, string_list, &new_list);
    try testing.expect(string_list != new_list.toHandle());
    string_list.swapAndClear(&new_list);
    try testing.expectEqualStrings("item1", try Heap.getString(listItem(string_list, 0)));
    try testing.expectEqualStrings("item 2", try Heap.getString(listItem(string_list, 1)));
    try testing.expectEqualStrings("item 3", try Heap.getString(listItem(string_list, 2)));
}

test "lists" {
    try testing.checkAllAllocationFailures(testing.allocator, testLists, .{});
}

pub fn dictGetMetadata(dict: Handle) *Heap.ExtraDataValue.Dictionary {
    assert(dict.peek().tag == .dict);
    return &dict.getHeap().getExtraData(dict.peek().body.dict.extra_data).dict;
}

const DictTable = Heap.ExtraDataValue.Dictionary.Table;
pub fn dictGetTable(dict: Handle) !*DictTable {
    // FIXME this doesn't use atomics to set the table currently.
    dict.assert(!dict.getMetadata().cross_thread);

    const metadata = dictGetMetadata(dict);
    if (metadata.table) |*table| return table;

    // Table didn't exist, so we need to generate it.
    var new_table: DictTable = .empty;
    errdefer new_table.deinit(dict.getHeap().gpa);

    // Populate the new table.
    const dict_len = dict.peek().body.dict.len;
    var pair: u32 = 0;
    while (pair < dict_len) : (pair += 2) {
        const key = collectionItem(dict, pair, dict_len);
        try new_table.put(dict.getHeap().gpa, key, pair + 1);
    }

    metadata.table = new_table;
    // Make sure to reference its new location after it moves to `metadata.table`.
    if (metadata.table) |*table| return table else unreachable;
}

pub fn dictMaybeGetTable(dict: Handle) ?*DictTable {
    if (dictGetMetadata(dict).table) |*table| return table else return null;
}

pub fn dictInvalidateTable(dict: Handle) void {
    assert(dict.peek().tag == .dict);
    assert(dict.canShimmer());
    if (dictGetMetadata(dict).table) |*table| {
        table.deinit(dict.getHeap().gpa);
        dictGetMetadata(dict).table = null;
    }
}

pub fn shimmerToDict(det: ?*ErrorDetails, provided_handle: Handle, new_dict: *OptionalHandle) !void {
    if (provided_handle.peek().tag == .dict) return;
    errdefer new_dict.swapWithNull();

    // Get length, potentially shimmering.
    const len = try listLength(det, provided_handle, new_dict);
    const shimmerable = new_dict.orElse(provided_handle);
    const handle_heap = shimmerable.getHeap();

    if (@mod(len, 2) == 1) {
        // Unmatched key.
        if (det) |details| details.* = .{
            .message = try newStringFmt(
                Heap.local_heap,
                "Missing value to go with key when converting \"{f}\" to a dictionary.",
                .{shimmerable},
            ),
        };
        return error.BadDict;
    }

    // Set dict body using the final handle.
    const metadata_index = try handle_heap.createExtraData();
    errdefer handle_heap.destroyExtraData(metadata_index);

    const metadata = handle_heap.getExtraData(metadata_index);
    metadata.* = .{ .dict = .{ .table = null } };

    // Make sure to mark all the keys as immutable, so they never change.
    // If they could change, they'd make the table invalid, and there's
    // no good way to check if a sub-object has changed and update the
    // table without adding checks everywhere.
    var pair: u32 = 0;
    while (pair < len) : (pair += 2) {
        const key = collectionItem(shimmerable, pair, len);
        key.getMetadata().mutable = false;
    }

    // Because both lists and dicts store their values directly after,
    // we can just swap out the head to convert to a dict.
    try shimmerable.prepareToShimmer();
    shimmerable.peek().tag = .dict;
    shimmerable.peek().body.dict = .{
        .extra_data = metadata_index,
        .len = len,
    };
}

pub fn dictItems(handle: Handle) []Heap.Object {
    assert(handle.peek().tag == .dict);
    const dict_len = handle.peek().body.dict.len;
    return handle.getHeap().objectSlice(handle.index + 1, handle.index + 1 + dict_len);
}

pub fn dictItem(dict: Handle, index: u32) Handle {
    assert(dict.peek().tag == .dict);
    return collectionItem(dict, index, dict.peek().body.dict.len);
}

pub fn dictItemFollowRefs(dict: Handle, index: u32) Handle {
    assert(dict.peek().tag == .dict);
    return collectionItemFollowRefs(dict, index, dict.peek().body.dict.len);
}

pub fn dictItemLength(handle: Handle) u32 {
    assert(handle.peek().tag == .dict);
    return handle.peek().body.dict.len;
}

pub fn dictPairLengthRaw(handle: Handle) u32 {
    assert(handle.peek().tag == .dict);
    return handle.getHeap().getExtraData(handle.peek().body.dict).dict.len / 2;
}

/// Length in pairs (total length / 2).
pub fn dictPairLength(det: ?*ErrorDetails, provided_handle: Handle, new_dict: *OptionalHandle) !u32 {
    errdefer new_dict.swapWithNull();
    try shimmerToDict(det, provided_handle, new_dict);

    const handle = new_dict.orElse(provided_handle);
    return dictPairLengthRaw(handle);
}

pub fn newDictWithCapacity(len: u32) !Handle {
    assert(@mod(len, 2) == 0);

    // `1 +` to make space for the dict's head.
    const dict_index = try Heap.local_heap.createObjects(1 + len);
    errdefer Heap.freeObjectBacking(Heap.local_heap.getHandle(dict_index));
    const dict_metadata = try Heap.local_heap.createExtraData();
    errdefer Heap.local_heap.destroyExtraData(dict_metadata);

    Heap.local_heap.getExtraData(dict_metadata).* = .{
        .dict = .{ .table = null },
    };

    const dict_head = Heap.local_heap.getLocalObject(dict_index);
    dict_head.* = .{
        .str = Heap.Object.null_string,
        .tag = .dict,
        .body = .{ .dict = .{
            .extra_data = dict_metadata,
            .len = 0,
        } },
    };

    return Heap.local_heap.getHandle(dict_index);
}

/// Caller is responsible that `handles` has handles.len % 2 == 0.
pub fn newDict(heap: *Heap, handles: []const Handle) !Handle {
    const dict = try newDictWithCapacity(@intCast(handles.len));
    errdefer dict.decrRefCount();
    dict.peek().body.dict.len = @intCast(handles.len);

    const new_items = dictItems(dict);

    for (handles, new_items) |handle, *item| {
        item.* = try Heap.dupOrReference(heap, handle);
    }

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

/// Asserts `dict` is a .dict.
pub fn dictLookupFollowRefs(dict: Handle, key: Handle) error{OutOfMemory}!OptionalHandle {
    dict.assert(dict.peek().tag == .dict);
    // Make sure key has a string representation, as table.get isn't allowed to fail.
    _ = try Heap.getString(key);

    const table = try dictGetTable(dict);
    if (table.get(key)) |value_offset| {
        return dictItemFollowRefs(dict, value_offset).toOptional();
    } else return .none;
}

fn dictHasDuplicatesRaw(dict: Handle) !bool {
    assert(dict.peek().tag == .dict);
    const table = try dictGetTable(dict);

    const len = dict.peek().body.dict.len;
    assert(table.size * 2 <= len);
    return table.size * 2 != len;
}

/// Removes duplicate entries. Assumes handle is a dict. If the caller needs to track
/// a key/value as it gets rearranged, set `to_track`. The result will be its new index,
/// unless it was removed.
fn dictRemoveDuplicates(provided_dict: Handle, new_dict: *OptionalHandle, to_track: ?u32) !?u32 {
    errdefer new_dict.swapWithNull();
    assert(provided_dict.peek().tag == .dict);

    // If the length of the table is the length of the dict, it means we have
    // no duplicates.
    const original_len = provided_dict.peek().body.dict.len;
    if (dictMaybeGetTable(provided_dict)) |table| {
        if (table.size * 2 == original_len) return to_track;
    }

    try Heap.ensureMutableOrDup(provided_dict, new_dict);
    const dict_before_shared_check = new_dict.orElse(provided_dict);
    var metadata = dictGetMetadata(dict_before_shared_check);

    // Check if any items are shared.
    for (0..original_len) |i| {
        if (dictItem(dict_before_shared_check, @intCast(i)).isShared()) {
            // Need to duplicate.
            const duplicated = try Heap.local_heap.duplicate(dict_before_shared_check);
            // Free the previous new_handle if it exists, since we have a newer one.
            new_dict.swapRef(duplicated);
            metadata = dictGetMetadata(duplicated); // Need to reload metadata.
            break;
        }
    }

    const dict = new_dict.orElse(provided_dict);
    var to_track_new_location: ?u32 = null;

    const table = try dictGetTable(dict);
    if (table.size * 2 == original_len) {
        // No duplicate entries.
        return to_track;
    }

    var pair_index: u32 = 0;
    while (pair_index < original_len) : (pair_index += 2) {
        const key_index = pair_index;
        const value_index = pair_index + 1;
        const key_handle = dictItem(dict, key_index);
        const value_handle = dictItem(dict, value_index);

        // Because keys are immutable, we know that they'll never lose their string rep.
        if (table.get(key_handle).? != value_index) {
            // Found a duplicate entry.
            key_handle.peek().tag = .marked;
            value_handle.peek().tag = .marked;
        }
    }

    // Why mark all the handles before later removing them? Because the hash map
    // requires all the keys and values to not move, and we use the hash map
    // to see what pairs need to be removed.
    const items = dictItems(dict);
    // How many pairs we've removed so far. Increments by 1.
    var removed: u32 = 0;
    pair_index = 0;
    while (pair_index < original_len) : (pair_index += 2) {
        const key_index = pair_index;
        const value_index = pair_index + 1;
        const key_handle = dictItem(dict, key_index);
        const value_handle = dictItem(dict, value_index);

        if (key_handle.peek().tag == .marked) {
            removed += 1;

            // Mark as mutable before invalidating (keys are marked immutable in shimmerToDict).
            key_handle.getMetadata().mutable = true;

            // We have to invalidate the string here, and not earlier, because
            // the hash map `.get()` uses the string rep of the keys.
            key_handle.invalidateString();
            key_handle.invalidateBody(); // sets tag to .none.
            value_handle.invalidateString();
            value_handle.invalidateBody(); // sets tag to .none.
        } else if (removed > 0) {
            // There was a pair removed at some point, so we need to shift this pair backwards.
            const new_key_index = pair_index - (removed * 2);
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
    for ((original_len - removed * 2)..original_len) |to_zero| {
        const item_handle = collectionItem(dict, @intCast(to_zero), original_len);
        item_handle.peek().* = .{
            .str = Heap.Object.null_string,
            .tag = .none,
            .body = undefined,
        };
        item_handle.trace("Zero out removed", .{});
        // Make sure to mark removed keys as mutable again.
        item_handle.getMetadata().mutable = true;
    }

    dict.peek().body.dict.len -= removed * 2;

    // The table is pretty broken at this point, as all its references have shifted around.
    //  TODO PERF For now, it's better just to free it altogether, though this has the
    // potential to slow things down.
    dictInvalidateTable(dict);

    return to_track_new_location;
}

const DictAndValueResult = struct { new_dict: OptionalHandle, new_value: Heap.Handle };
/// Takes ownership of `value`, including error cases. Returns a handle to the new value's location.
/// `value` must be in `Heap.local_heap`.
pub fn dictPutInner(provided_dict: Handle, key: Handle, provided_value: *Heap.Object) !DictAndValueResult {
    var value = provided_value.*; // Copy.
    provided_value.* = undefined; // This helps prevent reuse.

    // Because there's so many points at which this function can hit OOM,
    // we model this as a FSM, in order to handle error cases correctly.
    const State = union(enum) {
        start,
        ensured_mutable: struct {
            new_dict: OptionalHandle,
        },
        changed_value: struct {
            new_dict: OptionalHandle,
            old_value: Heap.Object,
            /// Index relative to the dict.
            value_index: u32,
        },
        appended_pair: struct {
            new_dict: OptionalHandle,
            /// Index relative to the dict.
            new_key_index: u32,
        },
    };

    var current_state: State = .start;
    while (true) current_state = next_state: switch (current_state) {
        .start => {
            errdefer value.deinitSingle(Heap.local_heap);

            // Make sure the key has a string representation.
            _ = try Heap.getString(key);
            // Also make sure we can mutate the dict.
            var new_dict: OptionalHandle = .none;
            try Heap.ensureMutableOrDup(provided_dict, &new_dict);

            break :next_state .{ .ensured_mutable = .{
                .new_dict = new_dict,
            } };
        },
        .ensured_mutable => |state| {
            errdefer value.deinitSingle(Heap.local_heap);
            var new_dict = state.new_dict;
            errdefer new_dict.swapWithNull();
            var dict = new_dict.orElse(provided_dict);

            const table = try dictGetTable(dict);
            // Does the key already exist?
            if (table.get(key)) |existing_value_index| {
                // Key exists, so replace the value in place.
                var value_handle = dictItem(dict, existing_value_index);
                if (value_handle.isShared()) {
                    // Looks like this dictionary value is shared, so we can't replace the value in place
                    // (else we'd smash up a value someone else is using). Instead, we'll start this whole
                    // process over with a new dictionary.
                    new_dict.swapRef(try Heap.duplicate(dict.getHeap(), dict));
                }

                value_handle.assert(value_handle.getHeap() == Heap.local_heap);
                const old_value = value_handle.peek().*; // Copy.
                // We can't fail at this point, so we don't need to worry about
                // `value` being freed after assignment.
                value_handle.peek().* = value;

                break :next_state .{ .changed_value = .{
                    .new_dict = new_dict,
                    .old_value = old_value,
                    .value_index = existing_value_index,
                } };
            } else {
                const original_len = dict.peek().body.dict.len;
                const new_length = original_len + 2;
                try table.ensureTotalCapacity(dict.getHeap().gpa, new_length / 2);

                // Key doesn't exist, so append both key and value.
                const len_before_resize = dict.peek().body.dict.len;
                const new_key_index = len_before_resize;
                const new_value_index = len_before_resize + 1;

                // Duplicate/reference the key _before_ resizing, so we can't fail
                // after the resize is successful.
                const new_key_handle, const new_value_handle = blk: {
                    var key_obj: Heap.Object = try Heap.dupOrReference(Heap.local_heap, key);
                    errdefer key_obj.deinitSingle(Heap.local_heap);

                    new_dict.swapRefIfNew(try setCollectionLength(dict, new_length));
                    dict = new_dict.orElse(dict);

                    const new_key_handle = dictItem(dict, new_key_index);
                    const new_value_handle = dictItem(dict, new_value_index);

                    new_key_handle.trace("Setting as new key to {f}", .{key_obj});

                    // Set the new key and value.
                    new_key_handle.peek().* = key_obj;
                    new_key_handle.getMetadata().mutable = false;
                    new_value_handle.peek().* = value;

                    break :blk .{ new_key_handle, new_value_handle };
                };
                errdefer {
                    new_key_handle.invalidateBoth();
                    new_value_handle.invalidateBoth();
                    dict.peek().body.dict.len = original_len;
                }

                // Make sure the key has a string rep.
                _ = try Heap.getString(new_key_handle);

                // Only put the key in the table if the table exists. It'll be discovered
                // when the table is generated if not.
                if (dictMaybeGetTable(dict)) |new_table| {
                    new_table.putAssumeCapacity(new_key_handle, new_value_index);
                }

                // Need to add a new pair.
                break :next_state .{ .appended_pair = .{
                    .new_dict = new_dict,
                    .new_key_index = new_key_index,
                } };
            }
        },
        .changed_value => |state| {
            var old_value = state.old_value;
            var new_dict = state.new_dict;
            errdefer new_dict.swapWithNull();
            var dict = new_dict.orElse(provided_dict);
            errdefer {
                const value_handle = dictItem(dict, state.value_index);
                // Invalidate new value.
                value_handle.invalidateBoth();
                // Restore old value.
                value_handle.peek().* = old_value;
            }

            // Because we mutated the dictionary, we need to remove any duplicates, if applicable.
            const new_index = new_index: {
                if (try dictHasDuplicatesRaw(dict)) {
                    const tracked_index = try dictRemoveDuplicates(dict, &new_dict, state.value_index);
                    dict = new_dict.orElse(dict);
                    break :new_index tracked_index.?;
                } else {
                    break :new_index state.value_index;
                }
            };

            // Success! We can now safely deinit the old value, since there's no need
            // to restore it anymore.
            old_value.deinitSingle(Heap.local_heap);

            return .{ .new_dict = new_dict, .new_value = dictItem(dict, new_index) };
        },
        .appended_pair => |state| {
            var new_dict = state.new_dict;
            errdefer new_dict.swapWithNull();
            var dict = new_dict.orElse(provided_dict);
            errdefer {
                // Because these are new values, we don't need to restore old values--
                // there's nothing to restore. Instead, we'll just free the last two
                // new values, and shrink the length.
                const len = dict.peek().body.dict.len;
                assert(state.new_key_index == len - 2);

                dictItem(dict, len - 2).getMetadata().mutable = true;
                dictItem(dict, len - 2).invalidateBoth();
                dictItem(dict, len - 1).invalidateBoth();
                dict.peek().body.dict.len -= 2;
            }

            // Because we mutated the dictionary, we need to remove any duplicates, if applicable.
            const new_index = new_index: {
                if (try dictHasDuplicatesRaw(dict)) {
                    const tracked_value = try dictRemoveDuplicates(dict, &new_dict, state.new_key_index + 1);
                    dict = new_dict.orElse(dict);
                    break :new_index tracked_value.?;
                } else {
                    break :new_index state.new_key_index + 1;
                }
            };

            return .{ .new_dict = new_dict, .new_value = dictItem(dict, new_index) };
        },
    };
}

/// Takes ownership of `value`, including in error cases. `value` must be in the local heap.
pub fn dictPutRecursively(det: ?*ErrorDetails, provided_dict: Handle, keys: []const Handle, value: *Heap.Object) !DictAndValueResult {
    var value_taken = false;
    errdefer if (!value_taken) value.deinitSingle(Heap.local_heap);

    var new_dict: OptionalHandle = .none;
    try shimmerToDict(det, provided_dict, &new_dict);
    errdefer new_dict.swapWithNull();

    assert(keys.len > 0);

    if (keys.len == 1) {
        value_taken = true; // `dictPutInner` always takes ownership.
        const put_result = try dictPutInner(new_dict.orElse(provided_dict), keys[0], value);
        new_dict.swapRefIfNew(put_result.new_dict);
        return .{ .new_dict = new_dict, .new_value = put_result.new_value };
    }

    // Find/create the child dict.
    const child_dict = blk: {
        if ((try dictLookupFollowRefs(new_dict.orElse(provided_dict), keys[0])).toHandle()) |existing_dict| {
            break :blk existing_dict;
        } else {
            // Create a new child dictionary.
            const new_child_dict = try newDictWithCapacity(2);

            var ref = new_child_dict.referenceTakeOwnership();
            const put_result = try dictPutInner(new_dict.orElse(provided_dict), keys[0], &ref);
            new_dict.swapRefIfNew(put_result.new_dict);
            break :blk put_result.new_value;
        }
    };

    value_taken = true;
    const child_put_result = try dictPutRecursively(det, child_dict, keys[1..], value);
    if (child_put_result.new_dict.toHandle()) |new_child| {
        errdefer new_child.decrRefCount();

        // The child dict changed, so we need to update ours.
        var ref = new_child.referenceTakeOwnership();
        const put_result = try dictPutInner(new_dict.orElse(provided_dict), keys[0], &ref);
        new_dict.swapRefIfNew(put_result.new_dict);
    }

    new_dict.orElse(provided_dict).invalidateString();

    return .{ .new_dict = new_dict, .new_value = child_put_result.new_value };
}

pub fn dictRemoveRecursively(det: ?*ErrorDetails, provided_dict: Handle, keys: []const Handle) !DictAndRemovedResult {
    var new_dict: OptionalHandle = .none;
    errdefer new_dict.swapWithNull();
    try shimmerToDict(det, provided_dict, &new_dict);

    assert(keys.len > 0);

    if (keys.len == 1) {
        const remove_result = try dictRemove(new_dict.orElse(provided_dict), keys[0]);
        new_dict.swapRefIfNew(remove_result.new_dict);
        return .{ .new_dict = new_dict, .did_remove = remove_result.did_remove };
    }

    // Find the child dict.
    if ((try dictLookupFollowRefs(new_dict.orElse(provided_dict), keys[0])).toHandle()) |child_dict| {
        const child_remove_result = try dictRemoveRecursively(det, child_dict, keys[1..]);
        // If the child dict was modified (either in place or by duplication), we need to
        // update our dict to point to the modified version.
        if (child_remove_result.new_dict.toHandle()) |new_child| {
            errdefer new_child.decrRefCount();
            // The child dict was duplicated, so we need to replace the old reference with the new one.
            var ref = new_child.referenceTakeOwnership();
            const put_result = try dictPutInner(new_dict.orElse(provided_dict), keys[0], &ref);
            new_dict.swapRefIfNew(put_result.new_dict);
        }

        new_dict.orElse(provided_dict).invalidateString();

        return .{ .new_dict = new_dict, .did_remove = child_remove_result.did_remove };
    } else {
        if (det) |details| details.* = .{
            .message = try newStringFmt(
                Heap.local_heap,
                "key \"{f}\" not known in dictionary \"{f}\"",
                .{ keys[0], provided_dict },
            ),
        };
        return error.MissingDictKey;
    }
}

pub const DictAndValueLookupResult = struct { new_dict: OptionalHandle, value: OptionalHandle };
pub fn dictLookupRecursively(det: ?*ErrorDetails, provided_dict: Handle, keys: []const Handle) !DictAndValueLookupResult {
    var new_dict: OptionalHandle = .none;
    new_dict.swapWithNull();
    try shimmerToDict(det, provided_dict, &new_dict);

    if (keys.len == 0) return .{ .new_dict = new_dict, .value = new_dict.orElse(provided_dict).toOptional() };
    if (keys.len == 1) {
        return .{ .new_dict = new_dict, .value = try dictLookupFollowRefs(new_dict.orElse(provided_dict), keys[0]) };
    }

    if ((try dictLookupFollowRefs(new_dict.orElse(provided_dict), keys[0])).toHandle()) |child_dict| {
        const child_result = try dictLookupRecursively(det, child_dict, keys[1..]);
        if (child_result.new_dict.toHandle()) |new_child| {
            errdefer new_child.decrRefCount();
            // The child dict changed, propagate back up.
            var ref = new_child.referenceTakeOwnership();
            const put_result = try dictPutInner(new_dict.orElse(provided_dict), keys[0], &ref);
            new_dict.swapRefIfNew(put_result.new_dict);
        }
        return .{ .new_dict = new_dict, .value = child_result.value };
    } else {
        return .{ .new_dict = new_dict, .value = .none };
    }
}

/// Assumes `handle` is a dict.
pub fn dictPut(dict: Handle, key: Handle, value: Handle) !DictAndValueResult {
    return dictPutInner(dict, key, try Heap.local_heap.dupOrReference(value));
}

const DictAndRemovedResult = struct { new_dict: OptionalHandle, did_remove: bool };
/// Returns true if the value was removed, or false if the value doesn't exist.
pub fn dictRemove(provided_dict: Handle, key: Handle) !DictAndRemovedResult {
    assert(provided_dict.peek().tag == .dict);

    const key_bytes = try Heap.getString(key);

    var new_dict: OptionalHandle = .none;
    errdefer new_dict.swapWithNull();
    try Heap.ensureMutableOrDup(provided_dict, &new_dict);
    var dict = new_dict.orElse(provided_dict);

    assert(dict.heap == Heap.local_heap.heapId());
    const dict_len = dictItemLength(dict);

    // Locate the first key (note, we can't use `metadata.table.get`, because Tcl removes all
    // key(s), while `metadata.table.get` only returns the last key).
    var first_key_index: u32 = 0;
    while (first_key_index < dict_len) : (first_key_index += 2) {
        const key_checking = try Heap.getString(dictItem(dict, first_key_index));
        if (std.mem.eql(u8, key_bytes, key_checking)) {
            break; // Found our key.
        }
    } else {
        return .{ .new_dict = new_dict, .did_remove = false }; // No key found.
    }

    // Make sure any keys/values we'll touch aren't shared. Because we're shifting all
    // other values to the left (to preserve relative order), we  need to check all items
    // following the key and value.
    var shared_values_found = false;
    for (first_key_index..dict_len) |item_index| {
        const item_handle = dictItem(dict, @intCast(item_index));
        if (item_handle.isShared()) shared_values_found = true;
    }

    if (shared_values_found) {
        // Looks like this dictionary item is shared, so we can't replace the value in place
        // (else we'd smash up an item someone else is using). Instead, we'll start this whole
        // process over with a new dictionary.
        const duplicated = try Heap.local_heap.duplicate(dict);
        new_dict.swapRef(duplicated);
        dict = duplicated;
    }

    // Make sure all the keys have string reps. If we OOM halfway through removal
    // we'll end in a really ugly state, so it's better to ensure all keys have a
    // string rep to start with. If not, we'll safely propagate the OOM.
    var item_index: u32 = 0;
    while (item_index < dict_len) : (item_index += 2) {
        _ = try Heap.getString(dictItem(dict, item_index));
    }

    // This is the start of mutation. From here on there's no going back.
    dictInvalidateTable(dict);

    // Remove all matching keys and their values, moving the following pair
    // backwards to fill the gap(s).
    item_index = first_key_index;
    var pairs_removed: u32 = 0;
    while (item_index < dict_len) : (item_index += 2) {
        const key_handle = dictItem(dict, item_index);
        const value_handle = dictItem(dict, item_index + 1);
        assert(!key_handle.isShared());
        assert(!value_handle.isShared());
        // We checked that all our keys have strings earlier.
        const key_checking = Heap.getString(dictItem(dict, item_index)) catch unreachable;
        if (std.mem.eql(u8, key_bytes, key_checking)) {
            key_handle.getMetadata().mutable = true; // Make mutable before invalidating.
            key_handle.invalidateBoth();
            value_handle.invalidateBoth();
            pairs_removed += 1;
        } else if (pairs_removed > 0) {
            // Move this pair backwards.
            const new_key_handle = dictItem(dict, item_index - pairs_removed * 2);
            const new_value_handle = dictItem(dict, item_index - pairs_removed * 2 + 1);
            new_key_handle.peek().* = key_handle.peek().*;
            new_value_handle.peek().* = value_handle.peek().*;
        }
    }

    // Be sure to "zero" out all the moved items that weren't replaced with something else.
    const start_of_removed = dict_len - pairs_removed * 2;
    for (start_of_removed..dict_len) |removed| {
        const item_handle = dictItem(dict, @intCast(removed));
        item_handle.peek().* = .{ .str = Heap.Object.null_string, .tag = .none, .body = undefined };
        // Mark abandoned keys as mutable again.
        item_handle.getMetadata().mutable = true;
    }

    dict.peek().body.dict.len -= pairs_removed * 2;

    dict.invalidateString();

    return .{ .new_dict = new_dict, .did_remove = true };
}

fn testDicts(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    const heap = try Heap.testStart(ta);

    const key_foo = try newString(heap, "foo");
    defer key_foo.decrRefCount();
    const value1 = try newString(heap, "1");
    defer value1.decrRefCount();
    const key_bar = try newString(heap, "bar");
    defer key_bar.decrRefCount();
    const value2 = try newString(heap, "2");
    defer value2.decrRefCount();

    const dict1 = try newDict(heap, &.{ key_foo, value1, key_bar, value2 });
    defer dict1.decrRefCount();

    const good_key = try newString(heap, "foo");
    defer good_key.decrRefCount();
    const bad_key = try newString(heap, "bogus");
    defer bad_key.decrRefCount();

    try testing.expectEqualStrings("1", try Heap.getString((try dictLookupFollowRefs(dict1, good_key)).?));
    try testing.expectEqual(null, try dictLookupFollowRefs(dict1, bad_key));

    // Dict with duplicate entries testing.
    var new_dict: OptionalHandle = .none;
    defer new_dict.swapWithNull();

    var dict_with_duplicates = try newString(heap, "foo 5 bar 10 foo 15");
    defer dict_with_duplicates.decrRefCount();
    const dup_len = try dictPairLength(null, dict_with_duplicates, &new_dict);
    dict_with_duplicates.swapAndClear(&new_dict);

    try testing.expectEqual(3, dup_len);
    // When a duplicate key is queried, it should point to the last corrisponding value.
    try testing.expectEqualStrings("15", try Heap.getString((try dictLookupFollowRefs(dict_with_duplicates, key_foo)).?));

    const dup_remove_result = try dictRemoveDuplicates(dict_with_duplicates, null);
    dict_with_duplicates.swapIfNew(dup_remove_result.new_dict);
    try testing.expectEqual(2, dictPairLengthRaw(dict_with_duplicates));

    // Dict put testing.
    var dict_for_put = try newDict(heap, &.{ key_foo, value1, key_bar, value2 });
    defer dict_for_put.decrRefCount();
    const key3 = try newString(heap, "baz");
    defer key3.decrRefCount();
    const value3 = try newString(heap, "3");
    defer value3.decrRefCount();

    try testing.expectEqual(2, dictPairLengthRaw(dict_for_put));
    var put_result = try dictPut(dict_for_put, key_bar, value3);
    dict_for_put.swapIfNew(put_result.new_dict);
    try testing.expectEqual(2, dictPairLengthRaw(dict_for_put));

    put_result = try dictPut(dict_for_put, key3, value3);
    dict_for_put.swapIfNew(put_result.new_dict);
    try testing.expectEqual(3, dictPairLengthRaw(dict_for_put));
    try testing.expectEqualStrings("3", try Heap.getString((try dictLookupFollowRefs(dict_for_put, key3)).?));

    // Dict remove testing.
    var dict_for_remove = try newDict(heap, &.{ key_foo, value1, key_bar, value2, key_foo, value3 });
    defer dict_for_remove.decrRefCount();
    const remove_result = try dictRemove(dict_for_remove, key_foo);
    dict_for_remove.swapIfNew(remove_result.new_dict);
    try testing.expectEqual(true, remove_result.did_remove);
    try testing.expectEqualStrings("bar 2", try Heap.getString(dict_for_remove));

    // Test dict edge cases.
    var dict_edge_cases = try newDict(heap, &.{ key_foo, value1, key_bar, value2 });
    defer dict_edge_cases.decrRefCount();

    // Try using a value as a key, and a key as the value while not shared (this is to check
    // that this handles using internal objects correctly).
    assert(dict_edge_cases.canMutate());
    put_result = try dictPut(dict_edge_cases, dictItemFollowRefs(dict_edge_cases, 1), dictItemFollowRefs(dict_edge_cases, 2));
    dict_edge_cases.swapIfNew(put_result.new_dict);
    try testing.expectEqualStrings("bar", try Heap.getString((try dictLookupFollowRefs(dict_edge_cases, value1)).?));

    // Try aliasing a key by using it as key and value.
    put_result = try dictPut(dict_edge_cases, dictItemFollowRefs(dict_edge_cases, 0), dictItemFollowRefs(dict_edge_cases, 0));
    dict_edge_cases.swapIfNew(put_result.new_dict);
    try testing.expectEqualStrings("foo", try Heap.getString((try dictLookupFollowRefs(dict_edge_cases, key_foo)).?));

    // Try aliasing a value by using it as key and value.
    put_result = try dictPut(dict_edge_cases, dictItemFollowRefs(dict_edge_cases, 3), dictItemFollowRefs(dict_edge_cases, 3));
    dict_edge_cases.swapIfNew(put_result.new_dict);
    try testing.expectEqualStrings("2", try Heap.getString((try dictLookupFollowRefs(dict_edge_cases, value2)).?));
}

test "dicts" {
    try testing.checkAllAllocationFailures(testing.allocator, testDicts, .{});
}

pub const SourceInfo = struct {
    file_name: OptionalHandle,
    line_no: u32,
};

/// .file_name will become invalid if the file name object's string becomes invalid.
/// Does not borrow the file_name object, so be sure to borrow shimmering the handle.
pub fn getSourceInfo(handle: Handle) ?SourceInfo {
    const obj = handle.peek();
    if (obj.tag != .source) return null;

    const file_name = obj.body.source.file_name_obj.toOptional(handle.getHeap());

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

    if (source_info.file_name.toHandle()) |file_name| {
        var same_heap_file_name = file_name;

        if (same_heap_file_name.heap != handle.heap) {
            same_heap_file_name = try Heap.local_heap.duplicate(same_heap_file_name);
        } else {
            // Make sure to increment the ref count.
            same_heap_file_name.incrRefCount();
        }

        // This should be true, as Heap.ensureShimmerable will make sure it's in our heap.
        assert(handle.heap == same_heap_file_name.heap);

        ref.body.source.file_name_obj = same_heap_file_name.toOptional().getIndex();
    } else {
        ref.body.source.file_name_obj = .null;
    }
}

fn testSourceInfo(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    const heap = try Heap.testStart(ta);

    var obj = try heap.createObject();
    defer obj.decrRefCount();

    const file_name = try newString(heap, "test_file.tcl");
    defer file_name.decrRefCount();

    try setSourceInfo(obj, .{ .file_name = file_name.toOptional(), .line_no = 42 });

    // Verify the object has the source tag
    const ref = obj.peek();
    try testing.expectEqual(.source, ref.tag);
    try testing.expectEqual(@as(u32, 42), ref.body.source.line_no);

    const info = getSourceInfo(obj);
    try testing.expectEqualSlices(u8, "test_file.tcl", try Heap.getString(info.?.file_name.toHandle().?));
    try testing.expectEqual(@as(u32, 42), info.?.line_no);

    const obj2 = try newString(heap, "hello");
    defer obj2.decrRefCount();

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
        .file_name = .none,
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
    var is_trimming_start = true;
    // Add all tokens to the list, handling any errors that may come up.
    while (true) {
        const next_token = parser.nextScriptToken();
        if (next_token) |token| {
            switch (token.tag) {
                .command_separator, .word_separator => {
                    if (!is_trimming_start) try tokens.append(Heap.local_heap.gpa, token);
                },
                .end_of_file => {
                    // Be sure to trim the ending spacing.
                    while (tokens.getLastOrNull()) |last| {
                        if (last.tag == .command_separator or last.tag == .word_separator) {
                            _ = tokens.pop();
                        } else {
                            break;
                        }
                    }
                    try tokens.append(Heap.local_heap.gpa, token);
                    break;
                },
                else => {
                    is_trimming_start = false;
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

        is_trimming_start = false;
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
    var new_token_values = try newListWithCapacity(new_token_capacity);
    errdefer new_token_values.decrRefCount();

    var new_token_tags = try std.ArrayList(Tokenizer.Token.Tag).initCapacity(Heap.local_heap.gpa, new_token_capacity);
    errdefer new_token_tags.deinit(Heap.local_heap.gpa);

    // Be sure to append the first .script_command token.
    try new_token_tags.append(Heap.local_heap.gpa, .start_of_command);
    var first_append_result: OptionalHandle = .none;
    _ = try listAppendObject(det, new_token_values, &first_append_result, .{
        .str = Heap.Object.null_string,
        .tag = .script_command,
        .body = .{
            .script_command = .{
                .line = source_info.line_no,
                .arg_count = 0, // Set later.
            },
        },
    });
    new_token_values.swapIfNew(first_append_result);

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
            var append_result: OptionalHandle = .none;
            const index = try listAppendObject(det, new_token_values, &append_result, .{
                .str = Heap.Object.null_string,
                .tag = .script_command,
                .body = .{ .script_command = .{ .line = tokens.items[i].loc.line_no, .arg_count = 0 } },
            });
            new_token_values.swapIfNew(append_result);
            script_command_idx = index;

            continue;
        }

        // Append the start of the word (only if necessary).
        if (found_expansion or arg_token_count > 1) {
            if (found_expansion) {
                try new_token_tags.append(Heap.local_heap.gpa, .argument_expansion);
            } else {
                try new_token_tags.append(Heap.local_heap.gpa, .start_of_word);
            }

            var append_result: OptionalHandle = .none;
            _ = try listAppendObject(det, new_token_values, &append_result, .{
                .str = Heap.Object.null_string,
                .tag = .integer,
                .body = .{
                    .integer = @intCast(arg_token_count),
                },
            });
            new_token_values.swapIfNew(append_result);
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
                        var append_result: OptionalHandle = .none;
                        const str_idx = try listAppendObject(
                            det,
                            new_token_values,
                            &append_result,
                            .{ .str = Heap.Object.null_string, .tag = .none, .body = undefined },
                        );
                        new_token_values.swapIfNew(append_result);

                        const item_handle = listItem(new_token_values, str_idx);
                        try setStringFromEscaped(item_handle, bytes[token.loc.start..token.loc.end]);

                        break :blk item_handle;
                    },
                    else => {
                        try new_token_tags.append(Heap.local_heap.gpa, token.tag);
                        var append_result: OptionalHandle = .none;
                        const str_idx = try listAppendObject(
                            det,
                            new_token_values,
                            &append_result,
                            .{ .str = Heap.Object.null_string, .tag = .none, .body = undefined },
                        );
                        new_token_values.swapIfNew(append_result);

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
    if (source_info.file_name.toHandle()) |file_name| file_name.incrRefCount();
    const parsed_script: Heap.ParsedScript = .{
        .tags = new_token_tags,
        .values = new_token_values,
        .first_line = source_info.line_no,
        .file_name_obj = source_info.file_name,
    };
    if (options.token_debugging) {
        std.debug.print("Dumping tokens\n", .{});
        parsed_script.printTokens();
    }

    return parsed_script;
}

fn testScriptParsing(ta: std.mem.Allocator) !void {
    const heap = try Heap.testStart(ta);
    defer Heap.testFinish();

    const script1 = try newString(heap,
        \\ set x 5
        \\ set y $x[set x]
    );
    defer script1.decrRefCount();
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

pub fn shimmerToScript(det: ?*ErrorDetails, provided_handle: Handle, new_handle: *OptionalHandle) !void {
    errdefer new_handle.swapWithNull();

    // Figure out whether the provided object already has a script id, or if we need to
    // generate a new one.
    const script_info = blk: {
        if (provided_handle.peek().tag == .script) {
            const script = provided_handle.peek().body.script;
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

    try Heap.ensureShimmerableOrDup(provided_handle, new_handle);
    const handle = new_handle.orElse(provided_handle);

    var parsed = parseScript(det, handle) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ParseError,
    };
    errdefer parsed.deinit(Heap.local_heap);

    try Heap.local_heap.parsed_scripts.put(Heap.local_heap.gpa, script_id.index, .{
        .script = parsed,
        .generation = script_id.generation,
    });

    try handle.prepareToShimmer();
    const obj = handle.peek();
    obj.body.script = .{ .id = script_id };
    obj.tag = .script;

    return;
}

pub fn getScript(det: ?*ErrorDetails, provided_handle: Handle, new_handle: *OptionalHandle) !Heap.ParsedScript {
    try shimmerToScript(det, provided_handle, new_handle);
    const handle = new_handle.orElse(provided_handle);
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
        defer old_script.decrRefCount();

        var parse_result: OptionalHandle = .none;
        const parsed_script = try getScript(null, old_script, &parse_result);
        old_script.swapIfNew(parse_result);
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
    defer new_script.decrRefCount();

    var parse_result: OptionalHandle = .none;
    try shimmerToScript(null, new_script, &parse_result);
    new_script.swapIfNew(parse_result);
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

pub fn shimmerToExpression(det: ?*ErrorDetails, provided_handle: Handle, new_handle: *OptionalHandle) !void {
    errdefer new_handle.swapWithNull();

    // Figure out whether the provided object already has a script id, or if we need to
    // generate a new one.
    const expr_info = blk: {
        if (provided_handle.peek().tag == .expr) {
            const expr = provided_handle.peek().body.expr;
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

    const source_info: SourceInfo = getSourceInfo(provided_handle) orelse .{ .file_name = .none, .line_no = 1 };
    var file_name = source_info.file_name.borrowOptional();
    errdefer file_name.swapWithNull();
    const line_no = source_info.line_no;

    try Heap.ensureShimmerableOrDup(provided_handle, new_handle);
    const handle = new_handle.orElse(provided_handle);

    // Parse all the tokens of the expr, handling any errors that come up.
    const bytes = try Heap.getString(handle);
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
                        errdefer err_on_heap.decrRefCount();

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

    try handle.prepareToShimmer();
    handle.peek().tag = .expr;
    handle.peek().body = .{
        .expr = .{ .id = expr_id },
    };

    return;
}

pub fn getExpression(det: ?*ErrorDetails, provided_handle: Handle, new_handle: *OptionalHandle) !Heap.ParsedExpression {
    errdefer new_handle.swapWithNull();
    try shimmerToExpression(det, provided_handle, new_handle);
    const handle = new_handle.orElse(provided_handle);
    assert(handle.peek().tag == .expr);

    const expr_id = handle.peek().body.script.id;
    const expr_and_generation = Heap.local_heap.parsed_exprs.get(expr_id.index).?;
    assert(expr_and_generation.generation == expr_id.generation);

    return expr_and_generation.expr;
}

fn testExpressions(ta: std.mem.Allocator) !void {
    const heap = try Heap.testStart(ta);
    defer Heap.testFinish();

    var expr1 = try newString(heap, "1 + 2 * 3 + 4");
    defer expr1.decrRefCount();

    var new_expr: OptionalHandle = .none;
    try shimmerToExpression(null, expr1, &new_expr);
    expr1.swapIfNew(new_expr);

    const expr_id = expr1.peek().body.expr.id;
    const parsed = heap.parsed_exprs.get(expr_id.index).?;

    try testing.expectEqual(.add, parsed.expr.nodes.get(@intFromEnum(parsed.expr.root_node)).tag);
}

test "expressions" {
    try testing.checkAllAllocationFailures(testing.allocator, testExpressions, .{});
}

pub fn shimmerToBoolean(det: ?*ErrorDetails, provided_handle: Handle, new_handle: *OptionalHandle) !void {
    if (provided_handle.peek().tag == .bool) return;
    errdefer new_handle.swapWithNull();

    // Fast case: if it's an int, we can get the value directly.
    if (provided_handle.peek().tag == .integer) {
        const new_value = provided_handle.peek().body.integer != 0;

        try Heap.ensureShimmerableOrDup(provided_handle, new_handle);
        const handle = new_handle.orElse(provided_handle);

        try handle.prepareToShimmer();
        handle.peek().tag = .bool;
        handle.peek().body.bool = new_value;
        return;
    }

    const Mapping = std.StaticStringMap(bool).initComptime(Tokenizer.boolean_mapping);

    const bytes = try Heap.getString(provided_handle);
    const new_value = Mapping.get(bytes) orelse blk: {
        // It might be an integer, so be sure to try parsing it as an int before giving up.
        const as_int = integerGetNoShimmer(null, provided_handle) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                // Finally, give up.
                if (det) |details| details.* = .{
                    .message = try newStringFmt(Heap.local_heap, "expected boolean but got \"{f}\"", .{provided_handle}),
                };
                return error.BadBoolean;
            },
        };
        break :blk as_int != 0;
    };

    try Heap.ensureShimmerableOrDup(provided_handle, new_handle);
    const handle = new_handle.orElse(provided_handle);

    try handle.prepareToShimmer();
    handle.peek().tag = .bool;
    handle.peek().body.bool = new_value;
}

pub fn getBoolean(det: ?*ErrorDetails, provided_handle: Handle, new_handle: *OptionalHandle) !bool {
    try shimmerToBoolean(det, provided_handle, new_handle);
    return new_handle.orElse(provided_handle).peek().body.bool;
}

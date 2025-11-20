const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const testing = std.testing;

const options = @import("options");
const stringutil = @import("./stringutil.zig");
const memutil = @import("./memutil.zig");
const Heap = @import("./Heap.zig");
const Parser = @import("./Parser.zig");
const Handle = Heap.Handle;

pub const Error = std.mem.Allocator.Error || error{
    WrongArgumentCount,
    BadIndex,
    NotMutable,
    BadEnumVariant,
    BadBoolean,
};

pub const ErrorDetails = struct {
    message: Handle,
    index: ?u32 = null,
};

pub fn shimmerToString(calling_heap: *Heap, handle: *Handle) !void {
    if (handle.peek().tag == .string) return;
    try Heap.ensureShimmerable(calling_heap, handle);

    const obj = handle.peek();
    _ = try Heap.getString(handle.*); // Ensure string representation

    if (obj.tag != .string) {
        handle.invalidateBody();
        obj.tag = .string;
        obj.body.string = .{
            // Don't know the utf-8 length yet
            .utf8_length = std.math.maxInt(u33),
        };
    }
}

pub fn getCodepointLength(calling_heap: *Heap, handle: *Handle) !usize {
    shimmerToString(calling_heap, handle);

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
            if (obj.body.string.utf8_length > std.math.maxInt(u32)) {
                return obj.body.string.utf8_length;
            } else {
                const utf8_length = stringutil.codepointLength(bytes);
                obj.body.string.utf8_length = utf8_length; // cache utf8 length
                return utf8_length;
            }
        }
    } else unreachable;
}

/// Copies provided string.
pub fn newString(calling_heap: *Heap, bytes: []const u8) !Handle {
    var str = try calling_heap.createObject();
    errdefer str.release();

    try Heap.setString(str, bytes);
    try shimmerToString(calling_heap, &str);
    return str;
}

pub fn newStringFmt(calling_heap: *Heap, comptime fmt: []const u8, args: anytype) !Handle {
    const str = try calling_heap.createObject();
    // TODO PERF no need to allocate the string, just to duplicate it
    const value = try std.fmt.allocPrint(calling_heap.gpa, fmt, args);
    defer calling_heap.gpa.free(value);
    try Heap.setString(str, value);
    return str;
}

pub fn newStringToFill(heap: *Heap, len: usize) !Handle {
    const handle = try heap.createObject();

    if (len < Heap.LongString.split_point) {
        const new_str = heap.createString(len);
        @memset(heap.getHeapString(new_str, len), 0);

        // New object, so we can set directly
        handle.peek().str = .{
            .u = .{
                .str = .{ .index = new_str, .len = len },
            },
            .is_ptr = false,
        };
    } else {
        // create new string
        const new_str = heap.gpa.allocSentinel(u8, len, 0);
        errdefer heap.gpa.free(new_str);
        @memset(new_str, 0);
        const did_take = try heap.setLongString(handle.index, new_str, .normal);
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
            obj.body.string.utf8_length = cp_length;
        },
        .empty => {
            obj.body.string = .{
                .utf8_length = 0,
            };
        },
        .null => unreachable,
    }

    return handle;
}

pub fn setStringFromEscaped(arena: std.mem.Allocator, handle: Handle, escaped: []const u8) !void {
    // Unescaped must be equal or shorter than escaped version
    const unescaped = try arena.allocSentinel(u8, escaped.len, 0);
    errdefer arena.free(unescaped);
    const written = stringutil.removeEscaping(escaped, unescaped);
    unescaped[written] = 0; // null terminator

    const did_set = try handle.getHeap().setNormalString(handle.index, unescaped[0..written]);
    if (did_set) {
        arena.free(unescaped);
    } else {
        // Too large for normal string, so we'll try setting as a long string.
        const did_take = try handle.getHeap().setLongString(
            handle.index,
            unescaped[0..written :0],
            .{ .different_capacity = unescaped.len },
        );
        if (!did_take) arena.free(unescaped);
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

///////////////////////////////
//  Index related functions  //

/// `start` is inclusive, `end` is exclusive. (Note, this is different from tcl's
/// convention, where both are inclusive. `fromObjects` accounts for this when
/// running the conversion).
pub const Range = struct {
    start: usize,
    end: usize,

    pub fn fromObjects(calling_heap: *Heap, det: ?*ErrorDetails, list_len: usize, start: *Handle, end: *Handle) !Range {
        const start_idx = try getIndex(calling_heap, start, det);
        const end_idx = try getIndex(calling_heap, end, det);

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
fn badIndexError(calling_heap: *Heap, det: ?*ErrorDetails, handle: Handle) !void {
    if (det) |details| details.* = .{
        .message = try newStringFmt(calling_heap, "bad index \"{f}\": must be intexpr or end?[+-]intexpr?", .{handle}),
    };

    return Error.BadIndex;
}

/// Shimmers to an index representation.
pub fn shimmerToIndex(det: ?*ErrorDetails, handle: Handle) !void {
    assert(Heap.canShimmer(handle));

    const bytes = try Heap.getString(handle);
    const obj = handle.peek();

    // Does it start with "end"? If so, it might be end+5, or end-2, etc
    if (bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], "end")) {
        if (bytes.len >= 4) {
            if (bytes[3] != '+' or bytes[3] != '-') return badIndexError(det, handle);

            const index_offset = std.fmt.parseInt(i33, bytes[3..], 10) catch {
                return badIndexError(det, handle);
            };
            obj.body.index = .{ .u = .{ .end_offset = index_offset }, .is_end = true };
        }

        obj.body.index = Heap.ListIndex.end;
    } else {
        const index = std.fmt.parseInt(u32, bytes, 10) catch {
            return badIndexError(det, handle);
        };
        obj.body.index = index;
    }

    obj.tag = .index;
}

pub fn ensureIndex(calling_heap: *Heap, det: ?*ErrorDetails, handle: *Handle) !void {
    if (handle.peek().tag != .index) {
        Heap.ensureShimmerable(calling_heap, handle);
        shimmerToIndex(det, handle.*);
    }
}

pub fn getIndex(calling_heap: *Heap, det: ?*ErrorDetails, handle: *Handle) !Heap.ListIndex {
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

    if (obj.tag != .index) {
        Heap.ensureShimmerable(calling_heap, handle);
        return handle.peek().body.index;
    } else {
        return obj.body.index;
    }
}

/// Creates a substring of the passed in string. Used in `[string range]`.
pub fn stringRange(calling_heap: *Heap, det: ?*ErrorDetails, str: *Handle, start: *Handle, end: *Handle) !Handle {
    const codepoint_len = try getCodepointLength(str);
    const bytes = Heap.getString(str);

    const unchecked_range = try Range.fromObjects(det, codepoint_len, start, end);
    if (unchecked_range) |range| {
        // cpIndex is generic across ascii or utf8.
        const byte_start = stringutil.cpIndex(bytes, range.start);
        const byte_end = stringutil.cpIndex(bytes, range.end);

        return try newStringWithCodepointLen(
            calling_heap,
            bytes[byte_start..byte_end],
            range.end - range.start,
        );
    } else {
        // Invalid range, so we'll just pass through the string.
        return try newStringWithCodepointLen(calling_heap, bytes, codepoint_len);
    }
}

/// Removes from `start` to `end`, optionally inserting `to_insert`.
pub fn stringReplace(calling_heap: *Heap, str: *Handle, start: *Handle, end: *Handle, to_insert: ?Handle) !Handle {
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

            const new_str = newStringToFill(calling_heap, up_to_range_len + to_insert_len + after_range_len);
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

            const new_str = newStringToFill(calling_heap, up_to_range_len + after_range_len);
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
        return try newStringWithCodepointLen(calling_heap, bytes, codepoint_len);
    }
}

/// Upper/lower/title case conversion.
pub fn stringCaseConversion(calling_heap: *Heap, str: Handle, mode: enum { upper, lower, title }) !Handle {
    const bytes = try Heap.getString(str);

    if (options.use_utf8) {
        // Go through once to calculate the length
        var new_len: usize = 0;
        var iter = stringutil.Iterator.init(bytes);
        var is_first_char = true;
        while (iter.next()) |cp| {
            var converted: u21 = undefined;
            switch (mode) {
                .upper => converted = stringutil.toUpper(cp),
                .lower => converted = stringutil.toLower(cp),
                .title => {
                    if (is_first_char) {
                        converted = stringutil.toTitle(cp);
                    } else {
                        converted = stringutil.toLower(cp);
                    }
                },
            }
            new_len += std.unicode.utf8ByteSequenceLength(converted);
            is_first_char = false;
        }

        const new_str = try newStringToFill(calling_heap, new_len);
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
            var converted: u21 = undefined;
            switch (mode) {
                .upper => converted = stringutil.toUpper(cp),
                .lower => converted = stringutil.toLower(cp),
                .title => {
                    if (is_first_char) {
                        converted = stringutil.toTitle(cp);
                    } else {
                        converted = stringutil.toLower(cp);
                    }
                },
            }
            written += std.unicode.utf8Encode(converted, new_bytes[written..]) catch unreachable;

            is_first_char = false;
        }
    } else {
        const new_len = bytes.len;
        const new_str = try newStringToFill(calling_heap, new_len);
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
pub fn stringTrimLeft(calling_heap: *Heap, str: Handle, trim_chars: Handle) !Handle {
    const bytes = try Heap.getString(str);
    const trim_chars_bytes = try Heap.getString(trim_chars);

    const start = stringutil.trimLeft(bytes, trim_chars_bytes);

    if (start == 0) {
        return str;
    } else {
        return try newString(calling_heap, bytes[start..]);
    }
}

/// Creates a new string if there was anything to trim.
pub fn stringTrimRight(calling_heap: *Heap, str: Handle, trim_chars: Handle) !Handle {
    const bytes = try Heap.getString(str);
    const trim_chars_bytes = try Heap.getString(trim_chars);

    const end = stringutil.trimRight(bytes, trim_chars_bytes);

    if (end == bytes.len) {
        return str;
    } else {
        return try newString(calling_heap, bytes[0..end]);
    }
}

/// Creates a new string if there was anything to trim.
pub fn stringTrim(calling_heap: *Heap, str: Handle, trim_chars: Handle) !Handle {
    const bytes = try Heap.getString(str);
    const trim_chars_bytes = try Heap.getString(trim_chars);

    const start = stringutil.trimLeft(bytes, trim_chars_bytes);
    const end = stringutil.trimRight(bytes, trim_chars_bytes);

    if (start == 0 and end == bytes.len) {
        return str;
    } else {
        return try newString(calling_heap, bytes[start..end]);
    }
}

//////////////////////////////
//  Enum related functions  //

/// Byte count of enum names joined by ", "
fn enumNamesCount(comptime T: type) usize {
    comptime {
        var result_size = 0;
        for (std.meta.fields(T)) |field| {
            result_size += field.name.len;
        }
        // Be sure to account for ", "
        result_size += ((std.meta.fields(T).len) -| 1) * 2;

        return result_size;
    }
}

/// Enum names joined by ", "
pub inline fn enumNames(comptime T: type) *const [enumNamesCount(T):0]u8 {
    comptime {
        // Fill the buffer
        var buf: [enumNamesCount(T):0]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);

        var first_time = true;
        for (std.meta.fields(T)) |field| {
            if (!first_time) {
                w.writeAll(", ") catch unreachable;
            } else first_time = false;

            w.writeAll(field.name) catch unreachable;
        }

        buf[buf.len] = 0;

        const final = buf;
        return &final;
    }
}

pub fn EnumMapping(comptime T: type) type {
    comptime {
        const field_count = std.meta.fields(T).len;

        // Create an entry type (instantiated as .{ "foo", .foo })
        const EntryType = std.meta.Tuple(&[_]type{ [:0]const u8, T });
        // Repeat that type for how many fields there are
        const entries = [1]type{EntryType} ** field_count;
        // Create a map type with those repeated entries
        const Mapping = std.meta.Tuple(&entries);

        // Fill out the map
        var mapping: Mapping = undefined;
        for (std.meta.fields(T), 0..) |variant, i| {
            const entry: EntryType = .{ variant.name, @enumFromInt(variant.value) };
            @field(mapping, std.fmt.comptimePrint("{}", .{i})) = entry;
        }

        // Create the table
        return struct {
            pub const StaticStringMap = std.StaticStringMap(T);

            map: StaticStringMap = StaticStringMap.initComptime(mapping),
        };
    }
}

pub fn TclEnum(comptime T: type, enum_name: []const u8) type {
    return struct {
        pub const variants = T;
        pub const map = (EnumMapping(T){}).map;
        pub const names = enumNames(T);

        pub fn get(calling_heap: *Heap, det: ?*ErrorDetails, value: *Handle) !T {
            // TODO PERF we can optimize this by shimmering the value to an "enum" type,
            // where the enum type has a u48 storing the hash of enum_name and a u16 for
            // which variant it is, by index.
            const bytes = try Heap.getString(value.*);
            const variant = map.get(bytes);
            if (variant) |unwrapped| {
                return unwrapped;
            } else {
                if (det) |details| details.* = .{
                    .message = try newStringFmt(
                        calling_heap,
                        "bad {s} \"{f}\": must be {s}",
                        .{ enum_name, value.*, names },
                    ),
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
pub fn stringIs(calling_heap: *Heap, det: ?*ErrorDetails, str: *Handle, class_to_check: *Handle, strict: bool) !bool {
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

    const class = try Class.get(calling_heap, det, class_to_check);

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
            _ = getBoolean(calling_heap, null, str) catch return false;
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
    const heap = try Heap.createHeap(ta);
    defer Heap.testFinish();

    var str = try newString(heap, "abcdefg");
    defer str.release();
    var str2 = try newString(heap, "abcdefg123");
    defer str2.release();
    var class = try newString(heap, "alpha");
    defer class.release();
    var bad_class = try newString(heap, "bad_class");
    defer bad_class.release();
    var details: ErrorDetails = undefined;

    try testing.expectEqual(true, try stringIs(heap, &details, &str, &class, false));
    try testing.expectEqual(false, try stringIs(heap, &details, &str2, &class, false));
    const err = stringIs(heap, &details, &str, &bad_class, false);
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

pub fn convertParserError(heap: *Heap, err: Parser.Error) error{OutOfMemory}!ErrorDetails {
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
        error.NotVariable => unreachable,
    }
}

pub fn listUninitializedNew(heap: *Heap, len: u32) !Handle {
    // `1 +` to make space for the list's head
    const list_index = try heap.createObjects(1 + len);
    const list_head: *Heap.Object = &heap.objects.items(.object)[list_index];

    list_head.* = .{
        .str = Heap.Object.null_string,
        .tag = .list,
        .body = .{
            .list = .{
                .len = len,
            },
        },
    };

    return heap.normalHandle(list_index);
}

pub fn listNew(heap: *Heap, handles: []const Handle) !Handle {
    const list = try listUninitializedNew(heap, @intCast(handles.len));
    errdefer list.release();

    const new_items = listItemsRaw(list);

    for (handles, new_items) |handle, *item| {
        item.* = try heap.duplicateOrReference(handle);
    }

    return list;
}

/// If shimmering, it creates the object in the calling heap
pub fn shimmerToList(calling_heap: *Heap, det: ?*ErrorDetails, handle: *Handle) !void {
    if (handle.peek().tag == .list) return;

    const obj = handle.peek();
    const obj_heap = handle.getHeap();

    // Optimise dict -> list for object with no string rep.
    if (obj.tag == .dict and Heap.getStringDetails(handle.*) == .null) {
        try Heap.ensureShimmerable(calling_heap, handle);

        const dict = &obj_heap.dicts.items[obj.body.dict];
        const len = dict.len;

        // Discard the old hash map.
        dict.dict.clearAndFree(obj_heap.gpa);

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
        var parser = Parser.init(str, line_no);

        // Figure out how many tokens there are, so we can create the correct list size
        // in the heap.
        var tokens: std.ArrayList(Parser.Token) = .empty;
        defer tokens.deinit(calling_heap.gpa);

        while (true) {
            const next_token = parser.parseList() catch |e| {
                if (det) |details| details.* = try convertParserError(calling_heap, e);
                return e;
            };
            switch (next_token.tag) {
                .simple_string, .escaped_string => {
                    try tokens.append(calling_heap.gpa, next_token);
                },
                .end_of_file => break,
                else => {
                    // Skip any line breaks or word breaks.
                },
            }
        }

        const new_list = try listUninitializedNew(calling_heap, @intCast(tokens.items.len));
        errdefer new_list.release();

        for (tokens.items, 0..) |token, i| {
            const item = listItemRaw(new_list, @intCast(i));

            if (token.tag == .simple_string) {
                // Normal string, so no escaping needed.
                try Heap.setString(item, str[token.loc.start..token.loc.end]);
            } else {
                // Needs escaping. We'll create another string to copy the escaped string into.
                try setStringFromEscaped(
                    calling_heap.gpa,
                    item,
                    str[token.loc.start..token.loc.end],
                );
            }

            if (source_info) |info| {
                try setSourceInfo(calling_heap, item, .{
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

/// Panics if provided handle is not a list, or if it can't shimmer.
fn listSetLength(calling_heap: *Heap, handle: *Handle, new_len: u32) !void {
    const list = handle.peek();
    assert(list.tag == .list);

    // We can only do these quick changes if the list is not shared.
    if (!handle.isShared()) {
        // No need to realloc if we're shrinking.
        if (new_len <= list.body.list.len) {
            // Be sure to free the objects when we shrink though.
            const freed_count = list.body.list.len - new_len;
            for (0..freed_count) |to_free| {
                const to_free_handle = listItemRaw(handle.*, @intCast(list.body.list.len - freed_count + to_free));
                to_free_handle.invalidateBody();
                to_free_handle.invalidateString();
            }

            list.body.list.len = new_len;
            return;
        }

        // Even if there's not enough length, there may be enough capacity.
        const order = handle.getHeap().objects.items(.metadata)[handle.index].order;
        const capacity = memutil.getOrderSize(order) - 1; // -1 for list head
        if (new_len <= capacity) {
            list.body.list.len = new_len;
            return;
        }
    }

    // We've exhausted all other options, so we'll need to make a new list.
    const new_list = try listUninitializedNew(calling_heap, new_len);
    errdefer Heap.freeObject(new_list);
    const new_items = listItemsRaw(new_list);

    if (handle.isShared()) {
        // If the list is shared, we need to duplicate all the items.
        for (0.., new_items) |i, *new_item| {
            new_item.* = try Heap.duplicateOrReference(calling_heap, listItemRaw(handle.*, @intCast(i)));
        }

        const old_handle = handle.*;
        handle.* = new_list;
        old_handle.release();
    } else {
        // If the list isn't shared, we can move the objects over without
        // any duplication.
        const old_items = listItemsRaw(handle.*);
        for (old_items, new_items[0..old_items.len]) |old_item, *new_item| {
            new_item.* = old_item;
        }

        // Free the old list without running destructors (because the objects are
        // still in use).
        Heap.freeObjectBacking(handle.*);

        handle.* = new_list;
    }
}

/// Assumes provided handle is a list.
pub fn listItemRaw(handle: Handle, index: u32) Handle {
    const list = handle.peek();
    assert(list.tag == .list);

    if (index < list.body.list.len) {
        return .{
            .index = handle.index + 1 + index,
            .heap = handle.heap,
            .ref_counted = false,
        };
    } else @panic("List element out of bounds");
}

pub fn listItem(calling_heap: *Heap, det: ?*ErrorDetails, handle: *Handle, index: u32) !?Handle {
    try shimmerToList(calling_heap, det, handle);
    const list = handle.peek().body.list;

    if (index < list.len) {
        return listItemRaw(handle.*, index);
    } else return null;
}

/// Assumes handle is a list.
pub fn listItemsRaw(handle: Handle) []Heap.Object {
    const list = handle.peek();
    assert(list.tag == .list);

    return handle.getHeap().objects.items(.object)[(handle.index + 1)..][0..list.body.list.len];
}

pub fn listAppendObject(calling_heap: *Heap, det: ?*ErrorDetails, handle: *Handle, item: Heap.Object) !u32 {
    try shimmerToList(calling_heap, det, handle);
    try listSetLength(calling_heap, handle, handle.peek().body.list.len + 1);

    const list = handle.peek();
    const index = list.body.list.len - 1;

    listItemsRaw(handle.*)[index] = item;

    return index;
}

pub fn listAppend(calling_heap: *Heap, det: ?*ErrorDetails, handle: *Handle, item: Handle) !u32 {
    try shimmerToList(calling_heap, det, handle);
    try listSetLength(calling_heap, handle, handle.peek().body.list.len + 1);

    const list = handle.peek();
    const index = list.body.list.len - 1;

    listItemsRaw(handle.*)[index] = try calling_heap.duplicateOrReference(item);

    return index;
}

fn testLists(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    const heap = try Heap.createHeap(ta);

    var det: ErrorDetails = undefined;

    // Simple case: two objects in a list
    const obj1 = try newString(heap, "object 1");
    defer obj1.release();
    const obj2 = try newString(heap, "object 2");
    defer obj2.release();
    var list1 = try listNew(heap, &.{ obj1, obj2 });
    defer list1.release();

    const items = listItemsRaw(list1);
    try testing.expectEqual(2, items.len);
    // The object should have been copied when being moved into the list
    try testing.expect(obj1.peek().str != items[0].str);
    // But it should have an identical string
    try testing.expectEqualStrings("object 1", try Heap.getString(listItemRaw(list1, 0)));

    const to_append = try newString(heap, "appended item");
    defer to_append.release();

    _ = try listAppend(heap, &det, &list1, to_append);
    try testing.expectEqualStrings("appended item", try Heap.getString(listItemRaw(list1, 2)));

    var string_list = try newString(heap,
        \\item1 {item 2} item\ 3
    );
    defer string_list.release();

    const old_string_list_handle = string_list;
    try shimmerToList(heap, &det, &string_list);
    try testing.expect(old_string_list_handle != string_list);
    try testing.expectEqualStrings("item1", try Heap.getString(listItemRaw(string_list, 0)));
    try testing.expectEqualStrings("item 2", try Heap.getString(listItemRaw(string_list, 1)));
    try testing.expectEqualStrings("item 3", try Heap.getString(listItemRaw(string_list, 2)));
}

test "lists" {
    try testing.checkAllAllocationFailures(testing.allocator, testLists, .{});
}

pub fn dictItemsRaw(handle: Handle) []Heap.Object {
    const obj = handle.peek();
    const obj_heap = handle.getHeap();

    assert(obj.tag == .dict);

    const len = obj_heap.dicts.items[obj.body.dict].len;
    return handle.getHeap().objects.items(.object)[(handle.index + 1)..][0..len];
}

pub fn dictItemRaw(handle: Handle, index: u32) Handle {
    const dict = handle.peek();
    assert(dict.tag == .dict);
    const metadata = handle.getHeap().dicts.items[dict.body.dict];

    if (index < metadata.len) {
        return .{
            .index = handle.index + 1 + index,
            .heap = handle.heap,
            .ref_counted = false,
        };
    } else {
        std.debug.panic("Index {} out of bounds (length {})", .{ index, metadata.len });
    }
}

fn dictUninitializedNew(heap: *Heap, len: u32) !Handle {
    assert(@mod(len, 2) == 0);

    // `1 +` to make space for the dict's head.
    const dict_index = try heap.createObjects(1 + len);
    errdefer Heap.freeObjectBacking(heap.normalHandle(dict_index));
    const dict_metadata = try heap.createDictMetadata();
    errdefer heap.destroyDictMetadata(dict_metadata);

    heap.dicts.items[dict_metadata] = .{
        .dict = .empty,
        .len = len,
    };

    const dict_head: *Heap.Object = &heap.objects.items(.object)[dict_index];
    dict_head.* = .{
        .str = Heap.Object.null_string,
        .tag = .dict,
        .body = .{
            .dict = dict_metadata,
        },
    };

    return heap.normalHandle(dict_index);
}

/// Caller is responsible that `handles` has handles.len % 2 == 0.
pub fn dictNew(heap: *Heap, handles: []const Handle) !Handle {
    const dict = try dictUninitializedNew(heap, @intCast(handles.len));
    errdefer dict.release();

    const new_items = dictItemsRaw(dict);

    for (handles, new_items) |handle, *item| {
        item.* = try heap.duplicateOrReference(handle);
    }

    try dictReindex(dict);

    return dict;
}

/// Panics if not a dict, or if it can't shimmer.
pub fn dictReindex(handle: Handle) !void {
    assert(handle.canShimmer());
    const obj = handle.peek();
    assert(obj.tag == .dict);
    const dict = &handle.getHeap().dicts.items[obj.body.dict];
    assert(dict.len % 2 == 0);

    dict.dict.clearRetainingCapacity();

    // This properly accounts for duplicate dictionary entries,
    // as it'll just overwrite it with the second `dict.put`.
    var pair: u32 = 0;
    while (pair < dict.len) : (pair += 2) {
        const key: Handle = .{
            .index = handle.index + 1 + pair,
            .heap = handle.heap,
            .ref_counted = false,
        };
        // Point to `pair + 1`, e.g. the value following the key
        try dict.dict.put(handle.getHeap().gpa, key, pair + 1);
    }
}

pub fn dictLookupRaw(dict: Handle, key: Handle) ?Handle {
    assert(dict.peek().tag == .dict);

    const dict_heap = dict.getHeap();
    const metadata = &dict_heap.dicts.items[dict.peek().body.dict];

    if (metadata.dict.get(key)) |value_offset| {
        return dictItemRaw(dict, value_offset);
    } else return null;
}

fn testDicts(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    const heap = try Heap.createHeap(ta);

    const key1 = try newString(heap, "foo");
    defer key1.release();
    const value1 = try newString(heap, "1");
    defer value1.release();
    const key2 = try newString(heap, "bar");
    defer key2.release();
    const value2 = try newString(heap, "2");
    defer value2.release();

    const dict1 = try dictNew(heap, &[_]Heap.Handle{ key1, value1, key2, value2 });
    defer dict1.release();

    const good_key = try newString(heap, "foo");
    defer good_key.release();
    const bad_key = try newString(heap, "bogus");
    defer bad_key.release();

    try testing.expectEqualStrings("1", try Heap.getString(dictLookupRaw(dict1, good_key).?));
    try testing.expectEqual(null, dictLookupRaw(dict1, bad_key));
}

test "dicts" {
    try testing.checkAllAllocationFailures(testing.allocator, testDicts, .{});
}

pub const SourceInfo = struct {
    file_name: ?Handle,
    line_no: u32,
};

/// .file_name will become invalid if the file name object's string becomes invalid.
pub fn getSourceInfo(handle: Handle) ?SourceInfo {
    const ref = handle.peek();
    if (ref.tag != .source) return null;

    const file_name_handle = handle.getHeap().normalHandle(ref.body.source.file_name_obj);
    const file_name = if (file_name_handle.index != 0) file_name_handle else null;

    return .{
        .file_name = file_name,
        .line_no = ref.body.source.line_no,
    };
}

pub fn setSourceInfo(calling_heap: *Heap, source: Handle, source_info: SourceInfo) !void {
    var source_handle = source;
    try Heap.ensureShimmerable(calling_heap, &source_handle);
    source_handle.invalidateBody();

    const ref = source_handle.peek();
    ref.tag = .source;
    ref.body.source.line_no = source_info.line_no;

    if (source_info.file_name) |unwrapped| {
        var same_heap_file_name = unwrapped;

        if (same_heap_file_name.heap != source_handle.heap) {
            same_heap_file_name = try calling_heap.duplicate(same_heap_file_name);
        } else {
            // Make sure to increment the ref count.
            _ = same_heap_file_name.reference();
        }

        // This should be true, as Heap.ensureShimmerable will make sure it's in our heap.
        assert(source_handle.heap == same_heap_file_name.heap);

        ref.body.source.file_name_obj = same_heap_file_name.index;
    } else {
        ref.body.source.file_name_obj = calling_heap.nullObject().index;
    }
}

fn testSourceInfo(ta: std.mem.Allocator) !void {
    const heap = try Heap.createHeap(ta);
    defer Heap.testFinish();

    const obj = try heap.createObject();
    defer obj.release();

    const file_name = try newString(heap, "test_file.tcl");
    defer file_name.release();

    try setSourceInfo(heap, obj, .{ .file_name = file_name, .line_no = 42 });

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
pub fn parseScript(calling_heap: *Heap, det: ?*ErrorDetails, handle: Handle) !Heap.ParsedScript {
    // Get source info, or use defaults.
    const source_info: SourceInfo = if (getSourceInfo(handle)) |info| info else SourceInfo{
        .file_name = null,
        .line_no = 1,
    };

    // Parse all the tokens of the script, handling any errors that come up. //

    const bytes = try Heap.getString(handle);
    var parser = Parser.init(bytes, source_info.line_no);

    // Set up tokens list (to be added to).
    var tokens = try std.ArrayList(Parser.Token).initCapacity(calling_heap.gpa, bytes.len / 8);
    defer tokens.deinit(calling_heap.gpa);

    // Used to ignore the first token if it's .command_separator (effectively
    // trimming any starting whitespace)
    var is_trimming = true;
    // Add all tokens to the list, handling any errors that may come up.
    while (true) {
        const next_token = parser.parseScript();
        if (next_token) |token| {
            switch (token.tag) {
                .command_separator, .word_separator => {
                    if (!is_trimming) try tokens.append(calling_heap.gpa, token);
                },
                .end_of_file => {
                    try tokens.append(calling_heap.gpa, token);
                    break;
                },
                else => {
                    is_trimming = false;
                    try tokens.append(calling_heap.gpa, token);
                },
            }
        } else |err| {
            if (det) |details| {
                details.* = try convertParserError(calling_heap, err);
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
    var new_token_values = try listUninitializedNew(calling_heap, new_token_capacity);
    errdefer new_token_values.release();
    // Set length to 0 so we can just call listAppend().
    try listSetLength(calling_heap, &new_token_values, 0);

    var new_token_tags = try std.ArrayList(Parser.Token.Tag).initCapacity(calling_heap.gpa, new_token_capacity);
    errdefer new_token_tags.deinit(calling_heap.gpa);

    // Be sure to append the first .script_command token.
    try new_token_tags.append(calling_heap.gpa, .start_of_command);
    _ = try listAppendObject(calling_heap, det, &new_token_values, .{
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
            listItemsRaw(new_token_values)[script_command_idx].body.script_command.arg_count = command_arg_count;

            if (tokens.items[i].tag == .end_of_file) {
                break; // Don't append a .script_command for EOF
            }

            i += 1; // Skip command separator.

            // Start a new command.
            command_arg_count = 0;
            try new_token_tags.append(calling_heap.gpa, .start_of_command);
            script_command_idx = try listAppendObject(calling_heap, det, &new_token_values, .{
                .str = Heap.Object.null_string,
                .tag = .script_command,
                .body = .{ .script_command = .{ .line = tokens.items[i].loc.line_no, .arg_count = 0 } },
            });

            continue;
        }

        // Append the start of the word (only if necessary).
        if (found_expansion or arg_token_count > 1) {
            if (found_expansion) {
                try new_token_tags.append(calling_heap.gpa, .argument_expansion);
            } else {
                try new_token_tags.append(calling_heap.gpa, .start_of_word);
            }

            _ = try listAppendObject(calling_heap, det, &new_token_values, .{
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

            var str_handle: Handle = undefined;
            switch (token.tag) {
                .argument_expansion => {},
                .escaped_string => {
                    try new_token_tags.append(calling_heap.gpa, .simple_string);
                    const str_idx = try listAppendObject(
                        calling_heap,
                        det,
                        &new_token_values,
                        .{ .str = Heap.Object.null_string, .tag = .none, .body = undefined },
                    );
                    str_handle = listItemRaw(new_token_values, str_idx);

                    try setStringFromEscaped(calling_heap.gpa, str_handle, bytes[token.loc.start..token.loc.end]);
                },
                else => {
                    try new_token_tags.append(calling_heap.gpa, token.tag);
                    const str_idx = try listAppendObject(
                        calling_heap,
                        det,
                        &new_token_values,
                        .{ .str = Heap.Object.null_string, .tag = .none, .body = undefined },
                    );
                    str_handle = listItemRaw(new_token_values, str_idx);

                    try Heap.setString(str_handle, bytes[token.loc.start..token.loc.end]);
                },
            }

            try setSourceInfo(calling_heap, str_handle, .{
                .file_name = source_info.file_name,
                .line_no = token.loc.line_no,
            });
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
    const heap = try Heap.createHeap(ta);
    defer Heap.testFinish();

    const script1 = try newString(heap,
        \\ set x 5
        \\ set y $x[set x]
    );
    defer script1.release();
    var parsed = try parseScript(heap, null, script1);
    defer parsed.deinit(heap);

    const tokens = parsed.tags.items;
    const values = listItemsRaw(parsed.values);

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

pub fn shimmerToScript(calling_heap: *Heap, det: ?*ErrorDetails, handle: *Handle) !void {
    var using_new_id: bool = undefined;
    var script_id: Heap.ScriptId = undefined;

    // Figure out whether the provided object already has a script id, or if we need to
    // generate a new one.
    if (handle.peek().tag == .script) {
        const script = handle.peek().body.script;
        script_id = script.id;
        using_new_id = false;
    } else {
        using_new_id = true;
        script_id = try Heap.ScriptId.next();
    }
    errdefer if (using_new_id) script_id.retire();

    if (calling_heap.parsed_scripts.get(script_id.index)) |existing_script| {
        if (existing_script.generation == script_id.generation) {
            // Object is already a script, it exists as parsed in our heap,
            // and it's the correct generation. No need to reparse!
            return;
        } else {
            // Wrong generation, so free the old one before overwriting (later in code).
            var script_as_mut = existing_script.script;
            script_as_mut.deinit(calling_heap);
            // Be sure to remove it, in case we hit an error before we have the chance
            // to overwrite it.
            _ = calling_heap.parsed_scripts.remove(script_id.index);
        }
    } else {
        // We don't have this script in our heap, so keep going to generate it.
    }

    try Heap.ensureShimmerable(calling_heap, handle);

    var parsed = try parseScript(calling_heap, det, handle.*);
    errdefer parsed.deinit(calling_heap);

    try calling_heap.parsed_scripts.put(calling_heap.gpa, script_id.index, .{
        .script = parsed,
        .generation = script_id.generation,
    });

    const obj = handle.peek();
    obj.body.script = .{ .id = script_id };
    obj.tag = .script;
}

pub fn getScript(calling_heap: *Heap, det: ?*ErrorDetails, handle: *Handle) !Heap.ParsedScript {
    try shimmerToScript(calling_heap, det, handle);
    assert(handle.peek().tag == .script);

    const script_id = handle.peek().body.script.id;
    const script_and_generation = calling_heap.parsed_scripts.get(script_id.index).?;
    assert(script_and_generation.generation == script_id.generation);

    return script_and_generation.script;
}

fn testScriptShimmering(ta: std.mem.Allocator) !void {
    const heap = try Heap.createHeap(ta);
    defer Heap.testFinish();

    const old_script_id = blk: {
        var old_script = try newString(heap,
            \\ set foo 5
            \\ set y $foo[set foo]
        );
        defer old_script.release();

        const parsed_script = try getScript(heap, null, &old_script);
        const script1_id = old_script.peek().body.script.id;
        try testing.expectEqualSlices(Parser.Token.Tag, &[_]Parser.Token.Tag{
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

    try shimmerToScript(heap, null, &new_script);
    const new_script_id = new_script.peek().body.script.id;

    // Make sure the new script recycles the old script's index.
    try testing.expectEqual(old_script_id.index, new_script_id.index);
    try testing.expect(old_script_id.generation != new_script_id.generation);
}

test "script shimmering" {
    try testing.checkAllAllocationFailures(testing.allocator, testScriptShimmering, .{});
}

fn expectEqualToken(script: *const Heap.ParsedScript, index: u32, tag: Parser.Token.Tag, value: []const u8) !void {
    try testing.expectEqual(tag, script.tags.items[index]);
    try testing.expectEqualStrings(value, try Heap.getString(listItemRaw(script.values, index)));
}

pub fn shimmerToBoolean(calling_heap: *Heap, det: ?*ErrorDetails, handle: *Handle) !void {
    try Heap.ensureShimmerable(calling_heap, handle);

    const Mapping = std.StaticStringMap(bool).initComptime(.{
        .{ "1", true },  .{ "true", true },   .{ "yes", true }, .{ "on", true },
        .{ "0", false }, .{ "false", false }, .{ "no", false }, .{ "off", false },
    });

    const bytes = try Heap.getString(handle.*);
    const new_value = Mapping.get(bytes) orelse {
        if (det) |details| details.* = .{
            .message = try newStringFmt(
                calling_heap,
                "expected boolean but got \"{f}\"",
                .{handle},
            ),
        };
        return Error.BadBoolean;
    };

    const ref = handle.peek();
    ref.tag = .bool;
    ref.body.bool = new_value;
}

pub fn getBoolean(calling_heap: *Heap, det: ?*ErrorDetails, handle: *Handle) !bool {
    try shimmerToBoolean(calling_heap, det, handle);

    return handle.peek().body.bool;
}

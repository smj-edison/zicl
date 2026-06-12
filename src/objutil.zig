const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const testing = std.testing;

const options = @import("options");
const ioutil = @import("ioutil.zig");
const strutil = @import("strutil.zig");
const expr_parse = @import("expr_parse.zig");
const memutil = @import("memutil.zig");
const Tokenizer = @import("Tokenizer.zig");
const Heap = @import("Heap.zig");
const regex = @import("regex.zig");
const pcre2 = @import("pcre2");
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
    PathNonexistent,
};

pub const ErrorDetails = struct {
    message: Handle,
    index: ?u32 = null,
};

/// Note that this is often cast to `Mutable`, so you can't depend on `original`
/// and `shimmered` as having the same value. Always use `.current()`. This is
/// because `Shimmerable` and `Mutable` are more conventions to keep straight
/// what's allowed to mutate, and what's just allowed to shimmer (a mutation is
/// considered a shimmer if it has/will generate the same string rep).
pub const Shimmerable = extern struct {
    original: Handle,
    shimmered: OptionalHandle = .none,

    pub fn deinit(self: *Shimmerable) void {
        self.original.decrRefCount();
        self.shimmered.decrOptional();
        self.* = undefined;
    }

    pub fn current(self: *const Shimmerable) Handle {
        return self.shimmered.orElse(self.original);
    }

    pub fn consume(self: *Shimmerable) Handle {
        defer self.* = undefined;
        if (self.shimmered.toHandle()) |shimmered| {
            self.original.decrRefCount();
            return shimmered;
        } else {
            return self.original;
        }
    }

    pub fn discardChanges(self: *Shimmerable) void {
        self.shimmered.swapWithNone();
    }

    pub fn takeShimmered(self: *Shimmerable) OptionalHandle {
        const result = self.shimmered;
        self.shimmered = .none;
        return result;
    }

    pub fn peek(self: *const Shimmerable) *Heap.Object {
        return self.current().peek();
    }

    pub fn tag(self: *const Shimmerable) Heap.Tag {
        return self.current().tag();
    }

    pub fn getString(self: *const Shimmerable) ![:0]const u8 {
        return try self.current().getString();
    }

    /// Be very careful when using `asMutable`, since mutation functions often invalidate
    /// the original string. Even if the mutation you do is transparent with the object
    /// model, it may free the original string, thus not being transparent.
    pub fn asMutable(self: *Shimmerable) *Mutable {
        return @ptrCast(self);
    }

    pub fn ensureShimmerable(self: *Shimmerable) error{OutOfMemory}!void {
        if (!self.current().canShimmer()) {
            self.shimmered.swap(try Heap.duplicate(self.current()));
        }
    }

    pub fn prepareToShimmer(self: *Shimmerable) !void {
        try self.ensureShimmerable();
        try self.current().prepareToShimmer();
    }

    pub fn duplicateForMutable(self: *const Shimmerable) !Handle {
        // Even if `original` or `replacement` can mutate due to ref count = 1,
        // we've been tasked with making sure this object doesn't mutate, since
        // the purpose of Shimmer is to ensure that we only ever write back
        // something that has the same string (or will have the same string
        // when generated).
        return try self.current().duplicate();
    }
};

pub const Mutable = extern struct {
    original: Handle,
    mutated: OptionalHandle = .none,

    pub fn deinit(self: *Mutable) void {
        self.original.decrRefCount();
        self.mutated.decrOptional();
        self.* = undefined;
    }

    pub fn current(self: *const Mutable) Handle {
        return self.mutated.orElse(self.original);
    }

    pub fn consume(self: *Mutable) Handle {
        if (self.mutated.toHandle()) |mutated| {
            self.original.decrRefCount();
            return mutated;
        } else {
            return self.original;
        }
    }

    pub fn discardChanges(self: *Mutable) void {
        self.mutated.swapWithNone();
    }

    pub fn takeMutated(self: *Mutable) OptionalHandle {
        const result = self.mutated;
        self.mutated = .none;
        return result;
    }

    pub fn peek(self: *const Mutable) *Heap.Object {
        return self.current().peek();
    }

    pub fn tag(self: *const Mutable) Heap.Tag {
        return self.current().tag();
    }

    pub fn getString(self: *const Mutable) ![:0]const u8 {
        return try self.current().getString();
    }

    pub fn asShimmerable(self: *Mutable) *Shimmerable {
        return @ptrCast(self);
    }

    pub fn prepareToShimmer(self: *Mutable) !void {
        if (!self.current().canShimmer()) {
            self.mutated.swap(try Heap.duplicate(self.current()));
        }

        try self.current().prepareToShimmer();
    }

    pub fn prepareToMutate(self: *Mutable) !void {
        if (!self.current().canMutate()) {
            self.mutated.swap(try Heap.duplicate(self.current()));
        }
    }
};

pub fn shimmerToString(wb: *Shimmerable) !void {
    if (wb.tag() == .string) return;

    try wb.prepareToShimmer();
    wb.current().peek().head.tag = .string;
    wb.current().peek().body = .{
        .string = .{
            .utf8_length = 0,
            // Don't know the utf-8 length yet.
            .length_determined = false,
        },
    };
}

pub fn createHashReference(referent: Handle) !Handle {
    const handle = try Heap.createObject();
    handle.peek().head.tag = .hash_reference;
    handle.peek().body.hash_reference = referent.borrow();
    return handle;
}

pub fn shimmerToHashReference(det: ?*ErrorDetails, wb: *Shimmerable) !void {
    if (wb.current().tag() == .hash_reference) return;

    const str = try wb.current().getString();
    const hash = Heap.parseHashReference(str) orelse {
        if (det) |details| details.* = .{
            .message = try newStringFmt(
                "Expected a hash reference like \"blake3^...\" in \"{s}\".",
                .{str},
            ),
        };
        return error.NotHashReference;
    };
    const target = Heap.registered_hashes.get(hash) orelse {
        if (det) |details| details.* = .{
            .message = try newStringFmt(
                "Could not find value for hash reference {s}",
                .{str},
            ),
        };
        return error.HashLookupFailed;
    };

    try wb.prepareToShimmer();
    wb.peek().head.tag = .hash_reference;
    wb.peek().body = .{ .hash_reference = target.borrow() };
}

pub fn getCodepointLength(wb: *Shimmerable) !usize {
    try shimmerToString(wb);

    // See if we already calculated the utf8 length.
    switch (wb.current().getStringDetails()) {
        .long => |long_str| {
            const current_len = long_str.getUtf8Length();
            if (current_len) |val| return val;

            // String length hasn't been computed yet, so compute now.
            const utf8_length = strutil.codepointLength(long_str.getString());
            long_str.setUtf8Length(utf8_length); // Cache utf8 length.
            return utf8_length;
        },
        .normal => {
            // Zig doesn't allow for atomically loading or storing packed enums, so we cast
            // it as a pointer to its underlying u64.
            const body_u64_ptr: *u64 = @ptrCast(Heap.Object.fieldPtr(wb.peek(), "body"));
            const body = @as(Heap.Body, @bitCast(@atomicLoad(u64, body_u64_ptr, .monotonic)));
            if (body.string.length_determined) {
                return body.string.utf8_length;
            } else {
                const bytes = try wb.current().getString();
                const utf8_length = strutil.codepointLength(bytes);
                @atomicStore(u64, body_u64_ptr, @bitCast(Heap.Body{
                    .string = .{
                        .utf8_length = @intCast(utf8_length), // Cache utf8 length.
                        .length_determined = true,
                    },
                }), .monotonic);

                return utf8_length;
            }
        },
        .empty => return 0,
        .null => unreachable,
    }
}

/// Copies provided string.
pub fn newString(bytes: []const u8) !Handle {
    var handle = try Heap.createObject();
    errdefer handle.decrRefCount();

    Heap.setString(handle, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OtherThreadSet => unreachable, // Brand new string, so impossible.
    };
    var handle_wb: Shimmerable = .{ .original = handle };
    try shimmerToString(&handle_wb);
    assert(handle_wb.shimmered == .none);

    return handle;
}

pub fn newStringFmt(comptime fmt: []const u8, args: anytype) !Handle {
    const str = try std.fmt.allocPrint(Heap.global_gpa, fmt, args);
    defer Heap.global_gpa.free(str);

    return try newString(str);
}

/// Copies provided string.
pub fn newStringWithCodepointLen(bytes: []const u8, cp_length: usize) !Handle {
    const handle = try Heap.createObject();
    errdefer handle.decrRefCount();
    try Heap.setString(handle, bytes);

    handle.peek().head.tag = .string;

    switch (handle.getStringDetails()) {
        .long => |long_str| {
            long_str.setUtf8Length(cp_length);
            handle.peek().body = undefined;
        },
        .normal => {
            handle.peek().body.string = .{
                .utf8_length = @intCast(cp_length),
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
    const unescaped = try Heap.global_gpa.alloc(u8, escaped.len);
    defer Heap.global_gpa.free(unescaped);
    const written = strutil.removeEscaping(escaped, unescaped);

    try Heap.setString(handle, unescaped[0..written]);
}

pub fn globMatch(pattern: Handle, to_check: Handle, case_insensitive: bool) !bool {
    const pattern_str = try pattern.getString();
    const to_check_str = try to_check.getString();

    return strutil.globMatch(pattern_str, to_check_str, case_insensitive);
}

pub fn compare(a: Handle, b: Handle, up_to_cp: ?usize, case_insensitive: bool) !std.math.Order {
    const a_str = try a.getString();
    const b_str = try b.getString();

    return strutil.compare(a_str, b_str, up_to_cp, case_insensitive);
}

// Integer related functions
pub fn newInteger(value: i64) !Handle {
    const handle = try Heap.createObject();
    handle.peek().head.tag = .integer;
    handle.peek().body.integer = value;
    return handle;
}

pub fn integerObject(value: i64) Heap.Object {
    return .{
        .head = .{ .str = Heap.Object.null_string, .tag = .integer },
        .body = .{ .integer = value },
    };
}

pub fn integerOverflowError(det: ?*ErrorDetails, value: ?[]const u8) error{ OutOfMemory, IntegerOverflow } {
    if (det) |details| {
        if (value) |val| {
            details.* = .{
                .message = try newStringFmt("integer value \"{s}\" too big to be represented", .{val}),
            };
        } else {
            details.* = .{
                .message = try newString("integer overflow"),
            };
        }
    }
    return error.IntegerOverflow;
}

pub fn integerOverflowErrorWithWide(det: ?*ErrorDetails, value: i128) error{ OutOfMemory, IntegerOverflow } {
    var buf: [std.fmt.count("{}", .{std.math.minInt(i128)})]u8 = undefined;
    const as_str = std.fmt.bufPrint(&buf, "{}", .{value}) catch unreachable;
    return integerOverflowError(det, as_str);
}

pub fn integerGetNoShimmer(det: ?*ErrorDetails, handle: Handle) !i64 {
    if (handle.tag() == .integer) return handle.peek().body.integer;

    const bytes = try handle.getString();
    if (std.fmt.parseInt(i64, bytes, 10)) |integer| {
        return integer;
    } else |err| switch (err) {
        error.InvalidCharacter => {
            if (det) |details| details.* = .{
                .message = try newStringFmt("expected integer but got \"{s}\"", .{bytes}),
            };
            return error.BadInteger;
        },
        error.Overflow => {
            return integerOverflowError(det, bytes);
        },
    }
}

pub fn shimmerToInteger(det: ?*ErrorDetails, wb: *Shimmerable) !void {
    if (wb.tag() == .integer) return;

    const value: i64 = try integerGetNoShimmer(det, wb.current());

    try wb.prepareToShimmer();
    wb.peek().head.tag = .integer;
    wb.peek().body.integer = value;
}

pub fn integerGet(det: ?*ErrorDetails, wb: *Shimmerable) !i64 {
    try shimmerToInteger(det, wb);
    return wb.peek().body.integer;
}

// Float related functions.
pub fn newFloat(value: f64) !Handle {
    const handle = try Heap.createObject();
    handle.peek().head.tag = .float;
    handle.peek().body.float = value;
    return handle;
}

pub fn floatGetNoShimmer(det: ?*ErrorDetails, handle: Handle) !f64 {
    if (handle.tag() == .float) return handle.peek().body.float;

    const bytes = try handle.getString();
    if (std.fmt.parseFloat(f64, bytes)) |float| {
        return float;
    } else |err| switch (err) {
        error.InvalidCharacter => {
            if (det) |details| details.* = .{
                .message = try newStringFmt("expected floating-point number but got \"{s}\"", .{bytes}),
            };
            return error.BadFloat;
        },
    }
}

pub fn shimmerToFloat(det: ?*ErrorDetails, wb: *Shimmerable) !void {
    if (wb.tag() == .float) return;

    const value = try floatGetNoShimmer(det, wb.current());

    try wb.prepareToShimmer();
    wb.peek().head.tag = .float;
    wb.peek().body.float = value;
}

pub fn floatGet(det: ?*ErrorDetails, wb: *Shimmerable) !i64 {
    try shimmerToFloat(det, wb);
    return wb.peek().body.float;
}

///////////////////////////////
//  Index related functions  //

/// `start` is inclusive, `end` is exclusive. (Note, this is different from Tcl's
/// convention, where both are inclusive. `fromIndexes` accounts for this when
/// running the conversion).
pub const Range = struct {
    start: usize,
    end: usize,

    /// This properly accounts for both `start` and `end` being inclusive, per tcl convention.
    pub fn fromIndexes(list_len: u32, start_index: Heap.ListIndex, end_index: Heap.ListIndex) Range {
        var start = start_index.asAbsoluteIndex(list_len);
        // Convert inclusive to exclusive with `+ 1`.
        var end = end_index.asAbsoluteIndex(list_len) + 1;

        if (start < 0) start = 0;
        if (end < 0) end = 0;
        if (end > list_len) end = list_len;

        return .{
            .start = @intCast(start),
            .end = @intCast(end),
        };
    }
};

/// Sets the details to a bad index message, and returns error.BadIndex.
fn badIndexError(det: ?*ErrorDetails, handle: Handle) error{ OutOfMemory, BadIndex } {
    if (det) |details| {
        const err_msg = newStringFmt(
            "bad index \"{f}\": must be intexpr or end?[+-]intexpr?",
            .{handle},
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            inline else => unreachable,
        };
        details.* = .{ .message = err_msg };
    }

    return error.BadIndex;
}

/// Shimmers to an index representation.
pub fn shimmerToIndex(det: ?*ErrorDetails, wb: *Shimmerable) !void {
    if (wb.tag() == .index) return;

    const bytes = try wb.current().getString();

    const index: Heap.ListIndex = blk: {
        // Does it start with "end"? If so, it might be end+5, or end-2, etc
        if (bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], "end")) {
            if (bytes.len >= 4) {
                if (bytes[3] != '+' and bytes[3] != '-') return badIndexError(det, wb.current());

                const index_offset = std.fmt.parseInt(i33, bytes[3..], 10) catch return badIndexError(det, wb.current());
                break :blk .{
                    .u = .{ .end_offset = index_offset },
                    .is_relative = true,
                };
            }

            break :blk Heap.ListIndex.end;
        } else {
            break :blk .{ .u = .{ .index = .{
                .data = std.fmt.parseInt(u32, bytes, 10) catch return badIndexError(det, wb.current()),
            } }, .is_relative = false };
        }
    };

    try wb.prepareToShimmer();
    wb.peek().head.tag = .index;
    wb.peek().body = .{ .index = .{ .data = index } };
}

pub fn getIndex(det: ?*ErrorDetails, wb: *Shimmerable) !Heap.ListIndex {
    // Fast case: if it's an integer or float, we can quickly cast it (don't
    // shimmer though, as it'll probably still be used for its original purpose)
    if (wb.tag() == .integer) {
        const integer = wb.peek().body.integer;
        if (integer < 0) return badIndexError(det, wb.current());
        if (integer > std.math.maxInt(u32)) return badIndexError(det, wb.current());

        return .{ .u = .{ .index = .{ .data = @intCast(integer) } }, .is_relative = false };
    } else if (wb.tag() == .float) {
        const float = wb.peek().body.float;

        if (std.math.isNan(float)) return badIndexError(det, wb.current());
        if (float < 0) return badIndexError(det, wb.current());
        if (float > std.math.maxInt(u32)) return badIndexError(det, wb.current());

        return .{ .u = .{ .index = .{ .data = @intFromFloat(float) } }, .is_relative = false };
    }

    try shimmerToIndex(det, wb);
    return wb.peek().body.index.data;
}

pub fn getRange(det: ?*ErrorDetails, list_len: u32, start: *Shimmerable, end: *Shimmerable) !Range {
    const start_index = try getIndex(det, start);
    const end_index = try getIndex(det, end);
    return Range.fromIndexes(list_len, start_index, end_index);
}

/// Creates a substring of the passed in string. Used in `[string range]`.
pub fn stringRange(det: ?*ErrorDetails, str: *Shimmerable, start: *Shimmerable, end: *Shimmerable) !Handle {
    const codepoint_len = try getCodepointLength(str);
    const bytes = try str.current().getString();

    const start_index = try getIndex(det, start);
    const end_index = try getIndex(det, end);

    const range = Range.fromIndexes(@intCast(codepoint_len), start_index, end_index);

    // cpIndex is generic across ASCII and UTF-8.
    const byte_start = strutil.cpIndex(bytes, range.start) orelse return Heap.local_heap.emptyHandle();
    const byte_end = strutil.cpIndex(bytes, range.end) orelse bytes.len;

    return try newStringWithCodepointLen(bytes[byte_start..byte_end], range.end - range.start);
}

/// Removes from `start` to `end`, optionally inserting `to_insert`.
pub fn stringReplace(
    det: ?*ErrorDetails,
    str: *Shimmerable,
    start: *Shimmerable,
    end: *Shimmerable,
    to_insert: OptionalHandle,
) Handle {
    const codepoint_len = try getCodepointLength(str);
    const bytes = str.current().getString();

    const start_index = try getIndex(det, start);
    const end_index = try getIndex(det, end);

    const range = try Range.fromIndexes(det, codepoint_len, start_index, end_index);

    const byte_start = strutil.cpIndex(bytes, range.start);
    const byte_end = strutil.cpIndex(bytes, range.end);

    const replaced: []u8 = blk: {
        // Is there anything to insert?
        if (to_insert.toHandle()) |val| {
            const to_insert_bytes = try val.getString();

            // Figure out how long the new string needs to be.
            const up_to_range_len = byte_start;
            const to_insert_len = to_insert_bytes.len;
            // Tcl ranges are inclusive, so `- 1` is needed.
            const after_range_len = bytes.len - byte_end - 1;

            var new_bytes = try Heap.global_gpa.alloc(u8, up_to_range_len + to_insert_len + after_range_len);
            @memcpy(new_bytes[0..up_to_range_len], bytes[0..up_to_range_len]);
            @memcpy(new_bytes[up_to_range_len..][0..to_insert_len], to_insert_bytes);
            @memcpy(new_bytes[(up_to_range_len + to_insert_len)..], bytes[(byte_end + 1)..]);

            break :blk new_bytes;
        } else {
            // Figure out how long the new string needs to be.
            const up_to_range_len = byte_start;
            // Tcl ranges are inclusive, so `- 1` is needed.
            const after_range_len = bytes.len - byte_end - 1;

            var new_bytes = try Heap.global_gpa.alloc(u8, up_to_range_len + after_range_len);
            @memcpy(new_bytes[0..up_to_range_len], bytes[0..up_to_range_len]);
            @memcpy(new_bytes[up_to_range_len..], bytes[(byte_end + 1)..]);

            break :blk new_bytes;
        }
    };
    defer Heap.global_gpa.free(replaced);

    return try newString(replaced);
}

/// Upper/lower/title case conversion.
pub fn stringCaseConversion(str: Handle, mode: enum { upper, lower, title }) !Handle {
    const bytes = try str.getString();

    if (options.use_utf8) {
        // Go through once to calculate the length.
        var new_len: usize = 0;
        var iter = strutil.Iterator.init(bytes);
        var is_first_char = true;
        while (iter.next()) |cp| {
            const converted = blk: {
                switch (mode) {
                    .upper => break :blk strutil.toUpper(cp),
                    .lower => break :blk strutil.toLower(cp),
                    .title => {
                        if (is_first_char) {
                            break :blk strutil.toTitle(cp);
                        } else {
                            break :blk strutil.toLower(cp);
                        }
                    },
                }
            };

            new_len += std.unicode.utf8ByteSequenceLength(converted);
            is_first_char = false;
        }

        var new_bytes = try Heap.global_gpa.alloc(u8, new_len);
        defer Heap.global_gpa.free(new_bytes);

        // Now go through and write all the bytes.
        iter = strutil.Iterator.init(bytes);
        var written: usize = 0;
        is_first_char = true;
        while (iter.next()) |cp| {
            const converted = blk: {
                switch (mode) {
                    .upper => break :blk strutil.toUpper(cp),
                    .lower => break :blk strutil.toLower(cp),
                    .title => {
                        if (is_first_char) {
                            break :blk strutil.toTitle(cp);
                        } else {
                            break :blk strutil.toLower(cp);
                        }
                    },
                }
            };
            written += std.unicode.utf8Encode(converted, new_bytes[written..]) catch unreachable;

            is_first_char = false;
        }

        return try newString(new_bytes);
    } else {
        const new_bytes = try Heap.global_gpa.alloc(bytes.len);
        defer Heap.global_gpa.free(new_bytes);

        for (bytes, new_bytes) |old_char, *new_char| {
            if (mode == .upper) {
                new_char.* = strutil.toUpper(old_char);
            } else {
                new_char.* = strutil.toLower(old_char);
            }
        }

        return try newString(new_bytes);
    }
}

/// Creates a new string if there was anything to trim.
pub fn stringTrimLeft(str: Handle, trim_chars: Handle) !Handle {
    const bytes = try str.getString();
    const trim_chars_bytes = try trim_chars.getString();

    const start = strutil.trimLeft(bytes, trim_chars_bytes);

    if (start == 0) {
        return str;
    } else {
        return try newString(bytes[start..]);
    }
}

/// Creates a new string if there was anything to trim, else passes `str` through.
pub fn stringTrimRight(str: Handle, trim_chars: Handle) !Handle {
    const bytes = try str.getString();
    const trim_chars_bytes = try trim_chars.getString();

    const end = strutil.trimRight(bytes, trim_chars_bytes);

    if (end == bytes.len) {
        return str;
    } else {
        return try newString(bytes[0..end]);
    }
}

/// Creates a new string if there was anything to trim, else passes `str` through.
pub fn stringTrim(str: Handle, trim_chars: Handle) !Handle {
    const bytes = try str.getString();
    const trim_chars_bytes = try trim_chars.getString();

    const start = strutil.trimLeft(bytes, trim_chars_bytes);
    const end = strutil.trimRight(bytes, trim_chars_bytes);

    if (start == 0 and end == bytes.len) {
        return str;
    } else {
        return try newString(bytes[start..end]);
    }
}

//////////////////////////////
//  Enum related functions  //

/// Enum names joined by ", "
pub fn enumNames(comptime T: type, comptime joiner: []const u8) []const u8 {
    return comptime blk: {
        var result: []const u8 = @tagName(std.enums.values(T)[0]);
        for (std.enums.values(T)[1..]) |value| {
            result = &(result[0..].* ++ joiner[0..].* ++ @tagName(value).*);
        }

        break :blk result;
    };
}

pub fn EnumMapping(comptime T: type, include_numbers: bool) type {
    comptime {
        @setEvalBranchQuota(20000);

        const values = std.enums.values(T);

        // Fill out the mapping.
        const final_entries = blk: {
            if (include_numbers) {
                var entries: [values.len * 2]struct { []const u8, T } = undefined;
                for (values, 0..) |value, i| {
                    entries[i * 2] = .{ @tagName(value), value };
                    // Add an entry for the integer value of the enum, to match Tcl behavior.
                    entries[i * 2 + 1] = .{ std.fmt.comptimePrint("{}", .{@intFromEnum(value)}), value };
                }
                break :blk entries;
            } else {
                var entries: [values.len]struct { []const u8, T } = undefined;
                for (values, 0..) |value, i| {
                    entries[i] = .{ @tagName(value), value };
                }
                break :blk entries;
            }
        };

        // Create the table
        return struct {
            pub const StaticStringMap = std.StaticStringMap(T);

            map: StaticStringMap = StaticStringMap.initComptime(final_entries),
        };
    }
}

pub fn TclEnum(comptime T: type, enum_name: []const u8, include_numbers: bool) type {
    return struct {
        pub const Variants = T;
        pub const map = (EnumMapping(T, include_numbers){}).map;
        pub const names = enumNames(T, ", ");

        pub fn get(det: ?*ErrorDetails, wb: *Shimmerable) !T {
            try wb.prepareToShimmer();

            // TODO PERF we can optimize this by shimmering the value to an "enum" type,
            // where the enum type has a u48 storing the hash of enum_name and a u16 for
            // which variant it is, by index.
            const bytes = try wb.current().getString();
            const variant = map.get(bytes);
            if (variant) |val| {
                return val;
            } else {
                if (det) |details| details.* = .{
                    .message = try newStringFmt("bad {s} \"{s}\": must be {s}", .{ enum_name, bytes, names }),
                };

                return error.BadEnumVariant;
            }
        }
    };
}

test "enum mapping" {
    const Things = enum { foo, bar, baz };
    const map = (EnumMapping(Things, false){}).map;
    const names = enumNames(Things, ", ");
    try testing.expectEqual(Things.foo, map.get("foo"));
    try testing.expectEqualSlices(u8, "foo, bar, baz", names);
}

test "tcl enum" {
    defer Heap.testFinish();
    try Heap.testStart(testing.allocator, testing.io);

    const MyEnum = enum { foo, bar, baz };
    const MyTclEnum = TclEnum(MyEnum, "myenum", true);

    var foo_str = try newString("foo");
    defer foo_str.decrRefCount();
    var one_str = try newString("1");
    defer one_str.decrRefCount();
    var bad_str = try newString("bad");
    defer bad_str.decrRefCount();

    var working: Shimmerable = .{ .original = foo_str, .shimmered = .none };
    try testing.expectEqual(MyEnum.foo, MyTclEnum.get(null, &working));
    working.discardChanges();
    working = .{ .original = one_str };
    try testing.expectEqual(MyEnum.bar, MyTclEnum.get(null, &working));
    working.discardChanges();
    working = .{ .original = bad_str };
    try testing.expectError(error.BadEnumVariant, MyTclEnum.get(null, &working));
    working.discardChanges();
}

fn generateSubcommandUsage(comptime Enum: type, args: []Shimmerable) !Handle {
    return try newStringFmt(
        "Usage: \"{f} command ... \", where command is one of: {s}",
        .{ args[0].current(), enumNames(Enum, ", ") },
    );
}

pub fn SubcommandParser(
    comptime Enum: type,
    comptime subcommands: []const struct {
        variant: Enum,
        usage: []const u8,
        min_args: u32 = 0,
        max_args: ?u32 = null,
        stride: u32 = 1,
    },
) type {
    const Subcommand = @typeInfo(@TypeOf(subcommands)).pointer.child;

    comptime assert(std.enums.values(Enum).len == subcommands.len);

    return struct {
        // Create a mapping from subcommand name -> Enum.
        pub const NameToEnum = (EnumMapping(Enum, false){}).map;
        // As well as a mapping from Enum -> subcommand.
        pub const EnumToSubcommand = blk: {
            const variants = std.enums.values(Enum);

            var converted_mapping: std.enums.EnumFieldStruct(Enum, Subcommand, null) = undefined;
            for (0..variants.len) |i| {
                const value = @tagName(variants[i]);
                assert(subcommands[i].variant == variants[i]);
                @field(converted_mapping, value) = subcommands[i];
            }

            break :blk std.EnumArray(Enum, Subcommand).init(converted_mapping);
        };

        const space_joined_names = enumNames(Enum, " ");
        const comma_joined_names = enumNames(Enum, ",");

        /// `args` should include the original command name.
        pub fn parse(det: ?*ErrorDetails, args: []Shimmerable) !Enum {
            if (args.len < 2) {
                if (det) |details| details.* = .{
                    .message = try newStringFmt(
                        \\wrong # args: should be "{f} command ..."
                        \\Use "{f} -help ?command?" for help
                    , .{ args[0].current(), args[0].current() }),
                };
                return error.WrongUsage;
            }

            // TODO PERF cache the subcommand lookup.

            if (try args[1].current().equalsString("-help")) {
                if (args.len >= 3) {
                    const subcommand_queried = try args[2].getString();

                    // Generate help for a specific subcommand, if the subcommand exists.
                    if (NameToEnum.get(subcommand_queried)) |val| {
                        const subcommand = EnumToSubcommand.get(val);
                        if (det) |details| details.* = .{
                            .message = try newStringFmt(
                                \\Usage: "{f} {s} {s}"
                            , .{ args[0].current(), subcommand_queried, subcommand.usage }),
                        };
                        return error.UsageHelp;
                    }

                    // Else, fall through to the general usage.
                }
                if (det) |details| details.* = .{ .message = try generateSubcommandUsage(Enum, args) };
                return error.UsageHelp;
            }

            if (try args[1].current().equalsString("-commands")) {
                if (det) |details| details.* = .{ .message = try newString(space_joined_names) };
                return error.UsageHelp;
            }

            const subcommand_name = try args[1].getString();
            const subcommand_enum = NameToEnum.get(subcommand_name) orelse {
                if (det) |details| details.* = .{
                    .message = try newStringFmt(
                        \\{f}, unknown command "{f}": should be {s}
                    , .{ args[0].current(), args[1].current(), space_joined_names }),
                };
                return error.WrongUsage;
            };
            const subcommand = EnumToSubcommand.get(subcommand_enum);

            // Now that we've gotten the usage, we need to make sure that we have the right
            // number of arguments.
            const correct_arg_count = blk: {
                if (args.len - 2 < subcommand.min_args) break :blk false;
                if (subcommand.max_args) |max_args| if (args.len - 2 > max_args) break :blk false;
                if (@mod(args.len - 2, subcommand.stride) != 0) break :blk false;
                break :blk true;
            };
            if (!correct_arg_count) {
                if (det) |details| details.* = .{
                    .message = try newStringFmt(
                        \\wrong # args: should be "{s}"
                    , .{subcommand.usage}),
                };
                return error.WrongUsage;
            }

            return subcommand_enum;
        }
    };
}

test "subcommand parser" {
    const Parser = SubcommandParser(enum { foo }, &.{
        .{ .variant = .foo, .usage = "arg1 arg2 ?arg3?", .min_args = 2, .max_args = 3 },
    });

    defer Heap.testFinish();
    try Heap.testStart(testing.allocator, testing.io);

    var base_str: Shimmerable = .{ .original = try newString("base") };
    defer base_str.deinit();
    var foo_str: Shimmerable = .{ .original = try newString("foo") };
    defer foo_str.deinit();
    var arg1_str: Shimmerable = .{ .original = try newString("arg1") };
    defer arg1_str.deinit();
    var arg2_str: Shimmerable = .{ .original = try newString("arg2") };
    defer arg2_str.deinit();
    var arg3_str: Shimmerable = .{ .original = try newString("arg3") };
    defer arg3_str.deinit();

    var args = [_]Shimmerable{ base_str, foo_str, arg1_str, arg2_str };
    try testing.expectEqual(.foo, try Parser.parse(null, &args));

    var args2 = [_]Shimmerable{ base_str, foo_str, arg1_str };
    try testing.expectError(error.WrongUsage, Parser.parse(null, &args2));
}

/// Runs a string check based on requested class. `class_to_check` must be shimmerable.
pub fn stringIs(det: ?*ErrorDetails, str: Handle, class_to_check: *Shimmerable, strict: bool) !bool {
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
    }, "class", false);

    const class = try Class.get(det, class_to_check);

    const bytes = try str.getString();
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
            var str_wb: Shimmerable = .{ .original = str };
            defer str_wb.discardChanges();
            _ = getBoolean(null, &str_wb) catch break :blk false;
            break :blk true;
        },
        .alpha => strutil.checkAllAscii(bytes, std.ascii.isAlphabetic),
        .alnum => strutil.checkAllAscii(bytes, std.ascii.isAlphanumeric),
        .ascii => strutil.checkAllAscii(bytes, std.ascii.isAscii),
        .digit => strutil.checkAllAscii(bytes, std.ascii.isDigit),
        .lower => strutil.checkAllAscii(bytes, std.ascii.isLower),
        .upper => strutil.checkAllAscii(bytes, std.ascii.isUpper),
        .space => strutil.checkAllAscii(bytes, std.ascii.isWhitespace),
        .xdigit => strutil.checkAllAscii(bytes, strutil.isHexDigit),
        .control => strutil.checkAllAscii(bytes, std.ascii.isControl),
        .print => strutil.checkAllAscii(bytes, std.ascii.isPrint),
        .graph => strutil.checkAllAscii(bytes, strutil.isGraph),
        .punct => strutil.checkAllAscii(bytes, strutil.isPunct),
    };
}

fn testStringIs(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    try Heap.testStart(ta, testing.io);

    var str = try newString("abcdefg");
    defer str.decrRefCount();
    var str2 = try newString("abcdefg123");
    defer str2.decrRefCount();
    var class = try newString("alpha");
    defer class.decrRefCount();
    var bad_class = try newString("bad_class");
    defer bad_class.decrRefCount();
    var det: ErrorDetails = undefined;

    var wb: Shimmerable = .{ .original = class };
    try testing.expectEqual(true, try stringIs(null, str, &wb, false));
    try testing.expectEqual(false, try stringIs(null, str2, &wb, false));
    wb.discardChanges();
    wb = .{ .original = bad_class };
    const err = stringIs(&det, str, &wb, false);
    if (err == error.OutOfMemory) return error.OutOfMemory;
    try testing.expectError(error.BadEnumVariant, err);
    try testing.expectEqualStrings(
        "bad class \"bad_class\": must be integer, alpha, alnum, ascii, digit, " ++
            "double, lower, upper, space, xdigit, control, print, graph, punct, boolean",
        try det.message.getString(),
    );
    det.message.decrRefCount();
    wb.discardChanges();
}

test "string is" {
    try testing.checkAllAllocationFailures(testing.allocator, testStringIs, .{});
}

pub fn convertTokenizerError(err: Tokenizer.Error) error{OutOfMemory}!ErrorDetails {
    const message = switch (err) {
        error.CharactersAfterCloseBrace => try newString("extra characters after close-brace"),
        error.MissingCloseBrace => try newString("missing close-brace"),
        error.MissingCloseBracket => try newString("unmatched \"[\""),
        error.MissingCloseQuote => try newString("missing quote"),
        error.TrailingBackslash => try newString("no character after \\"),
        error.FunctionMissingParentheses => try newString("function missing parentheses"),
        error.NotOperator => try newString("not operator"),
        error.NotNumber => try newString("not number"),
        error.NotVariable => unreachable,
    };

    return .{ .message = message };
}

pub fn newListWithCapacity(capacity: u32) !Handle {
    // `1 +` to make space for the list's head
    const list_index = try Heap.local_heap.createObjects(1 + capacity, false);
    const list_head = Heap.local_heap.getLocalObject(list_index);

    list_head.* = .{
        .head = .{
            .str = Heap.Object.null_string,
            .tag = .list,
        },
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
        item.* = handle.dupOrRef();
    }

    return list;
}

pub fn newListFromShimmerables(writebacks: []const Shimmerable) !Handle {
    const list = try newListWithCapacity(@intCast(writebacks.len));
    errdefer list.decrRefCount();

    for (writebacks) |wb| listAppendAssumeCapacity(list, wb.current().dupOrRef());

    return list;
}

/// `handle` must be shimmerable. Returns a new object if the list had to move.
pub fn shimmerToList(det: ?*ErrorDetails, wb: *Shimmerable) !void {
    if (wb.tag() == .list) return;

    // Optimise dict -> list.
    if (wb.tag() == .dict) {
        // Only need to ensure it's shimmerable in this case, since
        // in the other case we duplicate it anyways.
        const len = wb.peek().body.dict.len;

        try Heap.ensureMutableOrDup(wb.current(), &wb.shimmered);

        // Because both lists and dicts store their values directly after,
        // we can just swap out the head to convert to a list. Don't call
        // `prepareToShimmer` because that would invalidate the dict items,
        // but we want to reuse them as list items.
        _ = try wb.current().getString();

        // Clean up dict-specific resources (table and extra_data).
        const heap = wb.current().getHeap();
        heap.destroyExtraData(wb.peek().body.dict.extra_data);

        wb.peek().head.tag = .list;
        wb.peek().body = .{ .list = .{ .len = len } };

        return;
    } else {
        // No need to duplicate the handle if it can't shimmer, we have to create
        // a new object anyways.

        // Try to preserve information about filename / line number.
        const source_info: ?SourceInfo = getSourceInfo(wb.current());
        var file_name: OptionalHandle = .none;
        var line_no: u32 = 1;
        if (source_info) |info| {
            line_no = info.line_no;
            file_name = info.file_name.borrowOptional();
        }
        defer file_name.swapWithNone();

        const str = try wb.current().getString();
        var parser = Tokenizer.init(str, line_no);

        // Figure out how many tokens there are, so we can create the correct list size
        // in the heap.file_name
        var tokens: std.ArrayList(Tokenizer.Token) = .empty;
        defer tokens.deinit(Heap.global_gpa);

        while (true) {
            const next_token = parser.nextListToken() catch |err| {
                if (det) |details| details.* = try convertTokenizerError(err);
                return err;
            };
            switch (next_token.tag) {
                .simple_string, .escaped_string => {
                    try tokens.append(Heap.global_gpa, next_token);
                },
                .end_of_file => break,
                else => {
                    // Skip any line breaks or word breaks.
                },
            }
        }

        // TODO PERF reuse the object backing if it was allocated with more than one object.
        var new_list = try newListWithCapacity(@intCast(tokens.items.len));
        errdefer new_list.decrRefCount();
        new_list.peek().body.list.len = @intCast(tokens.items.len);

        for (tokens.items, 0..) |token, i| {
            const item = listItemNoFollow(new_list, @intCast(i));

            if (token.tag == .escaped_string) {
                // Needs escaping. We'll create another string to copy the escaped string into.
                setStringFromEscaped(item, str[token.loc.start..token.loc.end]) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.OtherThreadSet => unreachable,
                };
            } else {
                // Normal string, so no escaping needed.
                Heap.setString(item, str[token.loc.start..token.loc.end]) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.OtherThreadSet => unreachable,
                };
            }

            try setSourceInfo(item, .{ .file_name = file_name.borrowOptional(), .line_no = token.loc.line_no });
        }

        wb.shimmered.swap(new_list);
    }
}

/// Caller is responsible to ensure `list` is of type .list.
pub fn listLength(list: Handle) u32 {
    assert(list.tag() == .list);

    return list.peek().body.list.len;
}

pub fn listLengthShimmering(det: ?*ErrorDetails, wb: *Shimmerable) !u32 {
    try shimmerToList(det, wb);
    return wb.peek().body.list.len;
}

pub fn followIfRef(handle: Handle) Handle {
    if (handle.tag() == .reference) return handle.peek().body.reference;
    return handle;
}

pub fn collectionItemNoFollow(handle: Handle, index: u32, len: u32) Handle {
    handle.assert(handle.tag() == .list or handle.tag() == .dict);
    handle.assert(index < len);

    return .{
        .index = handle.index + 1 + index,
        .heap = handle.heap,
    };
}

fn collectionItemFollowRefs(handle: Handle, index: u32, len: u32) Heap.Handle {
    assert(handle.tag() == .list or handle.tag() == .dict);

    if (index < len) {
        const elem: Heap.Handle = .{
            .index = handle.index + 1 + index,
            .heap = handle.heap,
        };

        return followIfRef(elem);
    } else unreachable;
}

pub fn collectionItems(handle: Handle, len: u32) []Heap.Object {
    assert(handle.tag() == .list or handle.tag() == .dict);

    return handle.getHeap().objectSlice(handle.index + 1, handle.index + 1 + len);
}

/// The reason this returns a new object instead of having a `new_handle` parameter is
/// that we need to prevent a situation where `provided_handle` and the theoretical
/// `new_handle` alias, as that would lead to UAF. TODO: I've redesigned how out
/// parameters work, so this should be switched to the new system.
fn setCollectionLengthInner(original: Handle, new_len: u32) !OptionalHandle {
    const current_len = blk: {
        switch (original.tag()) {
            .list => break :blk original.peek().body.list.len,
            .dict => break :blk original.peek().body.dict.len,
            else => unreachable,
        }
    };

    // If it's the same length, no need to do anything.
    if (current_len == new_len) return .none;

    new_collection_needed: {
        // We can only do these quick changes if the collection can mutate in-place.
        if (!original.canMutate()) break :new_collection_needed;

        // No need to realloc if we're shrinking.
        if (new_len < current_len) {
            // We need to check if any of the abandoned items are shared. If so, we'll need to
            // split this collection and create a new one.
            const freed_count = current_len - new_len;
            for (0..freed_count) |to_free| {
                const to_free_handle = collectionItemFollowRefs(original, @intCast(current_len - freed_count + to_free), current_len);
                if (!to_free_handle.canShimmer()) break :new_collection_needed;
            }

            // Be sure to free the abandoned items when we shrink.
            for (0..freed_count) |to_free| {
                const to_free_handle = collectionItemFollowRefs(original, @intCast(current_len - freed_count + to_free), current_len);
                // If a dict, be sure to remove the keys from the table.
                if (original.tag() == .dict and @mod(to_free, 2) == 0) {
                    if (original.getDictExtraData().table) |*table| {
                        _ = table.remove(to_free_handle);
                    }
                }

                to_free_handle.invalidateBoth();
            }

            switch (original.tag()) {
                .list => original.peek().body.list.len = new_len,
                .dict => original.peek().body.dict.len = new_len,
                else => unreachable,
            }

            return .none;
        } else {
            // Even if there's not enough length, there may be enough capacity.
            const capacity = memutil.getOrderSize(original.getMetadata().order) - 1; // -1 for list head
            if (new_len <= capacity) {
                switch (original.tag()) {
                    .list => original.peek().body.list.len = new_len,
                    .dict => original.peek().body.dict.len = new_len,
                    else => unreachable,
                }

                return .none;
            }
        }
    }

    // We've exhausted all other options, so we'll need to make a new collection.
    const new_handle = switch (original.tag()) {
        .list => try newListWithCapacity(new_len),
        .dict => try newDictWithCapacity(new_len),
        else => unreachable,
    };
    errdefer new_handle.decrRefCount();
    const new_items = collectionItems(new_handle, new_len);

    // If the collection is shared, we need to duplicate all the items.
    for (0..current_len, new_items[0..current_len]) |i, *new_item| {
        new_item.* = collectionItemFollowRefs(original, @intCast(i), new_len).dupOrRef();
    }

    switch (new_handle.tag()) {
        .dict => new_handle.peek().body.dict.len = new_len,
        .list => new_handle.peek().body.list.len = new_len,
        else => unreachable,
    }

    return new_handle.toOptional();
}

fn setCollectionLength(wb: *Mutable, new_len: u32) !void {
    wb.mutated.swapIfNew(try setCollectionLengthInner(wb.current(), new_len));
}

/// Assumes provided handle is a list.
pub fn listItemNoFollow(handle: Handle, index: u32) Handle {
    assert(handle.tag() == .list);

    return collectionItemNoFollow(handle, index, handle.peek().body.list.len);
}

/// Assumes provided handle is a list.
pub fn listItem(handle: Handle, index: u32) Handle {
    assert(handle.tag() == .list);

    return collectionItemFollowRefs(handle, index, handle.peek().body.list.len);
}

/// Assumes handle is a list.
pub fn listItems(handle: Handle) []Heap.Object {
    assert(handle.tag() == .list);

    return handle.getHeap().objects.items(.object)[(handle.index + 1)..][0..handle.peek().body.list.len];
}

/// Takes ownership of `value` in all cases, including errors. Does not invalidate the string.
/// Must already be a list. Not atomic.
pub fn listSetInner(wb: *Mutable, index: u32, value: Heap.Object) error{OutOfMemory}!void {
    wb.current().assert(wb.tag() == .list);

    var value_mut = value;
    errdefer value_mut.deinitSingle(Heap.local_heap);

    // Make sure this item can mutate, as well as this list.
    if (!wb.current().canMutate() or !listItemNoFollow(wb.current(), index).canMutate()) {
        wb.mutated.swap(try wb.current().duplicate());
    }

    // We know that this item is now safe to modify.
    const item = listItemNoFollow(wb.current(), index);
    item.assert(item.canMutate());

    item.invalidateBoth(); // Clear the last value.
    item.peek().* = value_mut.take();
}

/// Must already be a list.
pub fn listSetObject(det: ?*ErrorDetails, wb: *Mutable, index: u32, value: Heap.Object) !void {
    try listSetInner(det, wb, index, value);
    wb.current().invalidateString();
}

pub fn listAppendObject(det: ?*ErrorDetails, wb: *Mutable, item: Heap.Object) !u32 {
    const len = try listLengthShimmering(det, wb.asShimmerable());
    try setCollectionLength(wb, len + 1);

    const index = wb.peek().body.list.len - 1;
    listItems(wb.current())[index] = item;

    return index;
}

pub fn listAppend(det: ?*ErrorDetails, wb: *Mutable, item: Handle) !Handle {
    const index = try listAppendObject(det, wb, item.dupOrRef());
    return listItemNoFollow(wb.current(), index);
}

/// `list` must be mutable.
pub fn listAppendAssumeCapacity(list: Handle, object: Heap.Object) void {
    list.assert(list.tag() == .list);
    list.assert(list.canMutate());

    const current_len = list.peek().body.list.len;
    // -2 for list head and new item.
    list.assert(current_len <= memutil.getOrderSize(list.getMetadata().order) - 2);
    list.peek().body.list.len += 1;

    listItemNoFollow(list, current_len).peek().* = object;
}

pub fn listToHandles(gpa: std.mem.Allocator, list: Handle) !std.ArrayList(Handle) {
    // TODO PERF this shouldn't have to exist. Maybe instead of functions taking
    // in []Handle, they take in []Object?
    const list_len = listLength(list);
    var handles = try std.ArrayList(Handle).initCapacity(gpa, list_len);
    for (0..list_len) |i| {
        handles.appendAssumeCapacity(listItemNoFollow(list, @intCast(i)));
    }
    return handles;
}

pub fn listToShimmerables(gpa: std.mem.Allocator, list: Handle) !std.ArrayList(Shimmerable) {
    // TODO PERF this shouldn't have to exist. Maybe instead of functions taking
    // in []Handle, they take in []Object?
    const list_len = listLength(list);
    var handles = try std.ArrayList(Shimmerable).initCapacity(gpa, list_len);
    for (0..list_len) |i| {
        handles.appendAssumeCapacity(.{ .original = listItemNoFollow(list, @intCast(i)) });
    }
    return handles;
}

fn testLists(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    try Heap.testStart(ta, testing.io);

    var det: ErrorDetails = undefined;

    // Simple case: two objects in a list
    const obj1 = try newString("object 1");
    defer obj1.decrRefCount();
    const obj2 = try newString("object 2");
    defer obj2.decrRefCount();
    var list1 = try newList(&.{ obj1, obj2 });
    defer list1.decrRefCount();

    const items = listItems(list1);
    try testing.expectEqual(2, items.len);
    // The object should have been copied when being moved into the list
    try testing.expect(obj1.peek() != &items[0]);
    // But it should have an identical string
    try testing.expectEqualStrings("object 1", try listItemNoFollow(list1, 0).getString());

    const to_append = try newString("appended item");
    defer to_append.decrRefCount();

    var list1_wb: Mutable = .{ .original = list1 };
    defer list1_wb.discardChanges();
    _ = try listAppend(&det, &list1_wb, to_append);
    try testing.expectEqualStrings("appended item", try listItemNoFollow(list1_wb.current(), 2).getString());

    var string_list: Shimmerable = .{ .original = try newString(
        \\item1 {item 2} item\ 3
    ) };
    defer string_list.deinit();

    try shimmerToList(&det, &string_list);
    try testing.expect(string_list.original != string_list.shimmered.toHandle());
    try testing.expectEqualStrings("item1", try listItemNoFollow(string_list.current(), 0).getString());
    try testing.expectEqualStrings("item 2", try listItemNoFollow(string_list.current(), 1).getString());
    try testing.expectEqualStrings("item 3", try listItemNoFollow(string_list.current(), 2).getString());
}

test "lists" {
    try testing.checkAllAllocationFailures(testing.allocator, testLists, .{});
}

const DictTable = Heap.ExtraDataValue.Dictionary.Table;
pub fn dictGetTable(dict: Handle) error{OutOfMemory}!*DictTable {
    const metadata = dict.getDictExtraData();
    if (metadata.table) |*table| return table;

    // FIXME make sure that the dict has a table before sending between threads.
    dict.assert(!dict.getMetadata().cross_thread);

    // Table didn't exist, so we need to generate it.
    var new_table: DictTable = .empty;
    errdefer new_table.deinit(Heap.global_gpa);

    // Populate the new table.
    const dict_len = dict.peek().body.dict.len;
    var pair: u32 = 0;
    while (pair < dict_len) : (pair += 2) {
        const key = collectionItemNoFollow(dict, pair, dict_len);
        try new_table.put(Heap.global_gpa, key, pair + 1);
    }

    metadata.table = new_table;
    // Make sure to reference its new location after it moves to `metadata.table`.
    if (metadata.table) |*table| return table else unreachable;
}

pub fn dictMaybeGetTable(dict: Handle) ?*DictTable {
    if (dict.getDictExtraData().table) |*table| return table else return null;
}

pub fn dictInvalidateTable(dict: Handle) void {
    assert(dict.tag() == .dict);
    assert(dict.canShimmer());
    if (dict.getDictExtraData().table) |*table| {
        table.deinit(Heap.global_gpa);
        dict.getDictExtraData().table = null;
    }
}

pub fn shimmerToDict(det: ?*ErrorDetails, wb: *Shimmerable) !void {
    if (wb.tag() == .dict) return;

    // Get length, potentially shimmering.
    const len = listLengthShimmering(det, wb) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadDict,
    };
    const handle_heap = wb.current().getHeap();

    if (@mod(len, 2) == 1) {
        // Unmatched key.
        if (det) |details| details.* = .{
            .message = try newStringFmt(
                "Missing value to go with key when converting \"{f}\" to a dictionary.",
                .{wb.current()},
            ),
        };
        return error.BadDict;
    }

    // Set dict body using the final handle.
    const metadata_index = try handle_heap.createExtraData();
    errdefer handle_heap.destroyExtraData(metadata_index);

    const metadata = handle_heap.getExtraData(metadata_index);
    metadata.* = .{ .dict = .{ .table = null } };

    // Because both lists and dicts store their values directly after,
    // we can just swap out the head to convert to a dict.
    wb.peek().head.tag = .dict;
    wb.peek().body.dict = .{
        .extra_data = metadata_index,
        .len = len,
    };
}

pub fn dictItems(handle: Handle) []Heap.Object {
    assert(handle.tag() == .dict);
    const dict_len = handle.peek().body.dict.len;
    return handle.getHeap().objectSlice(handle.index + 1, handle.index + 1 + dict_len);
}

pub fn dictItemNoFollow(dict: Handle, index: u32) Handle {
    dict.assert(dict.tag() == .dict);
    return collectionItemNoFollow(dict, index, dict.peek().body.dict.len);
}

pub fn dictItem(dict: Handle, index: u32) Handle {
    dict.assert(dict.tag() == .dict);
    return collectionItemFollowRefs(dict, index, dict.peek().body.dict.len);
}

pub fn dictItemLength(dict: Handle) u32 {
    dict.assert(dict.tag() == .dict);
    return dict.peek().body.dict.len;
}

pub fn dictPairLength(dict: Handle) u32 {
    dict.assert(dict.tag() == .dict);
    return dict.peek().body.dict.len / 2;
}

pub fn newDictWithCapacity(len: u32) !Handle {
    assert(@mod(len, 2) == 0);

    // `1 +` to make space for the dict's head.
    const dict_index = try Heap.local_heap.createObjects(1 + len, false);
    errdefer Heap.freeObjectBacking(Heap.local_heap.getHandle(dict_index));
    const dict_metadata = try Heap.local_heap.createExtraData();
    errdefer Heap.local_heap.destroyExtraData(dict_metadata);

    Heap.local_heap.getExtraData(dict_metadata).* = .{ .dict = .{
        .table = null,
    } };

    const dict_head = Heap.local_heap.getLocalObject(dict_index);
    dict_head.* = .{
        .head = .{
            .str = Heap.Object.null_string,
            .tag = .dict,
        },
        .body = .{ .dict = .{
            .extra_data = dict_metadata,
            .len = 0,
        } },
    };

    return Heap.local_heap.getHandle(dict_index);
}

/// `dict` must be mutable. Be careful that you append an even number of elements.
pub fn dictPutAssumeCapacity(dict: Handle, key: Handle, value: Heap.Object) void {
    dict.assert(dict.tag() == .dict);
    dict.assert(dict.canMutate());
    dict.assert(dict.getDictExtraData().table == null);

    const current_len = dict.peek().body.dict.len;
    // `- 3` for dict head, new key, and value.
    dict.assert(current_len <= memutil.getOrderSize(dict.getMetadata().order) - 3);

    dict.peek().body.dict.len += 2;
    dictItemNoFollow(dict, current_len).peek().* = key.dupOrRef();
    dictItemNoFollow(dict, current_len + 1).peek().* = value;
}

/// Caller is responsible that `handles` has handles.len % 2 == 0.
pub fn newDict(handles: []const Handle) !Handle {
    const dict = try newDictWithCapacity(@intCast(handles.len));
    errdefer dict.decrRefCount();
    dict.peek().body.dict.len = @intCast(handles.len);

    const new_items = dictItems(dict);
    for (handles, new_items) |handle, *item| {
        item.* = handle.dupOrRef();
    }

    return dict;
}

/// Asserts `dict` is a .dict. Like `dictLookup`, but returns the raw dict slot handle
/// without following references.
pub fn dictLookupNoFollow(dict: Handle, key: Handle) error{OutOfMemory}!OptionalHandle {
    dict.assert(dict.tag() == .dict);
    _ = try key.getString();

    const table = try dictGetTable(dict);
    if (table.get(key)) |value_offset| {
        return dictItemNoFollow(dict, value_offset).toOptional();
    } else return .none;
}

pub fn dictLookup(dict: Handle, key: Handle) error{OutOfMemory}!OptionalHandle {
    dict.assert(dict.tag() == .dict);
    // Make sure key has a string representation, as table.get isn't allowed to fail.
    _ = try key.getString();

    const table = try dictGetTable(dict);
    if (table.get(key)) |value_offset| {
        return dictItem(dict, value_offset).toOptional();
    } else return .none;
}

pub fn dictLookupFollowLinks(det: ?*ErrorDetails, wb: *Shimmerable, key: Handle) error{ OutOfMemory, LinkLookupFailed }!OptionalHandle {
    wb.current().assert(wb.tag() == .dict);

    // Make sure key has a string representation, as table.get isn't allowed to fail.
    _ = try key.getString();

    const table = try dictGetTable(wb.current());
    if (table.get(key)) |value_offset| {
        return dictItem(wb.current(), value_offset).toOptional();
    } else {
        const parent_key = Heap.local_heap.getInternedString(.@"^parent");
        if ((try dictLookup(wb.current(), parent_key)).toHandle()) |parent_link| {
            var parent_link_wb: Shimmerable = .{ .original = parent_link, .shimmered = .none };
            defer parent_link_wb.discardChanges();
            shimmerToHashReference(det, &parent_link_wb) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.HashLookupFailed => return error.LinkLookupFailed,
                error.NotHashReference => return error.LinkLookupFailed,
            };

            if (parent_link_wb.shimmered.toHandle()) |new_parent_link| {
                // This is delicate, but it's not mutation, since we're switching out the reference
                // for its shimmered representation, so it is transparent to the caller. Note that
                // `dictPutInner` does not invalidate the string representation, so even if the
                // underlying dictionary mutates, we preserve the original string.
                _ = try dictPutInner(wb.asMutable(), parent_key, new_parent_link.reference());
            }

            const parent = parent_link_wb.peek().body.hash_reference;
            var parent_wb: Shimmerable = .{ .original = parent, .shimmered = .none };
            defer parent_wb.discardChanges();
            shimmerToDict(det, &parent_wb) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.LinkLookupFailed,
            };

            const looked_up = try dictLookupFollowLinks(det, &parent_wb, key);
            if (parent_wb.shimmered.toHandle()) |val| {
                _ = try dictPutInner(wb.asMutable(), parent_key, val.hashReference());
            }

            return looked_up;
        }
        // Nothing found, even after checking parent links.
        return .none;
    }
}

fn dictHasDuplicatesRaw(dict: Handle) !bool {
    assert(dict.tag() == .dict);
    const table = try dictGetTable(dict);

    const len = dict.peek().body.dict.len;
    assert(table.size * 2 <= len);
    return table.size * 2 != len;
}

/// Removes duplicate entries. Assumes handle is a dict. If the caller needs to track
/// a key/value as it gets rearranged, set `to_track`. The result will be its new index,
/// unless it was removed.
fn dictRemoveDuplicates(wb: *Mutable, to_track: ?u32) error{OutOfMemory}!?u32 {
    wb.current().assert(wb.tag() == .dict);

    // If the length of the table is the length of the dict, it means we have
    // no duplicates.
    const original_len = wb.peek().body.dict.len;
    if (dictMaybeGetTable(wb.current())) |table| {
        if (table.size * 2 == original_len) return to_track;
    }

    try wb.prepareToMutate();
    var metadata = wb.current().getDictExtraData();

    // Check if any items are shared.
    for (0..original_len) |i| {
        if (dictItemNoFollow(wb.current(), @intCast(i)).isShared()) {
            // Need to duplicate.
            const duplicated = try wb.current().duplicate();
            wb.mutated.swap(duplicated);
            metadata = wb.current().getDictExtraData(); // Need to reload metadata.
            break;
        }
    }

    var to_track_new_location: ?u32 = null;

    const table = try dictGetTable(wb.current());
    if (table.size * 2 == original_len) {
        // No duplicate entries.
        return to_track;
    }

    // From here on out, the dictionary will reach a very unstable intermediate
    // state, so this ensures that no error is returned partway through.
    errdefer comptime unreachable;

    var pair_index: u32 = 0;
    while (pair_index < original_len) : (pair_index += 2) {
        const key_index = pair_index;
        const value_index = pair_index + 1;
        const key_handle = dictItemNoFollow(wb.current(), key_index);
        const value_handle = dictItemNoFollow(wb.current(), value_index);

        // Because keys are immutable, we know that they'll never lose their string rep.
        if (table.get(key_handle).? != value_index) {
            // Found a duplicate entry.
            key_handle.peek().head.tag = .marked;
            value_handle.peek().head.tag = .marked;
        }
    }

    // Why mark all the handles before later removing them? Because the hash map
    // requires all the keys and values to not move, and we use the hash map
    // to see what pairs need to be removed.
    const items = dictItems(wb.current());
    // How many pairs we've removed so far. Increments by 1.
    var removed: u32 = 0;
    pair_index = 0;
    while (pair_index < original_len) : (pair_index += 2) {
        const key_index = pair_index;
        const value_index = pair_index + 1;
        const key_handle = dictItemNoFollow(wb.current(), key_index);
        const value_handle = dictItemNoFollow(wb.current(), value_index);

        if (key_handle.tag() == .marked) {
            removed += 1;

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
        const item_handle = collectionItemNoFollow(wb.current(), @intCast(to_zero), original_len);
        item_handle.peek().* = .{
            .head = .{
                .str = Heap.Object.null_string,
                .tag = .none,
            },
            .body = undefined,
        };
        item_handle.trace("Zero out removed", .{});
    }

    wb.peek().body.dict.len -= removed * 2;

    // The table is pretty broken at this point, as all its references have shifted around.
    // TODO PERF For now, it's better just to free it altogether, though this has the
    // potential to slow things down.
    dictInvalidateTable(wb.current());

    return to_track_new_location;
}

/// Takes ownership of `value`, including error cases. Returns a handle to the new value's location.
/// `value` must be in `Heap.local_heap`. Does not invalidate the string rep.
fn dictPutInner(dict: *Mutable, key: Handle, value: Heap.Object) error{OutOfMemory}!Handle {
    dict.current().assert(dict.tag() == .dict);

    var value_mut = value;
    errdefer value_mut.deinitSingle(Heap.local_heap);

    // Make sure the key has a string representation.
    _ = try dict.current().getString();
    // Also make sure we can mutate the dict.
    try dict.prepareToMutate();

    const table = try dictGetTable(dict.current());
    // Does the key already exist?
    if (table.get(key)) |existing_value_index| {
        // Key exists, so replace the value in place.
        var value_handle = dictItemNoFollow(dict.current(), existing_value_index);
        if (value_handle.isShared()) {
            // Looks like this dictionary value is shared, so we can't replace the value in place
            // (else we'd smash up a value someone else is using). Instead, we'll use a new dict,
            // which due to duplication, must have non-shared elements.
            dict.mutated.swap(try dict.current().duplicate());
            value_handle = dictItemNoFollow(dict.current(), existing_value_index);
        }

        var old_value = value_handle.peek().*; // Copy old value.
        defer old_value.deinitSingle(Heap.local_heap);
        value_handle.peek().* = value_mut.take(); // Set new value.
        errdefer {
            // On error, we need to restore the old value we saved.
            value_handle.invalidateBoth(); // Invalidate new value.
            value_handle.peek().* = old_value.take(); // Restore old value.
        }

        // Because we mutated the dictionary, we need to remove any duplicates, if applicable.
        const new_index = new_index: {
            if (try dictHasDuplicatesRaw(dict.current())) {
                const tracked_index = try dictRemoveDuplicates(dict, existing_value_index);
                break :new_index tracked_index.?;
            } else {
                break :new_index existing_value_index;
            }
        };

        return dictItemNoFollow(dict.current(), new_index);
    } else {
        const original_len = dict.peek().body.dict.len;
        const new_length = original_len + 2;

        // Key doesn't exist, so append both key and value.
        const len_before_resize = dict.peek().body.dict.len;
        const new_key_index = len_before_resize;
        const new_value_index = len_before_resize + 1;

        // Local variable for any resized dict. Only committed to dict.mutated at the end.
        var maybe_new_dict: OptionalHandle = .none;
        errdefer maybe_new_dict.decrOptional();

        // Duplicate/reference the key _before_ resizing, so we can't fail
        // after the resize is successful.
        const new_key_handle, const new_value_handle = blk: {
            var key_obj: Heap.Object = key.dupOrRef();
            errdefer key_obj.deinitSingle(Heap.local_heap);

            maybe_new_dict = try setCollectionLengthInner(dict.current(), new_length);
            const work_dict = maybe_new_dict.orElse(dict.current());

            const new_key_handle = dictItemNoFollow(work_dict, new_key_index);
            const new_value_handle = dictItemNoFollow(work_dict, new_value_index);

            new_key_handle.trace("Setting as new key to {f}", .{key_obj});

            // Set the new key and value.
            new_key_handle.peek().* = key_obj.take();
            new_value_handle.peek().* = value_mut.take();

            break :blk .{ new_key_handle, new_value_handle };
        };
        errdefer {
            // Because these are new values, we don't need to restore old
            // values, since there's nothing to restore. Instead, we'll just
            // free the last two new values, and shrink the length.
            new_key_handle.invalidateBoth();
            new_value_handle.invalidateBoth();
            const work_dict = maybe_new_dict.orElse(dict.current());
            work_dict.peek().body.dict.len = original_len;
        }

        // Make sure the key has a string rep.
        _ = try new_key_handle.getString();

        // Only put the key in the table if the table exists. It'll be discovered
        // when the table is generated if not.
        const work_dict = maybe_new_dict.orElse(dict.current());
        if (dictMaybeGetTable(work_dict)) |new_table| {
            try new_table.put(Heap.global_gpa, new_key_handle, new_value_index);
        }

        // Because we mutated the dictionary, we need to remove any duplicates, if applicable.
        const new_index = new_index: {
            if (try dictHasDuplicatesRaw(work_dict)) {
                const tracked_value = try dictRemoveDuplicates(dict, new_key_index + 1);
                break :new_index tracked_value.?;
            } else {
                break :new_index new_key_index + 1;
            }
        };

        // Commit the resize (if any) only after all fallible work is done.
        dict.mutated.swapIfNew(maybe_new_dict);

        return dictItemNoFollow(dict.current(), new_index);
    }
}

pub fn dictPutObject(dict: *Mutable, key: Handle, value: Heap.Object) error{OutOfMemory}!Handle {
    const new_value_handle = try dictPutInner(dict, key, value);
    dict.current().invalidateString();
    return new_value_handle;
}

pub const HandleSliceContext = struct {
    items: []const Handle,
    pub fn len(self: @This()) usize {
        return self.items.len;
    }
    pub fn get(self: @This(), index: usize) Handle {
        return self.items[index];
    }
    pub fn sliceAfter(self: @This(), index: usize) @This() {
        return .{ .items = self.items[index..] };
    }
};

pub const ShimmerableSliceContext = struct {
    items: []const Shimmerable,
    pub fn len(self: @This()) usize {
        return self.items.len;
    }
    pub fn get(self: @This(), index: usize) Handle {
        return self.items[index].current();
    }
    pub fn sliceAfter(self: @This(), index: usize) @This() {
        return .{ .items = self.items[index..] };
    }
};

/// Takes ownership of `value`, including in error cases. `value` must be in the local heap.
pub fn dictPutRecursively(det: ?*ErrorDetails, wb: *Mutable, context: anytype, value: Heap.Object) !Handle {
    return dictPutRecursivelyInner(det, wb, context, value) catch |err| switch (err) {
        error.OutOfMemory => {
            // Only discard changes when OOM occurs.
            wb.discardChanges();
            return error.OutOfMemory;
        },
        else => return err,
    };
}

fn dictPutRecursivelyInner(
    det: ?*ErrorDetails,
    wb: *Mutable,
    context: anytype,
    value: Heap.Object,
) error{ OutOfMemory, BadDict, LinkLookupFailed }!Handle {
    var value_mut = value;
    errdefer value_mut.deinitSingle(Heap.local_heap);

    try shimmerToDict(det, wb.asShimmerable());

    assert(context.len() > 0);
    if (context.len() == 1) {
        // `dictPutObject` always takes ownership, even in error cases.
        return try dictPutObject(wb, context.get(0), value_mut.take());
    }

    // Find/create the child dict.
    const child_dict = blk: {
        if ((try dictLookup(wb.current(), context.get(0))).toHandle()) |existing_dict| {
            // Make sure the parent dict is mutable before the recursive call. If we wait until
            // after the child is modified, the parent may contain a stale .reference to an
            // invalidated child, and duplicating the parent would then panic.
            try wb.prepareToMutate();
            break :blk existing_dict;
        } else {
            // Create a new child dictionary.
            const new_child_dict = try newDictWithCapacity(2);

            _ = try dictPutObject(wb, context.get(0), new_child_dict.referenceOwning());
            break :blk new_child_dict;
        }
    };

    var child_wb: Mutable = .{ .original = child_dict };
    defer child_wb.discardChanges();
    const child_put_result = try dictPutRecursivelyInner(
        det,
        &child_wb,
        context.sliceAfter(1),
        value_mut.take(),
    );
    if (child_wb.takeMutated().toHandle()) |new_child| {
        // The child dict changed, so we need to update ours.
        // Ownership of new_child is transferred to dictPutObject, whether it
        // succeeds or fails (on failure its errdefer cleans up the .reference).
        _ = try dictPutObject(wb, context.get(0), new_child.referenceOwning());
    }

    wb.current().invalidateString();

    return child_put_result;
}

pub fn dictRemoveRecursively(det: ?*ErrorDetails, wb: *Mutable, context: anytype) !bool {
    return dictRemoveRecursivelyInner(det, wb, context);
}

fn dictRemoveRecursivelyInner(det: ?*ErrorDetails, wb: *Mutable, context: anytype) !bool {
    try shimmerToDict(det, wb.asShimmerable());

    assert(context.len() > 0);

    if (context.len() == 1) {
        return try dictRemove(det, wb, context.get(0));
    }

    // Find the child dict.
    if ((try dictLookup(wb.current(), context.get(0))).toHandle()) |child_dict| {
        var child_wb: Mutable = .{ .original = child_dict };
        defer child_wb.discardChanges();

        const did_remove = try dictRemoveRecursivelyInner(det, &child_wb, context.sliceAfter(1));
        if (child_wb.takeMutated().toHandle()) |new_child| {
            // Ownership of new_child is transferred from `child_wb.mutated` to the dict.
            _ = try dictPutObject(wb, context.get(0), new_child.referenceOwning());
        }
        wb.current().invalidateString();

        return did_remove;
    } else {
        if (det) |details| details.* = .{
            .message = try newStringFmt(
                "key \"{f}\" not known in dictionary \"{f}\"",
                .{ context.get(0), wb.current() },
            ),
        };
        return error.PathNonexistent;
    }
}

pub fn dictLookupRecursively(det: ?*ErrorDetails, wb: *Shimmerable, context: anytype) !OptionalHandle {
    return dictLookupRecursivelyInner(det, wb, context);
}

fn dictLookupRecursivelyInner(det: ?*ErrorDetails, wb: *Shimmerable, context: anytype) !OptionalHandle {
    try shimmerToDict(det, wb);

    if (context.len() == 0) return wb.current().toOptional();
    if (context.len() == 1) {
        return try dictLookupFollowLinks(det, wb, context.get(0));
    }

    if ((try dictLookupFollowLinks(det, wb, context.get(0))).toHandle()) |child_dict| {
        var child_wb: Shimmerable = .{ .original = child_dict };
        defer child_wb.discardChanges();
        const child_result = try dictLookupRecursivelyInner(det, &child_wb, context.sliceAfter(1));
        if (child_wb.takeShimmered().toHandle()) |new_child| {
            // The child dict changed, propagate back up.
            _ = try dictPutObject(wb.asMutable(), context.get(0), new_child.referenceOwning());
        }
        return child_result;
    } else {
        return .none;
    }
}

/// Asserts `handle` is a dict.
pub fn dictPut(wb: *Mutable, key: Handle, value: Handle) !Handle {
    return dictPutObject(wb, key, value.dupOrRef());
}

fn dictFlattenInner(det: ?*ErrorDetails, original: Handle) !OptionalHandle {
    if ((try dictLookup(original, Heap.local_heap.getInternedString(.@"^parent"))).toHandle()) |parent_link| {
        var parent_link_wb: Shimmerable = .{ .original = parent_link };
        defer parent_link_wb.discardChanges();
        try shimmerToHashReference(det, &parent_link_wb);

        const parent = parent_link_wb.peek().body.hash_reference;

        var new_dict = try dictFlattenInner(det, parent);
        const to_add_to = if (new_dict.toHandle()) |handle| handle else try parent.duplicate();
        var to_add_to_wb: Mutable = .{ .original = to_add_to };
        errdefer to_add_to_wb.deinit();

        var pair_i: u32 = 0;
        while (pair_i < original.peek().body.dict.len / 2) : (pair_i += 1) {
            _ = try dictPutObject(
                &to_add_to_wb,
                dictItem(original, pair_i * 2),
                dictItem(original, pair_i * 2 + 1).reference(),
            );
        }

        return to_add_to_wb.consume().toOptional();
    } else {
        return .none; // No need to flatten.
    }
}

pub fn dictFlatten(det: ?*ErrorDetails, wb: *Mutable) !void {
    const flattened = try dictFlattenInner(det, wb.current());
    wb.mutated.swapIfNew(flattened);
}

pub const DictKeysContext = struct {
    pub fn hash(_: @This(), key: Handle) u32 {
        const hash_value = key.getHash() catch unreachable;
        return @truncate(hash_value);
    }

    pub fn eql(_: @This(), a: Handle, b: Handle, _: usize) bool {
        return Heap.checkIfEqual(a, b) catch unreachable;
    }
};

pub const DictKvResult = std.array_hash_map.Custom(Handle, Handle, DictKeysContext, true);
pub fn dictGetKvPairs(det: ?*ErrorDetails, arena: std.mem.Allocator, wb: *Shimmerable) !DictKvResult {
    try shimmerToDict(det, wb);

    var result: DictKvResult = .empty;
    errdefer result.deinit(arena);

    errdefer for (result.keys()) |key| key.decrRefCount();
    errdefer for (result.values()) |value| value.decrRefCount();
    try dictGetKvPairsInner(det, arena, wb, &result);

    return result;
}

fn dictGetKvPairsInner(det: ?*ErrorDetails, arena: std.mem.Allocator, wb: *Shimmerable, result: *DictKvResult) !void {
    const parent_key = Heap.local_heap.getInternedString(.@"^parent");
    if ((try dictLookup(wb.current(), parent_key)).toHandle()) |parent_link| {
        var parent_link_wb: Shimmerable = .{ .original = parent_link, .shimmered = .none };
        defer parent_link_wb.discardChanges();
        shimmerToHashReference(det, &parent_link_wb) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.HashLookupFailed, error.NotHashReference => return error.LinkLookupFailed,
        };

        if (parent_link_wb.shimmered.toHandle()) |new_parent_link| {
            // This is very delicate, but it technically isn't a visible mutation, since
            // we're swapping one hash reference with another reference with identical content.
            _ = try dictPutInner(wb.asMutable(), parent_key, new_parent_link.reference());
        }

        const parent = parent_link_wb.peek().body.hash_reference;
        var parent_wb: Shimmerable = .{ .original = parent, .shimmered = .none };
        defer parent_wb.discardChanges();
        shimmerToDict(det, &parent_wb) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.LinkLookupFailed,
        };

        if (parent_wb.shimmered.toHandle()) |val| {
            _ = try dictPutInner(wb.asMutable(), parent_key, val.hashReference());
        }

        // Recurse into parent first so parent keys are inserted before child keys.
        try dictGetKvPairsInner(det, arena, &parent_wb, result);
    }

    const pair_count = dictPairLength(wb.current());
    var pair_i: u32 = 0;
    while (pair_i < pair_count) : (pair_i += 1) {
        const key = dictItem(wb.current(), pair_i * 2);
        const value = dictItem(wb.current(), pair_i * 2 + 1);
        if (try key.equalsString("^parent")) continue;

        const gop = try result.getOrPut(arena, key);
        if (!gop.found_existing) {
            gop.key_ptr.* = key.borrow();
            gop.value_ptr.* = value.borrow();
        }
    }
}

fn testDictFlatten(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    try Heap.testStart(ta, testing.io);

    const key_foo = try newString("foo");
    defer key_foo.decrRefCount();
    const value1 = try newString("1");
    defer value1.decrRefCount();
    const key_bar = try newString("bar");
    defer key_bar.decrRefCount();
    const value2 = try newString("2");
    defer value2.decrRefCount();
    const key_baz = try newString("baz");
    defer key_baz.decrRefCount();
    const value3 = try newString("3");
    defer value3.decrRefCount();

    const dict1 = try newDict(&.{ key_foo, value1, key_bar, value2 });
    defer dict1.decrRefCount();

    const dict2 = try newDict(&.{ key_foo, value2, key_baz, value3 });
    defer dict2.decrRefCount();

    var dict2_wb: Mutable = .{ .original = dict2 };
    defer dict2_wb.discardChanges();

    const parent_key = Heap.local_heap.getInternedString(.@"^parent");
    _ = try dictPutObject(&dict2_wb, parent_key, dict1.hashReference());
    try dictFlatten(null, &dict2_wb);
}
test "dict flatten" {
    try testing.checkAllAllocationFailures(testing.allocator, testDictFlatten, .{});
}

/// Returns true if the value was removed, or false if the value doesn't exist.
/// May merge parent links.
pub fn dictRemove(det: ?*ErrorDetails, wb: *Mutable, key: Handle) !bool {
    return dictRemoveInner(det, wb, key);
}

fn dictRemoveInner(det: ?*ErrorDetails, wb: *Mutable, key: Handle) !bool {
    assert(wb.tag() == .dict);

    try wb.prepareToMutate();
    const key_bytes = try key.getString();

    const parent_key = Heap.local_heap.getInternedString(.@"^parent");
    if ((try dictLookup(wb.current(), parent_key)).toHandle()) |parent_link| {
        // If the parent chain contains the key we're removing, we must flatten first,
        // otherwise removing locally would leave the parent value still visible.
        var parent_link_wb: Shimmerable = .{ .original = parent_link };
        try shimmerToHashReference(det, &parent_link_wb);
        if (parent_link_wb.shimmered.toHandle()) |new_parent_link| {
            _ = try dictPutObject(wb, parent_key, new_parent_link.reference());
        }

        const parent = parent_link_wb.peek().body.hash_reference; // Resolve to value of hash.
        var parent_wb: Shimmerable = .{ .original = parent };
        const key_in_parent = (try dictLookupFollowLinks(det, &parent_wb, key)) != .none;
        if (parent_wb.shimmered.toHandle()) |new_parent| {
            _ = try dictPutObject(wb, parent_key, new_parent.hashReference());
        }

        if (key_in_parent) {
            // Key was found in the parent, so we do need to flatten.
            try dictFlatten(det, wb);
        }
    }

    wb.current().assert(wb.current().canShimmer());
    const dict_len = dictItemLength(wb.current());

    // Locate the first key (note, we can't use `metadata.table.get`, because Tcl removes all
    // key(s), while `metadata.table.get` only returns the last key).
    var first_key_index: u32 = 0;
    while (first_key_index < dict_len) : (first_key_index += 2) {
        const key_checking = try dictItem(wb.current(), first_key_index).getString();
        if (std.mem.eql(u8, key_bytes, key_checking)) {
            break; // Found our key.
        }
    } else {
        return false; // No key found.
    }

    // Make sure any keys/values we'll touch aren't shared. Because we're shifting all
    // other values to the left (to preserve relative order), we  need to check all items
    // following the key and value.
    var shared_values_found = false;
    for (first_key_index..dict_len) |item_index| {
        const item_handle = dictItemNoFollow(wb.current(), @intCast(item_index));
        if (item_handle.isShared()) shared_values_found = true;
    }

    if (shared_values_found) {
        // Looks like this dictionary item is shared, so we can't replace the value in place
        // (else we'd smash up an item someone else is using). Instead, we'll start this whole
        // process over with a new dictionary.
        wb.mutated.swap(try wb.current().duplicate());
    }

    // Make sure all the keys have string reps. If we OOM halfway through removal
    // we'll end in a really ugly state, so it's better to ensure all keys have a
    // string rep to start with. If not, we'll safely propagate the OOM.
    var item_index: u32 = 0;
    while (item_index < dict_len) : (item_index += 2) {
        _ = try dictItem(wb.current(), item_index).getString();
    }

    // This is the start of mutation. From here on there's no going back.
    errdefer comptime unreachable;
    dictInvalidateTable(wb.current());

    // Remove all matching keys and their values, moving the following pair
    // backwards to fill the gap(s).
    item_index = first_key_index;
    var pairs_removed: u32 = 0;
    while (item_index < dict_len) : (item_index += 2) {
        const key_handle = dictItemNoFollow(wb.current(), item_index);
        const value_handle = dictItemNoFollow(wb.current(), item_index + 1);
        key_handle.assert(!key_handle.isShared());
        value_handle.assert(!value_handle.isShared());
        // We checked that all our keys have strings earlier.
        const key_checking = dictItem(wb.current(), item_index).getString() catch unreachable;
        if (std.mem.eql(u8, key_bytes, key_checking)) {
            key_handle.invalidateBoth();
            value_handle.invalidateBoth();
            pairs_removed += 1;
        } else if (pairs_removed > 0) {
            // Move this pair backwards.
            const new_key_handle = dictItemNoFollow(wb.current(), item_index - pairs_removed * 2);
            const new_value_handle = dictItemNoFollow(wb.current(), item_index - pairs_removed * 2 + 1);
            new_key_handle.peek().* = key_handle.peek().*;
            new_value_handle.peek().* = value_handle.peek().*;
        }
    }

    // Be sure to "zero" out all the moved items that weren't replaced with something else.
    const start_of_removed = dict_len - pairs_removed * 2;
    for (start_of_removed..dict_len) |removed| {
        const item_handle = dictItemNoFollow(wb.current(), @intCast(removed));
        item_handle.peek().* = .{ .head = .{ .str = Heap.Object.null_string, .tag = .none }, .body = undefined };
    }

    wb.peek().body.dict.len -= pairs_removed * 2;

    wb.current().invalidateString();

    return true;
}

fn testDicts(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    try Heap.testStart(ta, testing.io);

    const key_foo = try newString("foo");
    defer key_foo.decrRefCount();
    const value1 = try newString("1");
    defer value1.decrRefCount();
    const key_bar = try newString("bar");
    defer key_bar.decrRefCount();
    const value2 = try newString("2");
    defer value2.decrRefCount();

    const dict1 = try newDict(&.{ key_foo, value1, key_bar, value2 });
    defer dict1.decrRefCount();

    const good_key = try newString("foo");
    defer good_key.decrRefCount();
    const bad_key = try newString("bogus");
    defer bad_key.decrRefCount();

    try testing.expectEqualStrings("1", try (try dictLookup(dict1, good_key)).toHandle().?.getString());
    try testing.expectEqual(.none, try dictLookup(dict1, bad_key));

    // Dict with duplicate entries testing.
    var new_dict: OptionalHandle = .none;
    defer new_dict.swapWithNone();

    const dict_with_duplicates = try newString("foo 5 bar 10 foo 15");
    defer dict_with_duplicates.decrRefCount();
    var dict_with_duplicates_wb: Mutable = .{ .original = dict_with_duplicates };
    defer dict_with_duplicates_wb.discardChanges();
    try shimmerToDict(null, dict_with_duplicates_wb.asShimmerable());
    const dup_len = dictPairLength(dict_with_duplicates_wb.current());

    try testing.expectEqual(3, dup_len);
    // When a duplicate key is queried, it should point to the last corrisponding value.
    try testing.expectEqualStrings("15", try (try dictLookup(dict_with_duplicates_wb.current(), key_foo)).toHandle().?.getString());

    _ = try dictRemoveDuplicates(&dict_with_duplicates_wb, null);
    try testing.expectEqual(2, dictPairLength(dict_with_duplicates_wb.current()));

    // Dict put testing.
    const dict_for_put = try newDict(&.{ key_foo, value1, key_bar, value2 });
    defer dict_for_put.decrRefCount();
    const key3 = try newString("baz");
    defer key3.decrRefCount();
    const value3 = try newString("3");
    defer value3.decrRefCount();

    var dict_for_put_wb: Mutable = .{ .original = dict_for_put };
    defer dict_for_put_wb.discardChanges();
    try testing.expectEqual(2, dictPairLength(dict_for_put_wb.current()));
    _ = try dictPut(&dict_for_put_wb, key_bar, value3);
    try testing.expectEqual(2, dictPairLength(dict_for_put_wb.current()));

    _ = try dictPut(&dict_for_put_wb, key3, value3);
    try testing.expectEqual(3, dictPairLength(dict_for_put_wb.current()));
    try testing.expectEqualStrings("3", try (try dictLookup(dict_for_put_wb.current(), key3)).toHandle().?.getString());

    // Dict remove testing.
    var dict_for_remove: Mutable = .{ .original = try newDict(&.{ key_foo, value1, key_bar, value2, key_foo, value3 }) };
    defer dict_for_remove.deinit();
    const did_remove = try dictRemove(null, &dict_for_remove, key_foo);
    try testing.expectEqual(true, did_remove);
    try testing.expectEqualStrings("bar 2", try dict_for_remove.getString());

    // Test dict edge cases.
    var dict_edge_cases = try newDict(&.{ key_foo, value1, key_bar, value2 });
    defer dict_edge_cases.decrRefCount();
    var dict_edge_cases_wb: Mutable = .{ .original = dict_edge_cases };
    defer dict_edge_cases_wb.discardChanges();

    // Try using a value as a key, and a key as the value while not shared (this is to check
    // that this handles using internal objects correctly).
    assert(dict_edge_cases_wb.current().canMutate());
    _ = try dictPut(&dict_edge_cases_wb, dictItem(dict_edge_cases_wb.current(), 1), dictItem(dict_edge_cases_wb.current(), 2));
    try testing.expectEqualStrings("bar", try (try dictLookup(dict_edge_cases_wb.current(), value1)).toHandle().?.getString());

    // Try aliasing a key by using it as key and value.
    _ = try dictPut(&dict_edge_cases_wb, dictItem(dict_edge_cases_wb.current(), 0), dictItem(dict_edge_cases_wb.current(), 0));
    try testing.expectEqualStrings("foo", try (try dictLookup(dict_edge_cases_wb.current(), key_foo)).toHandle().?.getString());

    // Try aliasing a value by using it as key and value.
    _ = try dictPut(&dict_edge_cases_wb, dictItem(dict_edge_cases_wb.current(), 3), dictItem(dict_edge_cases_wb.current(), 3));
    try testing.expectEqualStrings("2", try (try dictLookup(dict_edge_cases_wb.current(), value2)).toHandle().?.getString());
}

test "dicts" {
    try testing.checkAllAllocationFailures(testing.allocator, testDicts, .{});
}

pub const SourceInfo = struct {
    file_name: OptionalHandle,
    line_no: u32,
};

/// `SourceInfo` does not contain a borrowed value from `handle`, it's
/// a temporary reference.
pub fn getSourceInfo(handle: Handle) ?SourceInfo {
    if (handle.tag() != .source) return null;

    const extra_data = handle.getSourceExtraData();

    return .{
        .file_name = extra_data.file_name,
        .line_no = extra_data.line_no,
    };
}

/// Asserts `handle` can shimmer.
pub fn setSourceInfo(handle: Handle, source_info: SourceInfo) !void {
    handle.assert(handle.canShimmer());

    // Check if it already has extra data. If so, we'll modify the existing
    // extra data in place.
    if (handle.tag() == .source) {
        const extra_data_value = handle.getSourceExtraData();

        extra_data_value.file_name.decrOptional();
        extra_data_value.file_name = source_info.file_name.borrowOptional();
        extra_data_value.line_no = source_info.line_no;
    } else {
        assert(handle.getHeap() == Heap.local_heap);
        const extra_data = try Heap.local_heap.createExtraData();

        handle.getHeap().getExtraData(extra_data).* = .{ .source = .{
            .file_name = source_info.file_name.borrowOptional(),
            .line_no = source_info.line_no,
            .hash = .{ .state = .init(.not_computed), .hash = undefined },
        } };
        errdefer handle.getHeap().destroyExtraData(extra_data);

        try handle.prepareToShimmer();
        handle.peek().head.tag = .source;
        handle.peek().body.source = .{ .extra_data = extra_data };
    }
}

fn testSourceInfo(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    try Heap.testStart(ta, testing.io);

    var obj = try Heap.createObject();
    defer obj.decrRefCount();

    const file_name = try newString("test_file.tcl");
    defer file_name.decrRefCount();

    try setSourceInfo(obj, .{ .file_name = file_name.toOptional(), .line_no = 42 });

    // Verify the object has the source tag.
    try testing.expectEqual(.source, obj.tag());
    try testing.expectEqual(@as(u32, 42), obj.getSourceExtraData().line_no);

    const info = getSourceInfo(obj);
    try testing.expectEqualSlices(u8, "test_file.tcl", try obj.getSourceExtraData().file_name.toHandle().?.getString());
    try testing.expectEqual(@as(u32, 42), info.?.line_no);

    const obj2 = try newString("hello");
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

/// Not threadsafe (though this will use `handle` correctly if it's from another thread).
pub fn parseScript(det: ?*ErrorDetails, handle: Handle) !Heap.ParsedScript {
    // Get source info, or use defaults.
    const source_info: SourceInfo = if (getSourceInfo(handle)) |info| info else .{ .file_name = .none, .line_no = 1 };

    // Parse all the tokens of the script, handling any errors that come up.

    const bytes = try handle.getString();
    // Because scripts are deduplicated, there may be scripts from multiple different
    // locations in the Tcl code. This means we can't use an absolute line number for the
    // script, but instead all line numbers are relative (hence why we start at 0 here).
    var parser = Tokenizer.init(bytes, 0);

    // Set up tokens list (to be added to).
    var tokens = try std.ArrayList(Tokenizer.Token).initCapacity(Heap.global_gpa, bytes.len / 8);
    defer tokens.deinit(Heap.global_gpa);

    // Used to ignore the first token if it's .command_separator (effectively
    // trimming any starting whitespace)
    var is_trimming_start = true;
    // Add all tokens to the list, handling any errors that may come up.
    while (true) {
        const next_token = parser.nextScriptToken();
        if (next_token) |token| {
            switch (token.tag) {
                .command_separator, .word_separator => {
                    if (!is_trimming_start) try tokens.append(Heap.global_gpa, token);
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
                    try tokens.append(Heap.global_gpa, token);
                    break;
                },
                else => {
                    is_trimming_start = false;
                    try tokens.append(Heap.global_gpa, token);
                },
            }
        } else |err| {
            if (det) |details| {
                details.* = try convertTokenizerError(err);
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
            ioutil.debug("[{: >3}@{: >3}]  .{s: <20}  \"{s}\"\n", .{
                i,
                token.loc.line_no,
                @tagName(token.tag),
                bytes[token.loc.start..token.loc.end],
            });
        }
    }

    // Worst case: every token becomes a parsed token, plus one .start_of_command.
    const new_token_capacity: u32 = @intCast(tokens.items.len + 1);

    // Initialize the Heap-stored list that will contain the corrisponding value for each token.
    var new_token_values = try newListWithCapacity(new_token_capacity);
    errdefer new_token_values.decrRefCount();

    var new_token_tags: std.ArrayList(Tokenizer.Token.Tag) = try .initCapacity(Heap.global_gpa, new_token_capacity);
    errdefer new_token_tags.deinit(Heap.global_gpa);

    // The current script line's token index.
    var script_command_idx: u32 = 0;
    // The number of arguments for this command.
    var command_arg_count: u32 = 0;
    var i: usize = 0;
    while (i < tokens.items.len) {
        // Skip any leading separators.
        while (tokens.items[i].tag == .word_separator) i += 1;
        if (i >= tokens.items.len) break;

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
            if (tokens.items[i].tag == .end_of_file) {
                if (command_arg_count > 0) {
                    const script_command = listItemNoFollow(new_token_values, script_command_idx).peek();
                    script_command.body.parsed_script_command.word_count = command_arg_count;
                }
                break; // Don't append a .script_command for EOF
            }

            i += 1; // Skip command separator.

            if (command_arg_count > 0) {
                const script_command = listItemNoFollow(new_token_values, script_command_idx).peek();
                script_command.body.parsed_script_command.word_count = command_arg_count;
                command_arg_count = 0;
            }

            continue;
        }

        // First word of a new command.
        if (command_arg_count == 0) {
            new_token_tags.appendAssumeCapacity(.start_of_command);
            listAppendAssumeCapacity(new_token_values, .{
                .head = .{ .tag = .parsed_script_command },
                .body = .{
                    .parsed_script_command = .{
                        .line = tokens.items[i].loc.line_no,
                        .word_count = 0,
                    },
                },
            });
            script_command_idx = listLength(new_token_values) - 1;
        }

        // Append the start of the word (only if necessary).
        if (found_expansion or arg_token_count > 1) {
            if (found_expansion) {
                new_token_tags.appendAssumeCapacity(.argument_expansion);
            } else {
                new_token_tags.appendAssumeCapacity(.start_of_word);
            }

            _ = listAppendAssumeCapacity(new_token_values, integerObject(
                // The argument_expansion token itself is not stored in the values
                // list (it's skipped in the loop below), so subtract 1 from the
                // count to reflect the actual number of tokens that follow.
                @intCast(if (found_expansion) arg_token_count - 1 else arg_token_count),
            ));
        }

        command_arg_count += 1;

        // Now append the tokens to the new list, escaping as necessary.
        for (i..(i + arg_token_count)) |token_idx| {
            const token = tokens.items[token_idx];

            const str_handle = blk: {
                switch (token.tag) {
                    .argument_expansion => break :blk null,
                    .escaped_string => {
                        new_token_tags.appendAssumeCapacity(.simple_string);
                        listAppendAssumeCapacity(new_token_values, .{ .head = .{ .tag = .none }, .body = undefined });
                        const item = listItemNoFollow(new_token_values, listLength(new_token_values) - 1);
                        setStringFromEscaped(item, bytes[token.loc.start..token.loc.end]) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.OtherThreadSet => unreachable,
                        };

                        break :blk item;
                    },
                    else => {
                        new_token_tags.appendAssumeCapacity(token.tag);
                        listAppendAssumeCapacity(new_token_values, .{ .head = .{ .tag = .none }, .body = undefined });
                        const item = listItemNoFollow(new_token_values, listLength(new_token_values) - 1);
                        Heap.setString(item, bytes[token.loc.start..token.loc.end]) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.OtherThreadSet => unreachable,
                        };

                        break :blk item;
                    },
                }
            };

            if (str_handle) |token_str| {
                try setSourceInfo(token_str, .{
                    .file_name = source_info.file_name,
                    .line_no = token.loc.line_no + source_info.line_no,
                });
            }
        }

        // Be sure to advance our index to the next word.
        i += arg_token_count;
    }

    if (command_arg_count > 0) {
        const script_command = listItemNoFollow(new_token_values, script_command_idx).peek();
        script_command.body.parsed_script_command.word_count = command_arg_count;
    }

    const parsed_script: Heap.ParsedScript = .{
        .tags = new_token_tags,
        .values = new_token_values,
    };
    if (options.token_debugging) {
        ioutil.debug("Dumping tokens\n", .{});
        parsed_script.printTokens();
    }

    return parsed_script;
}

fn testScriptParsing(ta: std.mem.Allocator) !void {
    try Heap.testStart(ta, testing.io);
    defer Heap.testFinish();

    const script1 = try newString(
        \\ set x 5
        \\ set y $x[set x]
    );
    defer script1.decrRefCount();
    var parsed = try parseScript(null, script1);
    defer parsed.deinit();

    const tokens = parsed.tags.items;
    const values = listItems(parsed.values);

    // set x 5
    try testing.expectEqual(.start_of_command, tokens[0]);
    try testing.expectEqual(0, values[0].body.parsed_script_command.line);
    try testing.expectEqual(3, values[0].body.parsed_script_command.word_count);
    try expectEqualToken(&parsed, 1, .simple_string, "set");
    try expectEqualToken(&parsed, 2, .simple_string, "x");
    try expectEqualToken(&parsed, 3, .simple_string, "5");

    try testing.expectEqual(.start_of_command, tokens[4]);
    try testing.expectEqual(1, values[4].body.parsed_script_command.line);
    try testing.expectEqual(3, values[4].body.parsed_script_command.word_count);
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

pub fn getScript(det: ?*ErrorDetails, handle: Handle, cache_key: u256) !Heap.ParsedScript {
    if (Heap.local_heap.parsed_scripts.get(cache_key)) |parsed| {
        return parsed.script;
    } else {
        const new_script = try parseScript(det, handle);
        if (Heap.local_heap.parsed_scripts.put(cache_key, .{ .script = new_script })) |ejected| {
            var old = ejected;
            old.script.deinit();
        }
        return new_script;
    }
}

fn testScriptShimmering(ta: std.mem.Allocator) !void {
    try Heap.testStart(ta, testing.io);
    defer Heap.testFinish();

    var script = try newString(
        \\ set foo 5
        \\ set y $foo[set foo]
    );
    defer script.decrRefCount();

    const cache_key = try script.getHash();

    // First call parses and caches.
    const parsed1 = try getScript(null, script, cache_key);
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
    }, parsed1.tags.items);

    // Second call with the same key returns the cached version.
    const parsed2 = try getScript(null, script, cache_key);
    try testing.expectEqual(parsed1.tags.items.ptr, parsed2.tags.items.ptr);

    // A different script gets its own cache entry.
    var script2 = try newString("set x 5");
    defer script2.decrRefCount();

    const cache_key2 = try script2.getHash();
    const parsed3 = try getScript(null, script2, cache_key2);
    try testing.expect(parsed1.tags.items.ptr != parsed3.tags.items.ptr);
}

test "script shimmering" {
    try testing.checkAllAllocationFailures(testing.allocator, testScriptShimmering, .{});
}

fn expectEqualToken(script: *const Heap.ParsedScript, index: u32, tag: Tokenizer.Token.Tag, value: []const u8) !void {
    try testing.expectEqual(tag, script.tags.items[index]);
    try testing.expectEqualStrings(value, try listItemNoFollow(script.values, index).getString());
}

pub fn parseExpression(det: ?*ErrorDetails, handle: Handle) !Heap.ParsedExpression {
    const source_info: SourceInfo = getSourceInfo(handle) orelse .{ .file_name = .none, .line_no = 1 };
    var file_name = source_info.file_name.borrowOptional();
    errdefer file_name.swapWithNone();
    const line_no = source_info.line_no;

    // Parse all the tokens of the expr, handling any errors that come up.
    const bytes = try handle.getString();
    var tokenizer = Tokenizer.init(bytes, line_no);
    var tokens = std.MultiArrayList(Tokenizer.Token).empty;
    defer tokens.deinit(Heap.global_gpa);
    while (true) {
        const next_token = tokenizer.nextExpressionToken();
        if (next_token) |token| {
            try tokens.append(Heap.global_gpa, token);
            if (token.tag == .end_of_file) break;
        } else |err| if (det) |details| {
            details.* = try convertTokenizerError(err);
            if (tokenizer.error_details) |parser_details| {
                details.index = parser_details.index;
            }
            return err;
        }
    }

    if (tokens.len == 0) {
        if (det) |details| details.* = .{
            .message = try newString("empty expression"),
        };
        return error.ParseError;
    }

    // Next, go ahead and parse the expression from the tokens.
    const parsed: Heap.ParsedExpression = blk: {
        var parser = expr_parse.Parse.init(file_name, bytes, tokens.slice());
        errdefer parser.deinit();
        if (parser.parseExpr()) |root_node| {
            break :blk .{ .nodes = parser.nodes, .root_node = root_node.? };
            // Note we don't deinit parser here, since we take ownership.
        } else |err| {
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ParseError => {
                    if (det) |details| {
                        var aw = std.Io.Writer.Allocating.init(Heap.global_gpa);
                        errdefer aw.deinit();
                        const err_details = parser.err.?;
                        parser.renderError(err_details, &aw.writer) catch return error.OutOfMemory;
                        const rendered_error = try aw.toOwnedSlice();
                        defer Heap.global_gpa.free(rendered_error);
                        const err_on_heap = try newString(rendered_error);
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

    return parsed;
}

pub fn getExpression(det: ?*ErrorDetails, handle: Handle, cache_key: u256) !Heap.ParsedExpression {
    if (Heap.local_heap.parsed_exprs.get(cache_key)) |parsed| {
        return parsed.expr;
    } else {
        const new_expr = try parseExpression(det, handle);
        if (Heap.local_heap.parsed_exprs.put(cache_key, .{ .expr = new_expr })) |ejected| {
            var old = ejected;
            old.expr.deinit();
        }
        return new_expr;
    }
}

fn testExpressions(ta: std.mem.Allocator) !void {
    try Heap.testStart(ta, testing.io);
    defer Heap.testFinish();

    var expr1 = try newString("1 + 2 * 3 + 4");
    defer expr1.decrRefCount();

    const parsed = try getExpression(null, expr1, try expr1.getHash());
    try testing.expectEqual(.add, parsed.nodes.get(@intFromEnum(parsed.root_node)).tag);
}

test "expressions" {
    try testing.checkAllAllocationFailures(testing.allocator, testExpressions, .{});
}

pub fn parseSubstitution(det: ?*ErrorDetails, handle: Handle, flags: Tokenizer.SubstFlags) !Heap.ParsedScript {
    // Get source info, or use defaults.
    const source_info: SourceInfo = if (getSourceInfo(handle)) |info| info else .{ .file_name = .none, .line_no = 1 };

    // Parse all the tokens of the script, handling any errors that come up.

    const bytes = try handle.getString();
    // Because scripts are deduplicated, there may be scripts from multiple different
    // locations in the Tcl code. This means we can't use an absolute line number for the
    // script, but instead all line numbers are relative (hence why we start at 0 here).
    var parser = Tokenizer.init(bytes, 0);

    // Set up tokens list (to be added to).
    var tokens = try std.ArrayList(Tokenizer.Token).initCapacity(Heap.global_gpa, bytes.len / 8);
    defer tokens.deinit(Heap.global_gpa);

    // Add all tokens to the list, handling any errors that may come up.
    while (true) {
        const next_token = parser.nextSubstToken(flags);
        if (next_token) |token| {
            if (token.tag == .end_of_file) break;
            try tokens.append(Heap.global_gpa, token);
        } else |err| {
            if (det) |details| {
                details.* = try convertTokenizerError(err);
                if (parser.error_details) |parser_details| {
                    details.index = parser_details.index;
                }
            }
            return err;
        }
    }

    if (options.token_debugging) {
        ioutil.debug("Substitution tokens:\n", .{});
        for (tokens.items, 0..) |token, i| {
            ioutil.debug("[{: >3}@{: >3}]  .{s: <20}  \"{s}\"\n", .{
                i,
                token.loc.line_no,
                @tagName(token.tag),
                bytes[token.loc.start..token.loc.end],
            });
        }
    }

    // Initialize the Heap-stored list that will contain the corrisponding value for each token.
    var new_token_values = try newListWithCapacity(@intCast(tokens.items.len));
    errdefer new_token_values.decrRefCount();
    new_token_values.peek().body.list.len = @intCast(tokens.items.len);

    var new_token_tags = try std.ArrayList(Tokenizer.Token.Tag).initCapacity(Heap.global_gpa, tokens.items.len);
    errdefer new_token_tags.deinit(Heap.global_gpa);

    // Append the tokens to the new list, escaping as necessary.
    for (0..tokens.items.len) |token_idx| {
        const token = tokens.items[token_idx];

        const str_handle = blk: {
            switch (token.tag) {
                .escaped_string => {
                    try new_token_tags.append(Heap.global_gpa, .simple_string);
                    const item_handle = listItemNoFollow(new_token_values, @intCast(token_idx));
                    setStringFromEscaped(item_handle, bytes[token.loc.start..token.loc.end]) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.OtherThreadSet => unreachable,
                    };
                    break :blk item_handle;
                },
                else => {
                    try new_token_tags.append(Heap.global_gpa, token.tag);
                    const item_handle = listItemNoFollow(new_token_values, @intCast(token_idx));
                    Heap.setString(item_handle, bytes[token.loc.start..token.loc.end]) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.OtherThreadSet => unreachable,
                    };
                    break :blk item_handle;
                },
            }
        };

        try setSourceInfo(str_handle, .{
            .file_name = source_info.file_name,
            .line_no = token.loc.line_no + source_info.line_no,
        });
    }

    const parsed_subst: Heap.ParsedScript = .{
        .tags = new_token_tags,
        .values = new_token_values,
    };
    if (options.token_debugging) {
        ioutil.debug("Dumping substitution tokens\n", .{});
        parsed_subst.printTokens();
    }

    return parsed_subst;
}

pub fn getSubstitution(det: ?*ErrorDetails, handle: Handle, cache_key: u256, flags: Tokenizer.SubstFlags) !Heap.Substitution {
    if (Heap.local_heap.parsed_substs.get(cache_key)) |parsed| {
        return parsed;
    } else {
        const new_subst = try parseSubstitution(det, handle, flags);
        if (Heap.local_heap.parsed_substs.put(cache_key, .{ .subst = new_subst, .flags = flags })) |evicted| {
            var evicted_mut = evicted;
            evicted_mut.subst.deinit();
        }
        return .{ .subst = new_subst, .flags = flags };
    }
}

pub fn shimmerToBoolean(det: ?*ErrorDetails, wb: *Shimmerable) !void {
    if (wb.tag() == .bool) return;

    // Fast case: if it's an int, we can get the value directly.
    if (wb.tag() == .integer) {
        const new_value = wb.peek().body.integer != 0;

        try wb.prepareToShimmer();
        wb.peek().head.tag = .bool;
        wb.peek().body.bool = .{ .data = new_value };
        return;
    }

    const Mapping = std.StaticStringMap(bool).initComptime(Tokenizer.boolean_mapping);

    const bytes = try wb.current().getString();
    const new_value = Mapping.get(bytes) orelse blk: {
        // It might be an integer, so be sure to try parsing it as an int before giving up.
        const as_int = integerGetNoShimmer(null, wb.current()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                // Finally, give up.
                if (det) |details| details.* = .{
                    .message = try newStringFmt("expected boolean but got \"{f}\"", .{wb.current()}),
                };
                return error.BadBoolean;
            },
        };
        break :blk as_int != 0;
    };

    try wb.prepareToShimmer();
    wb.peek().head.tag = .bool;
    wb.peek().body.bool = .{ .data = new_value };
}

pub fn getBoolean(det: ?*ErrorDetails, wb: *Shimmerable) !bool {
    try shimmerToBoolean(det, wb);
    return wb.peek().body.bool.data;
}

pub fn newBoolean(value: bool) !Handle {
    const handle = try Heap.createObject();
    handle.peek().head.tag = .bool;
    handle.peek().body.bool = .{ .data = value };
    return handle;
}

pub fn shimmerToRegexp(det: ?*ErrorDetails, wb: *Shimmerable, compile_opts: u32) !void {
    if (wb.tag() == .regexp and wb.peek().body.regexp.options == compile_opts) return;

    const pattern = try wb.current().getString();

    var err_code: c_int = 0;
    var err_offset: usize = 0;
    const compile_ctx = pcre2.pcre2_compile_context_create_8(regex.pcre2_ctx) orelse return error.OutOfMemory;
    defer pcre2.pcre2_compile_context_free_8(compile_ctx);

    const re = pcre2.pcre2_compile_8(
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
            details.* = .{ .message = try newString(msg) };
        }
        return error.BadRegexp;
    };

    const heap = wb.current().getHeap();
    const extra = try heap.createExtraData();
    errdefer heap.destroyExtraData(extra);

    heap.getExtraData(extra).* = .{ .regexp = re };

    try wb.prepareToShimmer();
    wb.peek().head.tag = .regexp;
    wb.peek().body.regexp = .{ .options = compile_opts, .extra_data = extra };
}

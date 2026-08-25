const std = @import("std");
const fmt = std.fmt;

const strutil = @import("../strutil.zig");

const common = @import("common.zig");
const heap = common.heap;
const ErrorDetails = common.ErrorDetails;
const Value = common.Value;
const objects = common.objects;
const String = objects.String;
const List = objects.List;
const Interp = common.Interp;
const Shimmerable = common.Shimmerable;
const registerCommand = common.registerCommand;
const memutil = common.memutil;

/// [append]
pub fn appendCmd(interp: *Interp, args: []Shimmerable) !void {
    // Get the variable's value if it exists, or else use an empty string.
    const var_name = &args[1];

    const var_value: []const u8 = blk: {
        if (try interp.getVariableInner(interp.callFrameIdx(), var_name, false)) |val| {
            break :blk try val.getString();
        } else {
            break :blk "";
        }
    };

    // Fast path: no values to append, just ensure the variable exists and return it.
    if (args.len == 2) {
        if ((try interp.getVariableTakingReference(var_name)).asValue()) |val| {
            interp.setResultOwning(val);
        } else {
            try interp.setVariable(var_name, heap.interned_empty_string);
            interp.setEmptyResult();
        }
        return;
    }

    // Compute total length so we can allocate a single string.
    var total_len: usize = var_value.len;
    for (args[2..]) |arg| {
        total_len += (try arg.current().getString()).len;
    }

    const combined_str = blk: {
        var new_bytes = try heap.global_gpa.allocSentinel(u8, total_len, 0);
        errdefer heap.global_gpa.free(new_bytes);

        if (total_len > 0) {
            var pos: usize = 0;
            @memcpy(new_bytes[pos..(pos + var_value.len)], var_value);
            pos += var_value.len;
            for (args[2..]) |arg| {
                const bytes = try arg.current().getString();
                @memcpy(new_bytes[pos..(pos + bytes.len)], bytes);
                pos += bytes.len;
            }
        }

        break :blk try String.newOwningNoFree(new_bytes);
    };
    defer combined_str.asHead().dropReference();

    try interp.setVariable(var_name, combined_str.asHead().asValue());
    interp.setResult(combined_str.asHead().asValue());
}

const StringSubcommand = enum {
    bytelength,
    byterange,
    cat,
    compare,
    equal,
    first,
    index,
    is,
    last,
    length,
    map,
    match,
    range,
    repeat,
    replace,
    reverse,
    tolower,
    totitle,
    toupper,
    trim,
    trimleft,
    trimright,
};

pub fn stringCmd(interp: *Interp, args: []Shimmerable) !void {
    const Parser = objects.SubcommandParser(StringSubcommand, &.{
        .{ .variant = .bytelength, .usage = "string", .min_args = 1, .max_args = 1 },
        .{ .variant = .byterange, .usage = "string first last", .min_args = 3, .max_args = 3 },
        .{ .variant = .cat, .usage = "?string ...?", .min_args = 0, .max_args = null },
        .{ .variant = .compare, .usage = "?-nocase? ?-length int? string1 string2", .min_args = 2, .max_args = 5 },
        .{ .variant = .equal, .usage = "?-nocase? ?-length int? string1 string2", .min_args = 2, .max_args = 5 },
        .{ .variant = .first, .usage = "subString string ?index?", .min_args = 2, .max_args = 3 },
        .{ .variant = .index, .usage = "string index", .min_args = 2, .max_args = 2 },
        .{ .variant = .is, .usage = "class ?-strict? str", .min_args = 2, .max_args = 3 },
        .{ .variant = .last, .usage = "subString string ?index?", .min_args = 2, .max_args = 3 },
        .{ .variant = .length, .usage = "string", .min_args = 1, .max_args = 1 },
        .{ .variant = .map, .usage = "?-nocase? mapList string", .min_args = 2, .max_args = 3 },
        .{ .variant = .match, .usage = "?-nocase? pattern string", .min_args = 2, .max_args = 3 },
        .{ .variant = .range, .usage = "string first last", .min_args = 3, .max_args = 3 },
        .{ .variant = .repeat, .usage = "string count", .min_args = 2, .max_args = 2 },
        .{ .variant = .replace, .usage = "string first last ?string?", .min_args = 3, .max_args = 4 },
        .{ .variant = .reverse, .usage = "string", .min_args = 1, .max_args = 1 },
        .{ .variant = .tolower, .usage = "string", .min_args = 1, .max_args = 1 },
        .{ .variant = .totitle, .usage = "string", .min_args = 1, .max_args = 1 },
        .{ .variant = .toupper, .usage = "string", .min_args = 1, .max_args = 1 },
        .{ .variant = .trim, .usage = "string ?trimchars?", .min_args = 1, .max_args = 2 },
        .{ .variant = .trimleft, .usage = "string ?trimchars?", .min_args = 1, .max_args = 2 },
        .{ .variant = .trimright, .usage = "string ?trimchars?", .min_args = 1, .max_args = 2 },
    });

    var det: ErrorDetails = undefined;
    const subcommand: StringSubcommand = try interp.wrapError(&det, Parser.parse(&det, args));

    dispatchStringCmd(interp, subcommand, args[2..]) catch |err| switch (err) {
        error.WrongUsage => {
            try interp.setResultFormatted(
                "wrong # args: should be \"{s} {s} {s}\"",
                .{ try args[0].current().getString(), try args[1].current().getString(), Parser.EnumToSubcommand.get(subcommand).usage },
            );
            return error.EvalError;
        },
        else => |e| return e,
    };
}

/// Runs the body of a single `[string]` subcommand. A subcommand rejects its
/// own arguments (beyond the arity `stringCmd` already checked) by returning
/// `error.WrongUsage`; the caller turns that into a message naming this
/// specific subcommand's usage, not the top-level `string` command's.
fn dispatchStringCmd(interp: *Interp, subcommand: StringSubcommand, sub_args: []Shimmerable) !void {
    var det: ErrorDetails = undefined;

    switch (subcommand) {
        .bytelength => {
            const bytes = try sub_args[0].current().getString();
            interp.setResultInteger(@intCast(bytes.len));
        },
        .byterange => {
            const bytes = try sub_args[0].current().getString();
            const range = try interp.wrapError(&det, objects.Index.getRange(&det, bytes.len, &sub_args[1], &sub_args[2]));
            try interp.setResultString(bytes[range.start..range.end]);
        },
        .cat => {
            var new_str: std.ArrayList(u8) = .empty;
            errdefer new_str.deinit(heap.global_gpa);
            for (sub_args[0..]) |handle| {
                const str = try handle.current().getString();
                try new_str.appendSlice(heap.global_gpa, str);
            }

            try interp.setResultStringOwning(try new_str.toOwnedSliceSentinel(heap.global_gpa, 0));
        },
        .compare, .equal => {
            var opt_case_insensitive = false;
            var opt_length: ?usize = null;

            // The last two arguments are the strings to compare. Everything
            // before is a flag.
            var i: usize = 0;
            while (i < sub_args.len - 2) : (i += 1) {
                if (try sub_args[i].current().equalsString("-nocase")) {
                    opt_case_insensitive = true;
                } else if (try sub_args[i].current().equalsString("-length")) {
                    if (i + 1 >= sub_args.len - 2) return error.WrongUsage; // There needs to be a value after `-length`.
                    opt_length = std.math.lossyCast(usize, try interp.getInteger(&sub_args[i + 1]));
                    i += 1;
                } else return error.WrongUsage;
            }

            const bytes_a = try sub_args[i].current().getString();
            const bytes_b = try sub_args[i + 1].current().getString();

            // Fast case: [string equal], case sensitive, no max length.
            if (subcommand == .equal and !opt_case_insensitive and opt_length == null) {
                interp.setResultBoolean(std.mem.eql(u8, bytes_a, bytes_b));
            } else {
                const order = strutil.compare(bytes_a, bytes_b, opt_length, opt_case_insensitive);
                if (subcommand == .equal) {
                    interp.setResultBoolean(order == .eq);
                } else switch (order) {
                    .lt => interp.setResultInteger(-1),
                    .eq => interp.setResultInteger(0),
                    .gt => interp.setResultInteger(1),
                }
            }
        },
        .length => {
            interp.setResultInteger(@intCast(try String.getCodepointLength(&sub_args[0])));
        },
        .range => {
            const str = &sub_args[0];
            const str_cp_len = try String.getCodepointLength(str);
            const range = try interp.wrapError(&det, objects.Index.getRange(&det, str_cp_len, &sub_args[1], &sub_args[2]));

            const bytes = try str.current().getString();
            const byte_start = strutil.cpIndex(bytes, range.start) orelse {
                interp.setResultOwning(heap.interned_empty_string);
                return;
            };
            const byte_end = strutil.cpIndex(bytes, range.end) orelse bytes.len;

            try interp.setResultString(bytes[byte_start..byte_end]);
        },
        .map => {
            var opt_case_insensitive = false;
            if (sub_args.len == 3) {
                if (!try sub_args[0].current().equalsString("-nocase")) return error.WrongUsage;
                opt_case_insensitive = true;
            }

            const map_list = try interp.getList(&sub_args[sub_args.len - 2]);
            const str_handle = &sub_args[sub_args.len - 1];

            if (map_list.items.len % 2 != 0) {
                try interp.setResultString("list must contain an even number of elements");
                return error.EvalError;
            }

            const pair_count = map_list.items.len / 2;
            const Pair = struct {
                key: []const u8,
                key_codepoint_len: usize,
                value: []const u8,
            };

            // Precompute keys and values since the search loop is pretty hot.
            var pairs = try std.ArrayList(Pair).initCapacity(heap.local_arena, pair_count);

            var key_i: usize = 0;
            while (key_i < map_list.items.len) : (key_i += 2) {
                const key_handle = map_list.items[key_i];
                const value_handle = map_list.items[key_i + 1];

                var key_shim: Shimmerable = .{ .original = key_handle };
                defer key_shim.discardChanges(); // TODO PERF this might not hold up well with objects from other threads.
                const key_codepoint_len = try String.getCodepointLength(&key_shim);

                pairs.appendAssumeCapacity(.{
                    .key = try key_handle.getString(),
                    .value = try value_handle.getString(),
                    .key_codepoint_len = key_codepoint_len,
                });
            }

            const str = try str_handle.current().getString();

            var result: std.ArrayList(u8) = .empty;
            defer result.deinit(heap.global_gpa);

            var str_iter = strutil.Iterator.init(str);

            // no_match_start tracks the first byte of a contiguous run of characters
            // that did not match any key. When a match is found, everything from
            // this byte index up to the current position is copied verbatim into
            // the result. It is null when we are not in the middle of an unmatched
            // run (e.g. right after a replacement, or at the start of the string).
            var no_match_start: ?usize = null;

            while (str_iter.peek()) |_| : (_ = str_iter.next()) {
                var matched = false;
                for (pairs.items) |pair| {
                    if (pair.key.len == 0) continue;
                    const remaining = str[str_iter.i..];
                    if (remaining.len < pair.key.len) continue;

                    // Limit the comparison to the key's codepoint count so that a
                    // longer remaining string still matches when the prefix is
                    // identical. Without the limit, compare would return .gt.
                    const order = strutil.compare(remaining, pair.key, pair.key_codepoint_len, opt_case_insensitive);
                    if (order != .eq) continue;

                    // A key matched. First, flush any preceding unmatched characters.
                    if (no_match_start) |start| {
                        try result.appendSlice(heap.global_gpa, str[start..str_iter.i]);
                        no_match_start = null;
                    }
                    try result.appendSlice(heap.global_gpa, pair.value);

                    // The outer loop already peeked at 1 codepoint but did not consume it.
                    // We need to advance past the rest of the matched key so the next
                    // iteration resumes at the first character after the replacement.
                    for (1..pair.key_codepoint_len) |_| {
                        _ = str_iter.next() orelse break;
                    }
                    matched = true;
                    break;
                }

                if (!matched) {
                    // This codepoint is not the start of any key. If we are not
                    // already tracking an unmatched run, mark the start here.
                    if (no_match_start == null) no_match_start = str_iter.i;
                }
            }

            // If the string ended while we were still in an unmatched run, copy the
            // trailing characters into the result.
            if (no_match_start) |start| {
                try result.appendSlice(heap.global_gpa, str[start..str_iter.i]);
            }
            try interp.setResultStringOwning(try result.toOwnedSliceSentinel(heap.global_gpa, 0));
        },
        .first, .last => {
            const needle = try sub_args[0].current().getString();
            const haystack_cp_len = try String.getCodepointLength(&sub_args[1]);
            const haystack = try sub_args[1].current().getString();

            if (needle.len == 0) {
                interp.setResultInteger(-1);
                return;
            }

            // An explicit index bounds where the match may *start* (`first`
            // searches forward from it, `last` searches backward from it);
            // without one, `first` starts at 0 and `last` may start anywhere.
            const byte_offset = blk: {
                if (subcommand == .first) {
                    var start_cp: usize = 0;
                    if (sub_args.len == 3) {
                        const index = try interp.getIndex(&sub_args[2]);
                        const abs = index.asAbsoluteIndex(haystack_cp_len);
                        start_cp = std.math.cast(usize, abs) orelse 0;
                    }
                    break :blk strutil.findFirstOccurrence(needle, haystack, start_cp);
                } else {
                    var end_cp: usize = haystack_cp_len;
                    if (sub_args.len == 3) {
                        const index = try interp.getIndex(&sub_args[2]);
                        const abs = index.asAbsoluteIndex(haystack_cp_len);
                        end_cp = std.math.cast(usize, abs) orelse 0;
                    }
                    const max_start_byte = strutil.cpIndex(haystack, end_cp) orelse haystack.len;
                    break :blk strutil.findLastOccurrenceBounded(needle, haystack, max_start_byte);
                }
            } orelse {
                interp.setResultInteger(-1);
                return;
            };

            const cp_offset = if (haystack.len == haystack_cp_len)
                byte_offset
            else
                strutil.codepointLength(haystack[0..byte_offset]);
            interp.setResultInteger(@intCast(cp_offset));
        },
        .is => {
            const Class = enum {
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
            };

            const ClassEnum = objects.EnumConstructor(Class, false);
            const class = ClassEnum.get(null, &sub_args[0]) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.BadEnumVariant => {
                    try interp.setResultFormatted(
                        "bad class \"{s}\": must be {s}",
                        .{ try sub_args[0].current().getString(), objects.enumNames(Class, ", ") },
                    );
                    return error.EvalError;
                },
            };

            // Without `-strict`, an empty string vacuously satisfies every
            // class; with it, an empty string always fails.
            var strict = false;
            const str_arg: *Shimmerable = switch (sub_args.len) {
                2 => &sub_args[1],
                3 => blk: {
                    if (!try sub_args[1].current().equalsString("-strict")) return error.WrongUsage;
                    strict = true;
                    break :blk &sub_args[2];
                },
                else => unreachable,
            };

            const str = try str_arg.current().getString();
            if (str.len == 0) {
                interp.setResultBoolean(!strict);
                return;
            }

            const result = switch (class) {
                .integer => is_valid: {
                    break :is_valid if (objects.Integer.shimmerFrom(null, str_arg)) |_|
                        true
                    else |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => false,
                    };
                },
                .double => is_valid: {
                    break :is_valid if (objects.Float.get(null, str_arg)) |_|
                        true
                    else |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => false,
                    };
                },
                .boolean => is_valid: {
                    break :is_valid if (objects.Boolean.shimmerFrom(null, str_arg)) |_|
                        true
                    else |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => false,
                    };
                },
                // Each arm passes a comptime-known function directly, rather than
                // through a runtime function-pointer variable, so the compiler can
                // still inline `checkAllAscii`'s call to it.
                .alpha => strutil.checkAllAscii(str, std.ascii.isAlphabetic),
                .alnum => strutil.checkAllAscii(str, std.ascii.isAlphanumeric),
                .ascii => strutil.checkAllAscii(str, std.ascii.isAscii),
                .digit => strutil.checkAllAscii(str, std.ascii.isDigit),
                .lower => strutil.checkAllAscii(str, std.ascii.isLower),
                .upper => strutil.checkAllAscii(str, std.ascii.isUpper),
                .space => strutil.checkAllAscii(str, std.ascii.isWhitespace),
                .xdigit => strutil.checkAllAscii(str, std.ascii.isHex),
                .control => strutil.checkAllAscii(str, std.ascii.isControl),
                .print => strutil.checkAllAscii(str, std.ascii.isPrint),
                .graph => strutil.checkAllAscii(str, strutil.isGraph),
                .punct => strutil.checkAllAscii(str, strutil.isPunct),
            };

            interp.setResultBoolean(result);
        },
        .match => {
            var opt_case_insensitive = false;
            if (sub_args.len == 3) {
                if (!try sub_args[0].current().equalsString("-nocase")) return error.WrongUsage;
                opt_case_insensitive = true;
            }

            const pattern = try sub_args[sub_args.len - 2].current().getString();
            const str = try sub_args[sub_args.len - 1].current().getString();
            interp.setResultBoolean(strutil.globMatch(pattern, str, opt_case_insensitive));
        },
        .repeat => {
            const str = try sub_args[0].current().getString();
            const count = try interp.getInteger(&sub_args[1]);

            if (count <= 0 or str.len == 0) {
                interp.setResultOwning(heap.interned_empty_string);
                return;
            }

            const count_usize: usize = std.math.cast(usize, count) orelse return interp.integerOverflowError(i64, count);
            const total_len = std.math.mul(usize, str.len, count_usize) catch return error.OutOfMemory;

            const buf = try heap.global_gpa.allocSentinel(u8, total_len, 0);
            for (0..count_usize) |i| {
                @memcpy(buf[i * str.len ..][0..str.len], str);
            }

            try interp.setResultStringOwning(buf);
        },
        .replace => {
            const cp_len = try String.getCodepointLength(&sub_args[0]);
            const bytes = try sub_args[0].current().getString();

            const first_index = try interp.getIndex(&sub_args[1]);
            const last_index = try interp.getIndex(&sub_args[2]);
            const first_abs = first_index.asAbsoluteIndex(cp_len);
            const last_abs = last_index.asAbsoluteIndex(cp_len);

            // An inverted range (first past last) leaves the string untouched,
            // regardless of a replacement string; there is nothing to splice into.
            if (first_abs > last_abs) {
                try interp.setResultString(bytes);
                return;
            }

            const first_clamped: usize = std.math.cast(usize, first_abs) orelse 0;
            const after_last = last_abs + 1;
            const after_clamped: usize = @min(std.math.cast(usize, after_last) orelse 0, cp_len);

            const byte_first = strutil.cpIndex(bytes, first_clamped) orelse bytes.len;
            const byte_after = strutil.cpIndex(bytes, after_clamped) orelse bytes.len;

            var result: std.ArrayList(u8) = .empty;
            defer result.deinit(heap.global_gpa);
            try result.appendSlice(heap.global_gpa, bytes[0..byte_first]);
            if (sub_args.len == 4) {
                try result.appendSlice(heap.global_gpa, try sub_args[3].current().getString());
            }
            try result.appendSlice(heap.global_gpa, bytes[byte_after..]);

            try interp.setResultStringOwning(try result.toOwnedSliceSentinel(heap.global_gpa, 0));
        },
        .reverse => {
            const str = try sub_args[0].current().getString();
            const buf = try heap.global_gpa.allocSentinel(u8, str.len, 0);

            // `.prev()` only tells us where the previous codepoint starts; the
            // raw bytes are copied as-is rather than decoded and re-encoded,
            // so a malformed sequence round-trips unchanged, matching Jim's own
            // [string reverse] (which likewise just `memcpy`s each codepoint's
            // original bytes into place).
            var iter = strutil.Iterator.init(str);
            iter.i = str.len;
            var pos: usize = 0;
            while (true) {
                const end = iter.i;
                _ = iter.prev() orelse break;
                const cp_bytes = str[iter.i..end];
                @memcpy(buf[pos..][0..cp_bytes.len], cp_bytes);
                pos += cp_bytes.len;
            }

            try interp.setResultStringOwning(buf);
        },
        .tolower, .toupper => {
            const str = try sub_args[0].current().getString();

            var result: std.ArrayList(u8) = .empty;
            defer result.deinit(heap.global_gpa);

            var iter = strutil.Iterator.init(str);
            while (iter.next()) |cp| {
                const converted = if (subcommand == .tolower) strutil.toLower(cp) else strutil.toUpper(cp);
                var encode_buf: [4]u8 = undefined;
                const encoded_len = strutil.encodeCodepoint(converted, &encode_buf) catch unreachable;
                try result.appendSlice(heap.global_gpa, encode_buf[0..encoded_len]);
            }

            try interp.setResultStringOwning(try result.toOwnedSliceSentinel(heap.global_gpa, 0));
        },
        .totitle => {
            // Only the first character is title-cased; the rest is lowercased
            // (not left as-is), matching Tcl's [string totitle].
            const str = try sub_args[0].current().getString();

            var result: std.ArrayList(u8) = .empty;
            defer result.deinit(heap.global_gpa);

            var iter = strutil.Iterator.init(str);
            var encode_buf: [4]u8 = undefined;
            if (iter.next()) |first_cp| {
                const encoded_len = strutil.encodeCodepoint(strutil.toTitle(first_cp), &encode_buf) catch unreachable;
                try result.appendSlice(heap.global_gpa, encode_buf[0..encoded_len]);
            }
            while (iter.next()) |cp| {
                const encoded_len = strutil.encodeCodepoint(strutil.toLower(cp), &encode_buf) catch unreachable;
                try result.appendSlice(heap.global_gpa, encode_buf[0..encoded_len]);
            }

            try interp.setResultStringOwning(try result.toOwnedSliceSentinel(heap.global_gpa, 0));
        },
        .trim, .trimleft, .trimright => {
            const str = try sub_args[0].current().getString();
            const trim_chars = if (sub_args.len == 2) try sub_args[1].current().getString() else " \t\n\r";

            const left = if (subcommand != .trimright) strutil.trimLeft(str, trim_chars) else 0;
            const right = if (subcommand != .trimleft) strutil.trimRight(str[left..], trim_chars) else str.len - left;

            try interp.setResultString(str[left..][0..right]);
        },
        .index => {
            const codepoint_len = try String.getCodepointLength(&sub_args[0]);
            const bytes = try sub_args[0].current().getString();
            const index = try interp.getIndex(&sub_args[1]);

            const abs_index = index.asAbsoluteIndex(@intCast(codepoint_len));
            if (abs_index < 0 or abs_index >= codepoint_len) {
                interp.setEmptyResult();
                return;
            } else if (bytes.len == codepoint_len) {
                // ASCII optimization.
                try interp.setResultString(&.{bytes[@intCast(abs_index)]});
            } else {
                // `std.unicode.utf8ByteSequenceLength` only inspects the leading
                // byte: for a truncated multi-byte lead it reports a length
                // longer than what's actually left in `bytes`, which used to
                // panic on the slice below. `Iterator.next()` decodes (and
                // bounds-checks) the same way the rest of this file already
                // does, so a malformed byte here comes back as its own
                // one-byte result instead, matching Jim's [string index].
                var char_iter = strutil.Iterator.init(bytes);
                char_iter.i = strutil.cpIndex(bytes, @intCast(abs_index)).?;
                const start = char_iter.i;
                _ = char_iter.next().?;
                try interp.setResultString(bytes[start..char_iter.i]);
            }
        },
    }
}

const FormatSpec = struct {
    left_align: bool = false,
    force_sign: bool = false,
    space_sign: bool = false,
    zero_pad: bool = false,
    alt_form: bool = false,
    width: ?usize = null,
    precision: ?usize = null,
};

/// Pads `text` out to `spec.width`, on the left with spaces (right-justified,
/// the default) or on the right with spaces (`-` flag). Zero-padding for
/// numeric conversions is handled by `formatNumeric` instead, since the
/// padding zeros have to land *after* any sign, not before it.
fn padAndAppend(gpa: std.mem.Allocator, text: []const u8, spec: FormatSpec, out: *std.ArrayList(u8)) !void {
    const pad = if (spec.width) |w| w -| text.len else 0;
    if (pad > 0 and !spec.left_align) try out.appendNTimes(gpa, ' ', pad);
    try out.appendSlice(gpa, text);
    if (pad > 0 and spec.left_align) try out.appendNTimes(gpa, ' ', pad);
}

/// Formats an already-rendered (unsigned, unpadded) digit string `digits`
/// for a numeric conversion: applies the sign, the `#`-flag prefix, and
/// width padding (zero-padding lands between the sign/prefix and the
/// digits, so `-007` not `00-7`, matching C's printf).
fn formatNumeric(
    gpa: std.mem.Allocator,
    digits: []const u8,
    negative: bool,
    prefix: []const u8,
    spec: FormatSpec,
    out: *std.ArrayList(u8),
) !void {
    const sign: []const u8 = if (negative) "-" else if (spec.force_sign) "+" else if (spec.space_sign) " " else "";
    const body_len = sign.len + prefix.len + digits.len;
    const pad = if (spec.width) |w| w -| body_len else 0;

    if (pad > 0 and !spec.left_align and !spec.zero_pad) try out.appendNTimes(gpa, ' ', pad);
    try out.appendSlice(gpa, sign);
    try out.appendSlice(gpa, prefix);
    if (pad > 0 and !spec.left_align and spec.zero_pad) try out.appendNTimes(gpa, '0', pad);
    try out.appendSlice(gpa, digits);
    if (pad > 0 and spec.left_align) try out.appendNTimes(gpa, ' ', pad);
}

fn formatInteger(gpa: std.mem.Allocator, value: i64, base: u8, uppercase: bool, spec: FormatSpec, out: *std.ArrayList(u8)) !void {
    const negative = value < 0 and base == 10;
    // Formatted as unsigned throughout: %x/%o always treat the bit pattern
    // as unsigned (matching C), and for %d we just strip the sign here and
    // reapply it in `formatNumeric`.
    const magnitude: u64 = if (base == 10) @abs(value) else @as(u64, @bitCast(value));

    var buf: [64]u8 = undefined;
    const digits_len = std.fmt.printInt(&buf, magnitude, base, if (uppercase) .upper else .lower, .{});
    const digits = buf[0..digits_len];

    var prefix: []const u8 = "";
    if (spec.alt_form and magnitude != 0) {
        if (base == 16) {
            prefix = if (uppercase) "0X" else "0x";
        } else if (base == 8) {
            prefix = "0";
        }
    }

    try formatNumeric(gpa, digits, negative, prefix, spec, out);
}

/// Fetches the next format argument, erroring if none are left. Each
/// conversion specifier consumes exactly one argument.
fn nextFormatArg(interp: *Interp, args: []Shimmerable, arg_i: *usize) !*Shimmerable {
    if (arg_i.* >= args.len) {
        try interp.setResultFormatted("not enough arguments for all format specifiers", .{});
        return error.EvalError;
    }
    const arg = &args[arg_i.*];
    arg_i.* += 1;
    return arg;
}

/// Number of decimal digits in `v` (1 for 0). Used to compute the
/// scientific exponent of a `FloatDecimal` for `%g`.
fn decimalLengthU64(v: u64) u32 {
    if (v == 0) return 1;
    var len: u32 = 0;
    var n = v;
    while (n > 0) : (n /= 10) len += 1;
    return len;
}

/// Removes trailing zeros after the decimal point for `%g`'s trailing-zero
/// suppression, but always keeps at least one digit after the dot so the
/// result always has a fractional part (e.g. `1.0`, not `1`).
/// If the rendered string has no decimal point at all (as happens when the
/// computed precision is 0), a `.0` is inserted before the exponent. In
/// scientific notation, the mantissa and exponent are adjacent in the
/// buffer, so the exponent is shifted to make room or close the gap.
fn stripTrailingZeros(buf: []u8, rendered: []u8) []u8 {
    var e_pos: usize = rendered.len;
    for (rendered, 0..) |ch, idx| {
        if (ch == 'e' or ch == 'E') {
            e_pos = idx;
            break;
        }
    }

    // Find the dot within the mantissa.
    var dot_pos: usize = e_pos;
    for (rendered[0..e_pos], 0..) |ch, idx| {
        if (ch == '.') {
            dot_pos = idx;
            break;
        }
    }

    if (dot_pos >= e_pos) {
        // No decimal point. Insert ".0" before the exponent so the result
        // always has a fractional part.
        const exp_len = rendered.len - e_pos;
        // Shift the exponent right by 2 to make room for ".0".
        for (rendered[e_pos..], 0..) |ch, j| {
            buf[e_pos + 2 + j] = ch;
        }
        buf[dot_pos] = '.';
        buf[dot_pos + 1] = '0';
        return buf[0 .. e_pos + 2 + exp_len];
    }

    // Strip trailing zeros down to the first non-zero digit after the dot,
    // but never remove the dot itself or its sole remaining digit.
    var mantissa_end = e_pos;
    while (mantissa_end > dot_pos + 2 and rendered[mantissa_end - 1] == '0') mantissa_end -= 1;

    if (e_pos < rendered.len) {
        const exp_len = rendered.len - e_pos;
        // Shift the exponent left to close the gap. Safe because
        // mantissa_end <= e_pos, so writes never overtake reads.
        for (rendered[e_pos..], 0..) |ch, j| {
            rendered[mantissa_end + j] = ch;
        }
        return rendered[0 .. mantissa_end + exp_len];
    }
    return rendered[0..mantissa_end];
}

/// Renders `value` (an `f64`) for `%f`, `%e`, or `%g` (and uppercase
/// variants), returning the unsigned rendered string. The caller adds the
/// sign via `formatNumeric`. Uses `std.fmt.float` (Ryu) for the digit
/// rendering, with post-processing for `%g`'s trailing-zero suppression.
fn formatFloat(buf: []u8, value: f64, conversion: u8, spec: FormatSpec) fmt.float.Error![]u8 {
    const abs_val = @abs(value);

    switch (conversion) {
        'f', 'F' => {
            const p = spec.precision orelse 6;
            const rendered: []u8 = @constCast(try fmt.float.render(buf, abs_val, .{
                .mode = .decimal,
                .precision = p,
            }));
            if (conversion == 'F') {
                for (rendered) |*ch| ch.* = std.ascii.toUpper(ch.*);
            }
            return rendered;
        },
        'e', 'E' => {
            const p = spec.precision orelse 6;
            const rendered: []u8 = @constCast(try fmt.float.render(buf, abs_val, .{
                .mode = .scientific,
                .precision = p,
            }));
            if (conversion == 'E') {
                for (rendered) |*ch| ch.* = std.ascii.toUpper(ch.*);
            }
            return rendered;
        },
        'g', 'G' => {
            const p = if (spec.precision) |pr| (if (pr == 0) @as(usize, 1) else pr) else 6;

            // For %g, decide between decimal and scientific by computing
            // the exponent that %e would produce. C: use %f if
            // P > exp >= -4, else %e.
            const bits: u64 = @bitCast(abs_val);
            const d = fmt.float.binaryToDecimal(u64, bits, 52, 11, false, fmt.float.Backend64_TablesFull);

            // inf/nan: binaryToDecimal sets exponent to special_exponent.
            if (d.exponent == 0x7fffffff) {
                const rendered: []u8 = @constCast(try fmt.float.render(buf, abs_val, .{
                    .mode = .decimal,
                    .precision = p,
                }));
                if (conversion == 'G') {
                    for (rendered) |*ch| ch.* = std.ascii.toUpper(ch.*);
                }
                return rendered;
            }

            const olength = decimalLengthU64(d.mantissa);
            const sci_exp = d.exponent + @as(i32, @intCast(olength)) - 1;

            if (sci_exp >= -4 and sci_exp < @as(i32, @intCast(p))) {
                // Decimal (%f) with precision P - 1 - sci_exp.
                const dec_prec: usize = @intCast(@as(i64, @intCast(p)) - 1 - @as(i64, @intCast(sci_exp)));
                var rendered: []u8 = @constCast(try fmt.float.formatDecimal(u64, buf, d, dec_prec));
                if (!spec.alt_form) {
                    rendered = stripTrailingZeros(buf, rendered);
                }
                if (conversion == 'G') {
                    for (rendered) |*ch| ch.* = std.ascii.toUpper(ch.*);
                }
                return rendered;
            } else {
                // Scientific (%e) with precision P - 1.
                var rendered: []u8 = @constCast(try fmt.float.formatScientific(u64, buf, d, p - 1));
                if (!spec.alt_form) {
                    rendered = stripTrailingZeros(buf, rendered);
                }
                if (conversion == 'G') {
                    for (rendered) |*ch| ch.* = std.ascii.toUpper(ch.*);
                }
                return rendered;
            }
        },
        else => unreachable,
    }
}

/// [format]
pub fn formatCmd(interp: *Interp, args: []Shimmerable) !void {
    const fmt_bytes = try args[1].current().getString();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(heap.global_gpa);

    var arg_i: usize = 2;
    var i: usize = 0;
    while (i < fmt_bytes.len) {
        if (fmt_bytes[i] != '%') {
            try out.append(heap.global_gpa, fmt_bytes[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i < fmt_bytes.len and fmt_bytes[i] == '%') {
            // Escaped percent.
            try out.append(heap.global_gpa, '%');
            i += 1;
            continue;
        }

        var spec: FormatSpec = .{};
        while (i < fmt_bytes.len) : (i += 1) {
            switch (fmt_bytes[i]) {
                '-' => spec.left_align = true,
                '+' => spec.force_sign = true,
                ' ' => spec.space_sign = true,
                '0' => spec.zero_pad = true,
                '#' => spec.alt_form = true,
                else => break,
            }
        }
        if (i < fmt_bytes.len and fmt_bytes[i] >= '0' and fmt_bytes[i] <= '9') {
            var w: usize = 0;
            while (i < fmt_bytes.len and fmt_bytes[i] >= '0' and fmt_bytes[i] <= '9') : (i += 1) {
                w = w * 10 + (fmt_bytes[i] - '0');
            }
            spec.width = w;
        }
        if (i < fmt_bytes.len and fmt_bytes[i] == '.') {
            i += 1;
            var p: usize = 0;
            while (i < fmt_bytes.len and fmt_bytes[i] >= '0' and fmt_bytes[i] <= '9') : (i += 1) {
                p = p * 10 + (fmt_bytes[i] - '0');
            }
            spec.precision = p;
        }
        if (i >= fmt_bytes.len) {
            try interp.setResultFormatted("format string ended in middle of field specifier", .{});
            return error.EvalError;
        }
        const conversion = fmt_bytes[i];
        i += 1;

        switch (conversion) {
            'd', 'i', 'u' => {
                const value = try interp.getInteger(try nextFormatArg(interp, args, &arg_i));
                try formatInteger(heap.global_gpa, value, 10, false, spec, &out);
            },
            'x', 'X' => {
                const value = try interp.getInteger(try nextFormatArg(interp, args, &arg_i));
                try formatInteger(heap.global_gpa, value, 16, conversion == 'X', spec, &out);
            },
            'o' => {
                const value = try interp.getInteger(try nextFormatArg(interp, args, &arg_i));
                try formatInteger(heap.global_gpa, value, 8, false, spec, &out);
            },
            'c' => {
                const value = try interp.getInteger(try nextFormatArg(interp, args, &arg_i));
                if (value < 0 or value > 0x10FFFF) {
                    try interp.setResultFormatted("expected a Unicode codepoint but got \"{d}\"", .{value});
                    return error.EvalError;
                }
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(@intCast(value), &buf) catch {
                    try interp.setResultFormatted("expected a Unicode codepoint but got \"{d}\"", .{value});
                    return error.EvalError;
                };
                try padAndAppend(heap.global_gpa, buf[0..len], spec, &out);
            },
            's' => {
                const value = try (try nextFormatArg(interp, args, &arg_i)).current().getString();
                const truncated = if (spec.precision) |p| value[0..@min(p, value.len)] else value;
                try padAndAppend(heap.global_gpa, truncated, spec, &out);
            },
            'f', 'F', 'e', 'E', 'g', 'G' => {
                const value = try interp.getFloat(try nextFormatArg(interp, args, &arg_i));
                var buf: [1024]u8 = undefined;
                const rendered = formatFloat(&buf, value, conversion, spec) catch |err| switch (err) {
                    error.BufferTooSmall => {
                        try interp.setResultFormatted("precision too large for format specifier", .{});
                        return error.EvalError;
                    },
                };
                try formatNumeric(heap.global_gpa, rendered, std.math.signbit(value), "", spec, &out);
            },
            else => {
                try interp.setResultFormatted("bad field specifier \"{c}\"", .{conversion});
                return error.EvalError;
            },
        }
    }

    if (arg_i < args.len) {
        try interp.setResultFormatted("too many arguments for format specifiers", .{});
        return error.EvalError;
    }

    try interp.setResultString(out.items);
}

pub fn registerCommands(interp: *Interp) !void {
    try registerCommand(interp, "append", appendCmd, "varName ?value ...?", 1, null);
    try registerCommand(interp, "format", formatCmd, "formatString ?arg ...?", 1, null);
    try registerCommand(interp, "string", stringCmd, "subcommand ?arg ...?", 1, null);
}

const testing = std.testing;

fn testAppendBasic(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Append a single value to a new variable.
    try interp.testExpectScriptResult("hello", "append x hello");
    // Appending again accumulates.
    try interp.testExpectScriptResult("hello world", "append x { world}");
}

test "append basic" {
    try memutil.checkAllocationFailures(.exhaustive, testAppendBasic, .{});
}

fn testAppendMultipleValues(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // All values are concatenated in order.
    try interp.testExpectScriptResult("abc", "append x a b c");
    try interp.testExpectScriptResult("abcdef", "append x d e f");
}

test "append multiple values" {
    try memutil.checkAllocationFailures(.exhaustive, testAppendMultipleValues, .{});
}

fn testAppendToUnsetVariable(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Variable doesn't exist yet, so it should be created as empty then appended to.
    try interp.testExpectScriptResult("new", "append unset_var new");
    try interp.testExpectScriptResult("new", "set unset_var");
}

test "append to unset variable" {
    try memutil.checkAllocationFailures(.exhaustive, testAppendToUnsetVariable, .{});
}

fn testAppendNoValues(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // No values: returns current content without modifying it.
    try interp.testExpectScriptResult("hi",
        \\ set x hi
        \\ append x
    );
    // No values on an unset variable: creates it as empty string.
    try interp.testExpectScriptResult("",
        \\ append never_set
    );
}

test "append no values" {
    try memutil.checkAllocationFailures(.exhaustive, testAppendNoValues, .{});
}

fn testAppendReturnValue(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // The return value of append is the new variable contents.
    try interp.testExpectScriptResult("foobar",
        \\ set x foo
        \\ set y [append x bar]
        \\ set y
    );
}

test "append return value" {
    try memutil.checkAllocationFailures(.exhaustive, testAppendReturnValue, .{});
}

fn testStringMapBasic(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Single-character replacement.
    try interp.testExpectScriptResult("bbbb", "string map {a b} abba");

    // Single-character replacement on single-char string.
    try interp.testExpectScriptResult("b", "string map {a b} a");

    // Multiple replacements with overlapping prefixes.
    // Longer keys are tried first, so "abc" matches before "ab" or "a".
    try interp.testExpectScriptResult("A321*A*321*", "string map {abc 321 ab * a A} aabcabaababcab");
}

test "string map basic" {
    try memutil.checkAllocationFailures(.exhaustive, testStringMapBasic, .{});
}

fn testStringMapNocase(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Case-insensitive single-character replacement.
    try interp.testExpectScriptResult("bbbb", "string map -nocase {a b} Abba");

    // Case-insensitive with overlapping prefixes.
    try interp.testExpectScriptResult("A321*A*321*", "string map -nocase {aBc 321 Ab * a A} aabcabaababcab");

    // One-pair case: longer key wins regardless of case.
    try interp.testExpectScriptResult("a32aBaAb32Ab", "string map -nocase {abc 32} aAbCaBaAbAbcAb");

    // One-pair case with shorter key.
    try interp.testExpectScriptResult("a4321C4321a43214321c4321", "string map -nocase {ab 4321} aAbCaBaAbAbcAb");
}

test "string map -nocase" {
    try memutil.checkAllocationFailures(.exhaustive, testStringMapNocase, .{});
}

fn testStringMapErrorCases(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Odd number of elements in the mapping list is an error.
    try interp.testExpectScriptError(error.EvalError, "list must contain an even number of elements", "string map {a b c} abba");
}

test "string map error cases" {
    try memutil.checkAllocationFailures(.exhaustive, testStringMapErrorCases, .{});
}

fn testStringMapEmptyKeys(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Empty key is skipped; the string is returned unchanged.
    try interp.testExpectScriptResult("foo", "string map -nocase {{} abc} foo");

    // Empty key followed by a real key still replaces the real key.
    try interp.testExpectScriptResult("baroo", "string map -nocase {{} abc f bar {} def} foo");
}

test "string map empty keys" {
    try memutil.checkAllocationFailures(.exhaustive, testStringMapEmptyKeys, .{});
}

fn testStringMapCaseSensitive(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Case-sensitive: "Ab" only matches "Ab", not "ab" or "aB".
    try interp.testExpectScriptResult("a4321CaBa43214321c4321", "string map {Ab 4321} aAbCaBaAbAbcAb");
}

test "string map case sensitive" {
    try memutil.checkAllocationFailures(.exhaustive, testStringMapCaseSensitive, .{});
}

fn testStringFirst(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("12", "string first bq abcdefgbcefgbqrs");
    // Empty needle never matches.
    try interp.testExpectScriptResult("-1", "string first {} x123xx345xxx789xxx012");
    try interp.testExpectScriptResult("-1", "string first a {}");
    try interp.testExpectScriptResult("-1", "string first aaa b");
    try interp.testExpectScriptResult("-1", "string first a bcd");
    // A plain negative literal index clamps to the start, not the end.
    try interp.testExpectScriptResult("0", "string first a aaa -4");
    // end-relative index.
    try interp.testExpectScriptResult("3", "string first a abcabc end-4");
    // Out of range index.
    try interp.testExpectScriptResult("-1", "string first abc abc 1000000");
}

test "string first" {
    try memutil.checkAllocationFailures(.exhaustive, testStringFirst, .{});
}

fn testStringLast(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("7", "string last xx xxxx123xx345x678");
    try interp.testExpectScriptResult("12", "string last x xxxx123xx345x678");
    try interp.testExpectScriptResult("-1", "string last abc def");
    // A plain negative literal index means "nowhere to search", not "from the end".
    try interp.testExpectScriptResult("-1", "string last ba badbad -1");
    // end-relative index bounds where a match may *start*; the match itself
    // may extend past that boundary.
    try interp.testExpectScriptResult("3", "string last ba badbad end-1");
    try interp.testExpectScriptResult("0", "string last ba badbad end-2");
}

test "string last" {
    try memutil.checkAllocationFailures(.exhaustive, testStringLast, .{});
}

fn testStringIs(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Empty string: true unless -strict.
    try interp.testExpectScriptResult("true", "string is alpha {}");
    try interp.testExpectScriptResult("false", "string is alpha -strict {}");

    try interp.testExpectScriptResult("true", "string is alnum abc123");
    try interp.testExpectScriptResult("true", "string is alpha abc");
    try interp.testExpectScriptResult("false", "string is alpha abc123");
    try interp.testExpectScriptResult("true", "string is ascii abc123");
    try interp.testExpectScriptResult("true", "string is digit 0123456789");
    try interp.testExpectScriptResult("false", "string is digit +123567");
    try interp.testExpectScriptResult("true", "string is lower abc");
    try interp.testExpectScriptResult("true", "string is upper ABC");
    try interp.testExpectScriptResult("true", "string is space { \t}");
    try interp.testExpectScriptResult("true", "string is xdigit abcdef123");
    try interp.testExpectScriptResult("false", "string is xdigit abcdefg");
    try interp.testExpectScriptResult("true", "string is print abc");
    try interp.testExpectScriptResult("true", "string is graph abc");
    try interp.testExpectScriptResult("true", "string is punct {!@#}");

    try interp.testExpectScriptResult("true", "string is integer +1234567890");
    try interp.testExpectScriptResult("false", "string is integer 123abc");
    try interp.testExpectScriptResult("true", "string is double 1.0");
    try interp.testExpectScriptResult("false", "string is double abc");
    try interp.testExpectScriptResult("true", "string is boolean true");
    try interp.testExpectScriptResult("false", "string is boolean nope");

    try interp.testExpectScriptError(error.EvalError, "bad class \"bogus\": must be integer, alpha, alnum, ascii, digit, double, lower, upper, space, xdigit, control, print, graph, punct, boolean", "string is bogus str");

    // A subcommand rejecting its own arguments (here, a middle argument that
    // isn't -strict) should report *this subcommand's* usage, not the
    // top-level `string` command's generic "subcommand ?arg ...?".
    try interp.testExpectScriptError(error.EvalError, "wrong # args: should be \"string is class ?-strict? str\"", "string is alpha -not-strict str");
}

test "string is" {
    try memutil.checkAllocationFailures(.exhaustive, testStringIs, .{});
}

fn testStringMatch(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("true", "string match a*c abc");
    try interp.testExpectScriptResult("false", "string match a*c abd");
    try interp.testExpectScriptResult("true", "string match -nocase A*C abc");
}

test "string match" {
    try memutil.checkAllocationFailures(.exhaustive, testStringMatch, .{});
}

fn testStringRepeat(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("ababab", "string repeat ab 3");
    try interp.testExpectScriptResult("", "string repeat ab 0");
    try interp.testExpectScriptResult("", "string repeat ab -1");
    try interp.testExpectScriptResult("", "string repeat {} 5");
}

test "string repeat" {
    try memutil.checkAllocationFailures(.exhaustive, testStringRepeat, .{});
}

fn testStringReverse(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("cba", "string reverse abc");
    try interp.testExpectScriptResult("", "string reverse {}");
}

test "string reverse" {
    try memutil.checkAllocationFailures(.exhaustive, testStringReverse, .{});
}

fn testStringCaseConversion(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("abc", "string tolower ABC");
    try interp.testExpectScriptResult("ABC", "string toupper abc");
    // Only the first character is title-cased; the rest is lowercased,
    // even across word boundaries.
    try interp.testExpectScriptResult("Abcdef", "string totitle abCDEf");
    try interp.testExpectScriptResult("Abc xyz", "string totitle {abc xYz}");
    try interp.testExpectScriptResult("123#$&*()", "string totitle {123#$&*()}");
}

test "string case conversion" {
    try memutil.checkAllocationFailures(.exhaustive, testStringCaseConversion, .{});
}

fn testStringTrim(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("hello", "string trim {  hello  }");
    try interp.testExpectScriptResult("hello  ", "string trimleft {  hello  }");
    try interp.testExpectScriptResult("  hello", "string trimright {  hello  }");
    try interp.testExpectScriptResult("hello", "string trim xxhelloxx x");
    try interp.testExpectScriptResult("", "string trim {   }");
}

test "string trim" {
    try memutil.checkAllocationFailures(.exhaustive, testStringTrim, .{});
}

fn testStringReplace(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("abp", "string replace abcdefghijklmnop 2 14");
    try interp.testExpectScriptResult("abcdefg", "string replace abcdefghijklmnop 7 1000");
    try interp.testExpectScriptResult("abcdefghij", "string replace abcdefghijklmnop 10 end");
    // Inverted range: unchanged, even out of bounds.
    try interp.testExpectScriptResult("abcdefghijklmnop", "string replace abcdefghijklmnop 10 9");
    try interp.testExpectScriptResult("abcdefghijklmnop", "string replace abcdefghijklmnop -3 -2");
    try interp.testExpectScriptResult("defghijklmnop", "string replace abcdefghijklmnop -3 2");
    try interp.testExpectScriptResult("", "string replace abcdefghijklmnop -100 end");
    try interp.testExpectScriptResult("abcdeNEWop", "string replace abcdefghijklmnop end-10 end-2 NEW");
    try interp.testExpectScriptResult("foo", "string replace abcdefghijklmnop 0 end foo");
}

test "string replace" {
    try memutil.checkAllocationFailures(.exhaustive, testStringReplace, .{});
}

fn testStringIndexMalformed(ta: std.mem.Allocator) !void {
    // These indices are codepoint positions relative to "\xc3\xa9" decoding
    // as a single character; with UTF-8 support disabled every byte is its
    // own "codepoint", so the indices below would land on different bytes.
    if (comptime !@import("options").use_utf8) return;

    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // A truncated 3-byte lead at the very end of the string used to read
    // past the end of `bytes` and panic; it should come back as its own
    // one-byte result instead, matching Jim's [string index].
    try interp.testExpectScriptResult("\xe0", "string index \"\\xc3\\xa9\\xe0\" 1");
    // Same, but with one (insufficient) continuation byte present.
    try interp.testExpectScriptResult("\xe0", "string index \"\\xc3\\xa9\\xe0\\x80\" 1");
    // A genuinely valid multi-byte character still decodes normally.
    try interp.testExpectScriptResult("\u{e9}", "string index \"\\xc3\\xa9\" 0");
}

test "string index malformed utf8" {
    try memutil.checkAllocationFailures(.exhaustive, testStringIndexMalformed, .{});
}

fn testFormatBasic(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("hello world", "format {%s %s} hello world");
    try interp.testExpectScriptResult("42", "format %d 42");
    try interp.testExpectScriptResult("-42", "format %d -42");
    try interp.testExpectScriptResult("100%", "format {%d%%} 100");
    try interp.testExpectScriptResult("1.2346", "format %6.4f 1.23456");
    // %e uses Ryu's exponent format (e0, e10, e-5).
    try interp.testExpectScriptResult("1.500000e0", "format %e 1.5");
    try interp.testExpectScriptResult("1.000000e10", "format %e 1e10");
    try interp.testExpectScriptResult("1.500000E0", "format %E 1.5");
}

test "format basic" {
    try memutil.checkAllocationFailures(.exhaustive, testFormatBasic, .{});
}

fn testFormatWidthAndFlags(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("   42", "format %5d 42");
    try interp.testExpectScriptResult("42   ", "format %-5d 42");
    try interp.testExpectScriptResult("00042", "format %05d 42");
    try interp.testExpectScriptResult("+42", "format %+d 42");
    try interp.testExpectScriptResult(" 42", "format {% d} 42");
    // Zero-padding lands after the sign, not before it.
    try interp.testExpectScriptResult("-0042", "format %05d -42");
}

test "format width and flags" {
    try memutil.checkAllocationFailures(.exhaustive, testFormatWidthAndFlags, .{});
}

fn testFormatRadixAndChar(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("ff", "format %x 255");
    try interp.testExpectScriptResult("FF", "format %X 255");
    try interp.testExpectScriptResult("0xff", "format %#x 255");
    try interp.testExpectScriptResult("10", "format %o 8");
    try interp.testExpectScriptResult("A", "format %c 65");
}

test "format radix and char" {
    try memutil.checkAllocationFailures(.exhaustive, testFormatRadixAndChar, .{});
}

fn testFormatStringPrecision(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("he", "format %.2s hello");
    try interp.testExpectScriptResult("        hi", "format %10s hi");
    try interp.testExpectScriptResult("hi        ", "format %-10s hi");
}

test "format string precision" {
    try memutil.checkAllocationFailures(.exhaustive, testFormatStringPrecision, .{});
}

fn testFormatNotEnoughArguments(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptError(error.EvalError,
        \\not enough arguments for all format specifiers
    , "format %d");
}

test "format not enough arguments" {
    try memutil.checkAllocationFailures(.exhaustive, testFormatNotEnoughArguments, .{});
}

fn testFormatG(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // %g strips trailing zeros but always keeps a fractional part, and
    // picks between decimal and scientific by exponent.
    try interp.testExpectScriptResult("1.0", "format %g 1.0");
    try interp.testExpectScriptResult("1.5", "format %g 1.5");
    try interp.testExpectScriptResult("100.0", "format %g 100.0");
    try interp.testExpectScriptResult("100000.0", "format %g 100000.0");
    // Exponent >= 6 (default precision): switches to scientific.
    try interp.testExpectScriptResult("1.0e6", "format %g 1000000.0");
    try interp.testExpectScriptResult("1.0e8", "format %g 100000000.0");
    // Exponent < -4: switches to scientific.
    try interp.testExpectScriptResult("1.0e-5", "format %g 0.00001");
    // Exponent exactly -4: stays decimal.
    try interp.testExpectScriptResult("0.0001", "format %g 0.0001");
    try interp.testExpectScriptResult("0.0", "format %g 0.0");
    // %G is uppercase.
    try interp.testExpectScriptResult("1.0E8", "format %G 100000000.0");
    // %#g keeps trailing zeros.
    try interp.testExpectScriptResult("1.00000", "format %#g 1.0");
}

test "format g conversion" {
    try memutil.checkAllocationFailures(.exhaustive, testFormatG, .{});
}

fn testFormatSpecial(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // inf and nan render as their names, sign applied by formatNumeric.
    try interp.testExpectScriptResult("inf", "format %f inf");
    try interp.testExpectScriptResult("nan", "format %f nan");
    try interp.testExpectScriptResult("-inf", "format %f -inf");
    try interp.testExpectScriptResult("inf", "format %g inf");
    try interp.testExpectScriptResult("1.234560e2", "format %e 123.456");
    try interp.testExpectScriptResult("0.000000e0", "format %e 0.0");
}

test "format special values" {
    try memutil.checkAllocationFailures(.exhaustive, testFormatSpecial, .{});
}

fn testFormatErrors(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Negative codepoint: clean error, not a crash.
    try interp.testExpectScriptError(error.EvalError,
        \\expected a Unicode codepoint but got "-1"
    , "format %c -1");
    // Too many arguments.
    try interp.testExpectScriptError(error.EvalError,
        \\too many arguments for format specifiers
    , "format %d 1 2 3");
    // Absurd precision on a float: clean error, not a crash.
    try interp.testExpectScriptError(error.EvalError,
        \\precision too large for format specifier
    , "format %.2000f 1.0");
}

test "format error cases" {
    try memutil.checkAllocationFailures(.exhaustive, testFormatErrors, .{});
}

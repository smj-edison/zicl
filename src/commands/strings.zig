const std = @import("std");

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
        if ((try interp.getVariable(var_name)).asValue()) |val| {
            break :blk try val.getString();
        } else {
            break :blk "";
        }
    };

    // Fast path: no values to append, just ensure the variable exists and return it.
    if (args.len == 2) {
        if ((try interp.getVariable(var_name)).asValue()) |val| {
            interp.setResult(val);
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
    defer combined_str.asHead().release();

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

pub fn registerCommands(interp: *Interp) !void {
    try registerCommand(interp, "append", appendCmd, "varName ?value ...?", 1, null);
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

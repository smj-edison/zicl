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

pub fn stringCmd(interp: *Interp, args: []Shimmerable) !void {
    const Subcommands = enum {
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
    const Parser = objects.SubcommandParser(Subcommands, &.{
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
    const subcommand: Subcommands = try interp.wrapError(&det, Parser.parse(&det, args));

    const sub_args = args[2..];
    const was_wrong_usage = wrong_usage: {
        switch (subcommand) {
            .bytelength => {
                const bytes = try sub_args[0].current().getString();
                try interp.setResultInteger(@intCast(bytes.len));
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
                        if (i + 1 >= sub_args.len - 2) break :wrong_usage true; // There needs to be a value after `-length`.
                        opt_length = std.math.lossyCast(usize, try interp.getInteger(&sub_args[i + 1]));
                        i += 1;
                    } else break :wrong_usage true;
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
                        .lt => try interp.setResultInteger(-1),
                        .eq => try interp.setResultInteger(0),
                        .gt => try interp.setResultInteger(1),
                    }
                }
            },
            .length => {
                try interp.setResultInteger(@intCast(try String.getCodepointLength(&sub_args[0])));
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
                    if (!try sub_args[0].current().equalsString("-nocase")) break :wrong_usage true;
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
                    const byte_index = strutil.cpIndex(bytes, @intCast(abs_index)).?;
                    const len = std.unicode.utf8ByteSequenceLength(bytes[byte_index]) catch {
                        interp.setEmptyResult();
                        return;
                    };
                    try interp.setResultString(bytes[byte_index..][0..len]);
                }
            },
            else => std.debug.panic("unimplemented: {}", .{subcommand}),
        }
        break :wrong_usage false;
    };

    if (was_wrong_usage) {
        try interp.setResultFormatted(
            "wrong # args: should be \"{s} {s} {s}\"",
            .{ try args[0].current().getString(), try args[1].current().getString(), Parser.EnumToSubcommand.get(subcommand).usage },
        );
        return error.EvalError;
    }
}

pub fn registerCommands(interp: *Interp) !void {
    try registerCommand(interp, "append", appendCmd, "varName ?value ...?", 1, null, null);
    try registerCommand(interp, "string", stringCmd, "subcommand ?arg ...?", 1, null, null);
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

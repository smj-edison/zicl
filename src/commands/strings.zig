/// [append]
pub fn appendCmd(interp: *Interp, args: []Shimmerable) !void {
    // Get the variable's value if it exists, or else use an empty string.
    const var_name = &args[1];

    const var_value: []const u8 = blk: {
        if ((try interp.getVariable(var_name)).toHandle()) |val| {
            break :blk try val.getString();
        } else {
            break :blk "";
        }
    };

    // Fast path: no values to append, just ensure the variable exists and return it.
    if (args.len == 2) {
        if ((try interp.getVariable(var_name)).toHandle()) |val| {
            interp.setResult(val);
        } else {
            try interp.setVariableTo(var_name, Heap.local_heap.emptyHandle());
            interp.setEmptyResult();
        }
        return;
    }

    // Compute total length so we can allocate a single string.
    var total_len: usize = var_value.len;
    for (args[2..]) |arg| {
        total_len += (try arg.getString()).len;
    }

    var new_bytes = try Heap.global_gpa.alloc(u8, total_len);
    defer Heap.global_gpa.free(new_bytes);

    if (total_len > 0) {
        var pos: usize = 0;
        @memcpy(new_bytes[pos..(pos + var_value.len)], var_value);
        pos += var_value.len;
        for (args[2..]) |arg| {
            const s = try arg.getString();
            @memcpy(new_bytes[pos..(pos + s.len)], s);
            pos += s.len;
        }
    }

    const result = try objutil.newString(new_bytes);
    defer result.decrRefCount();
    try interp.setVariableTo(var_name, result);
    interp.setResult((try interp.getVariable(var_name)).toHandle().?);
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
    const Parser = objutil.SubcommandParser(Subcommands, &.{
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

    var det: objutil.ErrorDetails = undefined;
    const subcommand: Subcommands = try interp.wrapError(&det, Parser.parse(&det, args));

    const sub_args = args[2..];
    const was_wrong_usage = wrong_usage: {
        switch (subcommand) {
            .bytelength => {
                const bytes = try sub_args[0].getString();
                try interp.setResultInteger(@intCast(bytes.len));
            },
            .byterange => {
                const bytes = try sub_args[0].getString();
                const range = try interp.wrapError(&det, objutil.getRange(
                    &det,
                    @intCast(bytes.len),
                    &sub_args[1],
                    &sub_args[2],
                ));
                try interp.setResultString(bytes[range.start..range.end]);
            },
            .cat => {
                var new_str: std.ArrayList(u8) = .empty;
                defer new_str.deinit(Heap.global_gpa);
                for (sub_args[0..]) |handle| {
                    const str = try handle.getString();
                    try new_str.appendSlice(Heap.global_gpa, str);
                }

                try interp.setResultString(new_str.items);
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

                const bytes_a = try sub_args[i].getString();
                const bytes_b = try sub_args[i + 1].getString();

                // Fast case: [string equal], case sensitive, no max length.
                if (subcommand == .equal and !opt_case_insensitive and opt_length == null) {
                    try interp.setResultBoolean(std.mem.eql(u8, bytes_a, bytes_b));
                } else {
                    const order = strutil.compare(bytes_a, bytes_b, opt_length, opt_case_insensitive);
                    if (subcommand == .equal) {
                        try interp.setResultBoolean(order == .eq);
                    } else switch (order) {
                        .lt => try interp.setResultInteger(-1),
                        .eq => try interp.setResultInteger(0),
                        .gt => try interp.setResultInteger(1),
                    }
                }
            },
            .length => {
                try interp.setResultInteger(@intCast(try interp.getCodepointLength(&sub_args[0])));
            },
            .range => {
                const ranged_str = try interp.wrapError(
                    &det,
                    objutil.stringRange(&det, &sub_args[0], &sub_args[1], &sub_args[2]),
                );

                interp.setResultOwning(ranged_str);
            },
            .map => {
                var opt_case_insensitive = false;
                if (sub_args.len == 3) {
                    if (!try sub_args[0].current().equalsString("-nocase")) break :wrong_usage true;
                    opt_case_insensitive = true;
                }

                const map_list = &sub_args[sub_args.len - 2];
                const str_handle = &sub_args[sub_args.len - 1];

                const map_len = try interp.getListLength(map_list);
                if (@mod(map_len, 2) != 0) {
                    try interp.setResultString("list must contain an even number of elements");
                    return error.EvalError;
                }

                const pair_count = map_len / 2;
                const Pair = struct {
                    key: []const u8,
                    value: []const u8,
                    key_codepoint_len: usize,
                };

                // Precompute keys and values since the search loop is pretty hot.
                var pairs = try std.ArrayList(Pair).initCapacity(Heap.global_gpa, pair_count);
                defer pairs.deinit(Heap.global_gpa);

                // Go through and make sure every key has type .string so we can get its codepoint length.
                var key_i: u32 = 0;
                while (key_i < map_len) : (key_i += 2) {
                    var key_wb: Shimmerable = .{ .original = objutil.listItem(map_list.current(), key_i) };
                    defer key_wb.discardChanges();
                    try objutil.shimmerToString(&key_wb);
                    if (key_wb.takeShimmered().toHandle()) |new_key| {
                        // Be sure to write back the new object to the list.
                        try objutil.listSetInner(map_list.asMutable(), key_i, new_key.steal());
                    }
                }

                key_i = 0;
                while (key_i < map_len) : (key_i += 2) {
                    const key_handle = objutil.listItem(map_list.current(), key_i);
                    const value_handle = objutil.listItem(map_list.current(), key_i + 1);

                    var key_wb: Shimmerable = .{ .original = key_handle };
                    const key_codepoint_len = try objutil.getCodepointLength(&key_wb);
                    assert(key_wb.shimmered == .none);

                    pairs.appendAssumeCapacity(.{
                        .key = try key_handle.getString(),
                        .value = try value_handle.getString(),
                        .key_codepoint_len = key_codepoint_len,
                    });
                }

                const str = try str_handle.getString();

                var result: std.ArrayList(u8) = .empty;
                defer result.deinit(Heap.global_gpa);

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
                            try result.appendSlice(Heap.global_gpa, str[start..str_iter.i]);
                            no_match_start = null;
                        }
                        try result.appendSlice(Heap.global_gpa, pair.value);

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
                    try result.appendSlice(Heap.global_gpa, str[start..str_iter.i]);
                }

                try interp.setResultString(result.items);
            },
            .index => {
                const codepoint_len = try interp.getCodepointLength(&sub_args[0]);
                const bytes = try sub_args[0].getString();
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
            "wrong # args: should be \"{f} {f} {s}\"",
            .{ args[0].current(), args[1].current(), Parser.EnumToSubcommand.get(subcommand).usage },
        );
        return error.EvalError;
    }
}

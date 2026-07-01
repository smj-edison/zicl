const std = @import("std");
const math = std.math;
const testing = std.testing;
const assert = std.debug.assert;

const pcre2 = @import("pcre2");

const ioutil = @import("ioutil.zig");
const strutil = @import("strutil.zig");
const heap = @import("heap.zig");
const hashutil = heap.hashutil;
const Value = heap.Value;
const OptionalValue = heap.OptionalValue;
const Object = heap.Object;
const Tokenizer = @import("Tokenizer.zig");
const objects = @import("objects.zig");


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

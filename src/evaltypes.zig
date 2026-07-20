const std = @import("std");

const strutil = @import("strutil.zig");
const ioutil = @import("ioutil.zig");
const memutil = @import("memutil.zig");
const StructIterator = memutil.StructIterator;
const expr_parse = @import("expr_parse.zig");
const Tokenizer = @import("Tokenizer.zig");
const heap = @import("heap.zig");
const Value = heap.Value;
const OptionalValue = heap.OptionalValue;
const Object = heap.Object;
const objects = @import("objects.zig");
const allocPrintZ = objects.allocPrintZ;
const Shimmerable = objects.Shimmerable;
const ErrorDetails = objects.ErrorDetails;
const division_by_zero_message = objects.Number.division_by_zero_message;
const negative_denom_message = objects.Number.negative_denom_message;
const Interp = @import("Interp.zig");
const vartypes = @import("vartypes.zig");

const options = @import("options");

pub const EvalError = error{
    OutOfMemory,
    EvalError,
    PropagateResult,
    Break,
    Continue,
    Signal,
    Exit,
};
pub const Error = EvalError || error{
    WrongUsage,
    Tailcall,
};

/// Return code values matching Tcl's convention.
pub const ReturnCode = enum(u8) {
    ok = 0,
    @"error" = 1,
    @"return" = 2,
    @"break" = 3,
    @"continue" = 4,
    signal = 5,
    exit = 6,
    oom = 7,
    usage = 8,
    tailcall = 9,

    pub fn fromErrorUnion(value: Error!void) ReturnCode {
        if (value) {
            return .ok;
        } else |err| {
            return ReturnCode.fromError(err);
        }
    }

    pub fn fromError(err: Error) ReturnCode {
        return switch (err) {
            error.EvalError => .@"error",
            error.PropagateResult => .@"return",
            error.Break => .@"break",
            error.Continue => .@"continue",
            error.Signal => .signal,
            error.Exit => .exit,
            error.OutOfMemory => .oom,
            error.WrongUsage => .usage,
            error.Tailcall => .tailcall,
        };
    }

    pub fn toError(self: ReturnCode) Error!void {
        switch (self) {
            .ok => return,
            .@"error" => return error.EvalError,
            .@"return" => return error.PropagateResult,
            .@"break" => return error.Break,
            .@"continue" => return error.Continue,
            .signal => return error.Signal,
            .exit => return error.Exit,
            .oom => return error.OutOfMemory,
            .usage => return error.WrongUsage,
            .tailcall => return error.Tailcall,
        }
    }
};
pub const ReturnCodeEnum = objects.EnumConstructor(ReturnCode, true);

pub const CommandFn = fn (interp: *Interp, args: []Shimmerable) Interp.Error!void;
pub const CCommandFn = fn (interp: *Interp, argc: c_int, argv: [*]Value) callconv(.c) Interp.ReturnCode;

pub const ParsedScriptCommand = struct {
    line: u32,
    word_count: u32,

    fn enumerateStruct(obj: *const Object, ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const command = obj.constCastTo(ParsedScriptCommand);
        try ctx.addField(u32, info, "line", "{}", command.line);
        try ctx.addField(u32, info, "word_count", "{}", command.word_count);
    }

    pub const vtable: Object.VTable = .{
        .duplicate = null,
        .update_string = null,
        .free_internal_rep = null,
        .make_crossthread = null,
        .enumerate_struct = enumerateStruct,
        .name = @typeName(ParsedScriptCommand),
    };
};

/// This is the script object internal representation. It is an array
/// of Tokenizer.Tokens alongside a heap-stored list for all tokens' values.
///
/// For example the script:
///
/// puts hello
/// set $i $x$y [foo]BAR
///
/// will produce a ParsedScript with the following token/object pairs:
///
/// | .start_of_command  | 2     |
/// | .simple_string     | puts  |
/// | .simple_string     | hello |
/// | .start_of_command  | 4     |
/// | .simple_string     | set   |
/// | .variable_subst    | i     |
/// | .start_of_word     | 2     |
/// | .variable_subst    | x     |
/// | .variable_subst    | y     |
/// | .start_of_word     | 2     |
/// | .command_subst     | foo   |
/// | .simple_string     | BAR   |
///
/// "puts hello" has two args (.start_of_command 2), composed of single tokens.
/// (Note that the .start_of_command token is omitted for the common case of a
/// single token.)
///
/// "set $i $x$y [foo]BAR" has four (.start_of_command 4) args, the first word
/// has 1 token (.simple_string set), and the last has two tokens
/// (.start_of_word 2 .command_subst foo .simple_string BAR)
///
/// The precomputation of the command structure makes eval() faster,
/// and simpler because there aren't dynamic lengths / allocations.
///
/// -- {*} handling --
///
/// Expand is handled in a special way.
///
///   If a "word" begins with {*}, the corrisponding object type is ".none".
///
/// For example the command:
///
/// list {*}{a b}
///
/// Will produce the following pairs:
///
/// | .start_of_command | 2     |
/// | .simple_string | list  |
/// | .start_of_word | .none |
/// | .braced_string | a b   |
///
/// Note that the '.start_of_command' token also contains the source information
/// for the first word of the line for error reporting purposes
///
/// -- the substFlags field of the structure --
///
/// The `scriptObj` structure is used to represent both "script" objects
/// and "subst" objects. In the second case, there are no `LIN` and `WRD`
/// tokens. Instead `SEP` and `EOL` tokens are added as-is.
/// In addition, the field `substFlags` is used to represent the flags used to turn
/// the string into the internal representation.
/// If these flags do not match what the application requires,
/// the scriptObj is created again. For example the script:
///
/// subst -nocommands $string
/// subst -novariables $string
///
/// Will (re)create the internal representation of the $string object
/// two times.
///
pub const Script = struct {
    ref_count: usize = 1,
    /// Tokens array.
    tags: []Tokenizer.Token.Tag,
    /// The associated values for their corresponding tokens.
    values: []Value,

    pub fn parse(det: ?*ErrorDetails, value: Value) !*Script {
        const file_name: OptionalValue = if (value.asType(objects.Source)) |src| src.file_name else .none;
        const line_no = if (value.asType(objects.Source)) |src| src.line_no else 1;

        // Parse all the tokens of the script, handling any errors that come up.

        const bytes = try value.getString();
        // Because scripts are deduplicated, there may be scripts from multiple different
        // locations in the Tcl code. This means we can't use an absolute line number for the
        // script, but instead all line numbers are relative (hence why we start at 0 here).
        var parser = Tokenizer.init(bytes, 0);

        // Set up tokens list (to be added to).
        var tokens = try std.ArrayList(Tokenizer.Token).initCapacity(heap.global_gpa, bytes.len / 8);
        defer tokens.deinit(heap.global_gpa);

        // Used to ignore the first token if it's .command_separator (effectively
        // trimming any starting whitespace)
        var is_trimming_start = true;
        // Add all tokens to the list, handling any errors that may come up.
        while (true) {
            const next_token = parser.nextScriptToken();
            if (next_token) |token| {
                switch (token.tag) {
                    .command_separator, .word_separator => {
                        if (!is_trimming_start) try tokens.append(heap.global_gpa, token);
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
                        try tokens.append(heap.global_gpa, token);
                        break;
                    },
                    else => {
                        is_trimming_start = false;
                        try tokens.append(heap.global_gpa, token);
                    },
                }
            } else |err| {
                if (det) |details| {
                    details.* = .{ .message = try Tokenizer.convertTokenizerError(heap.global_gpa, err) };
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

        // Initialize the Heap-stored list that will contain the corrisponding value for each token.
        var new_token_values: std.ArrayList(Value) = .empty;
        errdefer new_token_values.deinit(heap.global_gpa);
        errdefer for (new_token_values.items) |val| val.release();

        var new_token_tags: std.ArrayList(Tokenizer.Token.Tag) = .empty;
        errdefer new_token_tags.deinit(heap.global_gpa);

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
                        const script_command = new_token_values.items[script_command_idx].asType(ParsedScriptCommand).?;
                        script_command.word_count = command_arg_count;
                    }
                    break; // Don't append a .script_command for EOF
                }

                i += 1; // Skip command separator.

                if (command_arg_count > 0) {
                    const script_command = new_token_values.items[script_command_idx].asType(ParsedScriptCommand).?;
                    script_command.word_count = command_arg_count;
                    command_arg_count = 0;
                }

                continue;
            }

            // First word of a new command.
            if (command_arg_count == 0) {
                try new_token_tags.append(heap.global_gpa, .start_of_command);
                const parsed_script_cmd = try Object.newObject(ParsedScriptCommand);
                errdefer parsed_script_cmd.head.release();
                parsed_script_cmd.body.* = .{
                    .line = tokens.items[i].loc.line_no,
                    .word_count = 0,
                };
                try new_token_values.append(heap.global_gpa, parsed_script_cmd.head.asValue());
                script_command_idx = @intCast(new_token_values.items.len - 1);
            }

            // Append the start of the word (only if necessary).
            if (found_expansion or arg_token_count > 1) {
                if (found_expansion) {
                    try new_token_tags.append(heap.global_gpa, .argument_expansion);
                } else {
                    try new_token_tags.append(heap.global_gpa, .start_of_word);
                }

                try new_token_values.append(heap.global_gpa, Value.newInt(
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

                switch (token.tag) {
                    .argument_expansion => {},
                    .escaped_string => {
                        const source = try objects.Source.newFromEscaped(
                            bytes[token.loc.start..token.loc.end],
                            file_name,
                            token.loc.line_no + line_no,
                        );
                        errdefer source.asHead().release();
                        try new_token_tags.append(heap.global_gpa, .simple_string);
                        try new_token_values.append(heap.global_gpa, source.asHead().asValue());
                    },
                    else => {
                        const source = try objects.Source.new(
                            bytes[token.loc.start..token.loc.end],
                            file_name,
                            token.loc.line_no + line_no,
                        );
                        errdefer source.asHead().release();
                        try new_token_tags.append(heap.global_gpa, token.tag);
                        try new_token_values.append(heap.global_gpa, source.asHead().asValue());
                    },
                }
            }

            // Be sure to advance our index to the next word.
            i += arg_token_count;
        }

        if (command_arg_count > 0) {
            const script_command = new_token_values.items[script_command_idx].asType(ParsedScriptCommand).?;
            script_command.word_count = command_arg_count;
        }

        const tags_slice = try new_token_tags.toOwnedSlice(heap.global_gpa);
        errdefer heap.global_gpa.free(tags_slice);
        const values_slice = try new_token_values.toOwnedSlice(heap.global_gpa);
        errdefer heap.global_gpa.free(values_slice);

        const script_on_heap = try heap.global_gpa.create(Script);
        script_on_heap.* = .{
            .tags = tags_slice,
            .values = values_slice,
        };

        if (options.token_debugging) {
            ioutil.debug("Dumping tokens\n", .{});
            script_on_heap.printTokens();
        }

        return script_on_heap;
    }

    pub fn printTokens(script: *const Script) void {
        const formatting = "[{: >3}@{: >3}]  .{s: <20}  ";

        var line: u64 = 0;
        for (script.tags.items, script.values, 0..) |token, value, i| {
            switch (token) {
                .start_of_command => {
                    const command_details = value.asType(objects.ParsedScriptCommand).?;
                    line = command_details.line;
                    ioutil.debug(
                        formatting ++ "line: {}, word count: {}\n",
                        .{ i, line, @tagName(token), command_details.line, command_details.word_count },
                    );
                },
                .start_of_word => ioutil.debug(formatting ++ "{}\n", .{ i, line, @tagName(token), value.body.integer }),
                else => {
                    const str = value.getString() catch "<oom string>";
                    ioutil.debug(formatting ++ "{s}\n", .{ i, line, @tagName(token), str });
                },
            }
        }
    }

    pub fn deinit(parsed: *Script) void {
        heap.global_gpa.free(parsed.tags);
        for (parsed.values) |value| value.release();
        heap.global_gpa.free(parsed.values);
    }

    pub fn borrow(script: *Script) *Script {
        script.ref_count += 1;
        return script;
    }

    pub fn release(script: *Script) void {
        script.ref_count -= 1;
        if (script.ref_count == 0) {
            script.deinit();
            heap.global_gpa.destroy(script);
        }
    }
};

pub const Substitution = struct {
    ref_count: usize = 1,
    /// Tokens array.
    tags: []Tokenizer.Token.Tag,
    /// The associated values for their corresponding tokens.
    values: []Value,
    flags: Tokenizer.SubstFlags,

    pub fn parse(det: ?*ErrorDetails, value: Value, flags: Tokenizer.SubstFlags) !*Substitution {
        const file_name: OptionalValue = if (value.asType(objects.Source)) |src| src.file_name else .none;
        const line_no = if (value.asType(objects.Source)) |src| src.line_no else 1;

        // Parse all the tokens of the substitution, handling any errors that come up.

        const bytes = try value.getString();
        // Because substitutions are deduplicated, there may be substitutions
        // from multiple different locations in the Tcl code. This means we
        // can't use an absolute line number for the script, but instead all
        // line numbers are relative (hence why we start at 0 here).
        var parser = Tokenizer.init(bytes, 0);

        // Set up tokens list (to be added to).
        var tokens = try std.ArrayList(Tokenizer.Token).initCapacity(heap.global_gpa, bytes.len / 8);
        defer tokens.deinit(heap.global_gpa);

        // Add all tokens to the list, handling any errors that may come up.
        while (true) {
            const next_token = parser.nextSubstToken(flags) catch |err| {
                if (det) |details| {
                    details.* = .{ .message = try Tokenizer.convertTokenizerError(heap.global_gpa, err) };
                    if (parser.error_details) |parser_details| details.index = parser_details.index;
                }
                return err;
            };
            if (next_token.tag == .end_of_file) break;
            try tokens.append(heap.global_gpa, next_token);
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

        // This list will contain the corrisponding value for each token.
        var new_token_values: std.ArrayList(Value) = .empty;
        errdefer new_token_values.deinit(heap.global_gpa);
        errdefer for (new_token_values.items) |val| val.release();

        var new_token_tags: std.ArrayList(Tokenizer.Token.Tag) = .empty;
        errdefer new_token_tags.deinit(heap.global_gpa);

        for (0..tokens.items.len) |token_idx| {
            const token = tokens.items[token_idx];

            switch (token.tag) {
                .escaped_string => {
                    const source = try objects.Source.newFromEscaped(
                        bytes[token.loc.start..token.loc.end],
                        file_name,
                        token.loc.line_no + line_no,
                    );
                    errdefer source.asHead().release();
                    try new_token_tags.append(heap.global_gpa, .simple_string); // Switch it to .simple_string.
                    try new_token_values.append(heap.global_gpa, source.asHead().asValue());
                },
                else => {
                    const source = try objects.Source.new(
                        bytes[token.loc.start..token.loc.end],
                        file_name,
                        token.loc.line_no + line_no,
                    );
                    errdefer source.asHead().release();
                    try new_token_tags.append(heap.global_gpa, token.tag);
                    try new_token_values.append(heap.global_gpa, source.asHead().asValue());
                },
            }
        }

        const tags_slice = try new_token_tags.toOwnedSlice(heap.global_gpa);
        errdefer heap.global_gpa.free(tags_slice);
        const values_slice = try new_token_values.toOwnedSlice(heap.global_gpa);
        errdefer heap.global_gpa.free(values_slice);

        const subst_on_heap = try heap.global_gpa.create(Substitution);
        subst_on_heap.* = .{
            .tags = tags_slice,
            .values = values_slice,
            .flags = flags,
        };

        return subst_on_heap;
    }

    pub fn deinit(subst: *Substitution) void {
        heap.global_gpa.free(subst.tags);
        for (subst.values) |value| value.release();
        heap.global_gpa.free(subst.values);
    }

    pub fn borrow(subst: *Substitution) *Substitution {
        subst.ref_count += 1;
        return subst;
    }

    pub fn release(script: *Substitution) void {
        script.ref_count -= 1;
        if (script.ref_count == 0) {
            script.deinit();
            heap.global_gpa.destroy(script);
        }
    }
};

pub const Expression = struct {
    ref_count: u32 = 1,
    root_node: expr_parse.Node.Index,
    nodes: std.MultiArrayList(expr_parse.Node),

    pub fn parse(det: ?*ErrorDetails, value: Value) !*Expression {
        const file_name: OptionalValue = if (value.asType(objects.Source)) |val| val.file_name.borrow() else .none;
        const line_no: u32 = if (value.asType(objects.Source)) |val| val.line_no else 1;

        // Parse all the tokens of the expr, handling any errors that come up.
        const bytes = try value.getString();
        var tokenizer = Tokenizer.init(bytes, line_no);
        var tokens = std.MultiArrayList(Tokenizer.Token).empty;
        defer tokens.deinit(heap.global_gpa);
        while (true) {
            const next_token = tokenizer.nextExpressionToken();
            if (next_token) |token| {
                try tokens.append(heap.global_gpa, token);
                if (token.tag == .end_of_file) break;
            } else |err| {
                if (det) |details| {
                    details.* = .{ .message = try Tokenizer.convertTokenizerError(heap.global_gpa, err) };
                    if (tokenizer.error_details) |parser_details| {
                        details.index = parser_details.index;
                    }
                }
                return err;
            }
        }

        if (tokens.len == 0) {
            if (det) |details| details.* = .{
                .message = try heap.global_gpa.dupeSentinel(u8, "empty expression", 0),
            };
            return error.ParseError;
        }

        // Next, go ahead and parse the expression from the tokens.
        var parser = expr_parse.Parse.init(file_name, bytes, tokens.slice());
        errdefer parser.deinit();
        if (parser.parseExpr()) |root_node| {
            const new_expr = try heap.global_gpa.create(Expression);
            // Note we don't deinit parser here, since we take ownership.
            new_expr.* = .{ .nodes = parser.nodes, .root_node = root_node.? };
            return new_expr;
        } else |err| {
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ParseError => {
                    if (det) |details| {
                        var aw = std.Io.Writer.Allocating.init(heap.global_gpa);
                        errdefer aw.deinit();
                        const err_details = parser.err.?;
                        parser.renderError(err_details, &aw.writer) catch return error.OutOfMemory;

                        details.* = .{
                            .message = try aw.toOwnedSliceSentinel(0),
                            .index = err_details.sourceIndex(&parser),
                        };
                    }
                    return error.ParseError;
                },
            }
        }
    }

    fn evalBinaryOperatorInteger(interp: *Interp, oper: expr_parse.Node.Tag, lhs: i64, rhs: i64) !i64 {
        var det: ErrorDetails = undefined;
        return switch (oper) {
            .mul => blk: {
                break :blk std.math.mul(i64, lhs, rhs) catch {
                    const widened = std.math.mulWide(i64, lhs, rhs);
                    return objects.Integer.overflowError(i128, &det, widened);
                };
            },
            .div => std.math.divFloor(i64, lhs, rhs) catch |err| switch (err) {
                error.Overflow => {
                    const widened = std.math.divFloor(i65, lhs, rhs) catch unreachable;
                    return interp.wrapError(&det, objects.Integer.overflowError(i65, &det, widened));
                },
                error.DivisionByZero => {
                    interp.setResultOwning(division_by_zero_message.get());
                    return error.DivisionByZero;
                },
            },
            .mod => std.math.mod(i64, lhs, rhs) catch |err| switch (err) {
                error.NegativeDenominator => {
                    interp.setResultOwning(negative_denom_message.get());
                    return error.NegativeDenominator;
                },
                error.DivisionByZero => {
                    interp.setResultOwning(division_by_zero_message.get());
                    return error.DivisionByZero;
                },
            },
            .sub => std.math.sub(i64, lhs, rhs) catch {
                const widened = std.math.sub(i65, lhs, rhs) catch unreachable;
                return interp.wrapError(&det, objects.Integer.overflowError(i65, &det, widened));
            },
            .add => std.math.add(i64, lhs, rhs) catch {
                const widened = std.math.add(i65, lhs, rhs) catch unreachable;
                return interp.wrapError(&det, objects.Integer.overflowError(i65, &det, widened));
            },
            .shiftl => blk: {
                if (rhs > 63) break :blk 0;
                const rhs_constrained: u6 = @intCast(rhs);
                break :blk @as(i64, @bitCast(@as(u64, @bitCast(lhs)) << rhs_constrained));
            },
            .shiftr => blk: {
                if (rhs > 63) break :blk 0;
                const rhs_constrained: u6 = @intCast(rhs);
                break :blk @as(i64, @bitCast(@as(u64, @bitCast(lhs)) >> rhs_constrained));
            },
            .rotl => blk: {
                if (rhs > 63) break :blk 0;
                const rhs_constrained: u6 = @intCast(rhs);
                break :blk @as(i64, @bitCast(std.math.rotl(u64, @bitCast(lhs), rhs_constrained)));
            },
            .rotr => blk: {
                if (rhs > 63) break :blk 0;
                const rhs_constrained: u6 = @intCast(rhs);
                break :blk @as(i64, @bitCast(std.math.rotr(u64, @bitCast(lhs), rhs_constrained)));
            },
            .bit_and => lhs & rhs,
            .bit_xor => lhs ^ rhs,
            .bit_or => lhs | rhs,
            .bool_and => @intFromBool((lhs != 0) and (rhs != 0)),
            .bool_or => @intFromBool((lhs != 0) or (rhs != 0)),
            .pow => std.math.powi(i64, lhs, rhs) catch {
                // Report overflow for both underflow and overflow. Maybe I should report separately?
                interp.setResultOwning(heap.createInternedString("integer value too big to be represented").get());
                return error.IntegerOverflow;
            },
            else => unreachable,
        };
    }

    fn evalBinaryOperatorFloat(interp: *Interp, oper: expr_parse.Node.Tag, lhs: f64, rhs: f64) !f64 {
        return switch (oper) {
            .mul => lhs * rhs,
            .div => blk: {
                if (rhs == 0.0) {
                    interp.setResultOwning(division_by_zero_message.get());
                    return error.DivisionByZero;
                } else {
                    break :blk lhs / rhs;
                }
            },
            .mod => std.math.mod(f64, lhs, rhs) catch |err| switch (err) {
                error.DivisionByZero => {
                    interp.setResultOwning(division_by_zero_message.get());
                    return error.DivisionByZero;
                },
                error.NegativeDenominator => {
                    interp.setResultOwning(negative_denom_message.get());
                    return error.NegativeDenominator;
                },
            },
            .sub => lhs - rhs,
            .add => lhs + rhs,
            .shiftl, .shiftr, .rotl, .rotr => {
                try interp.setResultFormatted("cannot bit shift on floats {} and {}", .{ lhs, rhs });
                return error.BadInteger;
            },
            .bit_and, .bit_xor, .bit_or => {
                try interp.setResultFormatted("cannot do bitwise operations on floats {} and {}", .{ lhs, rhs });
                return error.BadInteger;
            },
            .pow => std.math.pow(f64, lhs, rhs),
            else => unreachable,
        };
    }

    fn integerCompare(oper: expr_parse.Node.Tag, lhs: i64, rhs: i64) bool {
        return switch (oper) {
            .less_than => lhs < rhs,
            .greater_than => lhs > rhs,
            .less_or_equal => lhs <= rhs,
            .greater_or_equal => lhs >= rhs,
            .equal => lhs == rhs,
            .not_equal => lhs != rhs,
            else => unreachable,
        };
    }

    fn floatCompare(oper: expr_parse.Node.Tag, lhs: f64, rhs: f64) bool {
        return switch (oper) {
            .less_than => lhs < rhs,
            .greater_than => lhs > rhs,
            .less_or_equal => lhs <= rhs,
            .greater_or_equal => lhs >= rhs,
            .equal => lhs == rhs,
            .not_equal => lhs != rhs,
            else => unreachable,
        };
    }

    pub fn evalNode(interp: *Interp, nodes: std.MultiArrayList(expr_parse.Node), node_index: expr_parse.Node.Index) !Value {
        const node_tag = nodes.items(.tag)[@intFromEnum(node_index)];
        const node_data: *expr_parse.Node.Data = &nodes.items(.data)[@intFromEnum(node_index)];
        switch (node_tag) {
            .mul,
            .div,
            .mod,
            .sub,
            .add,
            .shiftl,
            .shiftr,
            .rotl,
            .rotr,
            .bit_and,
            .bit_xor,
            .bit_or,
            .pow,
            => {
                const children = node_data.binary;
                var lhs_value = try evalNode(interp, nodes, children.@"0");
                defer lhs_value.release();
                var rhs_value = try evalNode(interp, nodes, children.@"1");
                defer rhs_value.release();

                // Fast case: both are already integers/both are already floats.
                if (objects.Integer.asInt(lhs_value)) |lhs| if (objects.Integer.asInt(rhs_value)) |rhs| {
                    return try objects.Integer.new(try evalBinaryOperatorInteger(interp, node_tag, lhs, rhs));
                };

                if (objects.Float.asFloat(lhs_value)) |lhs| if (objects.Float.asFloat(rhs_value)) |rhs| {
                    return Value.newFloat(try evalBinaryOperatorFloat(interp, node_tag, lhs, rhs));
                };

                // Slow case: coerce both to int-or-float (shimmering as needed),
                // then dispatch on int vs float.
                const lhs_number = try interp.getIntOrFloatInPlace(&lhs_value);
                const rhs_number = try interp.getIntOrFloatInPlace(&rhs_value);

                if (lhs_number.asInt()) |lhs| if (rhs_number.asInt()) |rhs| {
                    return try objects.Integer.new(try evalBinaryOperatorInteger(interp, node_tag, lhs, rhs));
                };

                return Value.newFloat(try evalBinaryOperatorFloat(interp, node_tag, lhs_number.asFloat(), rhs_number.asFloat()));
            },
            .less_than,
            .greater_than,
            .less_or_equal,
            .greater_or_equal,
            .equal,
            .not_equal,
            => {
                const children = node_data.binary;
                var lhs_value = try evalNode(interp, nodes, children.@"0");
                defer lhs_value.release();
                var rhs_value = try evalNode(interp, nodes, children.@"1");
                defer rhs_value.release();

                // Fast case: both are already integers/both are already floats.
                if (objects.Integer.asInt(lhs_value)) |lhs| if (objects.Integer.asInt(rhs_value)) |rhs| {
                    return Value.newBool(integerCompare(node_tag, lhs, rhs));
                };

                if (objects.Float.asFloat(lhs_value)) |lhs| if (objects.Float.asFloat(rhs_value)) |rhs| {
                    return Value.newBool(floatCompare(node_tag, lhs, rhs));
                };

                // Slow case: try both as integers first, else fall back to both as floats.
                const lhs_number = try interp.getIntOrFloatInPlace(&lhs_value);
                const rhs_number = try interp.getIntOrFloatInPlace(&rhs_value);

                if (lhs_number.asInt()) |lhs| if (rhs_number.asInt()) |rhs| {
                    return Value.newBool(integerCompare(node_tag, lhs, rhs));
                };

                return Value.newBool(floatCompare(node_tag, lhs_number.asFloat(), rhs_number.asFloat()));
            },
            .string_equal,
            .string_not_equal,
            .string_in,
            .string_not_in,
            .string_less_than,
            .string_greater_than,
            .string_less_than_or_equal,
            .string_greater_than_or_equal,
            => {
                const children = node_data.binary;
                var lhs_value = try evalNode(interp, nodes, children.@"0");
                defer lhs_value.release();
                var rhs_value = try evalNode(interp, nodes, children.@"1");
                defer rhs_value.release();

                const lhs_string = try lhs_value.getString();
                const rhs_string = try rhs_value.getString();

                const result = switch (node_tag) {
                    .string_equal => std.mem.eql(u8, lhs_string, rhs_string),
                    .string_not_equal => !std.mem.eql(u8, lhs_string, rhs_string),
                    .string_in => std.mem.indexOf(u8, rhs_string, lhs_string) != null,
                    .string_not_in => std.mem.indexOf(u8, rhs_string, lhs_string) == null,
                    .string_less_than => std.mem.order(u8, rhs_string, lhs_string).compare(.lt),
                    .string_greater_than => std.mem.order(u8, rhs_string, lhs_string).compare(.gt),
                    .string_less_than_or_equal => std.mem.order(u8, rhs_string, lhs_string).compare(.lte),
                    .string_greater_than_or_equal => std.mem.order(u8, rhs_string, lhs_string).compare(.gte),
                    inline else => unreachable,
                };

                return Value.newInt(if (result) 1 else 0);
            },
            .ternary_conditional => {
                const children = node_data.ternary;
                var condition = try evalNode(interp, nodes, children.@"0");
                defer condition.release();
                const condition_as_bool = try interp.getBooleanInPlace(&condition);

                if (condition_as_bool) {
                    return evalNode(interp, nodes, children.@"1");
                } else {
                    return evalNode(interp, nodes, children.@"2");
                }
            },
            .value => return node_data.value.borrow(),
            .command_subst => {
                const nested_cache_key = @as(u256, interp.callFrame().signature.cache_id) ^ try node_data.value.getHashNoRegister();
                try interp.evalObjectInner(interp.callFrameIdx(), node_data.value, nested_cache_key);
                return interp.result.borrow();
            },
            .variable_subst => {
                // `node_data.value` is the variable name. Wrap it in a
                // Shimmerable so the variable resolver can shimmer it to a
                // `CachedLocalVar`/`DictSugar` in place.
                var name_shim: Shimmerable = .{ .original = node_data.value };
                defer name_shim.discardChanges();
                const var_value = try interp.getVariableOrError(&name_shim);
                return var_value.borrow();
            },
            .bool_and => {
                const children = node_data.binary;
                var lhs_value = try evalNode(interp, nodes, children.@"0");
                defer lhs_value.release();
                const lhs_as_bool = try interp.getBooleanInPlace(&lhs_value);

                if (lhs_as_bool) {
                    var rhs_value = try evalNode(interp, nodes, children.@"0");
                    defer rhs_value.release();
                    const rhs_as_bool = try interp.getBooleanInPlace(&rhs_value);
                    return Value.newBool(rhs_as_bool);
                } else {
                    // Short circuit and never evaluate rhs.
                    return Value.newBool(false);
                }
            },
            .bool_or => {
                const children = node_data.binary;
                var lhs_value = try evalNode(interp, nodes, children.@"0");
                defer lhs_value.release();
                const lhs_as_bool = try interp.getBooleanInPlace(&lhs_value);

                if (lhs_as_bool) {
                    // Short circuit and never evaluate rhs.
                    return Value.newBool(true);
                } else {
                    var rhs_value = try evalNode(interp, nodes, children.@"0");
                    defer rhs_value.release();
                    const rhs_as_bool = try interp.getBooleanInPlace(&rhs_value);
                    return Value.newBool(rhs_as_bool);
                }
            },
            .bool_not => {
                var result = try evalNode(interp, nodes, node_data.unary);
                defer result.release();
                const result_bool = try interp.getBooleanInPlace(&result);
                return Value.newBool(!result_bool);
            },
            .bit_not => {
                var result = try evalNode(interp, nodes, node_data.unary);
                defer result.release();
                const value = try interp.getIntOrFloatInPlace(&result);
                return switch (value) {
                    .integer => |int| try objects.Integer.new(~int),
                    .float => |float| {
                        try interp.setResultFormatted("cannot bit invert on float {}", .{float});
                        return error.BadInteger;
                    },
                };
            },
            .identity => {
                var result = try evalNode(interp, nodes, node_data.unary);
                // Shimmer to a number (errors on non-numeric), then return it.
                _ = try interp.getIntOrFloatInPlace(&result);
                return result;
            },
            .negation => {
                var result = try evalNode(interp, nodes, node_data.unary);
                defer result.release();
                const value = try interp.getIntOrFloatInPlace(&result);
                return switch (value) {
                    .integer => |int| try objects.Integer.new(-int),
                    .float => |float| Value.newFloat(-float),
                };
            },
            .to_int, .to_wide => {
                var result = try evalNode(interp, nodes, node_data.unary);
                defer result.release();
                const value = try interp.getIntOrFloatInPlace(&result);
                return switch (value) {
                    .integer => |int| try objects.Integer.new(int),
                    .float => |float| {
                        if (float <= @as(f64, @floatFromInt(std.math.maxInt(i64))) and
                            float >= @as(f64, @floatFromInt(std.math.minInt(i64))) and !std.math.isNan(float))
                        {
                            return try objects.Integer.new(@intFromFloat(float));
                        }
                        try interp.setResultFormatted("could not convert float \"{}\" to integer", .{float});
                        return error.BadInteger;
                    },
                };
            },
            .abs => {
                var result = try evalNode(interp, nodes, node_data.unary);
                defer result.release();
                const value = try interp.getIntOrFloatInPlace(&result);
                return switch (value) {
                    .integer => |int| blk: {
                        const abs_val: u64 = @abs(int);
                        if (abs_val > @as(u64, @intCast(std.math.maxInt(i64)))) {
                            var det: ErrorDetails = undefined;
                            return interp.wrapError(&det, objects.Integer.overflowError(u64, &det, abs_val));
                        }
                        break :blk try objects.Integer.new(@intCast(abs_val));
                    },
                    .float => |float| Value.newFloat(@abs(float)),
                };
            },
            .to_double => {
                var result = try evalNode(interp, nodes, node_data.unary);
                defer result.release();
                const value = try interp.getIntOrFloatInPlace(&result);
                return switch (value) {
                    .integer => |int| Value.newFloat(@floatFromInt(int)),
                    .float => |float| Value.newFloat(float),
                };
            },
            .round => {
                var result = try evalNode(interp, nodes, node_data.unary);
                defer result.release();
                const value = try interp.getIntOrFloatInPlace(&result);
                return switch (value) {
                    .float => |float| Value.newFloat(@round(float)),
                    .integer => |int| try objects.Integer.new(int),
                };
            },
            .rand => {
                return Value.newFloat(interp.nextRandomFloat());
            },
            .srand => {
                var result = try evalNode(interp, nodes, node_data.unary);
                defer result.release();
                const value = try interp.getIntOrFloatInPlace(&result);
                const seed_int: i64 = switch (value) {
                    .integer => |int| int,
                    .float => |float| {
                        try interp.setResultFormatted("cannot seed random with {}", .{float});
                        return error.BadInteger;
                    },
                };

                interp.prng.seed(@bitCast(seed_int));

                return Value.newFloat(interp.nextRandomFloat());
            },
            .sin,
            .cos,
            .tan,
            .asin,
            .acos,
            .atan,
            .sinh,
            .cosh,
            .tanh,
            .ceil,
            .floor,
            .exp,
            .log,
            .log10,
            .sqrt,
            => {
                var result = try evalNode(interp, nodes, node_data.unary);
                defer result.release();
                const value = try interp.getIntOrFloatInPlace(&result);
                const as_float: f64 = switch (value) {
                    .integer => |int| @floatFromInt(int),
                    .float => |float| float,
                };

                const computed = switch (node_tag) {
                    .sin => @sin(as_float),
                    .cos => @cos(as_float),
                    .tan => @tan(as_float),
                    .asin => std.math.asin(as_float),
                    .acos => std.math.acos(as_float),
                    .atan => std.math.atan(as_float),
                    .sinh => std.math.sinh(as_float),
                    .cosh => std.math.cosh(as_float),
                    .tanh => std.math.tanh(as_float),
                    .ceil => @ceil(as_float),
                    .floor => @floor(as_float),
                    .exp => @exp(as_float),
                    .log => @log(as_float),
                    .log10 => @log10(as_float),
                    .sqrt => @sqrt(as_float),
                    inline else => unreachable,
                };

                return Value.newFloat(computed);
            },
            .atan2, .fmod, .hypot => {
                var lhs_result = try evalNode(interp, nodes, node_data.binary.@"0");
                defer lhs_result.release();
                var rhs_result = try evalNode(interp, nodes, node_data.binary.@"1");
                defer rhs_result.release();
                const lhs_number = try interp.getIntOrFloatInPlace(&lhs_result);
                const rhs_number = try interp.getIntOrFloatInPlace(&rhs_result);
                const lhs: f64 = switch (lhs_number) {
                    .integer => |int| @floatFromInt(int),
                    .float => |float| float,
                };
                const rhs: f64 = switch (rhs_number) {
                    .integer => |int| @floatFromInt(int),
                    .float => |float| float,
                };

                const computed = switch (node_tag) {
                    .atan2 => std.math.atan2(lhs, rhs),
                    .fmod => @mod(lhs, rhs),
                    .hypot => @sqrt(lhs * lhs + rhs * rhs),
                    inline else => unreachable,
                };
                return Value.newFloat(computed);
            },
            .none => unreachable,
        }
    }

    pub fn deinit(expr: *Expression) void {
        expr_parse.deinitNodes(heap.global_gpa, &expr.nodes);
        expr.* = undefined;
    }

    pub fn borrow(expr: *Expression) *Expression {
        expr.ref_count += 1;
        return expr;
    }

    pub fn release(expr: *Expression) void {
        expr.ref_count -= 1;
        if (expr.ref_count == 0) {
            expr.deinit();
            heap.global_gpa.destroy(expr);
        }
    }
};

pub const Closure = struct {
    pub const interned_name = heap.createInternedString("name");
    pub const interned_impl = heap.createInternedString("impl");
    pub const interned_scope = heap.createInternedString("scope");

    closure: *Content,

    pub const Content = struct {
        /// Argument list of the procedure.
        arg_names: objects.AlwaysCanBeType(objects.List),
        /// Default values of optional arguments.
        optional_values: ?objects.AlwaysCanBeType(objects.List),
        required_arity: usize,
        optional_arity: usize,
        /// Value for the script's body.
        body: Value,
        /// We do our best to track the closure's name.
        name: OptionalValue,
        /// Hash reference pointing to the scope.
        scope_hash_ref: ?objects.AlwaysCanBeType(objects.HashReference),
        /// Whether `args` is provided as an argument name. `args`, if present, is always
        /// the last argument name.
        has_args_parameter: bool,
        /// Whether this is a method. If so, `self` is injected as the first variable at call time.
        is_method: bool,
        /// Unique identifier for cache keying.
        cache_id: u64,

        pub fn duplicate(content: *const Content) Content {
            const borrowed_args = content.arg_names.duplicate();
            const borrowed_optional_values = if (content.optional_values) |val| val.duplicate() else null;
            const borrowed_hash_ref = if (content.scope_hash_ref) |val| val.duplicate() else null;

            return .{
                .arg_names = borrowed_args,
                .optional_values = borrowed_optional_values,
                .required_arity = content.required_arity,
                .optional_arity = content.optional_arity,
                .body = content.body.borrow(),
                .name = content.name.borrow(),
                .scope_hash_ref = borrowed_hash_ref,
                .has_args_parameter = content.has_args_parameter,
                .is_method = content.is_method,
                .cache_id = content.cache_id,
            };
        }

        pub fn deinit(content: *Content) void {
            content.arg_names.inner.release();
            if (content.optional_values) |vals| vals.inner.release();

            content.body.release();
            content.name.release();
            if (content.scope_hash_ref) |ref| ref.inner.release();

            content.* = undefined;
        }

        pub fn enumerateStruct(ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
            const closure: *const Content = @ptrCast(@alignCast(info.node));
            const helper: objects.IterHelper = .{ .ctx = ctx, .info = info };
            try helper.follow(Object, "args", closure.arg_names.inner);
            try helper.followOptional(Object, "optional_values", if (closure.optional_values) |val| val.inner else null);
            try helper.followValue("body", closure.body);
            try helper.followOptionalValue("name", closure.name);
            try helper.followOptional(Object, "scope_hash_ref", if (closure.scope_hash_ref) |val| val.inner else null);
            try helper.addField(bool, "has_args_parameter", "{}", closure.has_args_parameter);
            try helper.addField(bool, "is_method", "{}", closure.is_method);
            try helper.addField(u64, "cache_id", "{}", closure.cache_id);
        }

        pub fn getUsage(closure: *Content, gpa: std.mem.Allocator, command_name: []const u8) ![]const u8 {
            var aw = std.Io.Writer.Allocating.init(gpa);
            defer aw.deinit();

            aw.writer.writeAll(command_name) catch return error.OutOfMemory;

            const closure_args = (try closure.arg_names.get()).items;
            const signature_len = closure_args.len;
            const optional_start = if (closure.has_args_parameter) closure.required_arity - 1 else closure.required_arity;

            for (0..signature_len) |i| {
                const var_name = try closure_args[i].getString();

                if (i == signature_len - 1 and closure.has_args_parameter) {
                    aw.writer.writeAll(" ?arg ...?") catch return error.OutOfMemory;
                } else if (i >= optional_start) {
                    aw.writer.print(" ?{s}?", .{var_name}) catch return error.OutOfMemory;
                } else {
                    aw.writer.print(" {s}", .{var_name}) catch return error.OutOfMemory;
                }
            }

            return try aw.toOwnedSlice();
        }
    };

    pub var closure_cache_id: std.atomic.Value(u64) = .init(0);
    pub fn parse(det: ?*ErrorDetails, bytes: []const u8) !Content {
        const is_method, const prefix_len = blk: {
            if (bytes.len > 3 and std.mem.eql(u8, bytes[0..3], "fn "))
                break :blk .{ false, @as(usize, 3) };
            if (bytes.len > 7 and std.mem.eql(u8, bytes[0..7], "method "))
                break :blk .{ true, @as(usize, 7) };
            if (det) |details| details.* = .{
                .message = try allocPrintZ("not a valid function: \"{s}\"", .{bytes}),
            };
            return error.BadClosure;
        };

        var closure_value: Shimmerable = .{ .original = try objects.String.newValue(bytes[prefix_len..]) };
        defer closure_value.deinit();

        const as_dict = objects.Dictionary.shimmerFrom(null, &closure_value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                if (det) |details| details.* = .{
                    .message = try allocPrintZ("not a valid function: \"{s}\"", .{bytes}),
                };
                return error.BadClosure;
            },
        };

        const maybe_name = try as_dict.getNoFollow(interned_name.get());
        const maybe_impl = try as_dict.getNoFollow(interned_impl.get());
        const maybe_scope = try as_dict.getNoFollow(interned_scope.get());

        const args, const body = blk: {
            if (maybe_impl.asValue()) |impl| {
                var impl_wb: Shimmerable = .{ .original = impl };
                defer impl_wb.discardChanges();
                const as_list = objects.List.shimmerFrom(null, &impl_wb) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        if (det) |details| details.* = .{
                            .message = try allocPrintZ("not a valid function implementation: \"{s}\"", .{bytes}),
                        };
                        return error.BadClosure;
                    },
                };

                if (as_list.items.len != 2) {
                    if (det) |details| details.* = .{
                        .message = try allocPrintZ("not a valid function implementation: \"{s}\"", .{bytes}),
                    };
                    return error.BadClosure;
                }

                break :blk .{
                    as_list.items[0].borrow(),
                    as_list.items[1].borrow(),
                };
            } else {
                if (det) |details| details.* = .{
                    .message = try allocPrintZ("function missing implementation: \"{s}\"", .{bytes}),
                };
                return error.BadClosure;
            }
        };
        defer args.release();
        errdefer body.release();

        var args_shim: Shimmerable = .{ .original = args };
        defer args_shim.discardChanges();
        const args_as_list = objects.List.shimmerFrom(null, &args_shim) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                if (det) |details| details.* = .{
                    .message = try allocPrintZ("function args is not a valid list: \"{s}\"", .{try args.getString()}),
                };
                return error.BadClosure;
            },
        };

        // Scope must always be a hash reference.
        var scope_hash_ref: ?*objects.HashReference = null;
        if (maybe_scope.asValue()) |scope| {
            var scope_shim: Shimmerable = .{ .original = scope };
            defer scope_shim.discardChanges();
            // We know we're the only ones who own it, so const cast won't violate any assumptions.
            const hash_ref = @constCast(try objects.HashReference.shimmerFrom(det, &scope_shim));
            hash_ref.asHead().incrRefCount();
            scope_hash_ref = hash_ref;
        }
        errdefer if (scope_hash_ref) |ref| ref.asHead().release();

        var parsed_args = try parseArgList(det, args_as_list);
        defer parsed_args.deinit();

        const arg_names_list = try objects.List.newFromSliceOwning(parsed_args.arg_names);
        errdefer arg_names_list.asHead().release();
        const optional_values_list =
            if (parsed_args.optional_values.len > 0) try objects.List.newFromSliceOwning(parsed_args.optional_values) else null;
        errdefer if (optional_values_list) |list| list.asHead().release();

        return .{
            .arg_names = .initOwning(arg_names_list),
            .optional_values = if (optional_values_list) |val| .initOwning(val) else null,
            .required_arity = parsed_args.required_arity,
            .optional_arity = parsed_args.optional_values.len,
            .body = body,
            .name = maybe_name.borrow(),
            .scope_hash_ref = if (scope_hash_ref) |val| .initOwning(val) else null,
            .has_args_parameter = parsed_args.has_args_parameter,
            .is_method = is_method,
            .cache_id = closure_cache_id.fetchAdd(1, .monotonic),
        };
    }

    pub const ParsedArgList = struct {
        arg_names: []Value,
        required_arity: usize,
        optional_values: []Value,
        has_args_parameter: bool,

        pub fn deinit(self: *ParsedArgList) void {
            for (self.arg_names) |val| val.release();
            heap.global_gpa.free(self.arg_names);
            for (self.optional_values) |val| val.release();
            heap.global_gpa.free(self.optional_values);
            self.* = undefined;
        }
    };

    /// Validates a closure argument list and extracts arity information.
    pub fn parseArgList(det: ?*ErrorDetails, args: *const objects.List) !ParsedArgList {
        var arg_names: std.ArrayList(Value) = .empty;
        arg_names.deinit(heap.global_gpa);
        var optional_values: std.ArrayList(Value) = .empty;
        optional_values.deinit(heap.global_gpa);

        var args_parameter_found = false;
        for (0..args.items.len) |i| {
            if (args_parameter_found) {
                if (det) |details| details.* = .{
                    .message = try allocPrintZ("parameter after 'args' not allowed", .{}),
                };
                return error.BadClosure;
            }

            var arg_shim: Shimmerable = .{ .original = args.items[i] };
            defer arg_shim.discardChanges();
            const arg_as_list = objects.List.shimmerFrom(null, &arg_shim) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    if (det) |details| details.* = .{ .message = try allocPrintZ(
                        "malformed argument name \"{s}\"",
                        .{try arg_shim.current().getString()},
                    ) };
                    return error.BadClosure;
                },
            };

            if (arg_as_list.items.len == 0) {
                if (det) |details| details.* = .{
                    .message = try allocPrintZ("argument with no name", .{}),
                };
                return error.BadClosure;
            } else if (arg_as_list.items.len > 2) {
                if (det) |details| details.* = .{ .message = try allocPrintZ(
                    "too many fields in argument specifier \"{s}\"",
                    .{try arg_shim.current().getString()},
                ) };
                return error.BadClosure;
            } else if (arg_as_list.items.len == 2) {
                // Optional parameter.
                if (try arg_as_list.items[0].equalsString("args")) {
                    if (det) |details| details.* = .{
                        .message = try allocPrintZ("\"args\" must be a required parameter", .{}),
                    };
                    return error.BadClosure;
                }

                // Add the optional parameter onto the optional parameters list.
                try optional_values.append(heap.global_gpa, arg_as_list.items[1]);

                // Pull out the name from the default list (`{name default}`).
                try arg_names.append(heap.global_gpa, arg_as_list.items[0]);
            } else {
                if (optional_values.items.len > 0) {
                    if (det) |details| details.* = .{
                        .message = try allocPrintZ("required parameter after optional parameter not allowed", .{}),
                    };
                    return error.BadClosure;
                }

                if (try arg_as_list.items[0].equalsString("args")) args_parameter_found = true;

                try arg_names.append(heap.global_gpa, arg_as_list.items[0]);
            }
        }

        const arg_names_slice = try arg_names.toOwnedSlice(heap.global_gpa);
        errdefer heap.global_gpa.free(arg_names_slice);
        const optional_values_slice = try optional_values.toOwnedSlice(heap.global_gpa);
        errdefer comptime unreachable;

        for (arg_names_slice) |arg| arg.incrRefCount();
        for (optional_values_slice) |value| value.incrRefCount();

        const optional_arity = optional_values_slice.len;
        const required_arity = arg_names_slice.len - optional_arity - @intFromBool(args_parameter_found);

        return .{
            .arg_names = arg_names_slice,
            .required_arity = required_arity,
            .optional_values = optional_values_slice,
            .has_args_parameter = args_parameter_found,
        };
    }

    fn duplicate(src: *const Object) !*Object {
        const new_obj = try Object.newObjectUninitialized(Closure);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj.head);
        errdefer new_obj.head.invalidateString();

        const new_closure = try heap.global_gpa.create(Content);
        errdefer heap.global_gpa.destroy(new_closure);
        new_closure.* = src.constCastTo(Closure).closure.duplicate();

        new_obj.body.* = .{ .closure = new_closure };

        return new_obj.head;
    }

    fn freeInternalRep(src: *Object) void {
        const as_closure = src.castTo(Closure);
        as_closure.closure.deinit();
        heap.global_gpa.destroy(as_closure.closure);
    }

    fn updateString(obj: *Object) !void {
        const as_closure = obj.castTo(Closure);
        const closure = as_closure.closure;
        const required = closure.required_arity;
        const optional = closure.optional_arity;

        const arg_names = try closure.arg_names.get();
        const optional_values = if (closure.optional_values) |*val| try val.get() else null;

        // Step 1: Rebuild the arguments list from required and optional args.

        var rebuilt_args = try heap.local_arena.alloc([]const u8, arg_names.items.len);

        // Get all the strings (we'll overwrite the strings for the optional arguments).
        for (arg_names.items, rebuilt_args) |arg_name, *str| str.* = try arg_name.getString();

        // Next, copy over the optional args.
        var optional_written: usize = 0;
        while (optional_written < optional) : (optional_written += 1) {
            const name_and_value: [2][]const u8 = .{
                try arg_names.items[required + optional_written].getString(), // Argument name.
                try optional_values.?.items[optional_written].getString(), // Default value.
            };
            const bytes = try strutil.quoteStrings(heap.local_arena, &name_and_value);
            rebuilt_args[required + optional_written] = bytes;
        }

        // Combine all the arguments together to get the args string.
        const args_as_string = try strutil.quoteStrings(heap.local_arena, rebuilt_args);

        // Step 2: build the closure string from its parts.

        // Build the closure: fn|method ?name <name>? impl <impl> ?scope <scope>?
        var backing: [7][]const u8 = undefined;
        var result = std.ArrayList([]const u8).initBuffer(&backing);

        result.appendAssumeCapacity(if (closure.is_method) "method" else "fn");

        if (closure.name.asValue()) |val| {
            result.appendAssumeCapacity("name");
            result.appendAssumeCapacity(try val.getString());
        }

        // `impl` is a two element list: {args body}.
        const args_and_body: [2][]const u8 = .{ args_as_string, try closure.body.getString() };
        result.appendAssumeCapacity("impl");
        result.appendAssumeCapacity(try strutil.quoteStrings(heap.local_arena, &args_and_body));

        if (closure.scope_hash_ref) |hash_ref| {
            result.appendAssumeCapacity("scope");
            result.appendAssumeCapacity(try hash_ref.inner.getString());
        }

        try obj.setStringDuplicating(try strutil.quoteStrings(heap.local_arena, result.items));
    }

    fn enumerateStruct(obj: *const Object, ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const closure = obj.constCastTo(Closure);
        const helper: objects.IterHelper = .{ .ctx = ctx, .info = info };
        try helper.follow(Content, "closure", closure.closure);
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .free_internal_rep = freeInternalRep,
        .update_string = updateString,
        .make_crossthread = null,
        .enumerate_struct = enumerateStruct,
        .name = @typeName(Closure),
    };
};

pub const NativeCommand = struct {
    description: ?[]const u8 = "",
    min_arity: usize = 0,
    max_arity: ?usize = null,
    /// If the command argument length needs to be a multiple of some
    /// amount, set this. A good example is `dict create`, as it needs
    /// an even number of arguments.
    multiple_of: ?usize = null,

    call_info: union(enum) {
        zig: *const CommandFn,
        c: *const CCommandFn,
    },

    /// Returns a string containing all the usage information. Allocates the string
    /// onto `gpa`. Produces something like `cmd ...`, or `cmd arg1 arg2 ?arg3?`
    pub fn getUsageInfo(command: *NativeCommand, gpa: std.mem.Allocator, command_name: []const u8) ![]const u8 {
        var aw = std.Io.Writer.Allocating.init(gpa);
        defer aw.deinit();

        // Write command name.
        aw.writer.writeAll(command_name) catch return error.OutOfMemory;

        if (command.description) |description| {
            aw.writer.print(" {s}", .{description}) catch return error.OutOfMemory;
        } else {
            aw.writer.writeAll(" ...") catch return error.OutOfMemory;
        }

        return try aw.toOwnedSlice();
    }

    pub fn minArity(command: NativeCommand) usize {
        switch (command.call_info) {
            .zig => |info| return info.min_arity,
            .c => |info| return @intCast(info.min_arity),
        }
    }

    pub fn maxArity(command: NativeCommand) ?usize {
        switch (command.call_info) {
            .zig => |info| return info.max_arity,
            .c => |info| if (info.max_arity >= 0) {
                return @intCast(info.max_arity);
            } else return null,
        }
    }

    pub fn multipleOf(command: NativeCommand) ?usize {
        switch (command.call_info) {
            .zig => |info| return info.multiple_of,
            .c => |info| if (info.multiple_of >= 0) {
                return @intCast(info.multiple_of);
            } else return null,
        }
    }
};

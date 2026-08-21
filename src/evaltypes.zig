const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

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
const IterHelper = objects.IterHelper;
const allocPrintZ = objects.allocPrintZ;
const Shimmerable = objects.Shimmerable;
const ErrorDetails = objects.ErrorDetails;
const division_by_zero_message = objects.Number.division_by_zero_message;
const negative_denom_message = objects.Number.negative_denom_message;
const Interp = @import("Interp.zig");
const vartypes = @import("vartypes.zig");

const options = @import("options");

pub const ReturnCodeEnum = objects.EnumConstructor(heap.ReturnCode, true);

pub const CommandFn = fn (interp: *Interp, args: []Shimmerable) Interp.Error!void;
pub const CCommandFn = fn (interp: *Interp, argc: c_int, argv: [*]Shimmerable) callconv(.c) heap.ReturnCode;

pub const ParsedScriptCommand = struct {
    line: u32,
    word_count: u32,

    fn enumerateStruct(obj: *const Object, ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const command = obj.asTypeConst(ParsedScriptCommand).?;
        try ctx.addField(u32, info, "line", "{}", .{command.line});
        try ctx.addField(u32, info, "word_count", "{}", .{command.word_count});
    }

    pub const vtable: Object.VTable = .zig(@typeName(ParsedScriptCommand), .{
        .duplicate = null,
        .update_string = null,
        .free_internal_rep = null,
        .make_crossthread = null,
        .enumerate_struct = enumerateStruct,
    });
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
pub const Script = struct {
    /// Tokens array.
    tags: []Tokenizer.Token.Tag,
    /// The associated values for their corresponding tokens.
    values: []Value,

    pub fn asHead(self: *Script) *Object {
        return Object.from(Script, self);
    }

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
        errdefer for (new_token_values.items) |val| val.dropReference();

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
                errdefer parsed_script_cmd.head.dropReference();
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
                        errdefer source.asHead().dropReference();
                        try new_token_tags.append(heap.global_gpa, .simple_string);
                        try new_token_values.append(heap.global_gpa, source.asHead().asValue());
                    },
                    else => {
                        const source = try objects.Source.new(
                            bytes[token.loc.start..token.loc.end],
                            file_name,
                            token.loc.line_no + line_no,
                        );
                        errdefer source.asHead().dropReference();
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

        const script_obj = try Object.newObject(Script);
        errdefer script_obj.head.freeBacking();

        const tags_slice = try new_token_tags.toOwnedSlice(heap.global_gpa);
        errdefer heap.global_gpa.free(tags_slice);
        const values_slice = try new_token_values.toOwnedSlice(heap.global_gpa);

        script_obj.body.* = .{
            .tags = tags_slice,
            .values = values_slice,
        };

        if (options.token_debugging) {
            ioutil.debug("Dumping tokens\n", .{});
            script_obj.body.printTokens();
        }

        return script_obj.body;
    }

    pub fn printTokens(script: *const Script) void {
        const formatting = "[{: >3}@{: >3}]  .{s: <20}  ";

        var line: u64 = 0;
        for (script.tags.items, script.values, 0..) |token, value, i| {
            switch (token) {
                .start_of_command => {
                    const command_details = value.asType(ParsedScriptCommand).?;
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

    fn freeInternalRep(src: *Object) void {
        const as_script = src.asType(Script).?;
        heap.global_gpa.free(as_script.tags);
        for (as_script.values) |value| value.dropReference();
        heap.global_gpa.free(as_script.values);
    }

    fn enumerateStruct(obj: *const Object, ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const as_script = obj.asTypeConst(Script).?;

        const helper: IterHelper = .{ .ctx = ctx, .info = info };
        try helper.followValueSlice("values", as_script.values);
        try helper.followFieldSlice(Tokenizer.Token.Tag, "tags", "{}", as_script.tags);
    }

    pub const vtable: Object.VTable = .zig(@typeName(@This()), .{
        .duplicate = null,
        .free_internal_rep = freeInternalRep,
        .update_string = null,
        .make_crossthread = null,
        .enumerate_struct = enumerateStruct,
    });
};

pub const Substitution = struct {
    /// Tokens array.
    tags: []Tokenizer.Token.Tag,
    /// The associated values for their corresponding tokens.
    values: []Value,
    flags: Tokenizer.SubstFlags,

    pub fn asHead(self: *Substitution) *Object {
        return Object.from(Substitution, self);
    }

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
        errdefer for (new_token_values.items) |val| val.dropReference();

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
                    errdefer source.asHead().dropReference();
                    try new_token_tags.append(heap.global_gpa, .simple_string); // Switch it to .simple_string.
                    try new_token_values.append(heap.global_gpa, source.asHead().asValue());
                },
                else => {
                    const source = try objects.Source.new(
                        bytes[token.loc.start..token.loc.end],
                        file_name,
                        token.loc.line_no + line_no,
                    );
                    errdefer source.asHead().dropReference();
                    try new_token_tags.append(heap.global_gpa, token.tag);
                    try new_token_values.append(heap.global_gpa, source.asHead().asValue());
                },
            }
        }

        const subst_obj = try Object.newObject(Substitution);
        errdefer subst_obj.head.freeBacking();

        const tags_slice = try new_token_tags.toOwnedSlice(heap.global_gpa);
        errdefer heap.global_gpa.free(tags_slice);
        const values_slice = try new_token_values.toOwnedSlice(heap.global_gpa);

        subst_obj.body.* = .{
            .tags = tags_slice,
            .values = values_slice,
            .flags = flags,
        };

        return subst_obj.body;
    }

    fn freeInternalRep(obj: *Object) void {
        const as_subst = obj.asType(Substitution).?;
        heap.global_gpa.free(as_subst.tags);
        for (as_subst.values) |value| value.dropReference();
        heap.global_gpa.free(as_subst.values);
    }

    fn enumerateStruct(obj: *const Object, ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const as_subst = obj.asTypeConst(Substitution).?;

        const helper: IterHelper = .{ .ctx = ctx, .info = info };
        try helper.followValueSlice("values", as_subst.values);
        try helper.followFieldSlice(Tokenizer.Token.Tag, "tags", "{}", as_subst.tags);
    }

    pub const vtable: Object.VTable = .zig(@typeName(@This()), .{
        .duplicate = null,
        .free_internal_rep = freeInternalRep,
        .update_string = null,
        .make_crossthread = null,
        .enumerate_struct = enumerateStruct,
    });
};

pub const Expression = struct {
    parsed: expr_parse.Parsed,

    pub fn asHead(self: *Expression) *Object {
        return Object.from(Expression, self);
    }

    pub fn parse(det: ?*ErrorDetails, value: Value) !*Expression {
        const file_name: OptionalValue = if (value.asType(objects.Source)) |val| val.file_name.takeReference() else .none;
        const line_no: u32 = if (value.asType(objects.Source)) |val| val.line_no else 1;

        // The expression object we'll store the result in.
        const expr_obj = try Object.newObject(Expression);
        errdefer expr_obj.head.freeBacking();

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
                return error.ParseError;
            }
        }

        if (tokens.len == 0) {
            if (det) |details| details.* = .{
                .message = try heap.global_gpa.dupeSentinel(u8, "empty expression", 0),
            };
            return error.ParseError;
        }

        // Next, go ahead and parse the expression from the tokens.
        var parser = expr_parse.Parser.init(heap.global_gpa, file_name, bytes, tokens.slice());
        defer parser.deinit();
        const parsed = parser.parseExpr() catch |err| switch (err) {
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
        };

        expr_obj.body.* = .{ .parsed = parsed };
        return expr_obj.body;
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
                    interp.setResultOwning(division_by_zero_message);
                    return error.DivisionByZero;
                },
            },
            .mod => std.math.mod(i64, lhs, rhs) catch |err| switch (err) {
                error.NegativeDenominator => {
                    interp.setResultOwning(negative_denom_message);
                    return error.NegativeDenominator;
                },
                error.DivisionByZero => {
                    interp.setResultOwning(division_by_zero_message);
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
                interp.setResultOwning(heap.InternedString.newValue("integer value too big to be represented"));
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
                    interp.setResultOwning(division_by_zero_message);
                    return error.DivisionByZero;
                } else {
                    break :blk lhs / rhs;
                }
            },
            .mod => std.math.mod(f64, lhs, rhs) catch |err| switch (err) {
                error.DivisionByZero => {
                    interp.setResultOwning(division_by_zero_message);
                    return error.DivisionByZero;
                },
                error.NegativeDenominator => {
                    interp.setResultOwning(negative_denom_message);
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

    fn areBooleansEqual(lhs: Value, rhs: Value) !bool {
        const lhs_bool = try objects.Boolean.getFromValue(null, lhs);
        const rhs_bool = try objects.Boolean.getFromValue(null, rhs);

        return lhs_bool == rhs_bool;
    }

    /// Explicitly set as return type to avoid cycles in error type inference.
    pub const EvalNodeError = Interp.Error || error{
        BadInteger,
        DivisionByZero,
        IntegerOverflow,
        NegativeDenominator,
    };

    pub fn evalNode(interp: *Interp, nodes: []expr_parse.Node, node_index: expr_parse.Node.Index) EvalNodeError!Value {
        const node = nodes[@intFromEnum(node_index)];
        switch (node.tag) {
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
                const children = node.data.binary;
                var lhs_value = try evalNode(interp, nodes, children.@"0");
                defer lhs_value.dropReference();
                var rhs_value = try evalNode(interp, nodes, children.@"1");
                defer rhs_value.dropReference();

                // Fast case: both are already integers/both are already floats.
                if (objects.Integer.asInt(lhs_value)) |lhs| if (objects.Integer.asInt(rhs_value)) |rhs| {
                    return objects.Integer.new(try evalBinaryOperatorInteger(interp, node.tag, lhs, rhs));
                };

                if (objects.Float.asFloat(lhs_value)) |lhs| if (objects.Float.asFloat(rhs_value)) |rhs| {
                    return Value.newFloat(try evalBinaryOperatorFloat(interp, node.tag, lhs, rhs));
                };

                // Slow case: coerce both to int-or-float (shimmering as needed),
                // then dispatch on int vs float.
                const lhs_number = try interp.getIntOrFloatInPlace(&lhs_value);
                const rhs_number = try interp.getIntOrFloatInPlace(&rhs_value);

                if (lhs_number.asInt()) |lhs| if (rhs_number.asInt()) |rhs| {
                    return objects.Integer.new(try evalBinaryOperatorInteger(interp, node.tag, lhs, rhs));
                };

                return Value.newFloat(try evalBinaryOperatorFloat(interp, node.tag, lhs_number.asFloat(), rhs_number.asFloat()));
            },
            .less_than,
            .greater_than,
            .less_or_equal,
            .greater_or_equal,
            .equal,
            .not_equal,
            => {
                const children = node.data.binary;
                var lhs_value = try evalNode(interp, nodes, children.@"0");
                defer lhs_value.dropReference();
                var rhs_value = try evalNode(interp, nodes, children.@"1");
                defer rhs_value.dropReference();

                // Fast case: both are already integers/both are already floats.
                if (objects.Integer.asInt(lhs_value)) |lhs| if (objects.Integer.asInt(rhs_value)) |rhs| {
                    return Value.newBool(integerCompare(node.tag, lhs, rhs));
                };

                if (objects.Float.asFloat(lhs_value)) |lhs| if (objects.Float.asFloat(rhs_value)) |rhs| {
                    return Value.newBool(floatCompare(node.tag, lhs, rhs));
                };

                // Only `==` and `!=` are allowed to compare booleans.
                if (node.tag == .equal or node.tag == .not_equal) {
                    if (areBooleansEqual(lhs_value, rhs_value)) |result| {
                        return Value.newBool(if (node.tag == .equal) result else !result);
                    } else |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.BadBoolean => {
                            // Fall through to integer comparison.
                        },
                    }
                }

                // Slow case: try both as integers first, else fall back to both as floats.
                const lhs_number = try interp.getIntOrFloatInPlace(&lhs_value);
                const rhs_number = try interp.getIntOrFloatInPlace(&rhs_value);

                if (lhs_number.asInt()) |lhs| if (rhs_number.asInt()) |rhs| {
                    return Value.newBool(integerCompare(node.tag, lhs, rhs));
                };

                return Value.newBool(floatCompare(node.tag, lhs_number.asFloat(), rhs_number.asFloat()));
            },
            .keyword_in,
            .keyword_not_in,
            => {
                const children = node.data.binary;
                var lhs_value = try evalNode(interp, nodes, children.@"0");
                defer lhs_value.dropReference();
                var rhs_value = try evalNode(interp, nodes, children.@"1");
                defer rhs_value.dropReference();

                // `in`/`ni` is about list membership, not string membership.
                var rhs_shim: Shimmerable = .{ .original = rhs_value };
                defer rhs_shim.discardChanges();
                const rhs_list = try interp.getList(&rhs_shim);

                var found = false;
                for (rhs_list.items) |item| {
                    if (try lhs_value.equals(item)) {
                        found = true;
                        break;
                    }
                }

                return Value.newBool(if (node.tag == .keyword_in) found else !found);
            },
            .string_equal,
            .string_not_equal,
            .string_less_than,
            .string_greater_than,
            .string_less_than_or_equal,
            .string_greater_than_or_equal,
            => {
                const children = node.data.binary;
                var lhs_value = try evalNode(interp, nodes, children.@"0");
                defer lhs_value.dropReference();
                var rhs_value = try evalNode(interp, nodes, children.@"1");
                defer rhs_value.dropReference();

                const lhs_string = try lhs_value.getString();
                const rhs_string = try rhs_value.getString();

                const result = switch (node.tag) {
                    .string_equal => std.mem.eql(u8, lhs_string, rhs_string),
                    .string_not_equal => !std.mem.eql(u8, lhs_string, rhs_string),
                    .string_less_than => std.mem.order(u8, rhs_string, lhs_string).compare(.lt),
                    .string_greater_than => std.mem.order(u8, rhs_string, lhs_string).compare(.gt),
                    .string_less_than_or_equal => std.mem.order(u8, rhs_string, lhs_string).compare(.lte),
                    .string_greater_than_or_equal => std.mem.order(u8, rhs_string, lhs_string).compare(.gte),
                    inline else => unreachable,
                };

                return Value.newBool(result);
            },
            .ternary_conditional => {
                const children = node.data.ternary;
                var condition = try evalNode(interp, nodes, children.@"0");
                defer condition.dropReference();
                const condition_as_bool = try interp.getBooleanInPlace(&condition);

                if (condition_as_bool) {
                    return evalNode(interp, nodes, children.@"1");
                } else {
                    return evalNode(interp, nodes, children.@"2");
                }
            },
            .value => return node.data.value.takeReference(),
            .interpolated_string => return interp.evalSubstitution(node.data.value, .{}),
            .command_subst => {
                const nested_cache_key = @as(u256, interp.callFrame().signature.cache_id) ^ try node.data.value.getHashNoRegister();
                try interp.evalValueInner(interp.callFrameIdx(), node.data.value, nested_cache_key);
                return interp.result.takeReference();
            },
            .variable_subst => {
                // `node.data.value` is the variable name. Wrap it in a
                // Shimmerable so the variable resolver can shimmer it to a
                // `CachedLocalVar`/`DictSugar` in place.
                var name_shim: Shimmerable = .{ .original = node.data.value };
                defer name_shim.discardChanges();
                const var_value = try interp.getVariableOrError(&name_shim);
                return var_value.takeReference();
            },
            .bool_and => {
                const children = node.data.binary;
                var lhs_value = try evalNode(interp, nodes, children.@"0");
                defer lhs_value.dropReference();
                const lhs_as_bool = try interp.getBooleanInPlace(&lhs_value);

                if (lhs_as_bool) {
                    var rhs_value = try evalNode(interp, nodes, children.@"1");
                    defer rhs_value.dropReference();
                    const rhs_as_bool = try interp.getBooleanInPlace(&rhs_value);
                    return Value.newBool(rhs_as_bool);
                } else {
                    // Short circuit and never evaluate rhs.
                    return Value.newBool(false);
                }
            },
            .bool_or => {
                const children = node.data.binary;
                var lhs_value = try evalNode(interp, nodes, children.@"0");
                defer lhs_value.dropReference();
                const lhs_as_bool = try interp.getBooleanInPlace(&lhs_value);

                if (lhs_as_bool) {
                    // Short circuit and never evaluate rhs.
                    return Value.newBool(true);
                } else {
                    var rhs_value = try evalNode(interp, nodes, children.@"1");
                    defer rhs_value.dropReference();
                    const rhs_as_bool = try interp.getBooleanInPlace(&rhs_value);
                    return Value.newBool(rhs_as_bool);
                }
            },
            .bool_not => {
                var result = try evalNode(interp, nodes, node.data.unary);
                defer result.dropReference();
                const result_bool = try interp.getBooleanInPlace(&result);
                return Value.newBool(!result_bool);
            },
            .bit_not => {
                var result = try evalNode(interp, nodes, node.data.unary);
                defer result.dropReference();
                const value = try interp.getIntOrFloatInPlace(&result);
                return switch (value) {
                    .integer => |int| objects.Integer.new(~int),
                    .float => |float| {
                        try interp.setResultFormatted("cannot bit invert on float {}", .{float});
                        return error.BadInteger;
                    },
                };
            },
            .identity => {
                var result = try evalNode(interp, nodes, node.data.unary);
                // Shimmer to a number (errors on non-numeric), then return it.
                _ = try interp.getIntOrFloatInPlace(&result);
                return result;
            },
            .negation => {
                var result = try evalNode(interp, nodes, node.data.unary);
                defer result.dropReference();
                const value = try interp.getIntOrFloatInPlace(&result);
                return switch (value) {
                    .integer => |int| objects.Integer.new(-int),
                    .float => |float| Value.newFloat(-float),
                };
            },
            .to_int, .to_wide => {
                var result = try evalNode(interp, nodes, node.data.unary);
                defer result.dropReference();
                const value = try interp.getIntOrFloatInPlace(&result);
                return switch (value) {
                    .integer => |int| objects.Integer.new(int),
                    .float => |float| {
                        if (float <= @as(f64, @floatFromInt(std.math.maxInt(i64))) and
                            float >= @as(f64, @floatFromInt(std.math.minInt(i64))) and !std.math.isNan(float))
                        {
                            return objects.Integer.new(@intFromFloat(float));
                        }
                        try interp.setResultFormatted("could not convert float \"{}\" to integer", .{float});
                        return error.BadInteger;
                    },
                };
            },
            .abs => {
                var result = try evalNode(interp, nodes, node.data.unary);
                defer result.dropReference();
                const value = try interp.getIntOrFloatInPlace(&result);
                return switch (value) {
                    .integer => |int| blk: {
                        const abs_val: u64 = @abs(int);
                        if (abs_val > @as(u64, @intCast(std.math.maxInt(i64)))) {
                            var det: ErrorDetails = undefined;
                            return interp.wrapError(&det, objects.Integer.overflowError(u64, &det, abs_val));
                        }
                        break :blk objects.Integer.new(@intCast(abs_val));
                    },
                    .float => |float| Value.newFloat(@abs(float)),
                };
            },
            .to_double => {
                var result = try evalNode(interp, nodes, node.data.unary);
                defer result.dropReference();
                const value = try interp.getIntOrFloatInPlace(&result);
                return switch (value) {
                    .integer => |int| Value.newFloat(@floatFromInt(int)),
                    .float => |float| Value.newFloat(float),
                };
            },
            .round => {
                var result = try evalNode(interp, nodes, node.data.unary);
                defer result.dropReference();
                const value = try interp.getIntOrFloatInPlace(&result);
                return switch (value) {
                    .float => |float| Value.newFloat(@round(float)),
                    .integer => |int| objects.Integer.new(int),
                };
            },
            .rand => {
                return Value.newFloat(interp.nextRandomFloat());
            },
            .srand => {
                var result = try evalNode(interp, nodes, node.data.unary);
                defer result.dropReference();
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
                var result = try evalNode(interp, nodes, node.data.unary);
                defer result.dropReference();
                const value = try interp.getIntOrFloatInPlace(&result);
                const as_float: f64 = switch (value) {
                    .integer => |int| @floatFromInt(int),
                    .float => |float| float,
                };

                const computed = switch (node.tag) {
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
                var lhs_result = try evalNode(interp, nodes, node.data.binary.@"0");
                defer lhs_result.dropReference();
                var rhs_result = try evalNode(interp, nodes, node.data.binary.@"1");
                defer rhs_result.dropReference();
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

                const computed = switch (node.tag) {
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

    fn freeInternalRep(obj: *Object) void {
        const as_expr = obj.asType(Expression).?;
        as_expr.parsed.deinit(heap.global_gpa);
    }

    fn enumerateStruct(obj: *const Object, ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const as_expr = obj.asTypeConst(Expression).?;
        try ctx.followNode(expr_parse.Parsed, info, "parsed", &as_expr.parsed);
    }

    pub const vtable: Object.VTable = .zig(@typeName(@This()), .{
        .duplicate = null,
        .free_internal_rep = freeInternalRep,
        .update_string = null,
        .make_crossthread = null,
        .enumerate_struct = enumerateStruct,
    });
};

pub const Closure = struct {
    pub const interned_name = heap.InternedString.newValue("name");
    pub const interned_impl = heap.InternedString.newValue("impl");
    pub const interned_scope = heap.InternedString.newValue("scope");

    content: *Content,

    pub fn asHead(self: *Closure) *Object {
        return Object.from(Closure, self);
    }

    pub const Content = struct {
        /// Argument list of the procedure.
        arg_names: *objects.List,
        /// Default values of optional arguments.
        optional_values: ?*objects.List,
        required_arity: usize,
        optional_arity: usize,
        /// Value for the script's body.
        body: Value,
        /// We do our best to track the closure's name.
        name: OptionalValue,
        /// Dictionary containing the scope.
        scope: ?*objects.Dictionary,
        /// Whether `args` is provided as an argument name. `args`, if present, is always
        /// the last argument name.
        has_args_parameter: bool,
        /// Whether this is a method. If so, `self` is injected as the first variable at call time.
        is_method: bool,
        /// Unique identifier for cache keying.
        cache_id: u64,

        pub fn duplicate(content: *const Content) Content {
            assert(content.arg_names.asHead().metadata.cross_thread);
            content.arg_names.asHead().incrRefCount();
            if (content.optional_values) |val| {
                assert(val.asHead().metadata.cross_thread);
                val.asHead().incrRefCount();
            }
            if (content.scope) |val| {
                assert(val.asHead().metadata.cross_thread);
                val.asHead().incrRefCount();
            }

            return .{
                .arg_names = content.arg_names,
                .optional_values = content.optional_values,
                .required_arity = content.required_arity,
                .optional_arity = content.optional_arity,
                .body = content.body.takeReference(),
                .name = content.name.takeReference(),
                .scope = content.scope,
                .has_args_parameter = content.has_args_parameter,
                .is_method = content.is_method,
                .cache_id = content.cache_id,
            };
        }

        pub fn deinit(content: *Content) void {
            content.arg_names.asHead().dropReference();
            if (content.optional_values) |vals| vals.asHead().dropReference();

            content.body.dropReference();
            content.name.dropReference();
            if (content.scope) |ref| ref.asHead().dropReference();

            content.* = undefined;
        }

        pub fn enumerateStruct(ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
            const closure: *const Content = @ptrCast(@alignCast(info.node));
            const helper: objects.IterHelper = .{ .ctx = ctx, .info = info };
            try helper.follow(Object, "args", closure.arg_names.asHead());
            try helper.followOptional(Object, "optional_values", if (closure.optional_values) |val| val.asHead() else null);
            try helper.followValue("body", closure.body);
            try helper.followOptionalValue("name", closure.name);
            try helper.followOptional(Object, "scope", if (closure.scope) |val| val.asHead() else null);
            try helper.addField(bool, "has_args_parameter", "{}", .{closure.has_args_parameter});
            try helper.addField(bool, "is_method", "{}", .{closure.is_method});
            try helper.addField(u64, "cache_id", "{}", .{closure.cache_id});
        }

        pub fn getUsage(closure: *Content, gpa: std.mem.Allocator, command_name: []const u8) ![]const u8 {
            var aw = std.Io.Writer.Allocating.init(gpa);
            defer aw.deinit();

            aw.writer.writeAll(command_name) catch return error.OutOfMemory;

            const closure_args = closure.arg_names.items;
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
    pub fn parse(det: ?*ErrorDetails, bytes: []const u8) !*Closure {
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

        const maybe_name = try as_dict.getNoFollow(interned_name);
        const maybe_impl = try as_dict.getNoFollow(interned_impl);
        const maybe_scope = try as_dict.getNoFollow(interned_scope);

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
                    as_list.items[0].takeReference(),
                    as_list.items[1].takeReference(),
                };
            } else {
                if (det) |details| details.* = .{
                    .message = try allocPrintZ("function missing implementation: \"{s}\"", .{bytes}),
                };
                return error.BadClosure;
            }
        };
        defer args.dropReference();
        errdefer body.dropReference();

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

        // Scope must always be a dictionary.
        var scope: ?*objects.Dictionary = null;
        if (maybe_scope.asValue()) |scope_hash_ref| {
            var scope_hash_ref_shim: Shimmerable = .{ .original = scope_hash_ref };
            defer scope_hash_ref_shim.discardChanges();
            // We know we're the only ones who own it, so const cast won't violate any assumptions.
            const hash_ref = try objects.HashReference.shimmerFrom(det, &scope_hash_ref_shim);

            var scope_shim: Shimmerable = .{ .original = hash_ref.ref.asValue() };
            defer scope_shim.discardChanges();
            _ = try objects.Dictionary.shimmerFrom(null, &scope_shim);
            scope = scope_shim.current().takeReference().asType(objects.Dictionary).?;
        }
        errdefer if (scope) |val| val.asHead().dropReference();

        var parsed_args = try parseArgList(det, args_as_list);
        defer parsed_args.deinit();

        const arg_names_list = try objects.List.new(parsed_args.arg_names);
        errdefer arg_names_list.asHead().dropReference();
        const optional_values_list =
            if (parsed_args.optional_values.len > 0) try objects.List.new(parsed_args.optional_values) else null;
        errdefer if (optional_values_list) |list| list.asHead().dropReference();

        const closure_content = try heap.global_gpa.create(Content);
        errdefer heap.global_gpa.destroy(closure_content);
        const closure_obj = try Object.newObject(Closure);

        // By making these values crossthread, we can ensure they never shimmer away from their current type.
        arg_names_list.asHead().makeCrossthread();
        if (optional_values_list) |val| val.asHead().makeCrossthread();
        if (scope) |val| val.asHead().makeCrossthread();

        closure_content.* = .{
            .arg_names = arg_names_list,
            .optional_values = optional_values_list,
            .required_arity = parsed_args.required_arity,
            .optional_arity = parsed_args.optional_values.len,
            .body = body,
            .name = maybe_name.takeReference(),
            .scope = scope,
            .has_args_parameter = parsed_args.has_args_parameter,
            .is_method = is_method,
            .cache_id = closure_cache_id.fetchAdd(1, .monotonic),
        };
        closure_obj.body.content = closure_content;

        return closure_obj.body;
    }

    pub const ParsedArgList = struct {
        arg_names: []Value,
        required_arity: usize,
        optional_values: []Value,
        has_args_parameter: bool,

        pub fn deinit(self: *ParsedArgList) void {
            for (self.arg_names) |val| val.dropReference();
            heap.global_gpa.free(self.arg_names);
            for (self.optional_values) |val| val.dropReference();
            heap.global_gpa.free(self.optional_values);
            self.* = undefined;
        }
    };

    /// Validates a closure argument list and extracts arity information.
    pub fn parseArgList(det: ?*ErrorDetails, args: *const objects.List) !ParsedArgList {
        var arg_names: std.ArrayList(Value) = .empty;
        defer arg_names.deinit(heap.global_gpa);
        defer for (arg_names.items) |item| item.dropReference();
        var optional_values: std.ArrayList(Value) = .empty;
        defer optional_values.deinit(heap.global_gpa);
        defer for (optional_values.items) |item| item.dropReference();

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

                // Reserved up front, since a failing append would strand the reference in its argument.
                try optional_values.ensureUnusedCapacity(heap.global_gpa, 1);
                try arg_names.ensureUnusedCapacity(heap.global_gpa, 1);

                // Add the optional parameter onto the optional parameters list.
                optional_values.appendAssumeCapacity(arg_as_list.items[1].takeReference());

                // Pull out the name from the default list (`{name default}`).
                arg_names.appendAssumeCapacity(arg_as_list.items[0].takeReference());
            } else {
                if (optional_values.items.len > 0) {
                    if (det) |details| details.* = .{
                        .message = try allocPrintZ("required parameter after optional parameter not allowed", .{}),
                    };
                    return error.BadClosure;
                }

                if (try arg_as_list.items[0].equalsString("args")) args_parameter_found = true;

                try arg_names.ensureUnusedCapacity(heap.global_gpa, 1);
                arg_names.appendAssumeCapacity(arg_as_list.items[0].takeReference());
            }
        }

        const arg_names_slice = try arg_names.toOwnedSlice(heap.global_gpa);
        errdefer heap.global_gpa.free(arg_names_slice);
        errdefer for (arg_names_slice) |item| item.dropReference();
        const optional_values_slice = try optional_values.toOwnedSlice(heap.global_gpa);
        errdefer comptime unreachable;

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

        const new_content = try heap.global_gpa.create(Content);
        errdefer heap.global_gpa.destroy(new_content);
        new_content.* = src.asTypeConst(Closure).?.content.duplicate();

        new_obj.body.* = .{ .content = new_content };

        return new_obj.head;
    }

    fn freeInternalRep(src: *Object) void {
        const as_closure = src.asType(Closure).?;
        as_closure.content.deinit();
        heap.global_gpa.destroy(as_closure.content);
    }

    fn updateString(obj: *Object) !void {
        const closure = obj.asType(Closure).?.content;
        const required = closure.required_arity;
        const optional = closure.optional_arity;

        const arg_names = closure.arg_names;
        const optional_values = closure.optional_values;

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

        var scope_hash_ref: ?[heap.hashutil.hash_and_prepend_len]u8 = null;
        if (closure.scope) |scope| {
            result.appendAssumeCapacity("scope");
            // Use `getHashRegistering`, as the hash has escaped.
            scope_hash_ref = objects.HashReference.render(try scope.asHead().getHashRegistering());
            result.appendAssumeCapacity(&scope_hash_ref.?);
        }

        try obj.setStringDuplicating(try strutil.quoteStrings(heap.local_arena, result.items));
    }

    fn enumerateStruct(obj: *const Object, ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const closure = obj.asTypeConst(Closure).?;
        const helper: objects.IterHelper = .{ .ctx = ctx, .info = info };
        try helper.follow(Content, "closure", closure.content);
    }

    fn makeCrossthread(obj: *Object) void {
        const content = obj.asType(Closure).?.content;
        assert(content.arg_names.asHead().metadata.cross_thread);
        if (content.optional_values) |optional| assert(optional.asHead().metadata.cross_thread);
        content.body.makeCrossthread();
        content.name.makeCrossthread();
        if (content.scope) |scope| assert(scope.asHead().metadata.cross_thread);
    }

    pub const vtable: Object.VTable = .zig(@typeName(@This()), .{
        .duplicate = duplicate,
        .free_internal_rep = freeInternalRep,
        .update_string = updateString,
        .make_crossthread = makeCrossthread,
        .enumerate_struct = enumerateStruct,
    });
};

pub const CachedNativeCommand = struct {
    command: *const NativeCommand,
    command_epoch: u64,

    fn makeCrossthread(obj: *Object) void {
        assert(obj.maybeGetString() != null);
        obj.vtable = &objects.None.vtable;
    }

    pub const vtable: Object.VTable = .zig(@typeName(CachedNativeCommand), .{
        .duplicate = Object.duplicateStringOnly,
        .update_string = null,
        .free_internal_rep = null,
        .make_crossthread = makeCrossthread,
        // TODO same issue as `CachedLocalVar.vtable`.
        .enumerate_struct = null,
    });
};

pub const Letrec = struct {
    pub const interned_select = heap.InternedString.newValue("select");

    /// The scope containing all the functions that can call each other. Identical
    /// to any other bog-standard scope.
    scope: *objects.Dictionary,
    /// Which function is selected. For example, if I did
    /// ```tcl
    /// fn group::foo {} { bar }
    /// fn group::bar {} { foo }
    /// set foo [letrec select $group foo]
    /// ```
    /// then `foo` would be the value of `selected`. This means
    /// that [foo] is the entry point to recursion in this case.
    selected: Value,

    pub const prefix = "letrec ";

    pub fn asHead(self: *Letrec) *Object {
        return Object.from(Letrec, self);
    }

    pub fn new(det: ?*ErrorDetails, scope: *objects.Dictionary, selected: Value) !*Letrec {
        if (try selected.equals(objects.interned_tilde_parent)) return vartypes.badVariableNameError(det, "~parent");

        const new_obj = try Object.newObject(Letrec);
        errdefer new_obj.head.dropReference();

        assert(scope.asHead().metadata.cross_thread);
        scope.asHead().incrRefCount();

        new_obj.body.* = .{
            .scope = scope,
            .selected = selected.takeReference(),
        };
        return new_obj.body;
    }

    fn badLetrec(det: ?*ErrorDetails, bytes: []const u8) error{ OutOfMemory, BadLetrec } {
        if (det) |details| details.* = .{
            .message = try allocPrintZ("not a valid letrec: \"{s}\"", .{bytes}),
        };
        return error.BadLetrec;
    }

    pub fn shimmerFrom(det: ?*ErrorDetails, shim: *Shimmerable) !*const Letrec {
        if (shim.current().asType(Letrec)) |letrec| return letrec;

        const bytes = try shim.current().getString();
        if (bytes.len <= prefix.len or !std.mem.eql(u8, bytes[0..prefix.len], prefix)) return badLetrec(det, bytes);

        var letrec_value: Shimmerable = .{ .original = try objects.String.newValue(bytes[prefix.len..]) };
        defer letrec_value.deinit();

        const as_dict = objects.Dictionary.shimmerFrom(null, &letrec_value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return badLetrec(det, bytes),
        };

        const scope = (try as_dict.getNoFollow(Closure.interned_scope)).asValue() orelse return badLetrec(det, bytes);
        const selected = (try as_dict.getNoFollow(interned_select)).asValue() orelse return badLetrec(det, bytes);
        if (try selected.equals(objects.interned_tilde_parent)) return vartypes.badVariableNameError(det, "~parent");

        var scope_hash_ref_shim: Shimmerable = .{ .original = scope };
        defer scope_hash_ref_shim.discardChanges();
        // We know we're the only ones who own it, so const cast won't violate any assumptions.
        const hash_ref = try objects.HashReference.shimmerFrom(det, &scope_hash_ref_shim);

        var scope_shim: Shimmerable = .{ .original = hash_ref.ref.asValue() };
        defer scope_shim.discardChanges();
        _ = try objects.Dictionary.shimmerFrom(det, &scope_shim);
        const dict = scope_shim.current().asType(objects.Dictionary).?;

        const as_letrec = try shim.prepareToShimmer(Letrec);
        dict.asHead().makeCrossthread();
        dict.asHead().incrRefCount();
        as_letrec.* = .{
            .scope = dict,
            .selected = selected.takeReference(),
        };

        return as_letrec;
    }

    fn duplicate(src: *const Object) !*Object {
        const new_obj = try Object.newObjectUninitialized(Letrec);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj.head);

        const as_letrec = src.asTypeConst(Letrec).?;
        as_letrec.scope.asHead().incrRefCount();
        new_obj.body.* = .{
            .scope = as_letrec.scope,
            .selected = as_letrec.selected.takeReference(),
        };
        return new_obj.head;
    }

    fn freeInternalRep(obj: *Object) void {
        const as_letrec = obj.asType(Letrec).?;
        as_letrec.scope.asHead().dropReference();
        as_letrec.selected.dropReference();
    }

    fn updateString(obj: *Object) !void {
        const as_letrec = obj.asType(Letrec).?;
        const parts: [5][]const u8 = .{
            "letrec",
            "select",
            try as_letrec.selected.getString(),
            "scope",
            try as_letrec.scope.asHead().getString(),
        };
        try obj.setStringDuplicating(try strutil.quoteStrings(heap.local_arena, &parts));
    }

    fn enumerateStruct(obj: *const Object, ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const letrec = obj.asTypeConst(Letrec).?;
        const helper: objects.IterHelper = .{ .ctx = ctx, .info = info };
        try helper.follow(Object, "scope", letrec.scope.asHead());
        try helper.followValue("selected", letrec.selected);
    }

    fn makeCrossthread(obj: *Object) void {
        const letrec = obj.asType(Letrec).?;
        assert(letrec.scope.asHead().metadata.cross_thread);
        letrec.selected.makeCrossthread();
    }

    pub const vtable: Object.VTable = .zig(@typeName(@This()), .{
        .duplicate = duplicate,
        .free_internal_rep = freeInternalRep,
        .update_string = updateString,
        .make_crossthread = makeCrossthread,
        .enumerate_struct = enumerateStruct,
    });
};

pub const NativeCommand = struct {
    description: ?[]const u8 = "",
    min_arity: usize = 0,
    max_arity: ?usize = null,

    call_info: union(enum) {
        zig: *const CommandFn,
        c: *const CCommandFn,
    },

    /// Returns a string containing all the usage information. Allocates the string
    /// onto `gpa`. Produces something like `cmd ...`, or `cmd arg1 arg2 ?arg3?`
    pub fn getUsageInfo(command: *const NativeCommand, gpa: std.mem.Allocator, command_name: []const u8) ![]const u8 {
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

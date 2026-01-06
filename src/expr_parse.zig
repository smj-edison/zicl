const std = @import("std");
const testing = std.testing;
const Writer = std.io.Writer;

const Tokenizer = @import("Tokenizer.zig");
// Used to store parsed strings.
const Heap = @import("Heap.zig");
const Handle = Heap.Handle;
const NullableHandle = Heap.NullableHandle;
const object = @import("object.zig");
const Token = Tokenizer.Token;

const TokenIndex = u32;

pub const Node = struct {
    tag: Tag,
    data: Data,

    pub const Index = enum(u32) {
        _,
    };

    pub const Data = union {
        unary: Index,
        binary: struct { Index, Index },
        ternary: struct { Index, Index, Index },
        object: Handle,
        integer: i64,
        float: f64,
    };

    pub const Tag = enum(u8) {
        none,
        // Binary operators
        mul,
        div,
        mod,
        sub,
        add,
        shiftl,
        shiftr,
        rotl,
        rotr,
        less_than,
        greater_than,
        less_or_equal,
        greater_or_equal,
        equal,
        not_equal,
        bit_and,
        bit_xor,
        bit_or,
        bool_and,
        bool_or,
        pow,
        string_equal,
        string_not_equal,
        string_in,
        string_not_in,
        string_less_than,
        string_greater_than,
        string_less_than_or_equal,
        string_greater_than_or_equal,
        // Ternary
        ternary_conditional,
        // Value
        string,
        integer,
        float,
        command_subst,
        variable_subst,
        dict_sugar,
        value_false,
        value_true,
        // Unary operators
        bool_not,
        bit_not,
        identity,
        negation,
        // Builtin functions
        to_int,
        to_wide,
        abs,
        to_double,
        round,
        rand,
        srand,
        // Extras
        sin,
        cos,
        tan,
        asin,
        acos,
        atan,
        atan2,
        sinh,
        cosh,
        tanh,
        ceil,
        floor,
        exp,
        log,
        log10,
        sqrt,
        hypot,
        fmod,
    };
};

const Assoc = enum {
    left,
    none,
    right,
};

const OperInfo = struct {
    prec: i8,
    tag: Node.Tag,
    assoc: Assoc = Assoc.left,
};

const unary_precedence: i8 = 125;
const binary_oper_table = std.enums.directEnumArrayDefault(Token.Tag, OperInfo, .{ .prec = -1, .tag = Node.Tag.none }, 0, .{
    .asterisk_asterisk = .{ .prec = 120, .tag = Node.Tag.pow, .assoc = .right },

    .asterisk = .{ .prec = 110, .tag = Node.Tag.mul },
    .forward_slash = .{ .prec = 110, .tag = Node.Tag.div },
    .percent = .{ .prec = 110, .tag = Node.Tag.mod },

    .minus = .{ .prec = 100, .tag = Node.Tag.sub },
    .plus = .{ .prec = 100, .tag = Node.Tag.add },

    .angle_bracket_angle_bracket_left = .{ .prec = 90, .tag = Node.Tag.shiftl },
    .angle_bracket_angle_bracket_right = .{ .prec = 90, .tag = Node.Tag.shiftr },
    .angle_bracket_angle_bracket_angle_bracket_left = .{ .prec = 90, .tag = Node.Tag.rotl },
    .angle_bracket_angle_bracket_angle_bracket_right = .{ .prec = 90, .tag = Node.Tag.rotr },

    .angle_bracket_left = .{ .prec = 80, .tag = Node.Tag.less_than, .assoc = .none },
    .angle_bracket_right = .{ .prec = 80, .tag = Node.Tag.greater_than, .assoc = .none },
    .angle_bracket_left_equal = .{ .prec = 80, .tag = Node.Tag.less_than, .assoc = .none },
    .angle_bracket_right_equal = .{ .prec = 80, .tag = Node.Tag.less_than, .assoc = .none },

    // Precedence must be higher than ==, !=, eq, ne but lower than <, >, <=, >=
    .keyword_lt = .{ .prec = 75, .tag = Node.Tag.string_less_than, .assoc = .none },
    .keyword_gt = .{ .prec = 75, .tag = Node.Tag.string_greater_than, .assoc = .none },
    .keyword_le = .{ .prec = 75, .tag = Node.Tag.string_less_than_or_equal, .assoc = .none },
    .keyword_ge = .{ .prec = 75, .tag = Node.Tag.string_greater_than_or_equal, .assoc = .none },

    .equal_equal = .{ .prec = 70, .tag = Node.Tag.equal, .assoc = .none },
    .bang_equal = .{ .prec = 70, .tag = Node.Tag.not_equal, .assoc = .none },

    .keyword_in = .{ .prec = 55, .tag = Node.Tag.string_equal, .assoc = .none },
    .keyword_ni = .{ .prec = 55, .tag = Node.Tag.string_not_equal, .assoc = .none },

    .ampersand = .{ .prec = 50, .tag = Node.Tag.bit_and },
    .caret = .{ .prec = 49, .tag = Node.Tag.bit_xor },
    .pipe = .{ .prec = 48, .tag = Node.Tag.bit_or },

    .ampersand_ampersand = .{ .prec = 10, .tag = Node.Tag.bool_and },
    .pipe_pipe = .{ .prec = 9, .tag = Node.Tag.bool_or },
});

const FunctionArity = struct { arity: u8, tag: Node.Tag };
const function_arity = std.StaticStringMap(FunctionArity).initComptime([_]struct { []const u8, FunctionArity }{
    .{ "int", .{ .arity = 1, .tag = .to_int } },  .{ "wide", .{ .arity = 1, .tag = .to_wide } },
    .{ "abs", .{ .arity = 1, .tag = .abs } },     .{ "double", .{ .arity = 1, .tag = .to_double } },
    .{ "rand", .{ .arity = 0, .tag = .rand } },   .{ "srand", .{ .arity = 1, .tag = .srand } },
    .{ "sin", .{ .arity = 1, .tag = .sin } },     .{ "cos", .{ .arity = 1, .tag = .cos } },
    .{ "tan", .{ .arity = 1, .tag = .tan } },     .{ "asin", .{ .arity = 1, .tag = .asin } },
    .{ "acos", .{ .arity = 1, .tag = .acos } },   .{ "atan", .{ .arity = 1, .tag = .atan } },
    .{ "atan2", .{ .arity = 2, .tag = .atan2 } }, .{ "sinh", .{ .arity = 1, .tag = .sinh } },
    .{ "cosh", .{ .arity = 1, .tag = .cosh } },   .{ "tanh", .{ .arity = 1, .tag = .tanh } },
    .{ "ceil", .{ .arity = 1, .tag = .ceil } },   .{ "floor", .{ .arity = 1, .tag = .floor } },
    .{ "exp", .{ .arity = 1, .tag = .exp } },     .{ "log", .{ .arity = 1, .tag = .log } },
    .{ "log10", .{ .arity = 1, .tag = .log10 } }, .{ "sqrt", .{ .arity = 1, .tag = .sqrt } },
    .{ "pow", .{ .arity = 2, .tag = .pow } },     .{ "hypot", .{ .arity = 2, .tag = .hypot } },
    .{ "fmod", .{ .arity = 2, .tag = .fmod } },
});

pub const Parse = struct {
    const Tokens = std.MultiArrayList(Tokenizer.Token).Slice;

    gpa: std.mem.Allocator,
    heap: *Heap,
    source: []const u8,
    source_file_name: NullableHandle,
    tokens: Tokens,
    nodes: std.MultiArrayList(Node),
    err: ?Error,
    token_i: TokenIndex,

    fn tokenTag(p: *Parse, token_index: TokenIndex) Token.Tag {
        return p.tokens.items(.tag)[token_index];
    }

    fn tokenLoc(p: *Parse, token_index: TokenIndex) Token.Location {
        return p.tokens.items(.loc)[token_index];
    }

    fn addNode(p: *Parse, elem: Node) !Node.Index {
        const new_index: Node.Index = @enumFromInt(p.nodes.len);
        try p.nodes.append(p.gpa, elem);
        return new_index;
    }

    const Mode = struct {
        ternary: enum { not, true_branch, false_branch } = .not,
        parens: enum {
            none,
            non_function,
            function_more_args,
            function_no_more_args,
        } = .none,
    };
    fn parsePrefixExpr(p: *Parse, mode: Mode) error{ OutOfMemory, ParseError }!?Node.Index {
        const token = p.tokenTag(p.token_i);
        switch (token) {
            // Unary operator?
            .plus, .minus, .bang, .tilde => {
                p.token_i += 1;
                const operand = try p.parseExprPrecedence(unary_precedence, mode) orelse return null;
                // Convert Token.Tag -> Node.Tag for unary operator.
                const tag: Node.Tag = switch (token) {
                    .plus => .identity,
                    .minus => .negation,
                    .bang => .bool_not,
                    .tilde => .bit_not,
                    inline else => unreachable,
                };
                return try p.addNode(.{
                    .tag = tag,
                    .data = .{ .unary = operand },
                });
            },
            .l_paren => {
                p.token_i += 1;
                return try p.parseExprPrecedence(0, .{ .parens = .non_function, .ternary = mode.ternary });
            },
            .r_paren => {
                // We shouldn't normally hit a right paren as the first token, so something
                // has gone awry if this is the case.
                return p.fail(.too_many_r_parens);
            },
            .comma => {
                // If we have a comma as the first node, it would be something like `atan2(,)`, or
                // `atan2(5,,)`, neither of which is valid. This would be a case of a missing operand.
                return p.fail(.missing_operand);
            },
            .colon => {
                if (mode.ternary == .true_branch) {
                    // There should be an operand before the colon.
                    return p.fail(.missing_operand);
                } else {
                    // We're not even in a ternary!
                    return p.fail(.colon_without_question_mark);
                }
            },
            .question_mark,
            .asterisk,
            .forward_slash,
            .percent,
            .angle_bracket_left,
            .angle_bracket_right,
            .angle_bracket_left_equal,
            .angle_bracket_right_equal,
            .angle_bracket_angle_bracket_left,
            .angle_bracket_angle_bracket_right,
            .angle_bracket_angle_bracket_angle_bracket_left,
            .angle_bracket_angle_bracket_angle_bracket_right,
            .equal_equal,
            .bang_equal,
            .ampersand,
            .caret,
            .pipe,
            .ampersand_ampersand,
            .pipe_pipe,
            .asterisk_asterisk,
            .keyword_eq,
            .keyword_ne,
            .keyword_in,
            .keyword_ni,
            .keyword_lt,
            .keyword_gt,
            .keyword_le,
            .keyword_ge,
            => {
                // We shouldn't be starting with an operator.
                return p.fail(.missing_operand);
            },
            .function => {
                // Get the function name.
                const loc = p.tokenLoc(p.nextToken());
                var function_name_end = loc.start;
                while (true) : (function_name_end += 1) {
                    const char = p.source[function_name_end];
                    if (std.ascii.isWhitespace(char) or char == '(') break;
                }

                // Look up the function's arity and tag.
                const lookup = function_arity.get(p.source[loc.start..function_name_end]).?;
                const arity = lookup.arity;
                const tag = lookup.tag;

                // This design leaves room to deal with arbitrary arity, but
                // for now, we'll just manually deal with up to two arguments.
                switch (arity) {
                    0 => {
                        if (p.tokenTag(p.token_i) != .r_paren) return p.fail(.too_many_arguments);
                        p.token_i += 1;
                        return try p.addNode(.{
                            .tag = tag,
                            .data = undefined,
                        });
                    },
                    1 => {
                        const func_argument = try p.parseExprPrecedence(0, .{
                            .parens = .function_no_more_args,
                            .ternary = mode.ternary,
                        }) orelse return p.fail(.too_few_arguments);
                        return try p.addNode(.{
                            .tag = tag,
                            .data = .{ .unary = func_argument },
                        });
                    },
                    2 => {
                        const first_argument = try p.parseExprPrecedence(0, .{
                            .parens = .function_more_args,
                            .ternary = mode.ternary,
                        }) orelse return p.fail(.too_few_arguments);
                        const second_argument = try p.parseExprPrecedence(0, .{
                            .parens = .function_no_more_args,
                            .ternary = mode.ternary,
                        }) orelse return p.fail(.too_few_arguments);
                        return try p.addNode(.{
                            .tag = tag,
                            .data = .{ .binary = .{ first_argument, second_argument } },
                        });
                    },
                    else => unreachable,
                }
            },
            .integer => {
                const loc = p.tokenLoc(p.nextToken());
                const value = std.fmt.parseInt(i64, p.source[loc.start..loc.end], 10) catch unreachable;

                return try p.addNode(.{
                    .tag = .integer,
                    .data = .{ .integer = value },
                });
            },
            .float => {
                const loc = p.tokenLoc(p.nextToken());
                const value = std.fmt.parseFloat(f64, p.source[loc.start..loc.end]) catch unreachable;

                return try p.addNode(.{
                    .tag = .float,
                    .data = .{ .float = value },
                });
            },
            .simple_string => {
                const loc = p.tokenLoc(p.nextToken());
                const handle = try object.newString(p.heap, p.source[loc.start..loc.end]);
                errdefer handle.decrRefCount();

                return try p.addNode(.{
                    .tag = .string,
                    .data = .{ .object = handle },
                });
            },
            .escaped_string => {
                const loc = p.tokenLoc(p.nextToken());
                const handle = try p.heap.createObject();
                errdefer handle.decrRefCount();
                try object.setStringFromEscaped(handle, p.source[loc.start..loc.end]);

                return try p.addNode(.{
                    .tag = .string,
                    .data = .{ .object = handle },
                });
            },
            .command_subst => {
                const loc = p.tokenLoc(p.nextToken());
                const command_handle = try object.newString(p.heap, p.source[loc.start..loc.end]);
                errdefer command_handle.decrRefCount();

                // Be sure to save the source info.
                try object.setSourceInfo(command_handle, .{
                    .file_name = p.source_file_name,
                    .line_no = loc.line_no,
                });

                return try p.addNode(.{
                    .tag = .command_subst,
                    .data = .{ .object = command_handle },
                });
            },
            .variable_subst,
            .dict_sugar,
            .keyword_false,
            .keyword_true,
            => {
                const loc = p.tokenLoc(p.nextToken());
                var string_handle = try object.newString(p.heap, p.source[loc.start..loc.end]);
                errdefer string_handle.decrRefCount();

                return try p.addNode(.{
                    .tag = switch (token) {
                        .variable_subst => .variable_subst,
                        .dict_sugar => .dict_sugar,
                        .keyword_false => .value_false,
                        .keyword_true => .value_true,
                        inline else => unreachable,
                    },
                    .data = .{ .object = string_handle },
                });
            },
            .end_of_file => return null,
            .argument_expansion,
            .word_separator,
            .command_separator,
            .expression_sugar,
            .start_of_command,
            .start_of_word,
            .none,
            => unreachable,
        }
    }

    fn parseExprPrecedence(p: *Parse, min_prec: i32, mode: Mode) error{ OutOfMemory, ParseError }!?Node.Index {
        var node: Node.Index = try p.parsePrefixExpr(mode) orelse return null;
        var banned_prec: i8 = -1;

        while (true) {
            const token_tag = p.tokenTag(p.token_i);
            switch (token_tag) {
                .simple_string,
                .escaped_string,
                .variable_subst,
                .dict_sugar,
                .command_subst,
                .l_paren,
                .integer,
                .float,
                .keyword_true,
                .keyword_false,
                .function,
                => {
                    return p.fail(.missing_operator);
                },
                .r_paren => {
                    if (mode.parens == .function_more_args) {
                        return p.fail(.too_few_arguments);
                    } else if (mode.parens == .function_no_more_args) {
                        p.token_i += 1;
                        return node;
                    } else if (mode.parens == .non_function) {
                        p.token_i += 1;
                        return node;
                    } else {
                        return p.fail(.too_many_r_parens);
                    }
                },
                .comma => {
                    if (mode.parens == .function_more_args) {
                        p.token_i += 1;
                        return node;
                    } else if (mode.parens == .function_no_more_args) {
                        return p.failAt(.too_many_arguments, p.token_i + 1);
                    } else {
                        return p.fail(.comma_outside_function);
                    }
                },
                .colon => {
                    if (mode.ternary == .true_branch) {
                        return node;
                    } else {
                        return p.fail(.colon_without_question_mark);
                    }
                },
                .question_mark => {
                    p.token_i += 1;
                    const value_if_true = try p.parseExprPrecedence(0, .{
                        .ternary = .true_branch,
                        .parens = mode.parens,
                    }) orelse return p.fail(.missing_operand);
                    if (p.tokenTag(p.nextToken()) != .colon) {
                        return p.fail(.missing_colon);
                    }
                    const value_if_false = try p.parseExprPrecedence(0, .{
                        .ternary = .false_branch,
                        .parens = mode.parens,
                    }) orelse return p.fail(.missing_operand);

                    return try p.addNode(.{
                        .tag = .ternary_conditional,
                        .data = .{ .ternary = .{ node, value_if_true, value_if_false } },
                    });
                },
                .end_of_file => return node,
                .argument_expansion,
                .word_separator,
                .command_separator,
                .expression_sugar,
                .start_of_command,
                .start_of_word,
                => unreachable,
                else => {
                    // We checked all things that weren't binary operators, so we're good to
                    // do binary operator stuff.
                    const operator_tag = token_tag;
                    const info = binary_oper_table[@as(usize, @intCast(@intFromEnum(operator_tag)))];
                    if (info.prec < min_prec) {
                        return node;
                    }
                    if (info.prec == banned_prec) {
                        return p.fail(.chained_comparison_operators);
                    }

                    p.token_i += 1;
                    const new_prec = if (info.assoc == .right) info.prec else info.prec + 1;
                    const rhs = try p.parseExprPrecedence(new_prec, mode) orelse {
                        return p.failAt(.missing_operand, p.token_i + 1);
                    };

                    node = try p.addNode(.{
                        .tag = info.tag,
                        .data = .{ .binary = .{ node, rhs } },
                    });

                    if (info.assoc == Assoc.none) {
                        banned_prec = info.prec;
                    }
                },
            }
        }
    }

    fn nextToken(p: *Parse) TokenIndex {
        const token_i = p.token_i;
        p.token_i += 1;
        return token_i;
    }

    pub fn parseExpr(p: *Parse) error{ OutOfMemory, ParseError }!?Node.Index {
        return p.parseExprPrecedence(0, .{});
    }

    /// Does not borrow source_file_name.
    pub fn init(heap: *Heap, source_file_name: NullableHandle, source: []const u8, tokens: Tokens) Parse {
        return .{
            .gpa = heap.gpa,
            .heap = heap,
            .source = source,
            .source_file_name = source_file_name,
            .tokens = tokens,
            .nodes = .empty,
            .err = null,
            .token_i = 0,
        };
    }

    pub fn deinit(p: *Parse) void {
        deinitNodes(p.gpa, &p.nodes);
    }

    const Error = struct {
        tag: Tag,
        token: TokenIndex,

        const Tag = enum {
            missing_operand,
            colon_without_question_mark,
            missing_colon,
            too_few_arguments,
            too_many_arguments,
            too_many_r_parens,
            chained_comparison_operators,
            comma_outside_function,
            missing_operator,
        };

        pub fn sourceIndex(err: Error, p: *Parse) u32 {
            if (err.token >= p.nodes.len) {
                return @intCast(p.source.len);
            } else {
                return p.tokens.get(err.token).loc.start;
            }
        }
    };

    fn fail(p: *Parse, err: Error.Tag) error{ParseError} {
        p.err = .{
            .tag = err,
            .token = p.token_i,
        };
        return error.ParseError;
    }

    fn failAt(p: *Parse, err: Error.Tag, token_index: u32) error{ParseError} {
        p.err = .{
            .tag = err,
            .token = token_index,
        };
        return error.ParseError;
    }

    pub fn renderError(p: *Parse, parse_error: Error, w: *Writer) Writer.Error!void {
        const token_loc: Token.Location = blk: {
            if (parse_error.token < p.tokens.len) {
                break :blk p.tokenLoc(parse_error.token);
            } else {
                break :blk .{
                    .line_no = if (p.tokens.len > 0) p.tokens.get(p.tokens.len - 1).loc.line_no else 1,
                    .start = @intCast(p.source.len),
                    .end = @intCast(p.source.len),
                };
            }
        };
        const line_range = blk: {
            // Go backwards/forwards from the token until we hit eof or \n on each side.
            var line_start = if (token_loc.start < p.source.len) token_loc.start else token_loc.start -| 1;
            var line_end = line_start;

            while (line_start > 0) {
                line_start -= 1;
                if (p.source[line_start] == '\n') {
                    line_start += 1;
                    break;
                }
            }

            while (line_end < p.source.len) : (line_end += 1) {
                if (p.source[line_start] == '\n') break;
            }

            break :blk .{ .start = line_start, .end = line_end };
        };

        try w.writeAll("error: ");
        switch (parse_error.tag) {
            .missing_operand => try w.writeAll("missing operand"),
            .colon_without_question_mark => try w.writeAll("\":\" without \"?\" in expression"),
            .missing_operator => try w.writeAll("missing operator"),
            .missing_colon => try w.writeAll("missing operator \":\""),
            .too_few_arguments => try w.writeAll("not enough arguments for function"),
            .too_many_arguments => try w.writeAll("too many arguments for function"),
            .too_many_r_parens => try w.writeAll("unexpected closing parenthesis"),
            .chained_comparison_operators => try w.writeAll("unexpected chained comparison operator"),
            .comma_outside_function => try w.writeAll("unexpected \",\""),
        }
        try w.writeAll("\n");

        try w.splatByteAll(' ', std.fmt.count("{}", .{token_loc.line_no}));
        try w.writeAll(" |\n");
        try w.print("{} | {s}\n", .{ token_loc.line_no, p.source[line_range.start..line_range.end] });
        try w.splatByteAll(' ', std.fmt.count("{}", .{token_loc.line_no}));
        try w.writeAll(" | ");
        const line_offset = token_loc.start - line_range.start;
        try w.splatByteAll(' ', line_offset);
        try w.splatByteAll('^', @max(1, token_loc.end - line_offset));
    }

    pub fn write(p: *Parse, writer: *Writer, node: Node.Index) !void {
        const tag: Node.Tag = p.nodes.items(.tag)[@intFromEnum(node)];
        const data: Node.Data = p.nodes.items(.data)[@intFromEnum(node)];
        switch (tag) {
            .none => {},
            // Binary operators
            .mul,
            .div,
            .mod,
            .sub,
            .add,
            .shiftl,
            .shiftr,
            .rotl,
            .rotr,
            .less_than,
            .greater_than,
            .less_or_equal,
            .greater_or_equal,
            .equal,
            .not_equal,
            .bit_and,
            .bit_xor,
            .bit_or,
            .bool_and,
            .bool_or,
            .pow,
            .string_equal,
            .string_not_equal,
            .string_in,
            .string_not_in,
            .string_less_than,
            .string_greater_than,
            .string_less_than_or_equal,
            .string_greater_than_or_equal,
            => {
                try writer.print("(", .{});
                try p.write(writer, data.binary.@"0");
                try writer.print(" {} ", .{tag});
                try p.write(writer, data.binary.@"1");
                try writer.print(")", .{});
            },
            // Also binary, but functions.
            .atan2,
            .exp,
            .hypot,
            .fmod,
            => {
                try writer.print("({} ", .{tag});
                try p.write(writer, data.binary.@"0");
                try writer.print(" ", .{});
                try p.write(writer, data.binary.@"1");
                try writer.print(")", .{});
            },
            .ternary_conditional => {
                try writer.print("({} ", .{tag});
                try p.write(writer, data.ternary.@"0");
                try writer.print(" ", .{});
                try p.write(writer, data.ternary.@"1");
                try writer.print(" ", .{});
                try p.write(writer, data.ternary.@"2");
                try writer.print(")", .{});
            },
            // Value
            .string => try writer.print("\"{f}\"", .{data.object}),
            .integer => try writer.print("{}", .{data.integer}),
            .float => try writer.print("{}", .{data.float}),
            .command_subst => try writer.print("[{f}]", .{data.object}),
            .variable_subst => try writer.print("${f}", .{data.object}),
            .dict_sugar => try writer.print("${f}", .{data.object}),
            .value_false => try writer.print("false", .{}),
            .value_true => try writer.print("true", .{}),
            // Unary operators
            .bool_not,
            .bit_not,
            .identity,
            .negation,
            .to_int,
            .to_wide,
            .abs,
            .to_double,
            .round,
            .rand,
            .srand,
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
            .log,
            .log10,
            .sqrt,
            => {
                try writer.print("({} ", .{tag});
                try p.write(writer, data.unary);
                try writer.print(")", .{});
            },
        }
    }

    pub fn dump(p: *Parse, node: Node.Index) void {
        var buffer: [64]u8 = undefined;
        const writer = std.debug.lockStderrWriter(&buffer);
        defer std.debug.unlockStderrWriter();
        p.write(writer, node) catch @panic("couldn't write");
    }
};

pub fn deinitNodes(gpa: std.mem.Allocator, nodes: *std.MultiArrayList(Node)) void {
    for (0..nodes.len) |i| {
        const node = nodes.get(i);
        switch (node.tag) {
            .variable_subst,
            .dict_sugar,
            .value_false,
            .value_true,
            .command_subst,
            .string,
            => {
                node.data.object.decrRefCount();
            },
            else => {},
        }
    }

    nodes.deinit(gpa);
}

test "expr parsing" {
    defer Heap.testFinish();
    const heap = try Heap.testStart(testing.allocator);

    // Left associativity.
    try testExprParse(heap, "1 + 2 + 3 + 4", "(((1 .add 2) .add 3) .add 4)");
    // Right associativity.
    try testExprParse(heap, "1 ** 2 ** 3 ** 4", "(1 .pow (2 .pow (3 .pow 4)))");
    // No associativity.
    try testExprParseError(heap, "1 < 2 < 3", .chained_comparison_operators, null);

    // Various stress tests.
    try testExprParse(heap, "1 + 2 * 3 + 4", "((1 .add (2 .mul 3)) .add 4)");
    try testExprParse(heap, "1 ? 10 : 5", "(.ternary_conditional 1 10 5)");
    try testExprParse(
        heap,
        "atan2(1 ? 10 : 5, int(0 ? 5 : 2))",
        "(.atan2 (.ternary_conditional 1 10 5) (.to_int (.ternary_conditional 0 5 2)))",
    );

    // Test error messages.
    try testExprParseError(heap, "1 + ", .missing_operand,
        \\error: missing operand
        \\  |
        \\1 | 1 + 
        \\  |     ^
    );
    try testExprParseError(heap, ": 5", .colon_without_question_mark,
        \\error: ":" without "?" in expression
        \\  |
        \\1 | : 5
        \\  | ^
    );
    try testExprParseError(heap, "1 ? 5", .missing_colon,
        \\error: missing operator ":"
        \\  |
        \\1 | 1 ? 5
        \\  |      ^
    );
    try testExprParseError(heap, "atan2(1)", .too_few_arguments,
        \\error: not enough arguments for function
        \\  |
        \\1 | atan2(1)
        \\  |        ^
    );
    try testExprParseError(heap, "atan2(1, 2, 3)", .too_many_arguments,
        \\error: too many arguments for function
        \\  |
        \\1 | atan2(1, 2, 3)
        \\  |             ^
    );
    try testExprParseError(heap, "(5))", .too_many_r_parens,
        \\error: unexpected closing parenthesis
        \\  |
        \\1 | (5))
        \\  |    ^
    );
    try testExprParseError(heap, "5 < 10 > 15", .chained_comparison_operators,
        \\error: unexpected chained comparison operator
        \\  |
        \\1 | 5 < 10 > 15
        \\  |        ^
    );
    try testExprParseError(heap, "atan2((1, 5)", .comma_outside_function,
        \\error: unexpected ","
        \\  |
        \\1 | atan2((1, 5)
        \\  |         ^
    );
    try testExprParseError(heap, "10 20", .missing_operator,
        \\error: missing operator
        \\  |
        \\1 | 10 20
        \\  |    ^^
    );
}

fn testExprParse(heap: *Heap, expr: []const u8, comptime expected_tree: []const u8) !void {
    var tokens = tokenize(testing.allocator, expr) catch return error.TestUnexpectedResult;
    defer tokens.deinit(testing.allocator);
    var parser = Parse.init(heap, heap.emptyObject(), expr, tokens.slice());
    defer parser.deinit();
    const root_node = (parser.parseExpr() catch return error.TestUnexpectedResult) orelse return error.TestUnexpectedResult;

    var aw = try Writer.Allocating.initCapacity(testing.allocator, expected_tree.len);
    try parser.write(&aw.writer, root_node);
    const result = try aw.toOwnedSlice();
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(expected_tree, result);
}

fn testExprParseError(heap: *Heap, expr: []const u8, expected_error: Parse.Error.Tag, message: ?[]const u8) !void {
    var tokens = tokenize(testing.allocator, expr) catch return error.TestUnexpectedResult;
    defer tokens.deinit(testing.allocator);
    var parser = Parse.init(heap, heap.emptyObject(), expr, tokens.slice());
    defer parser.deinit();

    try testing.expectError(error.ParseError, parser.parseExpr());
    try testing.expectEqual(expected_error, parser.err.?.tag);

    if (message) |expected_message| {
        var aw = try Writer.Allocating.initCapacity(testing.allocator, expected_message.len);
        try parser.renderError(parser.err.?, &aw.writer);
        const actual_message = try aw.toOwnedSlice();
        defer testing.allocator.free(actual_message);
        try testing.expectEqualStrings(expected_message, actual_message);
    }
}

fn tokenize(gpa: std.mem.Allocator, expr: []const u8) !std.MultiArrayList(Token) {
    var tokenizer = Tokenizer.init(expr, 1);
    var tokens = std.MultiArrayList(Token).empty;
    while (true) {
        const token = try tokenizer.nextExpressionToken();
        try tokens.append(gpa, token);

        if (token.tag == .end_of_file) break;
    }

    return tokens;
}

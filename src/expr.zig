const std = @import("std");

const Tokenizer = @import("Tokenizer.zig");
// Used to store parsed strings.
const Heap = @import("Heap.zig");
const object = @import("object.zig");
const Token = Tokenizer.Token;

const TokenIndex = u32;

pub const Node = struct {
    tag: Tag,
    data: Data,

    pub const Index = enum(u32) {
        root = 0,
        _,
    };

    pub const Data = union {
        unary: Index,
        binary: struct { Index, Index },
        ternary: struct { Index, Index, Index },
        object: Heap.Handle,
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
        ternary,
        colon,
        pow,
        string_equal,
        string_not_equal,
        string_in,
        string_not_in,
        string_less_than,
        string_greater_than,
        string_less_than_or_equal,
        string_greater_than_or_equal,
        // Value
        string,
        integer,
        float,
        // Unary operators
        bool_not,
        bit_not,
        identity,
        negation,
        // Builtin functions
        int,
        wide,
        abs,
        double,
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

const function_arity = std.enums.directEnumArrayDefault(Token.Tag, i8, -1, 0, .{
    .function_int = 1,
    .function_wide = 1,
    .function_abs = 1,
    .function_double = 1,
    .function_rand = 0,
    .function_srand = 1,
    .function_sin = 1,
    .function_cos = 1,
    .function_tan = 1,
    .function_asin = 1,
    .function_acos = 1,
    .function_atan = 1,
    .function_atan2 = 2,
    .function_sinh = 1,
    .function_cosh = 1,
    .function_tanh = 1,
    .function_ceil = 1,
    .function_floor = 1,
    .function_exp = 1,
    .function_log = 1,
    .function_log10 = 1,
    .function_sqrt = 1,
    .function_pow = 2,
    .function_hypot = 2,
    .function_fmod = 2,
});

pub const Parse = struct {
    gpa: std.mem.Allocator,
    heap: *Heap,
    source: []const u8,
    source_file_name: Heap.Handle,
    tokens: std.MultiArrayList(Tokenizer.Token),
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

    fn parseExpr(p: *Parse, min_prec: i32, stop_at: ?Token.Tag) !?Node.Index {
        const first_token = p.tokenTag(p.token_i);
        var node: Node.Index = blk: {
            switch (first_token) {
                // Unary operator?
                .plus, .minus, .bang, .tilde => {
                    const operand = try p.parseExpr(unary_precedence) orelse return null;
                    // Token.Tag -> Node.Tag for unary operator.
                    const tag = switch (first_token) {
                        .plus => .identity,
                        .minus => .negation,
                        .bang => .bool_not,
                        .tilde => .bit_not,
                        inline else => unreachable,
                    };
                    break :blk try p.addNode(.{
                        .tag = tag,
                        .data = .{ .unary = operand },
                    });
                },
                .l_paren => {
                    break :blk try p.parseExpr(0, .r_paren) orelse return null;
                },
                .r_paren => {
                    // We shouldn't normally hit a right paren as the first token, so something
                    // has gone awry if this is the case.
                    return p.fail(.premature_expression_end);
                },
                .comma => {
                    // If we have a comma as the first node, it would be something like `atan2(,)`, or
                    // `atan2(5,,)`, neither of which is valid. This would be a case of a missing operand.
                    return p.fail(.missing_operand);
                },
                .colon => {
                    if (stop_at == .colon) {
                        // We should stop at colon, but there should be an operand first.
                        return p.fail(.missing_operand);
                    } else {
                        // We didn't even start a ternary!
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
                .not_equal,
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
                .function_int,
                .function_wide,
                .function_abs,
                .function_double,
                .function_rand,
                .function_srand,
                .function_sin,
                .function_cos,
                .function_tan,
                .function_asin,
                .function_acos,
                .function_atan,
                .function_atan2,
                .function_sinh,
                .function_cosh,
                .function_tanh,
                .function_ceil,
                .function_floor,
                .function_exp,
                .function_log,
                .function_log10,
                .function_sqrt,
                .function_pow,
                .function_hypot,
                .function_fmod,
                => {},
                .integer => {
                    const loc = p.tokenLoc(p.token_i);
                    const value = std.fmt.parseInt(i64, p.source[loc.start..loc.end]) catch unreachable;
                    const handle = try object.integerNew(value);
                    errdefer handle.release();

                    break :blk try p.addNode(.{
                        .tag = .integer,
                        .data = .{ .object = handle },
                    });
                },
                .float => {
                    const loc = p.tokenLoc(p.token_i);
                    const value = std.fmt.parseFloat(f64, p.source[loc.start..loc.end]) catch unreachable;
                    const handle = try object.floatNew(value);
                    errdefer handle.release();

                    break :blk try p.addNode(.{
                        .tag = .float,
                        .data = .{ .object = handle },
                    });
                },
                .simple_string => {
                    const loc = p.tokenLoc(p.token_i);
                    const handle = try object.newString(p.source[loc.start..loc.end]);
                    errdefer handle.release();

                    break :blk try p.addNode(.{
                        .tag = .string,
                        .data = .{ .object = handle },
                    });
                },
                .escaped_string => {
                    const loc = p.tokenLoc(p.token_i);
                    const handle = try p.heap.createObject();
                    errdefer handle.release();
                    try object.setStringFromEscaped(p.gpa, handle, p.source[loc.start..loc.end]);

                    break :blk try p.addNode(.{
                        .tag = .string,
                        .data = .{ .object = handle },
                    });
                },
                .command_subst => {
                    const loc = p.tokenLoc(p.token_i);
                    var command_handle = try object.newString(p.source[loc.start..loc.end]);
                    errdefer command_handle.release();

                    // Be sure to save the source info.
                    try object.setSourceInfo(&command_handle, .{
                        .file_name = p.source_file_name,
                        .line_no = loc.line_no,
                    });
                },
                .argument_expansion,
                .word_separator,
                .command_separator,
                .expression_sugar,
                .start_of_command,
                .start_of_word,
                => unreachable,
            }
        };
    }

    const Error = struct {
        tag: Tag,
        token: TokenIndex,

        const Tag = enum {
            premature_expression_end,
            missing_operand,
            colon_without_question_mark,
        };
    };

    fn fail(p: *Parse, err: Error.Tag) !void {
        p.err = err;
        return error.ParseError;
    }
};

//! This struct is for tokenizing both script and expression tokens.

// This is cobbled together from Molt, Zig's tokenizer, and Jimtcl.

const std = @import("std");
const isWhitespace = std.ascii.isWhitespace;
const isAlphanumeric = std.ascii.isAlphanumeric;

const testing = std.testing;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const strutil = @import("stringutil.zig");
const ioutil = @import("ioutil.zig");
const options = @import("options");

const Tokenizer = @This();

buffer: []const u8,
index: u32,
line_no: u32,
/// We need to keep track of whether we're in a quote or not across `next`
/// invocations, because something like `set x "hello[set world]!"` emits
/// three tokens.
in_quote: bool,
/// Similar to `in_quote`, this keeps track of whether it's possible for the
/// next token to be a comment (set to true after newline or semicolon).
comment_possible: bool,
/// Whether we've emitted {*} for this word yet. There can only be one
/// argument expansion per word, so the second {*} it sees it'll emit
/// a .normal_string with the value of "*"
can_parse_arg_expansion: bool,
last_token_type: Token.Tag,
error_details: ?struct { index: u32, line_no: u32 },

const ScriptError = error{
    MissingCloseBracket,
    MissingCloseBrace,
    MissingCloseQuote,
    CharactersAfterCloseBrace,
    TrailingBackslash,
    NotVariable,
};
const ExpressionError = error{
    FunctionMissingParentheses,
    NotOperator,
    NotNumber,
};
pub const Error = ScriptError || ExpressionError;

pub const Token = struct {
    tag: Tag,
    loc: Location,

    pub const Location = struct {
        start: u32,
        end: u32,
        line_no: u32,
    };

    pub const Tag = enum(u8) {
        /// Nothing (can be safely ignored)
        none,
        /// Simple string (no escaping needed)
        simple_string,
        /// String that needs escape character conversion
        escaped_string,
        /// "{*}" token
        argument_expansion,
        /// Variable substitution
        variable_subst,
        /// command substitution
        command_subst,
        /// word separator (white space)
        word_separator,
        /// command separator (line feed or semicolon)
        command_separator,
        /// end of script
        end_of_file,
        /// Expression sugar
        expression_sugar,

        /// Special 'start-of-line' token. Corrisponding object contains the
        /// number of arguments for this command.
        start_of_command,
        /// Special 'start-of-word' token. Corrisponding object contains the
        /// number of tokens to combine for this word (of type .integer)
        start_of_word,

        // Used for expression tokenizing.
        l_paren,
        r_paren,
        comma,

        // Values.
        integer,
        float,
        keyword_true,
        keyword_false,

        // Expression operators.
        asterisk,
        forward_slash,
        percent,
        minus,
        plus,
        angle_bracket_left,
        angle_bracket_right,
        angle_bracket_left_equal,
        angle_bracket_right_equal,
        angle_bracket_angle_bracket_left,
        angle_bracket_angle_bracket_right,
        angle_bracket_angle_bracket_angle_bracket_left,
        angle_bracket_angle_bracket_angle_bracket_right,
        equal_equal,
        bang_equal,
        ampersand,
        caret,
        pipe,
        ampersand_ampersand,
        pipe_pipe,
        question_mark,
        colon,
        asterisk_asterisk,
        keyword_eq,
        keyword_ne,
        keyword_in,
        keyword_ni,
        keyword_lt,
        keyword_gt,
        keyword_le,
        keyword_ge,
        bang,
        tilde,
        function,
    };
};

pub const boolean_mapping = .{
    .{ "1", true },  .{ "true", true },   .{ "yes", true }, .{ "on", true },
    .{ "0", false }, .{ "false", false }, .{ "no", false }, .{ "off", false },
};

pub fn init(buffer: []const u8, line_no: u32) Tokenizer {
    return .{
        .buffer = buffer,
        .index = 0,
        .line_no = line_no,
        .in_quote = false,
        .comment_possible = true,
        .can_parse_arg_expansion = false,
        .last_token_type = .none,
        .error_details = null,
    };
}

/// Returns a single token for a script, or returns an appropriate error (details are
/// included in `parser.error_details`
pub fn nextScriptToken(self: *Tokenizer) Error!Token {
    const token: ?Token = blk: {
        while (!self.atEnd()) {
            switch (self.current()) {
                '\\' => {
                    if (self.peek(1) == '\n' and !self.in_quote) {
                        // escaped newline, not in quotes = word separator
                        break :blk self.nextSeparatorToken();
                    } else {
                        // Else we're starting a string.
                        break :blk try self.nextStringToken();
                    }
                },
                '\t', 12, '\r', ' ' => {
                    if (self.in_quote) {
                        self.comment_possible = false;
                        break :blk try self.nextStringToken();
                    } else {
                        break :blk self.nextSeparatorToken();
                    }
                },
                '\n', ';' => {
                    if (self.in_quote) {
                        break :blk try self.nextStringToken();
                    } else {
                        self.comment_possible = true;
                        break :blk self.nextEolToken();
                    }
                },
                '[' => {
                    self.comment_possible = false;
                    break :blk try self.nextCommandToken();
                },
                '$' => {
                    self.comment_possible = false;
                    break :blk self.nextVariableToken() catch |err| {
                        if (err == Error.NotVariable) {
                            // An orphan '$'. Create a token for it.
                            var token = self.newToken();
                            token.tag = .simple_string;
                            self.advance(1);
                            token.loc.end = self.index;
                            break :blk token;
                        } else {
                            return err;
                        }
                    };
                },
                '#' => {
                    if (self.comment_possible) {
                        _ = try self.nextCommentToken();
                    } else {
                        break :blk try self.nextStringToken();
                    }
                },
                else => {
                    break :blk try self.nextStringToken();
                },
            }
        }
        break :blk null;
    };

    if (token) |unwrapped| {
        self.last_token_type = unwrapped.tag;
        return unwrapped;
    } else {
        // If nothing was returned, it means we've reached the end of the file.

        if (self.in_quote) {
            // Ended without closing the quote.
            return Error.MissingCloseQuote;
        }

        // Return EOF.
        return .{
            .tag = .end_of_file,
            .loc = .{
                .start = self.index,
                .end = self.index,
                .line_no = self.line_no,
            },
        };
    }
}

pub fn nextStringToken(self: *Tokenizer) !Token {
    switch (self.last_token_type) {
        .none, .word_separator, .command_separator, .argument_expansion => {
            // This branch checks if we're at the start of a new word, or right after argument
            // expansion.

            // If we're truly at the start of a new word, argument expansion is possible.
            if (self.last_token_type != .argument_expansion) self.can_parse_arg_expansion = true;

            // We need to check if we're at the start of a new word, because braces
            // and quotes only have their special sauce apply if they're at the beginning
            // of a word. For example `foo[bar]baz` emits three tokens ("foo", "[bar]", "baz").
            // Only "foo" counts as the start of a word.
            //
            // One more example, `{can have spaces}[separator]{nospaces this_is_a_new_word`.
            switch (self.current()) {
                '{' => {
                    const token = try self.nextBracedStringToken();
                    // After a braced word, only whitespace and command terminators
                    // (newline, semicolon) are valid. Other characters (e.g. `x{foo}y`)
                    // are errors, matching Tcl's "extra characters after close-brace".
                    // Argument expansion ({*}) is exempt — it's a prefix, so the
                    // word to expand follows immediately with no whitespace.
                    if (token.tag != .argument_expansion) {
                        if (self.peek(0)) |char| {
                            if (!isWhitespace(char) and char != ';') {
                                return error.CharactersAfterCloseBrace;
                            }
                        }
                    }
                    return token;
                },
                '"' => {
                    self.in_quote = true;
                    // Save where the opening quote is, so we can point to it
                    // if it's not matched.
                    self.error_details = .{
                        .index = self.index,
                        .line_no = self.line_no,
                    };
                    self.advance(1);
                },
                else => {},
            }
        },
        else => {},
    }

    var token = self.newToken();
    token.tag = .simple_string;

    while (!self.atEnd()) {
        switch (self.current()) {
            '\\' => {
                token.tag = .escaped_string;

                if (!self.in_quote and self.peek(1) == '\n') {
                    // The escaped newline is interpreted as a word
                    // separator, so we'll cap this word.
                    token.loc.end = self.index;
                    return token;
                }
                self.advance(1); // skip character after \
                try self.errorIfAtEndAfterBackslash();

                self.advance(1);
            },
            '$', '[' => {
                // Start of variable/command substitution, so cap this token.
                token.loc.end = self.index;
                return token;
            },
            '\t'...'\r', ' ', ';' => {
                if (!self.in_quote) {
                    token.loc.end = self.index;
                    return token;
                } else {
                    self.advance(1);
                }
            },
            '"' => {
                if (self.in_quote) {
                    self.in_quote = false;
                    token.tag = .escaped_string;
                    token.loc.end = self.index;
                    self.advance(1);
                    return token;
                }
            },
            else => self.advance(1),
        }
    }

    // If we reached here, it means we reached the end of the input
    if (self.in_quote) {
        return Error.MissingCloseQuote;
    } else {
        token.loc.end = self.index;
        return token;
    }
}

fn nextQuotedStringToken(self: *Tokenizer) !Token {
    // save for potential error message later if there's a missing close quote
    const index = self.index;
    const line_no = self.line_no;

    // skip the quote
    self.advance(1);

    var token = self.newToken();
    token.tag = .simple_string;

    while (!self.atEnd()) {
        switch (self.current()) {
            '\\' => {
                token.tag = .escaped_string;

                self.advance(1); // skip character after escape
                try self.errorIfAtEndAfterBackslash();
            },
            '"' => {
                token.loc.end = self.index;
                // advance past the quote
                self.advance(1);
                return token;
            },
            '[' => {
                // parseCommand will advance the index just past the end of the command
                _ = try self.nextCommandToken();
                // skip advancing this time, because parseCommand already did that
                continue;
            },
            '$' => {
                // Not our job to deal with variable substitution, so yield this as
                // the end
                token.loc.end = self.index;
                return token;
            },
            else => {},
        }

        self.advance(1);
    }

    // if we made it this far, it means we reached the end of input without
    // finding a closing quote.
    self.error_details = .{
        .index = index,
        .line_no = line_no,
    };
    return Error.MissingCloseQuote;
}

pub fn nextVariableToken(self: *Tokenizer) !Token {
    const start = self.mark();

    // Skip the '$'
    self.advance(1);

    if (self.atEnd()) {
        // rewind our location
        self.restore(start);
        return Error.NotVariable;
    }

    var token = self.newToken();
    token.tag = .variable_subst;

    // Braced variable? (e.g. ${foo})
    if (self.current() == '{') {
        const brace_index = self.index;
        const brace_line_no = self.line_no;

        self.advance(1);
        // set new token location to inside the brace
        token.loc.start = self.index;

        // search for closing brace
        var found_closing_brace = false;
        while (!self.atEnd()) : (self.advance(1)) {
            if (self.current() == '}') {
                found_closing_brace = true;
                break;
            }
        }

        if (!found_closing_brace) {
            self.error_details = .{
                .index = brace_index,
                .line_no = brace_line_no,
            };
            return Error.MissingCloseBrace;
        }

        token.loc.end = self.index;

        // be sure to point at past the brace
        if (!self.atEnd()) self.advance(1);
    } else {
        // Just a normal variable.
        while (!self.atEnd()) {
            // Skip double colon, but not single colon!
            if (self.current() == ':' and self.peek(1) == ':') {
                self.advance(2);
                continue;
            }
            // Note that any char >= 0x80 must be part of a utf-8 char.
            // We consider all unicode points outside of ASCII as letters
            if (isAlphanumeric(self.current()) or self.current() == '_' or self.current() >= 0x80) {
                self.advance(1);
                continue;
            }
            // None of the above, so we've reached the end of this variable.
            break;
        }

        token.loc.end = self.index;
    }

    // Check if we parsed just the '$' character. That's not a variable, so an
    // error is returned to tell the parser to consider this '$' as just
    // a string.
    if (token.loc.start == self.index) {
        self.restore(start);
        return Error.NotVariable;
    }

    return token;
}

pub fn nextCommandToken(self: *Tokenizer) Error!Token {
    // Save in case the bracket is not matched for better error message.
    const index = self.index;
    const line_no = self.line_no;

    // Skip opening '['
    self.advance(1);
    var bracket_level: u32 = 1;

    // Whether we're at the start of a word in the command
    // (quotes and braces only apply if they're the first
    // character of a word)
    var start_of_word = true;

    var token = self.newToken();

    while (!self.atEnd()) {
        switch (self.current()) {
            '\\' => {
                // Skip character after escape
                self.advance(1);
                try self.errorIfAtEndAfterBackslash();
            },
            '[' => {
                bracket_level += 1;
            },
            ']' => {
                bracket_level -= 1;
                if (bracket_level == 0) {
                    token.tag = .command_subst;
                    token.loc.end = self.index;

                    // make sure to advance past the closing bracket
                    self.advance(1);

                    return token;
                }
            },
            '"' => {
                if (start_of_word) {
                    // advance to just past where the quoted word ends
                    _ = try self.nextQuotedStringToken();
                    continue;
                }
            },
            '{' => {
                // Mark arg expansion...
                const could_parse_arg_expansion = self.can_parse_arg_expansion;
                self.can_parse_arg_expansion = true;

                // Advance to just past where the brace ends.
                _ = try self.nextBracedStringToken();

                // ...and restore.
                self.can_parse_arg_expansion = could_parse_arg_expansion;
                start_of_word = false; // have to set because of the continue
                continue;
            },
            else => {
                start_of_word = isWhitespace(self.current());
            },
        }

        self.advance(1);
    }

    // If we reached here, it means we reached the end of the input
    // without balancing our brackets. Thus, a missing bracket error
    // is needed.
    self.error_details = .{
        .index = index,
        .line_no = line_no,
    };
    return Error.MissingCloseBracket;
}

pub fn nextBracedStringToken(self: *Tokenizer) !Token {
    // Save the current line in case the braces are mismatched (so we can point
    // right to where the problem is)
    const index = self.index;
    const line_no = self.line_no;

    // Skip '{'
    self.advance(1);
    var brace_depth: usize = 1;

    var token = self.newToken();
    token.tag = .simple_string;

    while (!self.atEnd()) : (self.advance(1)) {
        switch (self.current()) {
            '{' => {
                brace_depth += 1;
            },
            '}' => {
                brace_depth -= 1;

                if (brace_depth == 0) {
                    token.loc.end = self.index;

                    // Special case: is this argument expansion?
                    if (self.can_parse_arg_expansion and
                        token.loc.end - token.loc.start == 1 and
                        self.buffer[token.loc.start] == '*')
                    {
                        // We can't have argument expansion more than once.
                        self.can_parse_arg_expansion = false;
                        token.tag = .argument_expansion;
                        // Make sure to point at after the closing brace.
                        self.advance(1);

                        return token;
                    }

                    // make sure to point at after the closing brace
                    self.advance(1);

                    return token;
                }
            },
            '\\' => {
                // Skip the character after the backslash so \{ and \} don't
                // affect brace counting. Standard Tcl: a brace preceded by an
                // odd number of backslashes is not counted. We intentionally do
                // not implement the \<newline> -> space substitution inside
                // braces, because it makes serialization of programs a pain.
                if (!self.atEnd()) self.advance(1);
            },
            else => {},
        }
    }

    // If we've reached this point, it means we've reached the end of input without
    // our braces being balanced. As such, we should error.
    self.error_details = .{
        .index = index,
        .line_no = line_no,
    };
    return Error.MissingCloseBrace;
}

/// Parse the end of the line until the next command.
pub fn nextEolToken(self: *Tokenizer) Token {
    var token = self.newToken();

    while (!self.atEnd()) : (self.advance(1)) {
        if (!isWhitespace(self.current()) and self.current() != ';') {
            break;
        }
    }

    token.tag = .command_separator;
    token.loc.end = self.index;

    return token;
}

/// Tokenize a word separator (spaces, tabs, etc). Accounts for newline escapes.
pub fn nextSeparatorToken(self: *Tokenizer) Token {
    var token = self.newToken();

    while (!self.atEnd()) : (self.advance(1)) {
        switch (self.current()) {
            '\t', 12, '\r', ' ' => {},
            '\\' => {
                if (self.peek(1) == '\n') {
                    // skip the \n
                    self.advance(1);
                }
            },
            '\n' => break,
            else => break,
        }
    }

    token.tag = .word_separator;
    token.loc.end = self.index;

    return token;
}

pub fn nextCommentToken(self: *Tokenizer) !void {
    // Consume characters until \n (excluding escaping)
    while (!self.atEnd()) : (self.advance(1)) {
        switch (self.current()) {
            '\\' => {
                self.advance(1); // skip escaped character
                try self.errorIfAtEndAfterBackslash();
            },
            '\n' => {
                self.advance(1);
                return;
            },
            else => {},
        }
    }
}

pub fn nextListToken(self: *Tokenizer) !Token {
    // Lists are data, not code, so there is no argument expansion.
    self.can_parse_arg_expansion = false;

    if (self.atEnd()) {
        return .{
            .tag = .end_of_file,
            .loc = .{
                .start = self.index,
                .end = self.index,
                .line_no = self.line_no,
            },
        };
    }

    if (isWhitespace(self.current())) {
        return self.nextListSeparatorToken();
    }

    switch (self.current()) {
        '"' => {
            return self.nextListQuoteToken();
        },
        '{' => {
            const token = try self.nextBracedStringToken();
            // In a list, only whitespace is valid after a braced element.
            if (self.peek(0)) |char| {
                if (!isWhitespace(char)) {
                    return error.CharactersAfterCloseBrace;
                }
            }
            return token;
        },
        else => {
            return self.nextListStringToken();
        },
    }
}

fn nextListSeparatorToken(self: *Tokenizer) Token {
    var token = self.newToken();
    token.tag = .word_separator;

    while (!self.atEnd() and isWhitespace(self.current())) {
        self.advance(1);
    }

    token.loc.end = self.index;
    return token;
}

fn nextListQuoteToken(self: *Tokenizer) Token {
    self.advance(1); // skip quote

    var token = self.newToken();
    token.tag = .simple_string;

    while (!self.atEnd()) : (self.advance(1)) {
        switch (self.current()) {
            '\\' => {
                token.tag = .escaped_string;
                self.advance(1);

                // trailing backslash
                if (self.atEnd()) {
                    token.loc.end = self.index;
                    return token;
                }
            },
            '"' => {
                self.advance(1);
                token.loc.end = self.index;
                return token;
            },
            else => {},
        }
    }

    token.loc.end = self.index;
    return token;
}

pub fn nextListStringToken(self: *Tokenizer) Token {
    var token = self.newToken();
    token.tag = .simple_string;

    while (!self.atEnd()) : (self.advance(1)) {
        if (isWhitespace(self.current())) {
            token.loc.end = self.index;
            return token;
        } else if (self.current() == '\\') {
            token.tag = .escaped_string;

            self.advance(1);
            if (self.atEnd()) {
                // Trailing backslash
                token.loc.end = self.index;
                return token;
            }
        }
    }

    token.loc.end = self.index;
    return token;
}

pub fn nextExpressionToken(self: *Tokenizer) Error!Token {
    // Argument expansion doesn't exist in expressions.
    self.can_parse_arg_expansion = false;

    while (!self.atEnd()) : (self.advance(1)) {
        // Discard comments and whitespace.
        if (isWhitespace(self.current())) {
            // Advance past this.
        } else if (self.startsWith("\\\n")) {
            // Skip escaped newline.
            self.advance(1);
        } else if (self.current() == '#') {
            try self.nextCommentToken();
        } else break;

        // Keep going until we skip all the whitespace.
    }

    if (self.atEnd()) return .{
        .tag = .end_of_file,
        .loc = .{
            .start = self.index,
            .end = self.index,
            .line_no = self.line_no,
        },
    };

    switch (self.current()) {
        '(' => return self.singleCharToken(.l_paren),
        ')' => return self.singleCharToken(.r_paren),
        ',' => return self.singleCharToken(.comma),
        '[' => return self.nextCommandToken(),
        '$' => {
            if (self.nextVariableToken()) |val| {
                return val;
            } else |err| switch (err) {
                error.NotVariable => {
                    return self.nextOperatorToken();
                },
                else => return err,
            }
        },
        '0'...'9' => return self.nextNumberToken(),
        '"' => return self.nextQuotedStringToken(),
        '{' => return self.nextBracedStringToken(),
        // May be the start of "NaN", "inf", or "no".
        'N', 'n', 'I', 'i' => {
            if (self.nextIrrationalFloatToken()) |val| {
                return val;
            } else |err| switch (err) {
                error.NotIrrationalFloat => {
                    // Might be "no"
                    if (self.nextBooleanToken()) |val| {
                        return val;
                    } else |inner_err| switch (inner_err) {
                        error.NotBoolean => return self.nextOperatorToken(),
                    }
                },
            }
        },
        // true, false, on, off, yes (not no, as that's handled by the previous branch).
        't', 'f', 'o', 'y' => {
            if (self.nextBooleanToken()) |val| {
                return val;
            } else |err| switch (err) {
                error.NotBoolean => return self.nextOperatorToken(),
            }
        },
        else => return self.nextOperatorToken(),
    }
}

pub const function_names = [_][:0]const u8{
    "int",   "wide", "abs",   "double", "rand",
    "srand", "sin",  "cos",   "tan",    "asin",
    "acos",  "atan", "atan2", "sinh",   "cosh",
    "tanh",  "ceil", "floor", "exp",    "log",
    "log10", "sqrt", "pow",   "hypot",  "fmod",
};
const sorted_function_names = blk: {
    var sorted_names = function_names;
    @setEvalBranchQuota(100_000);
    std.mem.sort([:0]const u8, &sorted_names, void, struct {
        fn lessThan(_: type, lhs: []const u8, rhs: []const u8) bool {
            return lhs.len > rhs.len;
        }
    }.lessThan);

    break :blk sorted_names;
};

const OperatorEntry = struct { [:0]const u8, Token.Tag };
const operator_to_token_mapping = [_]OperatorEntry{
    .{ "*", Token.Tag.asterisk },
    .{ "/", Token.Tag.forward_slash },
    .{ "%", Token.Tag.percent },
    .{ "-", Token.Tag.minus },
    .{ "+", Token.Tag.plus },
    .{ "<", Token.Tag.angle_bracket_left },
    .{ ">", Token.Tag.angle_bracket_right },
    .{ "<=", Token.Tag.angle_bracket_left_equal },
    .{ ">=", Token.Tag.angle_bracket_right_equal },
    .{ "<<", Token.Tag.angle_bracket_angle_bracket_left },
    .{ ">>", Token.Tag.angle_bracket_angle_bracket_right },
    .{ "<<<", Token.Tag.angle_bracket_angle_bracket_angle_bracket_left },
    .{ ">>>", Token.Tag.angle_bracket_angle_bracket_angle_bracket_right },
    .{ "==", Token.Tag.equal_equal },
    .{ "!=", Token.Tag.bang_equal },
    .{ "&", Token.Tag.ampersand },
    .{ "^", Token.Tag.caret },
    .{ "|", Token.Tag.pipe },
    .{ "&&", Token.Tag.ampersand_ampersand },
    .{ "||", Token.Tag.pipe_pipe },
    .{ "?", Token.Tag.question_mark },
    .{ ":", Token.Tag.colon },
    .{ "**", Token.Tag.asterisk_asterisk },
    .{ "eq", Token.Tag.keyword_eq },
    .{ "ne", Token.Tag.keyword_ne },
    .{ "in", Token.Tag.keyword_in },
    .{ "ni", Token.Tag.keyword_ni },
    .{ "lt", Token.Tag.keyword_lt },
    .{ "gt", Token.Tag.keyword_gt },
    .{ "le", Token.Tag.keyword_le },
    .{ "ge", Token.Tag.keyword_ge },
    .{ "!", Token.Tag.bang },
    .{ "~", Token.Tag.tilde },
};
/// These need to be sorted by longest string first, because otherwise
/// we might match "*" instead of matching "**" in `nextOperatorToken()`.
const sorted_operator_to_token_mapping = blk: {
    var mapping = operator_to_token_mapping;
    @setEvalBranchQuota(100_000);
    std.mem.sort(OperatorEntry, &mapping, void, struct {
        fn lessThan(_: type, lhs: OperatorEntry, rhs: OperatorEntry) bool {
            return lhs.@"0".len > rhs.@"0".len;
        }
    }.lessThan);

    break :blk mapping;
};

pub fn nextOperatorToken(self: *Tokenizer) !Token {
    var token = self.newToken();

    for (sorted_operator_to_token_mapping) |mapping| {
        const str_value = mapping.@"0";
        const tag = mapping.@"1";

        // Does the parser start with the token we're checking?
        if (self.startsWith(str_value)) {
            self.advance(str_value.len);

            token.tag = tag;
            token.loc.end = self.index;

            return token;
        } else {
            // It might be a function. There's only a certain number of valid functions,
            // so we'll check those names only.
            for (sorted_function_names) |function_name| {
                if (self.startsWith(function_name)) {
                    self.advance(function_name.len);

                    // This is a function token, so we need to make sure that it has
                    // an opening paren.
                    while (!self.atEnd() and isWhitespace(self.current())) self.advance(1);

                    if (self.atEnd() or self.current() != '(') return error.FunctionMissingParentheses;

                    self.advance(1);
                    // We should now be pointing to just after the opening parenthesis.
                    token.tag = .function;
                    token.loc.end = self.index;

                    return token;
                }
            }
        }
    }

    return error.NotOperator;
}

pub fn nextIrrationalFloatToken(self: *Tokenizer) !Token {
    inline for (.{ "NaN", "nan", "NAN", "Inf", "inf", "INF" }) |irrational| {
        if (self.startsWith(irrational)) {
            self.advance(3);

            var token = self.newToken();
            token.tag = .float;
            token.loc.end = self.index;
            return token;
        }
    }

    return error.NotIrrationalFloat;
}

pub fn nextBooleanToken(self: *Tokenizer) !Token {
    inline for (boolean_mapping) |mapping| {
        const str_value = mapping.@"0";
        const bool_value = mapping.@"1";

        if (self.startsWith(str_value)) {
            self.advance(str_value.len);

            var token = self.newToken();
            token.tag = if (bool_value) .keyword_true else .keyword_false;
            token.loc.end = self.index;
            return token;
        }
    }

    return error.NotBoolean;
}

pub fn nextNumberToken(self: *Tokenizer) !Token {
    var token = self.newToken();
    // Start by assuming it's an integer.
    token.tag = .integer;

    while (!self.atEnd()) : (self.advance(1)) {
        switch (self.current()) {
            '0'...'9' => {},
            // "1e5", "nan", "infinity", "1.5", etc
            'e', 'E', 'n', 'N', 'i', 'I', '.' => {
                token.tag = .float;
            },
            else => break,
        }
    }

    // Make sure it's a valid integer.
    if (std.fmt.parseInt(i64, self.buffer[token.loc.start..self.index], 10)) |_| {
        token.loc.end = self.index;
        return token;
    } else |_| {
        if (std.fmt.parseFloat(f64, self.buffer[token.loc.start..self.index])) |_| {
            token.loc.end = self.index;
            return token;
        } else |_| {
            self.error_details = .{
                .index = token.loc.start,
                .line_no = token.loc.line_no,
            };
            return error.NotNumber;
        }
    }
}

/// Initializes `.start`. Caller must initialize all other fields.
fn newToken(self: *Tokenizer) Token {
    return .{
        .tag = undefined,
        .loc = .{
            .start = self.index,
            .line_no = self.line_no,
            .end = undefined,
        },
    };
}

fn singleCharToken(self: *Tokenizer, tag: Token.Tag) Token {
    const start = self.index;
    self.advance(1);
    return .{
        .tag = tag,
        .loc = .{
            .start = start,
            .line_no = self.line_no,
            .end = self.index,
        },
    };
}

fn errorIfAtEndAfterBackslash(self: *Tokenizer) !void {
    if (self.atEnd()) {
        self.error_details = .{
            .index = self.index,
            .line_no = self.line_no,
        };
        return Error.TrailingBackslash;
    }
}

const Mark = struct {
    index: u32,
    line_no: u32,
    in_quote: bool,
    comment_possible: bool,
    last_token_type: Token.Tag,
    can_parse_arg_expansion: bool,
};

fn mark(self: *Tokenizer) Mark {
    return .{
        .index = self.index,
        .line_no = self.line_no,
        .in_quote = self.in_quote,
        .comment_possible = self.comment_possible,
        .last_token_type = self.last_token_type,
        .can_parse_arg_expansion = self.can_parse_arg_expansion,
    };
}

fn restore(self: *Tokenizer, to_restore: Mark) void {
    self.index = to_restore.index;
    self.line_no = to_restore.line_no;
    self.in_quote = to_restore.in_quote;
    self.comment_possible = to_restore.comment_possible;
    self.last_token_type = to_restore.last_token_type;
    self.can_parse_arg_expansion = to_restore.can_parse_arg_expansion;
}

fn current(self: *Tokenizer) u8 {
    return self.buffer[self.index];
}

fn peek(self: *Tokenizer, ahead_by: usize) ?u8 {
    if (self.index + ahead_by < self.buffer.len) {
        return self.buffer[self.index + ahead_by];
    } else {
        return null;
    }
}

fn advance(self: *Tokenizer, count: usize) void {
    for (0..count) |_| {
        if (self.buffer[self.index] == '\n') {
            self.line_no += 1;
        }

        self.index += 1;
    }
}

/// Checks if the next characters match `str`. Returns false if there are not enough
/// remaining characters.
fn startsWith(self: *Tokenizer, str: []const u8) bool {
    if (self.buffer.len - self.index >= str.len) {
        return std.mem.eql(u8, self.buffer[self.index .. self.index + str.len], str);
    } else {
        return false;
    }
}

fn atEnd(self: *Tokenizer) bool {
    return self.index == self.buffer.len;
}

test "parser" {
    const script =
        \\set x 5
        \\set y {a b c}
        \\set $i $x$y [foo]BAR
    ;

    var parser = Tokenizer.init(script, 1);

    try testNextToken(&parser, .simple_string, "set");
    try testNextToken(&parser, .word_separator, " ");
    try testNextToken(&parser, .simple_string, "x");
    try testNextToken(&parser, .word_separator, " ");
    try testNextToken(&parser, .simple_string, "5");
    try testNextToken(&parser, .command_separator, "\n");

    try testNextToken(&parser, .simple_string, "set");
    try testNextToken(&parser, .word_separator, " ");
    try testNextToken(&parser, .simple_string, "y");
    try testNextToken(&parser, .word_separator, " ");
    try testNextToken(&parser, .simple_string, "a b c");
    try testNextToken(&parser, .command_separator, "\n");

    try testNextToken(&parser, .simple_string, "set");
    try testNextToken(&parser, .word_separator, " ");
    try testNextToken(&parser, .variable_subst, "i");
    try testNextToken(&parser, .word_separator, " ");
    try testNextToken(&parser, .variable_subst, "x");
    try testNextToken(&parser, .variable_subst, "y");
    try testNextToken(&parser, .word_separator, " ");
    try testNextToken(&parser, .command_subst, "foo");
    try testNextToken(&parser, .simple_string, "BAR");

    try testNextToken(&parser, .end_of_file, "");

    const broken = "set x {good}bad";
    parser = Tokenizer.init(broken, 1);

    try testNextToken(&parser, .simple_string, "set");
    try testNextToken(&parser, .word_separator, " ");
    try testNextToken(&parser, .simple_string, "x");
    try testNextToken(&parser, .word_separator, " ");
    try testing.expectError(error.CharactersAfterCloseBrace, parser.nextScriptToken());

    const argument_expansion = "{*}$value";
    parser = Tokenizer.init(argument_expansion, 1);

    try testNextToken(&parser, .argument_expansion, "*");
    try testNextToken(&parser, .variable_subst, "value");

    const double_asterisks = "{*}{*}";
    parser = Tokenizer.init(double_asterisks, 1);

    try testNextToken(&parser, .argument_expansion, "*");
    try testNextToken(&parser, .simple_string, "*");
}

fn testNextToken(parser: *Tokenizer, expected_type: Token.Tag, expected_value: []const u8) !void {
    const next = parser.nextScriptToken() catch |err| {
        ioutil.debug("Error caught when parsing: {}", .{err});
        return error.TestUnexpectedResult;
    };

    try expectEqual(expected_type, next.tag);
    try expectEqualSlices(u8, expected_value, parser.buffer[next.loc.start..next.loc.end]);
}

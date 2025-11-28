// This is cobbled together from Molt, Zig's tokenizer, and Jimtcl

const std = @import("std");
const isWhitespace = std.ascii.isWhitespace;
const isAlphanumeric = std.ascii.isAlphanumeric;

const testing = std.testing;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const stringutil = @import("stringutil.zig");
const options = @import("options");

const Parser = @This();

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

pub const Error = error{
    MissingCloseBracket,
    MissingCloseBrace,
    MissingCloseQuote,
    CharactersAfterCloseBrace,
    TrailingBackslash,
    NotVariable,
};

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
        /// Syntax sugar for [dict get], $foo(bar)
        dict_sugar,
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

        // Used for expr parsing
    };
};

pub fn init(buffer: []const u8, line_no: u32) Parser {
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

/// Parses a single token, or returns an appropriate error (details are
/// included in `parser.error_details`
pub fn parseScript(self: *Parser) Error!Token {
    const token: ?Token = blk: {
        while (!self.atEnd()) {
            switch (self.current()) {
                '\\' => {
                    if (self.peek(1) == '\n' and !self.in_quote) {
                        // escaped newline, not in quotes = word separator
                        break :blk self.parseSeparator();
                    } else {
                        // Else we're starting a string.
                        break :blk try self.parseString();
                    }
                },
                '\t', 12, '\r', ' ' => {
                    if (self.in_quote) {
                        self.comment_possible = false;
                        break :blk try self.parseString();
                    } else {
                        break :blk self.parseSeparator();
                    }
                },
                '\n', ';' => {
                    if (self.in_quote) {
                        break :blk try self.parseString();
                    } else {
                        self.comment_possible = true;
                        break :blk self.parseEol();
                    }
                },
                '[' => {
                    self.comment_possible = false;
                    break :blk try self.parseCommand();
                },
                '$' => {
                    self.comment_possible = false;
                    break :blk self.parseVariable() catch |err| {
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
                        _ = try self.parseComment();
                    } else {
                        break :blk try self.parseString();
                    }
                },
                else => {
                    break :blk try self.parseString();
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

pub fn parseString(self: *Parser) !Token {
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
                '{' => return self.parseBrace(),
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
                }
            },
            '"' => {
                if (self.in_quote) {
                    self.in_quote = false;
                    token.tag = .escaped_string;
                    token.loc.end = self.index;
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

pub fn parseQuote(self: *Parser) !Token {
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
                _ = try self.parseCommand();
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

pub fn parseVariable(self: *Parser) !Token {
    const start = self.mark();

    // Skip the '$'
    self.advance(1);

    if (self.atEnd()) {
        // rewind our location
        self.restore(start);
        return Error.NotVariable;
    }

    if (options.bracket_expr_sugar and self.current() == '[') {
        // Parse $[...] expr shorthand syntax
        var command_token = try self.parseCommand();
        command_token.tag = .expression_sugar;
        return command_token;
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
            // None of the above, so we've reached the end of this variable
            // (excluding dictionary sugar, which we'll address next).
            break;
        }

        // Parse [dict get] syntax sugar (e.g. $foo(bar)).
        if (!self.atEnd() and self.current() == '(') {
            token.tag = .dict_sugar;

            self.advance(1); // skip '('

            var paren_depth: u32 = 1;
            // We need to keep track of the last seen closing paren,
            // because the parser will happily keep chugging along
            // until it's consumed everything. If that's the case,
            // we'll just rewind to the last seen closing paren.
            var last_seen_closing_paren: ?Mark = null;
            while (!self.atEnd() and paren_depth > 0) {
                switch (self.current()) {
                    '\\' => {
                        self.advance(1);
                        try self.errorIfAtEndAfterBackslash();
                    },
                    '(' => {
                        paren_depth += 1;
                    },
                    ')' => {
                        last_seen_closing_paren = self.mark();
                        paren_depth -= 1;
                    },
                    else => {},
                }
                self.advance(1);
            }

            if (paren_depth != 0 and last_seen_closing_paren != null) {
                // We ended unbalanced and may have consumed the universe,
                // so rewind to the last closing paren
                self.restore(last_seen_closing_paren.?);
                self.advance(1);
            }

            if (!options.bracket_expr_sugar and self.buffer[token.loc.start] == '(') {
                // We can either have $[] for expression sugar, or $(). This branch
                // is for the latter case (we handled the former earlier).
                token.tag = .expression_sugar;
            }
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

pub fn parseCommand(self: *Parser) Error!Token {
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
                    _ = try self.parseQuote();
                    continue;
                }
            },
            '{' => {
                // Mark arg expansion...
                const could_parse_arg_expansion = self.can_parse_arg_expansion;
                self.can_parse_arg_expansion = true;

                // Advance to just past where the brace ends.
                _ = try self.parseBrace();

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

pub fn parseBrace(self: *Parser) !Token {
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
                        // Note that this returns early, since we don't want to return
                        // Error.CharactersAfterCloseBrace for argument expansion.
                        return token;
                    }

                    // We've found the same number of opening and closing braces
                    // at this point. We'll just double-check that there's nothing
                    // afterwards.
                    if (self.peek(1)) |char| {
                        if (!isWhitespace(char)) {
                            return Error.CharactersAfterCloseBrace;
                        }
                    }

                    // make sure to point at after the closing brace
                    self.advance(1);

                    return token;
                }
            },
            '\\' => {
                // we intentionally don't check for "\\n", because tcl's curly brace
                // \n escape makes serialization of programs a pain (plus it's a rather
                // big gotcha)
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
pub fn parseEol(self: *Parser) Token {
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

/// Parses a word separator (spaces, tabs, etc). Accounts for newline escapes.
pub fn parseSeparator(self: *Parser) Token {
    var token = self.newToken();

    while (true) : (self.advance(1)) {
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

pub fn parseComment(self: *Parser) !void {
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

pub fn parseList(self: *Parser) !Token {
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
        return self.parseListSeparator();
    }

    switch (self.current()) {
        '"' => {
            return self.parseListQuote();
        },
        '{' => {
            return self.parseBrace();
        },
        else => {
            return self.parseListString();
        },
    }
}

pub fn parseListSeparator(self: *Parser) Token {
    var token = self.newToken();
    token.tag = .word_separator;

    while (!self.atEnd() and isWhitespace(self.current())) {
        self.advance(1);
    }

    token.loc.end = self.index;
    return token;
}

pub fn parseListQuote(self: *Parser) Token {
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

pub fn parseListString(self: *Parser) Token {
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

/// Initializes `.start`. Caller must initialize all other fields.
pub fn newToken(self: *Parser) Token {
    return .{
        .tag = undefined,
        .loc = .{
            .start = self.index,
            .line_no = self.line_no,
            .end = undefined,
        },
    };
}

pub fn errorIfAtEndAfterBackslash(self: *Parser) !void {
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

pub fn mark(self: *Parser) Mark {
    return .{
        .index = self.index,
        .line_no = self.line_no,
        .in_quote = self.in_quote,
        .comment_possible = self.comment_possible,
        .last_token_type = self.last_token_type,
        .can_parse_arg_expansion = self.can_parse_arg_expansion,
    };
}

pub fn restore(self: *Parser, to_restore: Mark) void {
    self.index = to_restore.index;
    self.line_no = to_restore.line_no;
    self.in_quote = to_restore.in_quote;
    self.comment_possible = to_restore.comment_possible;
    self.last_token_type = to_restore.last_token_type;
    self.can_parse_arg_expansion = to_restore.can_parse_arg_expansion;
}

pub fn current(self: *Parser) u8 {
    return self.buffer[self.index];
}

pub fn peek(self: *Parser, ahead_by: usize) ?u8 {
    if (self.index + ahead_by < self.buffer.len) {
        return self.buffer[self.index + ahead_by];
    } else {
        return null;
    }
}

pub fn advance(self: *Parser, count: usize) void {
    for (0..count) |_| {
        if (self.buffer[self.index] == '\n') {
            self.line_no += 1;
        }

        self.index += 1;
    }
}

/// Checks if the next characters match `str`. Returns false if there are not enough
/// remaining characters.
pub fn startsWith(self: *Parser, str: []const u8) bool {
    if (self.buffer.len - self.index >= str.len) {
        return std.mem.eql(u8, self.buffer[self.index .. self.index + str.len], str);
    } else {
        return false;
    }
}

pub fn atEnd(self: *Parser) bool {
    return self.index == self.buffer.len;
}

test "parser" {
    const script =
        \\set x 5
        \\set y {a b c}
        \\set $i $x$y [foo]BAR
    ;

    var parser = Parser.init(script, 1);

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
    parser = Parser.init(broken, 1);

    try testNextToken(&parser, .simple_string, "set");
    try testNextToken(&parser, .word_separator, " ");
    try testNextToken(&parser, .simple_string, "x");
    try testNextToken(&parser, .word_separator, " ");
    try testing.expectError(error.CharactersAfterCloseBrace, parser.parseScript());

    const argument_expansion = "{*}$value";
    parser = Parser.init(argument_expansion, 1);

    try testNextToken(&parser, .argument_expansion, "*");
    try testNextToken(&parser, .variable_subst, "value");

    const double_asterisks = "{*}{*}";
    parser = Parser.init(double_asterisks, 1);

    try testNextToken(&parser, .argument_expansion, "*");
    try testNextToken(&parser, .simple_string, "*");
}

fn testNextToken(parser: *Parser, expected_type: Token.Tag, expected_value: []const u8) !void {
    const next = parser.parseScript() catch |err| {
        std.debug.print("Error caught when parsing: {}", .{err});
        return error.TestUnexpectedResult;
    };

    try expectEqual(expected_type, next.tag);
    try expectEqualSlices(u8, expected_value, parser.buffer[next.loc.start..next.loc.end]);
}

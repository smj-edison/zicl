//! This struct is for tokenizing both script and expression tokens.

// This is cobbled together from Molt, Zig's tokenizer, and Jimtcl.

const std = @import("std");

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
    };
};

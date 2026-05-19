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
        /// Simple string (no escaping needed)
        simple_string,
        /// Variable substitution
        variable_subst,

        /// Special 'start-of-line' token. Corrisponding object contains the
        /// number of arguments for this command.
        start_of_command,
    };
};

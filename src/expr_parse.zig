const std = @import("std");
const testing = std.testing;
const Writer = std.Io.Writer;

const Tokenizer = @import("Tokenizer.zig");
// Used to store parsed strings.
const Heap = @import("Heap.zig");
const Handle = Heap.Handle;
const OptionalHandle = Heap.OptionalHandle;
const objutil = @import("objutil.zig");
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

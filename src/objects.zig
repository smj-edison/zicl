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
// const expr_parse = @import("expr_parse.zig");

/// Note that this is often cast to `Mutable`, so you can't depend on `original`
/// and `shimmered` as having the same value. Always use `.current()`. This is
/// because `Shimmerable` and `Mutable` are more conventions to keep straight
/// what's allowed to mutate, and what's just allowed to shimmer (a mutation is
/// considered a shimmer if it has/will generate the same string rep).
pub const Shimmerable = extern struct {
    original: Value,
    shimmered: OptionalValue = .none,

    pub fn deinit(self: *Shimmerable) void {
        self.original.release();
        self.shimmered.release();
        self.* = undefined;
    }

    pub fn current(self: Shimmerable) Value {
        return self.shimmered.orElse(self.original);
    }

    pub fn consume(self: *Shimmerable) Value {
        defer self.* = undefined;
        if (self.shimmered.asValue()) |shimmered| {
            self.original.release();
            return shimmered;
        } else {
            return self.original;
        }
    }

    pub fn discardChanges(self: *Shimmerable) void {
        self.shimmered.swapWithNone();
    }

    pub fn takeShimmered(self: *Shimmerable) OptionalValue {
        const shimmered = self.shimmered;
        self.shimmered = .none;
        return shimmered;
    }

    /// Be very careful when using `asMutable`, since mutation functions often invalidate
    /// the original string. Even if the mutation you do is transparent with the object
    /// model, it may free the original string, thus not being transparent.
    pub fn asMutable(self: *Shimmerable) *Mutable {
        return @ptrCast(self);
    }

    pub fn ensureShimmerable(self: *Shimmerable) error{OutOfMemory}!void {
        if (!self.current().canShimmer()) {
            self.shimmered.swap(self.current().duplicate());
        }
    }

    pub fn prepareToShimmer(self: *Shimmerable) !*Object {
        if (self.current().isPrimitive()) {
            self.shimmered.swap(try self.current().box());
        } else {
            try self.ensureShimmerable();
        }

        try self.current().prepareToShimmer();

        // We know that this must be a boxed object.
        return self.current().asPtr().?;
    }

    pub fn duplicateForMutable(self: *const Shimmerable) !Value {
        // Even if `original` or `replacement` can mutate due to ref count = 1,
        // we've been tasked with making sure this object doesn't mutate, since
        // the purpose of `Shimmer` is to ensure that we only ever write back
        // something that has the same string (or will have the same string
        // when generated).
        return try self.current().duplicate();
    }
};

pub const Mutable = extern struct {
    original: Value,
    mutated: OptionalValue = .none,

    pub fn deinit(self: *Mutable) void {
        self.original.release();
        self.mutated.release();
        self.* = undefined;
    }

    pub fn current(self: *const Mutable) Value {
        return self.mutated.orElse(self.original);
    }

    pub fn consume(self: *Mutable) Value {
        defer self.* = undefined;
        if (self.mutated.asValue()) |mutated| {
            self.original.release();
            return mutated;
        } else {
            return self.original;
        }
    }

    pub fn discardChanges(self: *Mutable) void {
        self.mutated.swapWithNone();
    }

    pub fn takeMutated(self: *Mutable) OptionalValue {
        const mutated = self.mutated;
        self.mutated = .none;
        return mutated;
    }

    pub fn asShimmerable(self: *Mutable) *Shimmerable {
        return @ptrCast(self);
    }

    pub fn prepareToShimmer(self: *Mutable) !void {
        if (!self.current().canShimmer()) {
            self.mutated.swap(try self.current().duplicate());
        }

        try self.current().prepareToShimmer();
    }

    pub fn prepareToMutate(self: *Mutable) !void {
        if (!self.current().canMutate()) {
            self.mutated.swap(try self.current().duplicate());
        }
    }
};

pub const NoneObject = struct {
    pub fn new(bytes: [:0]const u8) !*NoneObject {
        const new_obj = try Object.newObjectUninitialized(NoneObject);
        errdefer new_obj.head.freeBacking();
        const duped = try heap.global_gpa.dupeSentinel(u8, bytes, 0);
        errdefer heap.global_gpa.free(duped);
        try new_obj.head.setStringLocalObject(duped);

        return new_obj.body;
    }

    fn duplicate(src: *const Object) !*Object {
        assert(std.meta.activeTag(src.getStringDetails()) != .none);

        const new_obj = try Object.newObjectUninitialized(NoneObject);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj.head);
        return new_obj.head;
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .make_crossthread = null,
        .free_internal_rep = null,
        .update_string = null,
        .name = "none",
    };
};

pub const StringObject = struct {
    codepoint_length: std.atomic.Value(usize) = .init(math.maxInt(usize)),

    pub fn new(bytes: [:0]const u8) !*StringObject {
        const new_obj = try Object.newObjectUninitialized(StringObject);
        errdefer new_obj.head.freeBacking();
        const duped = try heap.global_gpa.dupeSentinel(u8, bytes, 0);
        errdefer heap.global_gpa.free(duped);
        try new_obj.head.setStringLocalObject(duped);

        return new_obj.body;
    }

    pub fn asHead(self: *StringObject) *Object {
        return Object.from(StringObject, self);
    }

    fn duplicate(src: *const Object) !*Object {
        assert(src.getStringDetails() != .none);
        const new_obj = try Object.newObjectUninitialized(StringObject);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj.head);

        new_obj.body.codepoint_length = .init(src.castToConst(StringObject).codepoint_length.load(.monotonic));

        return new_obj.head;
    }

    pub fn shimmer(shim: *Shimmerable) !void {
        const obj = try shim.prepareToShimmer();
        obj.vtable = &vtable;
        obj.castTo(StringObject).* = .{};
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .free_internal_rep = null,
        .update_string = null,
        .make_crossthread = null,
        .name = "string",
    };
};

fn testString(ta: std.mem.Allocator) !void {
    try heap.testStart(ta, testing.io);
    defer heap.testFinish();

    const obj = (try StringObject.new("hello")).asHead();
    defer obj.release();
    try testing.expectEqualStrings("hello", try obj.getString());
}

test "object test string" {
    try testing.checkAllAllocationFailures(testing.allocator, testString, .{});
}

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
pub const ParsedScript = struct {
    /// Tokens array.
    tags: std.ArrayList(Tokenizer.Token.Tag),
    /// The associated values for their corresponding tokens.
    values: []Value,

    pub fn printTokens(script: *const ParsedScript) void {
        const formatting = "[{: >3}@{: >3}]  .{s: <20}  ";

        var line: u64 = 0;
        for (script.tags.items, script.values, 0..) |token, value, i| {
            switch (token) {
                .start_of_command => {
                    const command_details = ParsedScriptCommandObject.castFrom(value.asPtr().?);
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

    pub fn deinit(parsed: *ParsedScript) void {
        parsed.tags.deinit(heap.global_gpa);
        for (parsed.values) |value| value.release();
    }
};

// pub const ParsedExpression = struct {
//     root_node: expr_parse.Node.Index,
//     nodes: std.MultiArrayList(expr_parse.Node),
//
//     pub fn deinit(expr: *ParsedExpression) void {
//         expr_parse.deinitNodes(heap.global_gpa, &expr.nodes);
//         expr.* = undefined;
//     }
// };

pub const SourceObject = struct {
    file_name: OptionalValue,
    line: u32,
    hash: std.atomic.Value(?*u256),

    pub fn new(file_name: OptionalValue, line: u32) !*SourceObject {
        const new_obj = try Object.newObject(SourceObject);
        new_obj.body.file_name = file_name.borrow();
        new_obj.body.line = line;

        return new_obj.body;
    }

    fn duplicate(src: *const Object) !*Object {
        const new_obj = try Object.newObjectUninitialized(SourceObject);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj.head);

        const cast_src = src.castToConst(SourceObject);
        new_obj.body.file_name = cast_src.file_name.borrow();
        new_obj.body.line = cast_src.line;

        return new_obj.head;
    }

    fn freeInternalRep(obj: *Object) void {
        const as_source = obj.castTo(SourceObject);
        as_source.file_name.release();
        if (as_source.hash.load(.monotonic)) |hash_ptr| heap.global_gpa.destroy(hash_ptr);
    }

    fn makeCrossthread(obj: *Object) void {
        obj.castTo(SourceObject).file_name.makeCrossthread();
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .free_internal_rep = freeInternalRep,
        .update_string = null,
        .make_crossthread = makeCrossthread,
        .name = "source",
    };
};

pub const Closure = struct {
    /// Value for the argument list of the procedure.
    args: Value,
    /// Value for the script's body.
    body: Value,
    /// We do our best to track the closure's name.
    name: OptionalValue,
    /// Hash reference pointing to the scope.
    scope_hash_ref: OptionalValue,
    /// Required number of arguments.
    required_arity: u32,
    /// Optional number of arguments.
    optional_arity: u32,
    /// Default values of optional arguments, if any.
    optional_values: OptionalValue,
    /// Whether `args` is provided as an argument name. `args`, if present, is always
    /// the last argument name.
    has_args_parameter: bool,
    /// Whether this is a method. If so, `self` is injected as the first variable at call time.
    is_method: bool,
    /// Unique identifier for cache keying.
    cache_id: u64,

    pub fn borrow(closure: Closure) Closure {
        return .{
            .args = closure.args.borrow(),
            .body = closure.body.borrow(),
            .name = closure.name.borrow(),
            .scope_hash_ref = closure.scope_hash_ref.borrow(),
            .required_arity = closure.required_arity,
            .optional_arity = closure.optional_arity,
            .optional_values = closure.optional_values.borrow(),
            .has_args_parameter = closure.has_args_parameter,
            .is_method = closure.is_method,
            .cache_id = closure.cache_id,
        };
    }

    pub fn deinit(closure: Closure) void {
        closure.args.release();
        closure.body.release();
        closure.name.release();
        closure.scope_hash_ref.release();
        closure.optional_values.release();
    }
};

pub const ClosureObject = struct {
    closure: *Closure,

    fn duplicate(src: *const Object) !*Object {
        const new_obj = try Object.duplicateStringOnly(src);
        errdefer new_obj.deinit();

        const new_closure = try heap.global_gpa.create(Closure);
        new_obj.vtable = &vtable;
        new_closure.* = src.castToConst(ClosureObject).closure.borrow();

        return new_obj;
    }

    fn freeInternalRep(src: *Object) void {
        const as_closure = src.castTo(ClosureObject);
        as_closure.closure.deinit();
        heap.global_gpa.destroy(as_closure.closure);
    }

    fn updateString(_: *Object) !void {
        @panic("FIXME: generate closure from parts (see old code)");
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .free_internal_rep = freeInternalRep,
        .update_string = updateString,
        .make_crossthread = null,
        .name = "closure",
    };
};

pub const UpvarLinkObject = struct {
    /// An object containing the name of the variable in the linked
    /// scope. Whenever someone shimmers this to a variable, they should
    /// always do it in `call_frame`.
    linked_name: Value,
    /// The call frame the linked variable lives in.
    call_frame: u32,

    fn freeInternalRep(src: *Object) void {
        src.castTo(UpvarLinkObject).linked_name.release();
    }

    pub const vtable: Object.VTable = .{
        .duplicate = null,
        .free_internal_rep = freeInternalRep,
        .update_string = null,
        .make_crossthread = null,
        .name = "upvar_link",
    };
};

/// `dict_name` points  to an object that contains the name of the dictionary
/// (and most likely specializes to whatever type of variable caching is necessary),
/// while `dict_path` points to a list containing all parts of the path. For
/// example, `foo::bar::baz` would turn into roughly
/// ```
/// dict_name: foo
/// dict_path: {bar baz}
/// ```
pub const DictSugarObject = struct {
    dict_name: Value,
    dict_path: Value,

    fn freeInternalRep(src: *Object) void {
        const as_dict_sugar = src.castTo(DictSugarObject);
        as_dict_sugar.dict_name.release();
        as_dict_sugar.dict_path.release();
    }

    pub const vtable: Object.VTable = .{
        .name = "dict_sugar",
        .duplicate = Object.duplicateStringOnly,
        .free_internal_rep = freeInternalRep,
        .update_string = null,
        .make_crossthread = null,
    };
};

pub const HashReferenceObject = struct {
    /// This is of type `*ObjectType` instead of `Value`, because a
    /// hash reference can only ever point to a heap `Object`.
    ref: *Object,

    fn duplicate(src: *const Object) !*Object {
        const new_obj = try Object.newObject(HashReferenceObject);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj.head);
        errdefer new_obj.head.invalidateString();

        const as_hash_ref = src.castToConst(HashReferenceObject);
        new_obj.body.ref = as_hash_ref.ref.borrow();

        return new_obj.head;
    }

    fn freeInternalRep(obj: *Object) void {
        const as_hash_ref = obj.castTo(HashReferenceObject);
        as_hash_ref.ref.release();
    }

    fn updateString(obj: *Object) !void {
        const as_hash_ref = obj.castTo(HashReferenceObject);
        const target_hash = try as_hash_ref.ref.getHash();
        var encoded: [hashutil.hash_and_prepend_len]u8 = undefined;
        _ = hashutil.hash_encoder.encode(encoded[hashutil.hash_prepend.len..], &@as([32]u8, @bitCast(target_hash)));
        @memcpy(encoded[0..hashutil.hash_prepend.len], hashutil.hash_prepend);
        const new_str = try heap.global_gpa.dupeSentinel(u8, &encoded, 0);
        obj.setString(new_str) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.OtherThreadSet => {},
        };
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .update_string = updateString,
        .free_internal_rep = freeInternalRep,
        .make_crossthread = null,
        .name = "hash_reference",
    };
};

pub const RegexpObject = struct {
    regexp: *pcre2.pcre2_code_8,

    fn freeInternalRep(obj: *Object) void {
        const as_regexp = obj.castTo(RegexpObject);
        pcre2.pcre2_code_free_8(as_regexp.regexp);
    }

    pub const vtable: Object.VTable = .{
        .duplicate = Object.duplicateStringOnly,
        .update_string = null,
        .free_internal_rep = freeInternalRep,
        .make_crossthread = null,
        .name = "regexp",
    };
};

pub const IndexObject = struct {
    index: i64,
    is_relative: bool,

    fn duplicate(src: *const Object) !*Object {
        const new_obj = try Object.newObjectUninitialized(IndexObject);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj.head);

        const as_index = src.castToConst(IndexObject);
        new_obj.body.index = as_index.index;
        new_obj.body.is_relative = as_index.is_relative;

        return new_obj.head;
    }

    fn updateString(obj: *Object) !void {
        const as_index = obj.castTo(IndexObject);
        const bytes = if (as_index.is_relative)
            try std.fmt.allocPrintSentinel(heap.global_gpa, "end{s}{d}", .{ if (as_index.index >= 0) "+" else "", as_index.index }, 0)
        else
            try std.fmt.allocPrintSentinel(heap.global_gpa, "{d}", .{as_index.index}, 0);
        try obj.setStringConsuming(bytes);
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .free_internal_rep = null,
        .update_string = updateString,
        .make_crossthread = null,
        .name = "index",
    };
};

pub const BoxedFloatObject = struct {
    value: f64,

    pub fn new(value: f64) !*BoxedFloatObject {
        const new_obj = try Object.newObject(BoxedFloatObject);
        new_obj.body.value = value;
        return new_obj.body;
    }

    fn updateString(obj: *Object) !void {
        const as_float = obj.castTo(BoxedFloatObject);
        const bytes = try std.fmt.allocPrintSentinel(heap.global_gpa, "{}", .{as_float.value}, 0);
        try obj.setStringConsuming(bytes);
    }

    fn duplicate(src: *const Object) !*Object {
        const new_obj = try Object.newObject(BoxedFloatObject);
        errdefer new_obj.head.deinit();
        try src.duplicateHeadOnto(new_obj.head);

        const as_float = src.castToConst(BoxedFloatObject);
        new_obj.body.value = as_float.value;

        return new_obj.head;
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .free_internal_rep = null,
        .update_string = updateString,
        .make_crossthread = null,
        .name = "boxed_float",
    };
};

pub const BoxedIntObject = struct {
    value: i64,

    pub fn new(value: i64) !*BoxedIntObject {
        const new_obj = try Object.newObject(BoxedIntObject);
        new_obj.body.value = value;
        return new_obj.body;
    }

    fn updateString(obj: *Object) !void {
        const bytes = try std.fmt.allocPrintSentinel(heap.global_gpa, "{}", .{obj.castTo(BoxedIntObject).value}, 0);
        try obj.setStringConsuming(bytes);
    }

    fn duplicate(src: *const Object) !*Object {
        const new_obj = try Object.newObjectUninitialized(BoxedIntObject);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj.head);

        new_obj.body.value = src.castToConst(BoxedIntObject).value;

        return new_obj.head;
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .free_internal_rep = null,
        .update_string = updateString,
        .make_crossthread = null,
        .name = "boxed_int",
    };
};

pub const BoxedBooleanObject = struct {
    value: bool,

    pub fn new(value: bool) !*BoxedBooleanObject {
        const new_obj = try Object.newObject(BoxedBooleanObject);
        new_obj.body.value = value;
        return new_obj.body;
    }

    fn updateString(obj: *Object) !void {
        const bytes = if (obj.castTo(BoxedBooleanObject).value)
            try heap.global_gpa.dupeSentinel(u8, "true", 0)
        else
            try heap.global_gpa.dupeSentinel(u8, "false", 0);
        try obj.setStringConsuming(bytes);
    }

    fn duplicate(src: *const Object) !*Object {
        const new_obj = try Object.newObjectUninitialized(BoxedBooleanObject);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj.head);

        new_obj.body.value = src.castToConst(BoxedBooleanObject).value;

        return new_obj.head;
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .free_internal_rep = null,
        .update_string = updateString,
        .make_crossthread = null,
        .name = "boxed_boolean",
    };
};

pub const CachedLocalVarObject = struct {
    ref: *const Value,
    call_epoch: u64,

    pub const vtable: Object.VTable = .{
        .duplicate = Object.duplicateStringOnly,
        .update_string = null,
        .free_internal_rep = null,
        .make_crossthread = null,
        .name = "cached_local_var",
    };
};

pub const CachedLexicalVarObject = struct {
    ref: *const Value,
    call_epoch: u64,

    pub const vtable: Object.VTable = .{
        .duplicate = Object.duplicateStringOnly,
        .update_string = null,
        .free_internal_rep = null,
        .make_crossthread = null,
        .name = "cached_lexical_var",
    };
};

pub const ParsedScriptCommandObject = struct {
    line: u32,
    word_count: u32,

    pub const vtable: Object.VTable = .{
        .duplicate = null,
        .update_string = null,
        .free_internal_rep = null,
        .make_crossthread = null,
        .name = "parsed_script_command",
    };

    pub fn castFrom(obj: *Object) *ParsedScriptCommandObject {
        assert(obj.vtable == &vtable);
        return @ptrCast(obj);
    }
};

fn quoteValues(gpa: std.mem.Allocator, items: []const Value) ![:0]u8 {
    var fallback = std.heap.stackFallback(64, gpa);
    var quoting_types = try fallback.get().alloc(strutil.QuotingType, items.len);
    defer fallback.get().free(quoting_types);

    var upper_bound_len: usize = 0;
    for (0.., items, quoting_types) |i, item, *quote_type| {
        const item_bytes = try item.getString();

        quote_type.* = strutil.calculateNeededQuotingType(item_bytes);
        if (i == 0 and quote_type.* == .bare and item_bytes.len > 0 and item_bytes[0] == '#') {
            // Make sure the first element has # escaped in braces, instead of
            // being bare. This way a list isn't accidentally interpreted as
            // a comment.
            quoting_types[i] = .brace;
        }

        upper_bound_len += strutil.quoteSize(quote_type.*, item_bytes.len);
        upper_bound_len += 1; // Space between each element.
    }

    var unfinished_str = try gpa.alloc(u8, upper_bound_len + 1);
    errdefer gpa.free(unfinished_str);
    var written: usize = 0;

    for (0.., items, quoting_types) |i, item, quote_type| {
        const item_bytes = try item.getString();
        written += strutil.quoteString(
            quote_type,
            item_bytes,
            unfinished_str[written..],
            i == 0,
        );

        if (i + 1 < items.len) {
            unfinished_str[written] = ' ';
            written += 1;
        }
    }

    // Slap a nul on the end.
    unfinished_str[written] = 0x00;

    // We actually need to realloc, because `allocator.free` needs the
    // original slice length (and we don't track the original slice
    // length, only the accessible length). TODO PERF might be worth
    // creating a long string if this string is long enough.
    const finished_str = try gpa.realloc(unfinished_str, written + 1);
    return finished_str[0..written :0];
}

pub const ListObject = struct {
    items: []Value,
    capacity: usize,

    fn getCapacity(len: usize) error{OutOfMemory}!usize {
        return math.ceilPowerOfTwo(usize, len) catch error.OutOfMemory;
    }

    pub fn new(items: []Value) !*ListObject {
        const capacity = try getCapacity(items.len);
        const new_list = try Object.newObject(ListObject);
        errdefer new_list.head.freeBacking();

        const new_items = try heap.global_gpa.alloc(Value, capacity);
        for (items, new_items[0..items.len]) |item, *new_item| {
            new_item.* = item.borrow();
        }
        new_list.body.items = new_items[0..items.len];
        new_list.body.capacity = capacity;

        return new_list.body;
    }

    fn updateString(obj: *Object) !void {
        const as_list = obj.castTo(ListObject);
        const bytes = try quoteValues(heap.global_gpa, as_list.items);
        try obj.setStringConsuming(bytes);
    }

    fn duplicate(src: *const Object) !*Object {
        const as_list = src.castToConst(ListObject);
        const new_obj = try Object.newObjectUninitialized(ListObject);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj.head);
        errdefer new_obj.head.invalidateString();

        const new_items = try heap.global_gpa.alloc(Value, as_list.capacity);
        for (as_list.items, new_items[0..as_list.items.len]) |item, *new_item| {
            new_item.* = item.borrow();
        }
        new_obj.body.items = new_items[0..as_list.items.len];
        new_obj.body.capacity = as_list.capacity;

        return new_obj.head;
    }

    fn freeInternalRep(obj: *Object) void {
        const as_list = obj.castTo(ListObject);
        for (as_list.items) |item| item.release();
        heap.global_gpa.free(as_list.items.ptr[0..as_list.capacity]);
    }

    fn makeCrossthread(obj: *Object) void {
        const as_list = obj.castTo(ListObject);
        for (as_list.items) |item| item.makeCrossthread();
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .free_internal_rep = freeInternalRep,
        .update_string = updateString,
        .make_crossthread = makeCrossthread,
        .name = "list",
    };
};

pub const DictObject = struct {
    items: []Value,
    capacity: usize,
    table: ?*Table,

    /// Note that the caller is responsible for ensuring that each key has a string when calling any function
    /// that uses its `hash` or `eql` functions.
    const Table = std.HashMapUnmanaged(Value, usize, struct {
        pub fn hash(_: @This(), key: Value) u64 {
            return key.getHashNoRegister() catch unreachable;
        }
        pub fn eql(_: @This(), a: Value, b: Value) bool {
            return a.equals(b) catch unreachable;
        }
    }, 80);

    fn getCapacity(len: usize) error{OutOfMemory}!usize {
        return math.ceilPowerOfTwo(usize, len) catch error.OutOfMemory;
    }

    pub fn new(items: []Value) !*DictObject {
        const capacity = try getCapacity(items.len);
        const new_dict = try Object.newObject(DictObject);
        errdefer new_dict.head.freeBacking();

        const new_items = try heap.global_gpa.alloc(Value, capacity);
        for (items, new_items[0..items.len]) |item, *new_item| {
            new_item.* = item.borrow();
        }
        new_dict.body.items = new_items[0..items.len];
        new_dict.body.capacity = capacity;
        new_dict.body.table = null;

        return new_dict.body;
    }

    fn duplicate(src: *const Object) !*Object {
        const as_dict = src.castToConst(DictObject);
        const new_obj = try Object.newObjectUninitialized(DictObject);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj.head);
        errdefer new_obj.head.invalidateString();

        const new_items = try heap.global_gpa.alloc(Value, as_dict.capacity);
        for (as_dict.items, new_items[0..as_dict.items.len]) |item, *new_item| {
            new_item.* = item.borrow();
        }
        new_obj.body.items = new_items[0..as_dict.items.len];
        new_obj.body.capacity = as_dict.capacity;
        new_obj.body.table = null;

        return new_obj.head;
    }

    fn freeInternalRep(obj: *Object) void {
        const as_dict = obj.castTo(DictObject);
        for (as_dict.items) |item| item.release();
        heap.global_gpa.free(as_dict.items.ptr[0..as_dict.capacity]);
        if (as_dict.table) |table| table.deinit(heap.global_gpa);
    }

    fn makeCrossthread(obj: *Object) void {
        const as_dict = obj.castTo(DictObject);
        for (as_dict.items) |item| item.makeCrossthread();
    }

    fn updateString(obj: *Object) !void {
        const as_dict = obj.castTo(DictObject);
        const bytes = try quoteValues(heap.global_gpa, as_dict.items);
        try obj.setStringConsuming(bytes);
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .free_internal_rep = freeInternalRep,
        .update_string = updateString,
        .make_crossthread = makeCrossthread,
        .name = "dict",
    };
};

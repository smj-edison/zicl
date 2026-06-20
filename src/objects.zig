const std = @import("std");
const math = std.math;
const assert = std.debug.assert;

const pcre2 = @import("pcre2");

const ioutil = @import("ioutil.zig");
const strutil = @import("strutil.zig");
const heap = @import("heap.zig");
const hashutil = heap.hashutil;
const Value = heap.Value;
const OptionalValue = heap.OptionalValue;
const ObjectHead = heap.ObjectHead;
const ObjectType = heap.ObjectType;
const Tokenizer = @import("Tokenizer.zig");
const expr_parse = @import("expr_parse.zig");

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

    pub fn ensureShimmerable(self: *Shimmerable, new_size: usize) error{OutOfMemory}!void {
        if (!self.current().canShimmer(new_size)) {
            self.shimmered.swap(self.current().duplicate());
        }
    }

    pub fn prepareToShimmer(self: *Shimmerable, new_size: usize) !void {
        try self.ensureShimmerable(new_size);
        try self.current().prepareToShimmer(new_size);
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

pub const NoneObject = extern struct {
    head: ObjectHead,

    pub fn new(bytes: [:0]const u8) !*NoneObject {
        const new_obj = try ObjectHead.newObject(NoneObject);
        errdefer new_obj.head.deinit();
        try new_obj.head.setStringLocalObject(bytes);

        return new_obj;
    }

    pub const Type: heap.ObjectType = .{
        .duplicate = ObjectHead.duplicateStringOnly,
        .free_internal_rep = null,
        .update_string = null,
        .name = "none",
    };
};

pub const StringObject = extern struct {
    head: ObjectHead,
    codepoint_length: std.atomic.Value(usize) = .init(math.maxInt(usize)),

    pub fn new(bytes: [:0]const u8) !*StringObject {
        const new_obj = try ObjectHead.newObject(StringObject, null);
        errdefer new_obj.head.deinit();
        try new_obj.head.setStringLocalObject(bytes);

        return new_obj;
    }

    fn duplicate(src: *const ObjectHead, min_size: usize) !*ObjectHead {
        assert(std.meta.activeTag(src.getStringDetails()) != .none);
        const new_obj = try ObjectHead.newObjectUninitialized(StringObject, min_size);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(&new_obj.head);

        const as_string: *StringObject = @ptrCast(src);
        new_obj.codepoint_length = .init(as_string.codepoint_length.load(.monotonic));

        return &new_obj.head;
    }

    pub fn shimmer(shim: *Shimmerable) !void {
        try shim.prepareToShimmer();
    }

    pub const Type: ObjectType = .{
        .duplicate = duplicate,
        .free_internal_rep = null,
        .update_string = null,
        .name = "string",
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

pub const ParsedExpression = struct {
    root_node: expr_parse.Node.Index,
    nodes: std.MultiArrayList(expr_parse.Node),

    pub fn deinit(expr: *ParsedExpression) void {
        expr_parse.deinitNodes(heap.global_gpa, &expr.nodes);
        expr.* = undefined;
    }
};

pub const SourceObject = extern struct {
    head: ObjectHead,
    file_name: OptionalValue,
    line: u32,
    hash: std.atomic.Value(?*u256),

    pub fn new(file_name: OptionalValue, line: u32) !*SourceObject {
        const new_obj = try ObjectHead.newObject(SourceObject);
        new_obj.file_name = file_name.borrow();
        new_obj.line = line;

        return new_obj;
    }

    fn duplicate(src: *const ObjectHead) !*ObjectHead {
        const new_obj = try ObjectHead.newObject(SourceObject);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj);
        errdefer new_obj.head.invalidateString();

        const as_source_obj: *SourceObject = @ptrCast(src);
        new_obj.file_name = as_source_obj.file_name.borrow();
        new_obj.line = as_source_obj.line;

        return &new_obj.head;
    }

    pub fn freeInternalRep(obj: *ObjectHead) void {
        const as_source: *SourceObject = @ptrCast(obj);
        as_source.file_name.release();
    }

    pub const Type: ObjectType = .{
        .duplicate = duplicate,
        .free_internal_rep = freeInternalRep,
        .update_string = null,
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

pub const ClosureObject = extern struct {
    head: ObjectHead,
    closure: Closure,

    fn duplicate(src: *const ObjectHead) !*ObjectHead {
        const new_obj = try ObjectHead.newObject(ClosureObject);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj);
        errdefer new_obj.head.invalidateString();

        const as_closure: *ClosureObject = @ptrCast(src);

        errdefer comptime unreachable;
        new_obj.closure = as_closure.closure.borrow();

        return &new_obj.head;
    }

    fn freeInternalRep(src: *ObjectHead) void {
        const as_closure: *ClosureObject = @ptrCast(src);
        as_closure.closure.deinit();
    }

    fn updateString(_: *ObjectHead) !void {
        @panic("FIXME: generate closure from parts (see old code)");
    }

    pub const Type: ObjectType = .{
        .duplicate = duplicate,
        .free_internal_rep = freeInternalRep,
        .update_string = updateString,
        .name = "closure",
    };
};

pub const UpvarLinkObject = extern struct {
    head: ObjectHead,
    /// An object containing the name of the variable in the linked
    /// scope. Whenever someone shimmers this to a variable, they should
    /// always do it in `call_frame`.
    linked_name: Value,
    /// The call frame the linked variable lives in.
    call_frame: u32,

    fn freeInternalRep(src: *ObjectHead) void {
        const as_upvar: *UpvarLinkObject = @ptrCast(src);
        as_upvar.linked_name.release();
    }

    pub const Type: ObjectType = .{
        .duplicate = null,
        .free_internal_rep = freeInternalRep,
        .update_string = null,
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
pub const DictSugarObject = extern struct {
    head: ObjectHead,
    dict_name: Value,
    dict_path: Value,

    fn freeInternalRep(src: *ObjectHead) void {
        const as_dict_sugar: *DictSugarObject = @ptrCast(src);
        as_dict_sugar.dict_name.release();
        as_dict_sugar.dict_path.release();
    }

    pub const Type: ObjectType = .{
        .name = "dict_sugar",
        .duplicate = ObjectHead.duplicateStringOnly,
        .free_internal_rep = freeInternalRep,
        .update_string = null,
    };
};

pub const HashReferenceObject = extern struct {
    head: ObjectHead,
    /// This is of type `*ObjectType` instead of `Value`, because a
    /// hash reference can only ever point to a heap `Object`.
    ref: *ObjectHead,

    fn duplicate(src: *const ObjectHead) !*ObjectHead {
        const new_obj = try ObjectHead.newObject(HashReferenceObject);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(&new_obj.head);
        errdefer new_obj.head.invalidateString();

        const as_hash_ref: *HashReferenceObject = @ptrCast(src);
        new_obj.ref = as_hash_ref.ref.borrow();

        return new_obj;
    }

    fn freeInternalRep(obj: *ObjectHead) void {
        const as_hash_ref: *HashReferenceObject = @ptrCast(obj);
        as_hash_ref.ref.release();
    }

    fn updateString(obj: *ObjectHead) !void {
        const as_hash_ref: *HashReferenceObject = @ptrCast(obj);
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

    pub const Type: ObjectType = .{
        .duplicate = duplicate,
        .update_string = updateString,
        .free_internal_rep = freeInternalRep,
        .name = "hash_reference",
    };
};

pub const RegexpObject = extern struct {
    head: ObjectHead,
    regexp: *pcre2.pcre2_code_8,

    fn freeInternalRep(obj: *ObjectHead) void {
        const as_regexp: *RegexpObject = @ptrCast(obj);
        pcre2.pcre2_code_free_8(as_regexp.regexp);
    }

    pub const Type: ObjectType = .{
        .duplicate = ObjectHead.duplicateStringOnly,
        .update_string = null,
        .free_internal_rep = freeInternalRep,
        .name = "regexp",
    };
};

pub const IndexObject = extern struct {
    head: ObjectHead,
    index: i64,
    is_relative: bool,

    fn duplicate(src: *const ObjectHead) !*ObjectHead {
        const new_obj = try ObjectHead.newObjectUninitialized(IndexObject);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(&new_obj.head);

        const as_index: *IndexObject = @ptrCast(src);
        new_obj.index = as_index.index;
        new_obj.is_relative = as_index.is_relative;

        return &as_index.head;
    }

    pub const Type: ObjectType = .{
        .duplicate = duplicate,
        .free_internal_rep = null,
    };
};

pub const BoxedFloatObject = extern struct {
    head: ObjectHead,
    value: f64,

    pub fn new(value: f64) !*BoxedFloatObject {
        const new_obj = try ObjectHead.newObject(BoxedFloatObject);
        new_obj.value = value;
        return new_obj;
    }

    fn updateString(obj: *ObjectHead) !void {
        const as_float: *BoxedFloatObject = @ptrCast(obj);
        const bytes = try std.fmt.allocPrintSentinel(heap.global_gpa, "{}", .{as_float.value}, 0);
        obj.setString(bytes);
    }

    fn duplicate(src: *const ObjectHead) !*ObjectHead {
        const new_obj = try ObjectHead.newObject(BoxedFloatObject);
        errdefer new_obj.head.deinit();
        try src.duplicateHeadOnto(&new_obj.head);

        const as_float: *BoxedFloatObject = @ptrCast(src);
        new_obj.value = as_float.value;

        return &new_obj.head;
    }

    pub const Type: ObjectType = .{
        .duplicate = duplicate,
        .free_internal_rep = null,
        .update_string = updateString,
        .name = "boxed_float",
    };
};

pub const BoxedIntObject = extern struct {
    head: ObjectHead,
    value: i64,

    pub fn new(value: i64) !*BoxedIntObject {
        const new_obj = try ObjectHead.newObject(BoxedIntObject);
        new_obj.value = value;
        return new_obj;
    }

    fn updateString(obj: *ObjectHead) !void {
        const as_int: *BoxedIntObject = @ptrCast(obj);
        const bytes = try std.fmt.allocPrintSentinel(heap.global_gpa, "{}", .{as_int.value}, 0);
        obj.setString(bytes);
    }

    fn duplicate(src: *const ObjectHead) !*ObjectHead {
        const new_obj = try ObjectHead.newObject(BoxedIntObject);
        errdefer new_obj.head.deinit();
        try src.duplicateHeadOnto(&new_obj.head);

        const as_int: *BoxedIntObject = @ptrCast(src);
        new_obj.value = as_int.value;

        return &new_obj.head;
    }

    pub const Type: ObjectType = .{
        .duplicate = duplicate,
        .free_internal_rep = null,
        .update_string = updateString,
        .name = "boxed_int",
    };
};

pub const CachedLocalVarObject = extern struct {
    head: ObjectHead,
    ref: *const Value,
    call_epoch: u64,

    pub const Type: ObjectType = .{
        .duplicate = ObjectHead.duplicateStringOnly,
        .update_string = null,
        .free_internal_rep = null,
        .name = "cached_local_var",
    };
};

pub const CachedLexicalVarObject = extern struct {
    head: ObjectHead,
    ref: *const Value,
    call_epoch: u64,

    pub const Type: ObjectType = .{
        .duplicate = ObjectHead.duplicateStringOnly,
        .update_string = null,
        .free_internal_rep = null,
        .name = "cached_lexical_var",
    };
};

pub const ParsedScriptCommandObject = extern struct {
    head: ObjectHead,
    line: u32,
    word_count: u32,

    pub const Type: ObjectType = .{
        .duplicate = null,
        .update_string = null,
        .free_internal_rep = null,
        .name = "parsed_script_command",
    };

    pub fn castFrom(obj: *ObjectHead) *ParsedScriptCommandObject {
        assert(obj.obj_type == &Type);
        return @ptrCast(obj);
    }
};

pub const ListObject = extern struct {
    head: ObjectHead,
    len: usize,

    fn getLayout(len: usize) struct { alloc_size: usize } {
        const capacity = math.ceilPowerOfTwo(usize, len) catch return error.OutOfMemory;
        const total_size = @sizeOf(ListObject) + @sizeOf(Value) * capacity;
        return .{ .alloc_size = total_size };
    }

    pub fn getItems(list: *ListObject) []Value {
        // Items are stored directly after in the same allocation.
        const item_start = @as([*]u8, list) + @sizeOf(ListObject);
        return @as([*]Value, @ptrCast(item_start))[0..list.len];
    }

    pub fn new(items: []Value) !*ListObject {
        const layout = getLayout(items.len);
        const new_list = try ObjectHead.newObject(ListObject, layout.alloc_size);
        new_list.len = items.len;

        for (items, new_list.getItems()) |to_add, *list_item| {
            list_item.* = to_add.borrow();
        }

        return new_list;
    }

    fn updateString(obj: *ObjectHead) !void {
        const as_list: *ListObject = @ptrCast(obj);
        const items = as_list.getItems();

        // We need to calculate the quoting type for each item. This
        // will also let us calculate the upper bound of the string's
        // length.
        var fallback = std.heap.stackFallback(64, heap.global_gpa);
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

        // Step 2: actually create said string.
        var unfinished_str = try heap.global_gpa.alloc(u8, upper_bound_len + 1);
        errdefer heap.global_gpa.free(unfinished_str);
        var written: usize = 0;

        for (0.., items, quoting_types) |i, item, quote_type| {
            const item_bytes = try item.getString();
            written += strutil.quoteString(
                quote_type,
                item_bytes,
                unfinished_str[written..],
                i == 0,
            );

            // Add a space to separate the elements (except at the end of the list).
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
        const finished_str = try heap.global_gpa.realloc(unfinished_str, written + 1);
        try obj.setString(finished_str[0..written :0]);
    }
};

pub const DictObject = extern struct {
    head: ObjectHead,
    table: ?std.HashMapUnmanaged(Value, *Value, struct {
        pub fn hash(_: @This(), key: Value) u64 {
            key.getHashNoRegister() catch unreachable;
        }
        pub fn eql(_: @This(), a: Value, b: Value) bool {
            return a.equals(a, b) catch unreachable;
        }
    }, 80),
    len: usize,

    pub fn items(list: *ListObject) []Value {
        // Items are stored directly after in the same allocation.
        const item_start = @as([*]u8, list) + @sizeOf(ListObject);
        return @as([*]Value, @ptrCast(item_start))[0..list.len];
    }

    pub fn shimmer(shim: *Shimmerable) !void {
        try shim.ensureShimmerable();
    }
};

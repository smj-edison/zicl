const std = @import("std");
const math = std.math;
const testing = std.testing;
const mem = std.mem;
const assert = std.debug.assert;

const pcre2 = @import("pcre2");

const ioutil = @import("ioutil.zig");
const strutil = @import("strutil.zig");
const heap = @import("heap.zig");
const leak_check = @import("leak_check.zig");
const StructIterator = leak_check.StructIterator;
const hashutil = heap.hashutil;
const Value = heap.Value;
const OptionalValue = heap.OptionalValue;
const Object = heap.Object;
const Tokenizer = @import("Tokenizer.zig");
// const expr_parse = @import("expr_parse.zig");

pub const interned_empty_string = heap.createInternedString("");
pub const interned_tilde_parent = heap.createInternedString("~parent");

pub const ErrorDetails = struct {
    message: [:0]u8,
};

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
        if (self.current().asPtr() != null and !self.current().canShimmer()) {
            self.shimmered.swap(try self.current().duplicate());
        }
    }

    pub fn prepareToShimmer(self: *Shimmerable) !*Object {
        switch (self.current().expandedValue()) {
            .ptr => try self.ensureShimmerable(),
            else => self.shimmered.swap((try self.current().box()).asValue()),
        }

        // We know that this must be an object, since we boxed it if
        // it was a primitive.
        const obj = self.current().asPtr().?;
        // Make sure the object has a string rep before we free its body. That is, if
        // it has a string rep. `.none` objects are brand new, so they obviously don't
        // have a string rep yet.
        if (obj.vtable != &None.vtable) _ = try obj.getString();
        obj.invalidateInternalRep();

        return obj;
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

    pub fn prepareToShimmer(self: *Mutable) !*Object {
        switch (self.current().expandedValue()) {
            .ptr => try self.ensureShimmerable(),
            else => self.shimmered.swap(Value.fromPtr(try self.current().box())),
        }

        // We know that this must be an object, since we boxed it if
        // it was a primitive.
        const obj = self.current().asPtr().?;
        // Make sure the object has a string rep before we free its body. That is, if
        // it has a string rep. `.none` objects are brand new, so they obviously don't
        // have a string rep yet.
        if (obj.vtable != &None.vtable) _ = try obj.getString();
        obj.invalidateInternalRep();

        return obj;
    }

    pub fn prepareToMutate(self: *Mutable) !void {
        if (!self.current().canMutate()) {
            self.mutated.swap(try self.current().duplicate());
        }
    }
};

/// Helpers to work with child walking, used for walking the heap if a leak occured.
pub const ChildWalkHelper = struct {
    ctx: StructIterator,
    info: *const StructIterator.NodeInfo,

    pub fn follow(helper: *const ChildWalkHelper, T: type, field_name: []const u8, ptr: *const T) StructIterator.Error!void {
        if (@hasDecl(T, "vtable") and @TypeOf(T.vtable) == Object.VTable)
            @compileError("Can't follow an object body directly, follow its *Object instead.");
        try helper.ctx.followNode(T, helper.info, field_name, ptr);
    }

    pub fn followOptional(helper: *const ChildWalkHelper, T: type, field_name: []const u8, ptr: ?*const T) StructIterator.Error!void {
        if (ptr) |val| try helper.ctx.followNode(T, helper.info, field_name, val);
    }

    pub fn followValue(helper: *const ChildWalkHelper, field_name: []const u8, value: Value) StructIterator.Error!void {
        if (value.asPtr()) |obj| {
            try helper.ctx.followNode(Object, helper.info, field_name, obj);
        } else {
            var buf: [350]u8 = undefined;
            const str = value.getStringWithBuffer(&buf) catch unreachable;
            try helper.ctx.addFieldString(Value, helper.info, field_name, str);
        }
    }

    pub fn followOptionalValue(
        helper: *const ChildWalkHelper,
        field_name: []const u8,
        optional: OptionalValue,
    ) StructIterator.Error!void {
        if (optional.asValue()) |val| try helper.followValue(field_name, val);
    }
};

pub const None = struct {
    pub fn new(bytes: [:0]const u8) !*None {
        const new_obj = try Object.newObjectUninitialized(None);
        errdefer new_obj.head.freeBacking();
        const duped = try heap.global_gpa.dupeSentinel(u8, bytes, 0);
        errdefer heap.global_gpa.free(duped);
        try new_obj.head.setStringLocalObject(duped);

        return new_obj.body;
    }

    fn duplicate(src: *const Object) !*Object {
        assert(std.meta.activeTag(src.getStringDetails()) != .none);

        const new_obj = try Object.newObjectUninitialized(None);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj.head);
        return new_obj.head;
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .make_crossthread = null,
        .free_internal_rep = null,
        .update_string = null,
        .enumerate_struct = null,
        .name = "none",
    };
};

pub const String = struct {
    const null_sentinel: usize = math.maxInt(usize);
    codepoint_length: std.atomic.Value(usize) = .init(null_sentinel),

    pub fn new(bytes: []const u8) !*String {
        const new_obj = try Object.newObjectUninitialized(String);
        errdefer new_obj.head.freeBacking();
        const duped_bytes = try heap.global_gpa.dupeSentinel(u8, bytes, 0);
        errdefer heap.global_gpa.free(duped_bytes);
        try new_obj.head.setStringLocalObject(duped_bytes);

        new_obj.body.* = .{};

        return new_obj.body;
    }

    pub fn newObject(bytes: []const u8) !*Object {
        return (try new(bytes)).asHead();
    }

    pub fn newValue(bytes: []const u8) !Value {
        return (try newObject(bytes)).asValue();
    }

    pub fn newFormatted(comptime fmt: []const u8, args: anytype) !*String {
        const formatted = try std.fmt.allocPrintSentinel(heap.global_gpa, fmt, args, 0);
        errdefer heap.global_gpa.free(formatted);
        const new_obj = try Object.newObjectUninitialized(String);
        errdefer new_obj.head.freeBacking();
        try new_obj.head.setStringLocalObject(formatted);

        return new_obj.body;
    }

    pub fn newFromEscaped(escaped: []const u8) !*String {
        // Unescaped will be equal or shorter than escaped version.
        const unescaped = try heap.global_gpa.alloc(u8, escaped.len);
        defer heap.global_gpa.free(unescaped);
        const written = strutil.removeEscaping(escaped, unescaped);

        return try new(unescaped[0..written]);
    }

    pub fn newWithCodepointLength(bytes: []const u8, codepoint_len: usize) !*String {
        const new_obj = try Object.newObjectUninitialized(String);
        errdefer new_obj.head.freeBacking();
        const duped_bytes = try heap.global_gpa.dupeSentinel(u8, bytes, 0);
        errdefer heap.global_gpa.free(duped_bytes);
        try new_obj.head.setStringLocalObject(duped_bytes);

        new_obj.body.* = .{
            .codepoint_len = codepoint_len,
        };

        return new_obj.body;
    }

    pub fn getCodepointLength(shim: *Shimmerable) !usize {
        const as_str = try String.shimmerFrom(null, shim);

        // See if we already calculated the utf8 length.
        switch (as_str.asHead().getStringDetails()) {
            .special => |special_str| {
                if (special_str.getCodepointLength()) |len| return len;

                // String length hasn't been computed yet, so compute now.
                const codepoint_len = strutil.codepointLength(special_str.getString());
                special_str.setCodepointLength(codepoint_len); // Cache utf8 length.
                return codepoint_len;
            },
            .normal => |bytes| {
                const len = as_str.codepoint_length.load(.monotonic);
                if (len != null_sentinel) return len;

                const codepoint_len = strutil.codepointLength(bytes);
                assert(codepoint_len != null_sentinel);
                as_str.codepoint_length.store(codepoint_len, .monotonic);

                return codepoint_len;
            },
            .none => unreachable,
        }
    }

    pub fn shimmerFrom(det: ?*ErrorDetails, shim: *Shimmerable) !*String {
        _ = det;
        if (shim.current().asType(String)) |str| return str;

        const obj = try shim.prepareToShimmer();
        obj.vtable = &vtable;
        const as_string = obj.castTo(String);
        as_string.* = .{};
        return as_string;
    }

    pub fn asHead(self: *String) *Object {
        return Object.from(String, self);
    }

    fn duplicate(src: *const Object) !*Object {
        assert(src.getStringDetails() != .none);
        const new_obj = try Object.newObjectUninitialized(String);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj.head);

        new_obj.body.codepoint_length = .init(src.castToConst(String).codepoint_length.load(.monotonic));

        return new_obj.head;
    }

    fn enumerateStruct(obj: *const Object, ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const string = obj.castToConst(String);
        try ctx.addField(usize, info, "codepoint_length", "{}", string.codepoint_length.load(.monotonic));
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .free_internal_rep = null,
        .update_string = null,
        .make_crossthread = null,
        .enumerate_struct = enumerateStruct,
        .name = @typeName(String),
    };
};

fn testString(ta: std.mem.Allocator) !void {
    try heap.testStart(ta, testing.io);
    defer heap.testFinish();

    const obj = try String.newObject("hello");
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
                    const command_details = ParsedScriptCommand.castFrom(value.asPtr().?);
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

pub const Source = struct {
    file_name: OptionalValue,
    line_no: u32,
    hash: std.atomic.Value(?*u256),

    pub fn new(file_name: OptionalValue, line: u32) !*Source {
        const new_obj = try Object.newObject(Source);
        new_obj.body.file_name = file_name.borrow();
        new_obj.body.line_no = line;

        return new_obj.body;
    }

    fn duplicate(src: *const Object) !*Object {
        const new_obj = try Object.newObjectUninitialized(Source);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj.head);

        const cast_src = src.castToConst(Source);
        new_obj.body.file_name = cast_src.file_name.borrow();
        new_obj.body.line_no = cast_src.line_no;

        return new_obj.head;
    }

    fn freeInternalRep(obj: *Object) void {
        const as_source = obj.castTo(Source);
        as_source.file_name.release();
        if (as_source.hash.load(.monotonic)) |hash_ptr| heap.global_gpa.destroy(hash_ptr);
    }

    fn makeCrossthread(obj: *Object) void {
        obj.castTo(Source).file_name.makeCrossthread();
    }

    fn enumerateStruct(obj: *const Object, ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const source = obj.castToConst(Source);
        const helper: ChildWalkHelper = .{ .ctx = ctx, .info = info };
        try helper.followOptionalValue("file_name", source.file_name);
        if (source.hash.load(.monotonic)) |hash| try ctx.followNode(u256, info, "hash", hash);
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .free_internal_rep = freeInternalRep,
        .update_string = null,
        .make_crossthread = makeCrossthread,
        .enumerate_struct = enumerateStruct,
        .name = @typeName(Source),
    };
};

pub const ClosureValues = struct {
    /// Value for the argument list of the procedure.
    args: Value,
    /// Value for the script's body.
    body: Value,
    /// We do our best to track the closure's name.
    name: OptionalValue,
    /// Hash reference pointing to the scope.
    scope_hash_ref: ?*HashReference,
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

    pub fn borrow(closure: ClosureValues) ClosureValues {
        const borrowed_hash_ref = closure.scope_hash_ref;
        if (borrowed_hash_ref) |val| _ = val.asHead().borrow();
        return .{
            .args = closure.args.borrow(),
            .body = closure.body.borrow(),
            .name = closure.name.borrow(),
            .scope_hash_ref = borrowed_hash_ref,
            .required_arity = closure.required_arity,
            .optional_arity = closure.optional_arity,
            .optional_values = closure.optional_values.borrow(),
            .has_args_parameter = closure.has_args_parameter,
            .is_method = closure.is_method,
            .cache_id = closure.cache_id,
        };
    }

    pub fn deinit(closure: ClosureValues) void {
        closure.args.release();
        closure.body.release();
        closure.name.release();
        if (closure.scope_hash_ref) |val| val.asHead().release();
        closure.optional_values.release();
    }

    pub fn enumerateStruct(ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const closure: *const ClosureValues = @ptrCast(@alignCast(info.node));
        const helper: ChildWalkHelper = .{ .ctx = ctx, .info = info };
        try helper.followValue("args", closure.args);
        try helper.followValue("body", closure.body);
        try helper.followOptionalValue("name", closure.name);
        try helper.followOptional(HashReference, "scope_hash_ref", closure.scope_hash_ref);
        @compileLog("here");
        // if (closure.scope_hash_ref) |hash_ref|
        //     try helper.followOptional(Object, "scope_hash_ref", hash_ref.asHead());
        try helper.followOptionalValue("optional_values", closure.optional_values);
    }
};

pub const Closure = struct {
    closure: *ClosureValues,

    fn duplicate(src: *const Object) !*Object {
        const new_obj = try Object.duplicateStringOnly(src);
        errdefer new_obj.deinit();

        const new_closure = try heap.global_gpa.create(ClosureValues);
        new_obj.vtable = &vtable;
        new_closure.* = src.castToConst(Closure).closure.borrow();

        return new_obj;
    }

    fn freeInternalRep(src: *Object) void {
        const as_closure = src.castTo(Closure);
        as_closure.closure.deinit();
        heap.global_gpa.destroy(as_closure.closure);
    }

    fn updateString(_: *Object) !void {
        @panic("FIXME: generate closure from parts (see old code)");
    }

    fn enumerateStruct(obj: *const Object, ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const closure = obj.castToConst(Closure);
        const helper: ChildWalkHelper = .{ .ctx = ctx, .info = info };
        try helper.follow(ClosureValues, "closure", closure.closure);
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .free_internal_rep = freeInternalRep,
        .update_string = updateString,
        .make_crossthread = null,
        .enumerate_struct = enumerateStruct,
        .name = "closure",
    };
};

pub const UpvarLink = struct {
    /// An object containing the name of the variable in the linked
    /// scope. Whenever someone shimmers this to a variable, they should
    /// always do it in `call_frame`.
    linked_name: Value,
    /// The call frame the linked variable lives in.
    call_frame: u32,

    fn freeInternalRep(src: *Object) void {
        src.castTo(UpvarLink).linked_name.release();
    }

    fn enumerateStruct(ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const upvar: *const UpvarLink = @ptrCast(@alignCast(info.node));
        const helper: ChildWalkHelper = .{ .ctx = ctx, .info = info };
        try helper.followValue("linked_name", upvar.linked_name);
    }

    pub const vtable: Object.VTable = .{
        .duplicate = null,
        .free_internal_rep = freeInternalRep,
        .update_string = null,
        .make_crossthread = null,
        .enumerate_struct = enumerateStruct,
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
pub const DictSugar = struct {
    dict_name: Value,
    dict_path: *List,

    fn freeInternalRep(src: *Object) void {
        const as_dict_sugar = src.castTo(DictSugar);
        as_dict_sugar.dict_name.release();
        as_dict_sugar.dict_path.asHead().release();
    }

    fn enumerateStruct(ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const dict_sugar: *const DictSugar = @ptrCast(@alignCast(info.node));
        const helper: ChildWalkHelper = .{ .ctx = ctx, .info = info };
        try helper.followValue("dict_name", dict_sugar.dict_name);
        try helper.follow(List, "dict_path", dict_sugar.dict_path);
    }

    pub const vtable: Object.VTable = .{
        .name = "dict_sugar",
        .duplicate = Object.duplicateStringOnly,
        .free_internal_rep = freeInternalRep,
        .update_string = null,
        .make_crossthread = null,
        .enumerate_struct = enumerateStruct,
    };
};

pub const HashReference = struct {
    /// This is of type `*ObjectType` instead of `Value`, because a
    /// hash reference can only ever point to a heap `Object`.
    ref: *Object,

    pub fn new(referent: *Object) !*HashReference {
        const new_obj = try Object.newObject(HashReference);
        new_obj.body.* = .{ .ref = referent.borrow() };
        return new_obj.body;
    }

    pub fn shimmerFrom(det: ?*ErrorDetails, shim: *Shimmerable) !*HashReference {
        if (shim.current().asType(HashReference)) |hash_ref| return hash_ref;

        const bytes = try shim.current().getString();
        const hash = heap.hashutil.parseHashReference(bytes) orelse {
            if (det) |details| details.* = .{
                .message = try std.fmt.allocPrintSentinel(
                    heap.global_gpa,
                    "expected a hash reference like \"blake3~...\" in \"{s}\".",
                    .{bytes},
                    0,
                ),
            };
            return error.NotHashReference;
        };
        const target = heap.registered_hashes.get(hash) orelse {
            if (det) |details| details.* = .{
                .message = try std.fmt.allocPrintSentinel(
                    heap.global_gpa,
                    "could not find value for hash reference {s}",
                    .{bytes},
                    0,
                ),
            };
            return error.HashLookupFailed;
        };

        const obj = try shim.prepareToShimmer();
        obj.vtable = &vtable;
        const as_hash_ref = obj.castTo(HashReference);
        as_hash_ref.* = .{ .ref = target.borrow() };
        return as_hash_ref;
    }

    pub fn asHead(self: *HashReference) *Object {
        return Object.from(HashReference, self);
    }

    fn duplicate(src: *const Object) !*Object {
        const new_obj = try Object.newObject(HashReference);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj.head);
        errdefer new_obj.head.invalidateString();

        const as_hash_ref = src.castToConst(HashReference);
        new_obj.body.ref = as_hash_ref.ref.borrow();

        return new_obj.head;
    }

    fn freeInternalRep(obj: *Object) void {
        const as_hash_ref = obj.castTo(HashReference);
        as_hash_ref.ref.release();
    }

    fn updateString(obj: *Object) !void {
        const as_hash_ref = obj.castTo(HashReference);
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

    fn enumerateStruct(obj: *const Object, ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const hash_ref = obj.castToConst(HashReference);
        const helper: ChildWalkHelper = .{ .ctx = ctx, .info = info };
        try helper.follow(Object, "ref", hash_ref.ref);
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .update_string = updateString,
        .free_internal_rep = freeInternalRep,
        .make_crossthread = null,
        .enumerate_struct = enumerateStruct,
        .name = "hash_reference",
    };
};

pub const Regexp = struct {
    regexp: *pcre2.pcre2_code_8,

    fn freeInternalRep(obj: *Object) void {
        const as_regexp = obj.castTo(Regexp);
        pcre2.pcre2_code_free_8(as_regexp.regexp);
    }

    fn enumerateStruct(obj: *const Object, ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const regexp = obj.castToConst(Regexp);
        ctx.followNode(pcre2.pcre2_code_8, info, "regexp", regexp.regexp);
    }

    pub const vtable: Object.VTable = .{
        .duplicate = Object.duplicateStringOnly,
        .update_string = null,
        .free_internal_rep = freeInternalRep,
        .make_crossthread = null,
        .enumerate_struct = enumerateStruct,
        .name = "regexp",
    };
};

pub const Index = struct {
    index: i64,
    is_relative: bool,

    pub const as_end: Index = .{ .index = 0, .is_relative = true };

    /// `start` is inclusive, `end` is exclusive. (Note, this is different from Tcl's
    /// convention, where both are inclusive. `fromIndexes` accounts for this when
    /// running the conversion).
    pub const Range = struct {
        start: usize,
        end: usize,

        /// This properly accounts for both `start` and `end` being inclusive, per tcl convention.
        pub fn fromIndexes(len: u32, start_index: Index, end_index: Index) Range {
            var start = start_index.asAbsoluteIndex(len);
            // Convert inclusive to exclusive with `+ 1`.
            var end = end_index.asAbsoluteIndex(len) + 1;

            if (start < 0) start = 0;
            if (end < 0) end = 0;
            if (end > len) end = len;

            return .{
                .start = @intCast(start),
                .end = @intCast(end),
            };
        }
    };

    pub fn asAbsoluteIndex(self: Index, len: u32) i64 {
        if (self.is_relative) {
            return self.index + (len -| 1);
        } else {
            return self.index;
        }
    }

    /// Sets the details to a bad index message, and returns error.BadIndex.
    fn badIndexError(det: ?*ErrorDetails, bytes: []const u8) error{ OutOfMemory, BadIndex } {
        if (det) |details| details.* = .{
            .message = try std.fmt.allocPrintSentinel(
                heap.global_gpa,
                "bad index \"{f}\": must be intexpr or end?[+-]intexpr?",
                .{bytes},
                0,
            ),
        };

        return error.BadIndex;
    }

    pub fn shimmerFrom(det: ?*ErrorDetails, shim: *Shimmerable) !*Index {
        if (shim.current().asType(Index)) |index| return index;

        const bytes = try shim.current().getString();
        const index: Index = blk: {
            // Does it start with "end"? If so, it might be end+5, or end-2, etc
            if (bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], "end")) {
                if (bytes.len >= 4) {
                    if (bytes[3] != '+' and bytes[3] != '-') return badIndexError(det, bytes);

                    const index_offset = std.fmt.parseInt(i64, bytes[3..], 10) catch return badIndexError(det, bytes);
                    break :blk .{
                        .index = index_offset,
                        .is_relative = true,
                    };
                } else break :blk as_end;
            } else {
                break :blk .{
                    .index = std.fmt.parseInt(i64, bytes, 0) catch return badIndexError(det, bytes),
                    .is_relative = false,
                };
            }
        };

        const obj = try shim.prepareToShimmer();
        obj.vtable = &vtable;
        obj.castTo(Index).* = index;
    }

    pub fn get(det: ?*ErrorDetails, shim: *Shimmerable) !Index {
        // Fast case: if it's an integer or float, we can quickly cast it (don't
        // shimmer though, as it'll probably still be used for its original purpose).

        switch (shim.current().expandedValue()) {
            .int => |int| {
                return .{ .index = int, .is_relative = false };
            },
            .float => |float| {
                if (math.isNan(float)) return badIndexError(det, try shim.current().getString());
                if (float < std.math.minInt(i64)) return badIndexError(det, try shim.current().getString());
                if (float > std.math.maxInt(i64)) return badIndexError(det, try shim.current().getString());
                if (@trunc(float) != float) return badIndexError(det, try shim.current().getString());

                return .{ .index = @trunc(float), .is_relative = false };
            },
            else => {
                return (try shimmerFrom(det, shim)).*;
            },
        }
    }

    pub fn getRange(det: ?*ErrorDetails, len: usize, start: *Shimmerable, end: *Shimmerable) !Range {
        const start_index = try get(det, start);
        const end_index = try get(det, end);
        return Range.fromIndexes(len, start_index, end_index);
    }

    fn duplicate(src: *const Object) !*Object {
        const new_obj = try Object.newObjectUninitialized(Index);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj.head);

        const as_index = src.castToConst(Index);
        new_obj.body.index = as_index.index;
        new_obj.body.is_relative = as_index.is_relative;

        return new_obj.head;
    }

    fn updateString(obj: *Object) !void {
        const as_index = obj.castTo(Index);
        const bytes = blk: {
            if (as_index.is_relative) {
                const sign = if (as_index.index >= 0) "+" else "";
                break :blk try std.fmt.allocPrintSentinel(heap.global_gpa, "end{s}{d}", .{ sign, as_index.index }, 0);
            } else {
                break :blk try std.fmt.allocPrintSentinel(heap.global_gpa, "{d}", .{as_index.index}, 0);
            }
        };
        try obj.setStringConsuming(bytes);
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .free_internal_rep = null,
        .update_string = updateString,
        .make_crossthread = null,
        .enumerate_struct = null,
        .name = "index",
    };
};

pub const Float = struct {
    value: f64,

    pub fn new(value: f64) Value {
        if (math.isNan(value)) return Value.newFloat(math.nan(f64));
        return Value.newFloat(value);
    }

    pub fn renderFloat(float: f64, buf: *[350]u8) [:0]const u8 {
        if (@trunc(float) == float) {
            // If it has no fractional part, we render it with ".0" at the end.
            return std.fmt.bufPrintSentinel(buf, "{:.1}", .{float}, 0) catch unreachable;
        } else {
            return std.fmt.bufPrintSentinel(buf, "{}", .{float}, 0) catch unreachable;
        }
    }

    pub fn asHead(self: *Integer) *Object {
        return Object.from(Integer, self);
    }

    pub fn newBoxed(value: f64) !*Float {
        const new_obj = try Object.newObject(Float);
        new_obj.body.value = value;
        return new_obj.body;
    }

    pub fn parse(det: ?*ErrorDetails, bytes: []const u8) !f64 {
        if (std.fmt.parseFloat(f64, bytes)) |parsed| {
            return parsed;
        } else |_| {
            if (det) |details| details.* = .{
                .message = try std.fmt.allocPrint("expected float but got \"{s}\"", .{bytes}),
            };
            return error.BadFloat;
        }
    }

    pub fn shimmer(det: ?*ErrorDetails, shim: *Shimmerable) !void {
        if (shim.current().asFloat() != null) return;
        if (shim.current().asType(Float) != null) return;

        const parsed = try parse(det, try shim.current().getString());

        // Compare the parsed version to the regenerated version, and if identical,
        // shimmer to a float value. This way, we don't lose a string representation
        // if it wouldn't be regenerated the same way.
        var buf: [32]u8 = undefined;
        const written = std.fmt.bufPrint(&buf, parsed);
        const regenerated = buf[0..written];

        if (mem.eql(u8, parsed, regenerated)) {
            // The two strings are identical, so we can use a float value.
            shim.shimmered.swap(Value.newFloat(parsed));
        }

        const obj = try shim.prepareToShimmer();
        obj.vtable = &vtable;
        const as_boxed_float = obj.castTo(Float);
        as_boxed_float = .{ .value = parsed };
        return as_boxed_float;
    }

    pub fn get(det: ?*ErrorDetails, shim: *Shimmerable) !i64 {
        try shimmer(det, shim);

        if (shim.current().asFloat()) |float| return float;
        if (shim.current().asType(Float)) |boxed| return boxed.value;
        unreachable;
    }

    fn updateString(obj: *Object) !void {
        const as_float = obj.castTo(Float);
        const bytes = try std.fmt.allocPrintSentinel(heap.global_gpa, "{}", .{as_float.value}, 0);
        try obj.setStringConsuming(bytes);
    }

    fn duplicate(src: *const Object) !*Object {
        const new_obj = try Object.newObject(Float);
        errdefer new_obj.head.deinit();
        try src.duplicateHeadOnto(new_obj.head);

        const as_float = src.castToConst(Float);
        new_obj.body.value = as_float.value;

        return new_obj.head;
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .free_internal_rep = null,
        .update_string = updateString,
        .make_crossthread = null,
        .enumerate_struct = null,
        .name = "boxed_float",
    };
};

pub const Integer = struct {
    value: i64,

    pub fn new(value: i64) !Value {
        if (value >= math.minInt(i32) and value <= math.maxInt(i32)) {
            return Value.newInt(@intCast(value));
        }
        return Value.fromPtr((try newBoxed(value)).asHead());
    }

    pub fn newBoxed(value: i64) !*Integer {
        const new_obj = try Object.newObject(Integer);
        new_obj.body.value = value;
        return new_obj.body;
    }

    pub fn asHead(self: *Integer) *Object {
        return Object.from(String, self);
    }

    pub fn integerOverflowError(det: ?*ErrorDetails, rendered_int: []const u8) error{ OutOfMemory, IntegerOverflow } {
        if (det) |details| details.* = .{
            .message = try std.fmt.allocPrint("integer value \"{s}\" too big to be represented", .{rendered_int}),
        };
        return error.IntegerOverflow;
    }

    pub fn parse(det: ?*ErrorDetails, bytes: []const u8) !i64 {
        if (std.fmt.parseInt(i64, bytes, 0)) |integer| {
            return integer;
        } else |err| switch (err) {
            error.InvalidCharacter => {
                if (det) |details| details.* = .{
                    .message = try std.fmt.allocPrint("expected integer but got \"{s}\"", .{bytes}),
                };
                return error.BadInteger;
            },
            error.Overflow => {
                return integerOverflowError(det, bytes);
            },
        }
    }

    pub fn shimmer(det: ?*ErrorDetails, shim: *Shimmerable) !void {
        if (shim.current().asInt() != null) return;
        if (shim.current().asType(Integer) != null) return;

        const parsed = try parse(det, try shim.current().getString());

        if (parsed >= math.minInt(i32) and parsed <= math.maxInt(i32)) {
            // Compare the parsed version to the regenerated version, and if identical,
            // shimmer to an integer value. TODO PERF if we have our own int parser,
            // we could see if it was a normal parse, and bypass the byte comparsion.
            var buf: [32]u8 = undefined;
            const written = std.fmt.bufPrint(&buf, parsed);
            const regenerated = buf[0..written];

            if (mem.eql(u8, parsed, regenerated)) {
                // The two strings are identical, so we can use an int value.
                shim.shimmered.swap(Value.newInt(@intCast(parsed)));
            }
        }

        const obj = try shim.prepareToShimmer();
        obj.vtable = &vtable;
        const as_boxed_int = obj.castTo(Integer);
        as_boxed_int = .{ .value = parsed };
        return as_boxed_int;
    }

    pub fn get(det: ?*ErrorDetails, shim: *Shimmerable) !i64 {
        try shimmer(det, shim);

        if (shim.current().asInt()) |int| return int;
        if (shim.current().asType(Integer)) |boxed| return boxed.value;
        unreachable;
    }

    fn updateString(obj: *Object) !void {
        const bytes = try std.fmt.allocPrintSentinel(heap.global_gpa, "{}", .{obj.castTo(Integer).value}, 0);
        try obj.setStringConsuming(bytes);
    }

    fn duplicate(src: *const Object) !*Object {
        const new_obj = try Object.newObjectUninitialized(Integer);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj.head);

        new_obj.body.value = src.castToConst(Integer).value;

        return new_obj.head;
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .free_internal_rep = null,
        .update_string = updateString,
        .make_crossthread = null,
        .enumerate_struct = null,
        .name = "boxed_int",
    };
};

/// Enum names joined by ", "
pub fn enumNames(comptime E: type, comptime joiner: []const u8) []const u8 {
    return comptime blk: {
        var result: []const u8 = @tagName(std.enums.values(E)[0]);
        for (std.enums.values(E)[1..]) |value| {
            result = &(result[0..].* ++ joiner[0..].* ++ @tagName(value).*);
        }

        break :blk result;
    };
}

pub fn EnumMapping(comptime E: type, include_numbers: bool) type {
    comptime {
        @setEvalBranchQuota(20000);

        const values = std.enums.values(E);

        // Fill out the mapping.
        const final_entries = blk: {
            if (include_numbers) {
                var entries: [values.len * 2]struct { []const u8, E } = undefined;
                for (values, 0..) |value, i| {
                    entries[i * 2] = .{ @tagName(value), value };
                    // Add an entry for the integer value of the enum, to match Tcl behavior.
                    entries[i * 2 + 1] = .{ std.fmt.comptimePrint("{}", .{@intFromEnum(value)}), value };
                }
                break :blk entries;
            } else {
                var entries: [values.len]struct { []const u8, E } = undefined;
                for (values, 0..) |value, i| {
                    entries[i] = .{ @tagName(value), value };
                }
                break :blk entries;
            }
        };

        // Create the table
        return struct {
            pub const StaticStringMap = std.StaticStringMap(E);

            map: StaticStringMap = StaticStringMap.initComptime(final_entries),
        };
    }
}

pub fn EnumConstructor(comptime E: type, include_numbers: bool) type {
    return struct {
        pub const names = enumNames(E, ", ");
        pub const map = (EnumMapping(E, include_numbers){}).map;
        pub const enum_name = @typeName(E);
        const Self = @This();

        variant: E,

        pub fn shimmerFrom(det: ?*ErrorDetails, shim: *Shimmerable) !*Self {
            if (shim.current().asType(Self)) |self| return self;

            const bytes = try shim.current().getString();
            const variant = map.get(bytes);
            if (variant) |val| {
                const obj = try shim.prepareToShimmer();
                obj.vtable = &vtable;
                const self = obj.castTo(Self);
                self.variant = val;
                return self;
            } else {
                if (det) |details| details.* = .{
                    .message = try std.fmt.allocPrintSentinel(
                        heap.global_gpa,
                        "bad {s} \"{s}\": must be {s}",
                        .{ enum_name, bytes, names },
                        0,
                    ),
                };
                return error.BadEnumVariant;
            }
        }

        pub fn get(det: ?*ErrorDetails, shim: *Shimmerable) !E {
            return (try shimmerFrom(det, shim)).variant;
        }

        fn duplicate(src: *const Object) !*Object {
            assert(src.getStringDetails() != .none);
            const new_obj = try Object.newObjectUninitialized(Self);
            errdefer new_obj.head.freeBacking();
            try src.duplicateHeadOnto(new_obj.head);

            new_obj.body.variant = src.castToConst(Self).variant;

            return new_obj.head;
        }

        pub const vtable: Object.VTable = .{
            .duplicate = duplicate,
            .free_internal_rep = null,
            .update_string = null,
            .make_crossthread = null,
            .enumerate_struct = null,
            .name = "enum_for_" ++ enum_name,
        };
    };
}

test "enum mapping" {
    const Things = enum { foo, bar, baz };
    const map = (EnumMapping(Things, false){}).map;
    const names = enumNames(Things, ", ");
    try testing.expectEqual(Things.foo, map.get("foo"));
    try testing.expectEqualSlices(u8, "foo, bar, baz", names);
}

test "tcl enum" {
    try heap.testStart(testing.allocator, testing.io);
    defer heap.testFinish();

    const MyEnum = enum { foo, bar, baz };
    const MyTclEnum = EnumConstructor(MyEnum, true);

    var foo_str = try String.newValue("foo");
    defer foo_str.release();
    var one_str = try String.newValue("1");
    defer one_str.release();
    var bad_str = try String.newValue("bad");
    defer bad_str.release();

    var working: Shimmerable = .{ .original = foo_str, .shimmered = .none };
    try testing.expectEqual(MyEnum.foo, MyTclEnum.get(null, &working));
    working.discardChanges();
    working = .{ .original = one_str };
    try testing.expectEqual(MyEnum.bar, MyTclEnum.get(null, &working));
    working.discardChanges();
    working = .{ .original = bad_str };
    try testing.expectError(error.BadEnumVariant, MyTclEnum.get(null, &working));
    working.discardChanges();
}

fn generateSubcommandUsage(comptime E: type, args: []Shimmerable) ![:0]u8 {
    return try std.fmt.allocPrintSentinel(
        heap.global_gpa,
        "Usage: \"{s} command ... \", where command is one of: {s}",
        .{ try args[0].current().getString(), enumNames(E, ", ") },
        0,
    );
}

pub fn SubcommandParser(
    comptime E: type,
    comptime subcommands: []const struct {
        variant: E,
        usage: []const u8,
        min_args: u32 = 0,
        max_args: ?u32 = null,
        stride: u32 = 1,
    },
) type {
    const Subcommand = @typeInfo(@TypeOf(subcommands)).pointer.child;

    comptime assert(std.enums.values(E).len == subcommands.len);

    return struct {
        // Create a mapping from subcommand name -> Enum.
        pub const NameToEnum = EnumConstructor(E, false);
        // As well as a mapping from Enum -> subcommand.
        pub const EnumToSubcommand = blk: {
            const variants = std.enums.values(E);

            var converted_mapping: std.enums.EnumFieldStruct(E, Subcommand, null) = undefined;
            for (0..variants.len) |i| {
                const value = @tagName(variants[i]);
                assert(subcommands[i].variant == variants[i]);
                @field(converted_mapping, value) = subcommands[i];
            }

            break :blk std.EnumArray(E, Subcommand).init(converted_mapping);
        };

        const space_joined_names = enumNames(E, " ");
        const comma_joined_names = enumNames(E, ",");

        /// `args` should include the original command name.
        pub fn parse(det: ?*ErrorDetails, args: []Shimmerable) !E {
            if (args.len < 2) {
                const bytes = try args[0].current().getString();
                if (det) |details| details.* = .{
                    .message = try std.fmt.allocPrintSentinel(heap.global_gpa,
                        \\wrong # args: should be "{s} command ..."
                        \\Use "{s} -help ?command?" for help
                    , .{ bytes, bytes }, 0),
                };
                return error.WrongUsage;
            }

            // TODO PERF cache the subcommand lookup.

            if (try args[1].current().equalsString("-help")) {
                if (args.len >= 3) {
                    const subcommand_queried = &args[2];

                    // Generate help for a specific subcommand, if the subcommand exists.
                    if (NameToEnum.get(null, subcommand_queried)) |val| {
                        const subcommand = EnumToSubcommand.get(val);
                        if (det) |details| details.* = .{
                            .message = try std.fmt.allocPrintSentinel(
                                heap.global_gpa,
                                "Usage: \"{s} {s} {s}\"",
                                .{
                                    try args[0].current().getString(),
                                    try subcommand_queried.current().getString(),
                                    subcommand.usage,
                                },
                                0,
                            ),
                        };
                        return error.UsageHelp;
                    } else |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {
                            // Else, fall through to the general usage.
                        },
                    }
                }
                if (det) |details| details.* = .{ .message = try generateSubcommandUsage(E, args) };
                return error.UsageHelp;
            }

            if (try args[1].current().equalsString("-commands")) {
                if (det) |details| details.* = .{ .message = try heap.global_gpa.dupeSentinel(u8, space_joined_names, 0) };
                return error.UsageHelp;
            }

            const subcommand_name = &args[1];
            const subcommand_enum = NameToEnum.get(null, subcommand_name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.BadEnumVariant => {
                    if (det) |details| details.* = .{
                        .message = try std.fmt.allocPrintSentinel(heap.global_gpa, "{s}, unknown command \"{s}\": should be {s}", .{
                            try args[0].current().getString(),
                            try args[1].current().getString(),
                            space_joined_names,
                        }, 0),
                    };
                    return error.WrongUsage;
                },
            };
            const subcommand = EnumToSubcommand.get(subcommand_enum);

            // Now that we've gotten the usage, we need to make sure that we have the right
            // number of arguments.
            const correct_arg_count = blk: {
                if (args.len - 2 < subcommand.min_args) break :blk false;
                if (subcommand.max_args) |max_args| if (args.len - 2 > max_args) break :blk false;
                if (@mod(args.len - 2, subcommand.stride) != 0) break :blk false;
                break :blk true;
            };
            if (!correct_arg_count) {
                if (det) |details| details.* = .{
                    .message = try std.fmt.allocPrintSentinel(
                        heap.global_gpa,
                        "wrong # args: should be \"{s}\"",
                        .{subcommand.usage},
                        0,
                    ),
                };
                return error.WrongUsage;
            }

            return subcommand_enum;
        }
    };
}

test "subcommand parser" {
    const Parser = SubcommandParser(enum { foo }, &.{
        .{ .variant = .foo, .usage = "arg1 arg2 ?arg3?", .min_args = 2, .max_args = 3 },
    });

    try heap.testStart(testing.allocator, testing.io);
    defer heap.testFinish();

    var base_str: Shimmerable = .{ .original = try String.newValue("base") };
    defer base_str.deinit();
    var foo_str: Shimmerable = .{ .original = try String.newValue("foo") };
    defer foo_str.deinit();
    var arg1_str: Shimmerable = .{ .original = try String.newValue("arg1") };
    defer arg1_str.deinit();
    var arg2_str: Shimmerable = .{ .original = try String.newValue("arg2") };
    defer arg2_str.deinit();
    var arg3_str: Shimmerable = .{ .original = try String.newValue("arg3") };
    defer arg3_str.deinit();

    var args = [_]Shimmerable{ base_str, foo_str, arg1_str, arg2_str };
    try testing.expectEqual(.foo, try Parser.parse(null, &args));

    var args2 = [_]Shimmerable{ base_str, foo_str, arg1_str };
    try testing.expectError(error.WrongUsage, Parser.parse(null, &args2));
}

pub const BoxedBoolean = struct {
    value: bool,

    pub fn new(value: bool) !*BoxedBoolean {
        const new_obj = try Object.newObject(BoxedBoolean);
        new_obj.body.value = value;
        return new_obj.body;
    }

    fn updateString(obj: *Object) !void {
        const bytes = if (obj.castTo(BoxedBoolean).value)
            try heap.global_gpa.dupeSentinel(u8, "true", 0)
        else
            try heap.global_gpa.dupeSentinel(u8, "false", 0);
        try obj.setStringConsuming(bytes);
    }

    fn duplicate(src: *const Object) !*Object {
        const new_obj = try Object.newObjectUninitialized(BoxedBoolean);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj.head);

        new_obj.body.value = src.castToConst(BoxedBoolean).value;

        return new_obj.head;
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .free_internal_rep = null,
        .update_string = updateString,
        .make_crossthread = null,
        .enumerate_struct = null,
        .name = "boxed_boolean",
    };
};

pub const CachedLocalVar = struct {
    ref: *const Value,
    call_epoch: u64,

    pub const vtable: Object.VTable = .{
        .duplicate = Object.duplicateStringOnly,
        .update_string = null,
        .free_internal_rep = null,
        .make_crossthread = null,
        // TODO it would be nice to be able to walk the cached local var,
        // but we'd need the call epoch invalidation logic embedded in it.
        .enumerate_struct = null,
        .name = "cached_local_var",
    };
};

pub const CachedLexicalVar = struct {
    ref: *const Value,
    call_epoch: u64,

    pub const vtable: Object.VTable = .{
        .duplicate = Object.duplicateStringOnly,
        .update_string = null,
        .free_internal_rep = null,
        .make_crossthread = null,
        // TODO same as `CachedLocalVar.vtable`.
        .enumerate_struct = null,
        .name = "cached_lexical_var",
    };
};

pub const ParsedScriptCommand = struct {
    line: u32,
    word_count: u32,

    pub const vtable: Object.VTable = .{
        .duplicate = null,
        .update_string = null,
        .free_internal_rep = null,
        .make_crossthread = null,
        .name = "parsed_script_command",
    };

    pub fn castFrom(obj: *Object) *ParsedScriptCommand {
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

pub const List = struct {
    items: []Value,
    capacity: usize,

    pub fn new(items: []const Value) !*List {
        const capacity = math.ceilPowerOfTwo(usize, items.len) catch items.len;
        return try newWithCapacity(items, capacity);
    }

    pub fn newWithCapacity(items: []const Value, capacity: usize) !*List {
        const new_list = try Object.newObject(List);
        errdefer new_list.head.freeBacking();

        const new_items = try heap.global_gpa.alloc(Value, capacity);
        for (items, new_items[0..items.len]) |item, *new_item| {
            new_item.* = item.borrow();
        }
        new_list.body.items = new_items[0..items.len];
        new_list.body.capacity = capacity;

        return new_list.body;
    }

    fn backingSlice(self: *List) []Value {
        return self.items.ptr[0..self.capacity];
    }

    pub fn append(det: ?*ErrorDetails, mut: *Mutable, value: Value) !void {
        try mut.prepareToMutate();
        const list = try List.shimmerFrom(det, mut.asShimmerable());
        try list.appendInner(value);
    }

    pub fn set(det: ?*ErrorDetails, mut: *Mutable, index: usize, value: Value) !void {
        try mut.prepareToMutate();
        const list = try List.shimmerFrom(det, mut.asShimmerable());
        list.setInner(index, value);
    }

    fn ensureCapacity(self: *List, new_capacity: usize) !void {
        if (new_capacity > self.capacity) {
            const new_backing = try heap.global_gpa.realloc(self.backingSlice(), new_capacity);
            self.items = new_backing[0..self.items.len];
            self.capacity = new_capacity;
        }
    }

    fn appendInner(self: *List, value: Value) !void {
        if (self.capacity < self.items.len + 1) try self.ensureCapacity(@max(4, self.capacity * 2));

        const old_len = self.items.len;
        self.items = self.items.ptr[0..(old_len + 1)];
        self.items[old_len] = value.borrow();
    }

    fn setInner(self: *List, index: usize, value: Value) void {
        self.items[index].swap(value);
    }

    pub fn shimmerFrom(det: ?*ErrorDetails, shim: *Shimmerable) !*List {
        if (shim.current().asType(List)) |list| return list;

        // Optimise dict -> list.
        if (shim.current().asType(Dictionary)) |_| {
            try shim.ensureShimmerable();

            const obj: *Object = shim.current().asPtr().?;
            const as_dict = obj.castTo(Dictionary);
            // The list shares the dict's items, so just free the dict's table
            // and swap the head over.
            as_dict.table.deinit(heap.global_gpa);
            const old_items = as_dict.items;
            const old_capacity = as_dict.capacity;

            obj.vtable = &vtable;
            const as_list = obj.castTo(List);
            as_list.* = .{ .items = old_items, .capacity = old_capacity };

            return as_list;
        }

        // Try to preserve information about filename / line number.
        var file_name: OptionalValue = .none;
        var line_no: u32 = 1;
        if (shim.current().asType(Source)) |source_info| {
            line_no = source_info.line_no;
            file_name = source_info.file_name;
        }

        const bytes = try shim.current().getString();
        var parser = Tokenizer.init(bytes, line_no);

        var new_items: std.ArrayList(Value) = .empty;
        errdefer {
            for (new_items.items) |item| item.release();
            new_items.deinit(heap.global_gpa);
        }

        while (true) {
            const next_token = parser.nextListToken() catch |err| {
                if (det) |details| details.* = .{ .message = try convertTokenizerError(err) };
                return error.BadList;
            };
            switch (next_token.tag) {
                .simple_string, .escaped_string => {
                    const token_value = bytes[next_token.loc.start..next_token.loc.end];
                    const str = if (next_token.tag == .escaped_string)
                        try String.newFromEscaped(token_value)
                    else
                        try String.new(token_value);
                    const obj = str.asHead();
                    errdefer obj.release();

                    obj.vtable = &Source.vtable;
                    obj.castTo(Source).* = .{
                        .file_name = file_name.borrow(),
                        .line_no = line_no,
                        .hash = .init(null),
                    };

                    try new_items.append(heap.global_gpa, obj.asValue());
                },
                .end_of_file => break,
                else => {
                    // Skip any line breaks or word breaks.
                },
            }
        }

        const obj = try shim.prepareToShimmer();
        obj.vtable = &vtable;
        const as_list = obj.castTo(List);
        as_list.* = .{
            .items = new_items.items,
            .capacity = new_items.capacity,
        };

        return as_list;
    }

    fn convertTokenizerError(err: Tokenizer.Error) error{OutOfMemory}![:0]u8 {
        return switch (err) {
            error.CharactersAfterCloseBrace => try heap.global_gpa.dupeSentinel(u8, "extra characters after close-brace", 0),
            error.MissingCloseBrace => try heap.global_gpa.dupeSentinel(u8, "missing close-brace", 0),
            error.MissingCloseBracket => try heap.global_gpa.dupeSentinel(u8, "unmatched \"[\"", 0),
            error.MissingCloseQuote => try heap.global_gpa.dupeSentinel(u8, "missing quote", 0),
            error.TrailingBackslash => try heap.global_gpa.dupeSentinel(u8, "no character after \\", 0),
            error.FunctionMissingParentheses => try heap.global_gpa.dupeSentinel(u8, "function missing parentheses", 0),
            error.NotOperator => try heap.global_gpa.dupeSentinel(u8, "not operator", 0),
            error.NotNumber => try heap.global_gpa.dupeSentinel(u8, "not number", 0),
            error.NotVariable => unreachable,
        };
    }

    pub fn asHead(self: *List) *Object {
        return Object.from(List, self);
    }

    fn updateString(obj: *Object) !void {
        const as_list = obj.castTo(List);
        const bytes = try quoteValues(heap.global_gpa, as_list.items);
        try obj.setStringConsuming(bytes);
    }

    fn duplicate(src: *const Object) !*Object {
        const as_list = src.castToConst(List);
        const new_obj = try Object.newObjectUninitialized(List);
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
        const as_list = obj.castTo(List);
        for (as_list.items) |item| item.release();
        heap.global_gpa.free(as_list.items.ptr[0..as_list.capacity]);
    }

    fn makeCrossthread(obj: *Object) void {
        const as_list = obj.castTo(List);
        for (as_list.items) |item| item.makeCrossthread();
    }

    fn enumerateStruct(obj: *const Object, ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const list = obj.castToConst(List);
        if (list.items.len == 0) return;

        const items_info: StructIterator.NodeInfo = .{
            .node = @ptrCast(list.items.ptr),
            .parent_info = info,
            .enumerate_struct = null, // `[]Value` has no walking function.
            .type_name = @typeName([]Value),
            .as_string = null,
        };
        try ctx.vtable.visit_node(ctx, &items_info, "items");

        const items_helper: ChildWalkHelper = .{ .ctx = ctx, .info = &items_info };
        for (list.items) |item| try items_helper.followValue("items", item);
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .free_internal_rep = freeInternalRep,
        .update_string = updateString,
        .make_crossthread = makeCrossthread,
        .enumerate_struct = enumerateStruct,
        .name = "list",
    };
};

fn testLists(ta: std.mem.Allocator) !void {
    try heap.testStart(ta, testing.io);
    defer heap.testFinish();

    var det: ErrorDetails = undefined;

    // Simple case: two objects in a list
    const obj1 = try String.newValue("object 1");
    defer obj1.release();
    const obj2 = try String.newValue("object 2");
    defer obj2.release();
    var list1 = try List.new(&.{ obj1, obj2 });
    defer list1.asHead().release();

    try testing.expectEqual(2, list1.items.len);
    try testing.expectEqualStrings("object 1", try list1.items[0].getString());

    const to_append = try String.newValue("appended item");
    defer to_append.release();

    var list1_mut: Mutable = .{ .original = list1.asHead().asValue() };
    defer list1_mut.discardChanges();
    try List.append(&det, &list1_mut, to_append);
    const appended = list1_mut.current().asType(List).?.items[2];
    try testing.expectEqualStrings("appended item", try appended.getString());

    var string_list: Shimmerable = .{ .original = try String.newValue(
        \\item1 {item 2} item\ 3
    ) };
    defer string_list.deinit();

    const new_list = try List.shimmerFrom(&det, &string_list);
    try testing.expectEqualStrings("item1", try new_list.items[0].getString());
    try testing.expectEqualStrings("item 2", try new_list.items[1].getString());
    try testing.expectEqualStrings("item 3", try new_list.items[2].getString());
}

test "lists" {
    try testing.checkAllAllocationFailures(testing.allocator, testLists, .{});
}

/// A key path passed to the recursive dict operations, as a slice of `Value`s.
pub const ValueSliceContext = struct {
    items: []const Value,
    pub fn len(self: @This()) usize {
        return self.items.len;
    }
    pub fn get(self: @This(), index: usize) Value {
        return self.items[index];
    }
    pub fn sliceAfter(self: @This(), index: usize) @This() {
        return .{ .items = self.items[index..] };
    }
};

pub const Dictionary = struct {
    items: []Value,
    capacity: usize,
    table: Table,

    /// This table is always used in a way that ensures that any
    /// key inserted already has its string generated.
    const Table = std.HashMapUnmanaged(Value, usize, struct {
        pub fn hash(_: @This(), key: Value) u64 {
            return @truncate(key.getHashNoRegister() catch unreachable);
        }
        pub fn eql(_: @This(), a: Value, b: Value) bool {
            return a.equals(b) catch unreachable;
        }
    }, 80);

    pub fn asHead(self: *Dictionary) *Object {
        return Object.from(Dictionary, self);
    }

    fn backingSlice(self: *Dictionary) []Value {
        return self.items.ptr[0..self.capacity];
    }

    fn ensureCapacity(self: *Dictionary, new_capacity: usize) !void {
        if (new_capacity > self.capacity) {
            const new_backing = try heap.global_gpa.realloc(self.backingSlice(), new_capacity);
            self.items = new_backing[0..self.items.len];
            self.capacity = new_capacity;
            try self.table.ensureTotalCapacity(heap.global_gpa, @intCast(new_capacity / 2));
        }
    }

    pub fn new(items: []const Value) !*Dictionary {
        const capacity = math.ceilPowerOfTwo(usize, @max(4, items.len)) catch items.len;
        const new_dict = try Object.newObject(Dictionary);
        errdefer new_dict.head.freeBacking();

        const new_items = try heap.global_gpa.alloc(Value, capacity);
        errdefer heap.global_gpa.free(new_items);
        for (items, new_items[0..items.len]) |item, *new_item| {
            new_item.* = item.borrow();
        }
        errdefer for (new_items) |item| item.release();

        new_dict.body.* = .{
            .items = new_items[0..items.len],
            .capacity = capacity,
            .table = try generateTable(new_items[0..items.len], capacity),
        };

        return new_dict.body;
    }

    /// Generate the mapping from keys to values. `capacity` is the backing
    /// capacity the dict will hold, not the live item count, so the table is
    /// sized to absorb future `putAssumeCapacity` calls without the items
    /// backing having to grow first.
    fn generateTable(items: []Value, capacity: usize) !Table {
        var table: Table = .empty;
        errdefer table.deinit(heap.global_gpa);
        try table.ensureTotalCapacity(heap.global_gpa, @intCast(capacity / 2));

        var item_index: usize = 0;
        while (item_index < items.len) : (item_index += 2) {
            // Note that if a key appears multiple times, the last instance
            // of that key will win.
            _ = try items[item_index].getHashNoRegister(); // Make sure it has a hash in advance.
            try table.put(heap.global_gpa, items[item_index], item_index + 1);
        }
        return table;
    }

    pub fn shimmerFrom(det: ?*ErrorDetails, shim: *Shimmerable) !*Dictionary {
        if (shim.current().asType(Dictionary)) |dict| return dict;

        const list = List.shimmerFrom(det, shim) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadList => return error.BadDict,
        };
        // A dict needs an even number of elements.
        if (list.items.len % 2 != 0) {
            if (det) |details| details.* = .{
                .message = try std.fmt.allocPrintSentinel(
                    heap.global_gpa,
                    "Missing value to go with key when converting \"{s}\" to a dictionary.",
                    .{try shim.current().getString()},
                    0,
                ),
            };
            return error.BadDict;
        }

        const table = try generateTable(list.items, list.capacity);

        const old_items = list.items;
        const old_capacity = list.capacity;
        const obj = list.asHead();
        obj.vtable = &vtable;
        const as_dict = obj.castTo(Dictionary);
        as_dict.* = .{
            .items = old_items,
            .capacity = old_capacity,
            .table = table,
        };
        return as_dict;
    }

    pub fn get(self: *Dictionary, key: Value) !OptionalValue {
        if (key.asPtr()) |obj| _ = try obj.getHashNoRegister();
        if (self.table.get(key)) |idx| return self.items[idx].asOptional();
        return .none;
    }

    pub fn getPtr(self: *Dictionary, key: Value) !?*Value {
        if (key.asPtr()) |obj| _ = try obj.getHashNoRegister();
        if (self.table.get(key)) |idx| return &self.items[idx];
        return .none;
    }

    pub fn put(det: ?*ErrorDetails, mut: *Mutable, key: Value, value: Value) !usize {
        const result = try putInner(det, mut, key, value);
        if (mut.current().asPtr()) |obj| obj.invalidateString();
        return result;
    }

    /// Does not invalidate the string.
    pub fn putInner(det: ?*ErrorDetails, mut: *Mutable, key: Value, value: Value) !usize {
        // Ensure the key already has a hash, since the table requires everything used
        // to have a precomputed hash.
        if (key.asPtr()) |obj| _ = try obj.getHashNoRegister();

        try mut.prepareToMutate();
        const dict = try Dictionary.shimmerFrom(det, mut.asShimmerable());

        if (dict.table.get(key)) |existing_value_index| {
            // Key exists, so replace the value in place.
            const old = dict.items[existing_value_index];
            dict.items[existing_value_index] = value.borrow();
            errdefer {
                dict.items[existing_value_index].release();
                dict.items[existing_value_index] = old;
            }

            const shifted_index = removeDuplicates(dict, existing_value_index);
            old.release();
            return shifted_index.?;
        } else {
            // New item, so we need to expand the dict.

            const old_len = dict.items.len;
            const new_key_index = old_len;
            const new_value_index = old_len + 1;

            if (dict.capacity < old_len + 2) try dict.ensureCapacity(@max(4, dict.capacity * 2));
            // `ensureCapacity` also ensures enough room for the table.
            dict.table.putAssumeCapacity(key, new_value_index);

            // Expand the items slice to include the new items we made room for.
            dict.items = dict.backingSlice()[0..(old_len + 2)];
            dict.items[new_key_index] = key.borrow();
            dict.items[new_value_index] = value.borrow();

            const shifted_index = removeDuplicates(dict, new_value_index);
            return shifted_index.?;
        }
    }

    /// Remove all pairs with key `key`. Returns true if any were removed, and
    /// keeps the table live (clearing and re-putting into the same allocation).
    pub fn remove(det: ?*ErrorDetails, mut: *Mutable, key: Value) !bool {
        if (key.asPtr()) |obj| _ = try obj.getHashNoRegister();

        try mut.prepareToMutate();
        var dict = try Dictionary.shimmerFrom(det, mut.asShimmerable());

        // Locate the first key. We have to do a scan instead of using `dict.get`, since
        // `dict.get` only returns the last key.
        var first_key_index: usize = 0;
        while (first_key_index < dict.items.len) : (first_key_index += 2) {
            if (key.equals(dict.items[first_key_index]) catch unreachable) break;
        } else {
            return false; // No matching key.
        }

        // Before removing a key from the dictionary, we first need to check if
        // that key is contained in a linked parent. For example, say we have
        // 1: {a 5}
        // 2: {a 10 parent 1}
        // then we remove "a" from 2. So it would look something like
        // 1: {a 5}
        // 2: {parent 1}
        // The problem is when "a" is looked up, it will traverse to 1, thus returning
        // "5" as the value of "a", instead of returning none. So we have to flatten
        // the linked dictionaries into a singular dictionary so we can remove "a"
        // without resolving to a parent.
        const tilde_parent = interned_tilde_parent.value();
        if ((try dict.get(tilde_parent)).asValue()) |parent_hash_ref| {
            // This dictionary has a parent link, so we need to see if any of the parents
            // contain `key`. This requires a decent bit of shimmering, since at any point
            // we could have strings instead of internal representations.
            var parent_hash_ref_shim: Shimmerable = .{ .original = parent_hash_ref };
            defer parent_hash_ref_shim.discardChanges();
            const parent = (try HashReference.shimmerFrom(det, &parent_hash_ref_shim)).ref; // Resolve to value of hash.
            var parent_shim: Shimmerable = .{ .original = parent.asValue() };
            defer parent_shim.discardChanges();
            // We've finally hash reference and resolved it to its dictionary, so we'll now
            // see if the key is in any of the linked parents.
            const key_in_parent = (try getFollowingLinks(det, &parent_shim, key)) != .none;

            if (parent_shim.takeShimmered().asValue()) |new_parent| {
                // Write back the shimmered value to the dictionary.
                const ref_to_new_parent = (try HashReference.new(new_parent.asPtr().?)).asHead();
                defer ref_to_new_parent.release();
                _ = try putInner(det, mut, tilde_parent, ref_to_new_parent.asValue());
            } else if (parent_hash_ref_shim.takeShimmered().asValue()) |new_hash_ref| {
                defer new_hash_ref.release();
                _ = try putInner(det, mut, tilde_parent, new_hash_ref);
            }

            // Reload `dict` after potential modifications.
            dict = mut.current().asType(Dictionary).?;

            if (key_in_parent) {
                // Key was found in the parent, so we do need to flatten.
                try flatten(det, mut);
                dict = mut.current().asType(Dictionary).?;

                // Flattening may change indicies, so we need to rescan for the first key.
                first_key_index = 0;
                while (first_key_index < dict.items.len) : (first_key_index += 2) {
                    if (key.equals(dict.items[first_key_index]) catch unreachable) break;
                } else {
                    return false; // No matching key.
                }
            }
        }

        // Remove the key from the table before shifting everything around.
        _ = dict.table.remove(key);

        // Main removal loop.
        const original_len = dict.items.len;
        var pairs_removed: usize = 0;
        var item_index: usize = 0;
        while (item_index < original_len) : (item_index += 2) {
            if (dict.items[item_index].equals(key) catch unreachable) {
                dict.items[item_index].release();
                dict.items[item_index + 1].release();
                pairs_removed += 1;
            } else if (pairs_removed > 0) {
                // Be sure to shift items back after we've removed one or more pairs.
                const new_key_index = item_index - pairs_removed * 2;
                dict.items[new_key_index] = dict.items[item_index];
                dict.items[new_key_index + 1] = dict.items[item_index + 1];
            }
        }
        dict.items.len -= pairs_removed * 2;

        // Rebuild the table in place. Pretty sure this will be faster in most cases
        // compared to updating all the hash table indexes. If we use swap removal
        // this would be a lot easier, but I do like having dictionaries preserve
        // their ordering.
        dict.table.clearRetainingCapacity();
        item_index = 0;
        while (item_index < dict.items.len) : (item_index += 2) {
            // Items after removal will be strictly less than items before removal.
            dict.table.putAssumeCapacity(dict.items[item_index], item_index + 1);
        }

        // Match Tcl behavior by removing duplicates in other parts of the dictionary.
        _ = dict.removeDuplicates(null);
        dict.asHead().invalidateString();
        return true;
    }

    /// Remove earlier duplicate pairs, keeping the last value for each key. If
    /// `to_track` is given, returns its new index (or null if it was removed).
    fn removeDuplicates(dict: *Dictionary, to_track: ?usize) ?usize {
        if (dict.table.count() * 2 == dict.items.len) return to_track; // No duplicates.

        var to_track_new_location: ?usize = null;
        var pairs_removed: usize = 0;
        var item_index: usize = 0;
        while (item_index < dict.items.len) : (item_index += 2) {
            const key_index = item_index;
            const value_index = item_index + 1;
            // Figure out whether this key is the last key or not by seeing whether
            // it's the key stored in the table or not.
            const canonical = dict.table.get(dict.items[key_index]).?;
            if (value_index != canonical) {
                // This was not the value that was registered in the table,
                // so we'll go ahead and remove it.
                dict.items[item_index].release();
                dict.items[item_index + 1].release();
                pairs_removed += 1;
            } else if (pairs_removed > 0) {
                // Be sure to shift items back after we've removed one or more pairs.
                const new_key_index = item_index - pairs_removed * 2;
                const new_value_index = new_key_index + 1;

                dict.items[new_key_index] = dict.items[item_index];
                dict.items[new_value_index] = dict.items[item_index + 1];

                if (key_index == to_track) to_track_new_location = new_key_index;
                if (value_index == to_track) to_track_new_location = new_value_index;
            } else {
                if (key_index == to_track) to_track_new_location = key_index;
                if (value_index == to_track) to_track_new_location = value_index;
            }
        }
        dict.items.len -= pairs_removed * 2;

        // Rebuild the table after removing duplicates.
        dict.table.clearRetainingCapacity();
        item_index = 0;
        while (item_index < dict.items.len) : (item_index += 2) {
            dict.table.putAssumeCapacity(dict.items[item_index], item_index + 1);
        }

        return to_track_new_location;
    }

    pub fn flatten(det: ?*ErrorDetails, mut: *Mutable) !void {
        const dict = try shimmerFrom(det, mut.asShimmerable());
        const flattened = try flattenInner(det, dict);
        if (flattened) |new_dict| mut.mutated.swap(new_dict.asHead().asValue());
    }

    /// Remove all links from a dict and combine them into one dict.
    pub fn flattenInner(det: ?*ErrorDetails, original: *Dictionary) !?*Dictionary {
        if ((try original.get(interned_tilde_parent.value())).asValue()) |parent_hash_ref| {
            var parent_hash_ref_shim: Shimmerable = .{ .original = parent_hash_ref };
            defer parent_hash_ref_shim.discardChanges();
            const parent = (try HashReference.shimmerFrom(det, &parent_hash_ref_shim)).ref; // Resolve to value of hash.
            var parent_shim: Shimmerable = .{ .original = parent.asValue() };
            errdefer parent_shim.discardChanges();
            const parent_as_dict = try shimmerFrom(det, &parent_shim);

            const new_dict = try flattenInner(det, parent_as_dict);
            const to_add_to = if (new_dict) |val| val.asHead() else try parent.duplicate();
            var to_add_to_mut: Mutable = .{ .original = to_add_to.asValue() };
            errdefer to_add_to_mut.deinit();

            var pair_index: u32 = 0;
            while (pair_index < original.items.len) : (pair_index += 2) {
                _ = try put(det, &to_add_to_mut, original.items[pair_index], original.items[pair_index + 1]);
            }

            return to_add_to_mut.consume().asType(Dictionary).?;
        } else {
            return null; // We've reached the end, so no need to flatten.
        }
    }

    pub fn getFollowingLinks(det: ?*ErrorDetails, shim: *Shimmerable, key: Value) error{ OutOfMemory, LinkLookupFailed }!OptionalValue {
        if (key.asPtr()) |obj| _ = try obj.getHashNoRegister();

        const dict = shimmerFrom(det, shim) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadDict => return error.LinkLookupFailed,
        };

        // See if it's immediately in this dictionary.
        if ((try dict.get(key)).asValue()) |val| return val.asOptional();

        // Wasn't in this dictionary, so check if it's in a parent dict.
        const tilde_parent = interned_tilde_parent.value();
        if ((try dict.get(tilde_parent)).asValue()) |parent_hash_ref| {
            var parent_hash_ref_shim: Shimmerable = .{ .original = parent_hash_ref };
            defer parent_hash_ref_shim.discardChanges();
            const parent_as_dict = HashReference.shimmerFrom(det, &parent_hash_ref_shim) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NotHashReference, error.HashLookupFailed => return error.LinkLookupFailed,
            };
            const parent = parent_as_dict.ref; // Resolve to value of hash.

            var parent_shim: Shimmerable = .{ .original = parent.asValue(), .shimmered = .none };
            defer parent_shim.discardChanges();
            const looked_up = try getFollowingLinks(det, &parent_shim, key);

            if (parent_shim.takeShimmered().asValue()) |new_parent| {
                // Write back the shimmered value to the dictionary.
                const ref_to_new_parent = (try HashReference.new(new_parent.asPtr().?)).asHead();
                defer ref_to_new_parent.release();

                // This is delicate, but it's not mutation, since we're switching out the hash reference
                // with its shimmered representation, so it is transparent to the caller. Note that
                // `putInner` does not invalidate the string representation, so even if the underlying
                // dictionary mutates, we preserve the original string.
                _ = putInner(det, shim.asMutable(), tilde_parent, ref_to_new_parent.asValue()) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.BadDict => unreachable,
                };
            } else if (parent_hash_ref_shim.takeShimmered().asValue()) |new_hash_ref| {
                defer new_hash_ref.release();
                _ = putInner(det, shim.asMutable(), tilde_parent, new_hash_ref) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.BadDict => unreachable,
                };
            }

            return looked_up;
        }

        // Nothing found, even after checking parent links.
        return .none;
    }

    pub fn getRecursively(det: ?*ErrorDetails, shim: *Shimmerable, context: anytype) !OptionalValue {
        if (context.len() == 0) return shim.current().asOptional();
        if (context.len() == 1) return try getFollowingLinks(det, shim, context.get(0));

        if ((try getFollowingLinks(det, shim, context.get(0))).asValue()) |child_dict| {
            var child_shim: Shimmerable = .{ .original = child_dict };
            defer child_shim.discardChanges();
            const child_result = try getRecursively(det, &child_shim, context.sliceAfter(1));
            if (child_shim.takeShimmered().asValue()) |new_child| {
                defer new_child.release();
                // The child dict changed, propagate back up.
                _ = try putInner(det, shim.asMutable(), context.get(0), new_child);
            }
            return child_result;
        } else {
            return .none;
        }
    }

    pub fn putRecursively(det: ?*ErrorDetails, mut: *Mutable, context: anytype, value: Value) !Value {
        const dict = try shimmerFrom(det, mut.asShimmerable());

        assert(context.len() > 0);
        if (context.len() == 1) {
            const inserted_at = try put(det, mut, context.get(0), value);
            return mut.current().asType(Dictionary).?.items[inserted_at];
        }

        // Find/create the child dict.
        const child_dict = blk: {
            if ((try dict.get(context.get(0))).asValue()) |existing_dict| {
                break :blk existing_dict;
            } else {
                // Create a new child dictionary.
                const new_child_dict = (try new(&.{})).asHead().asValue();
                defer new_child_dict.release();

                _ = try put(det, mut, context.get(0), new_child_dict);
                break :blk new_child_dict;
            }
        };

        var child_wb: Mutable = .{ .original = child_dict };
        defer child_wb.discardChanges();
        const child_put_result = try putRecursively(det, &child_wb, context.sliceAfter(1), value);
        if (child_wb.takeMutated().asValue()) |new_child| {
            // The child dict changed, so we need to update ours.
            defer new_child.release();
            _ = try put(det, mut, context.get(0), new_child);
        }

        mut.current().asPtr().?.invalidateString();

        return child_put_result;
    }

    pub fn removeRecursively(det: ?*ErrorDetails, mut: *Mutable, context: anytype) !bool {
        var dict = try shimmerFrom(det, mut.asShimmerable());

        assert(context.len() > 0);
        if (context.len() == 1) return try remove(det, mut, context.get(0));

        if ((try dict.get(context.get(0))).asValue()) |child_dict| {
            var child_mut: Mutable = .{ .original = child_dict };
            defer child_mut.discardChanges();

            const did_remove = try removeRecursively(det, &child_mut, context.sliceAfter(1));
            if (child_mut.takeMutated().asValue()) |new_child| {
                defer new_child.release();
                _ = try put(det, mut, context.get(0), new_child);
            }

            mut.current().asPtr().?.invalidateString();

            return did_remove;
        } else {
            if (det) |details| details.* = .{
                .message = try std.fmt.allocPrintSentinel(
                    heap.global_gpa,
                    "key \"{s}\" not known in dictionary \"{s}\"",
                    .{ try context.get(0).getString(), try mut.current().getString() },
                    0,
                ),
            };
            return error.PathNonexistent;
        }
    }

    /// A key->value map, with parent keys inserted before child keys.
    pub const KvResult = std.array_hash_map.Custom(Value, Value, struct {
        pub fn hash(_: @This(), key: Value) u32 {
            return @truncate(key.getHashNoRegister() catch unreachable);
        }
        pub fn eql(_: @This(), a: Value, b: Value, _: usize) bool {
            return a.equals(b) catch unreachable;
        }
    }, true);

    pub fn getKvPairs(det: ?*ErrorDetails, arena: std.mem.Allocator, shim: *Shimmerable) !KvResult {
        _ = det;
        _ = arena;
        _ = shim;
        @panic("TODO: ~parent getKvPairs not yet ported to the new heap");
    }

    fn duplicate(src: *const Object) !*Object {
        const as_dict = src.castToConst(Dictionary);
        const new_obj = try Object.newObjectUninitialized(Dictionary);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj.head);
        errdefer new_obj.head.invalidateString();

        const new_items = try heap.global_gpa.alloc(Value, as_dict.capacity);
        for (as_dict.items, new_items[0..as_dict.items.len]) |item, *new_item| {
            new_item.* = item.borrow();
        }
        errdefer for (new_items) |item| item.release();

        new_obj.body.* = .{
            .items = new_items[0..as_dict.items.len],
            .capacity = as_dict.capacity,
            .table = try generateTable(new_items[0..as_dict.items.len], as_dict.capacity),
        };

        return new_obj.head;
    }

    fn freeInternalRep(obj: *Object) void {
        const as_dict = obj.castTo(Dictionary);
        for (as_dict.items) |item| item.release();
        heap.global_gpa.free(as_dict.backingSlice());
        as_dict.table.deinit(heap.global_gpa);
    }

    fn makeCrossthread(obj: *Object) void {
        const as_dict = obj.castTo(Dictionary);
        for (as_dict.items) |item| item.makeCrossthread();
    }

    fn updateString(obj: *Object) !void {
        const as_dict = obj.castTo(Dictionary);
        const bytes = try quoteValues(heap.global_gpa, as_dict.items);
        try obj.setStringConsuming(bytes);
    }

    fn enumerateStruct(obj: *const Object, ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const list = obj.castToConst(Dictionary);
        if (list.items.len == 0) return;

        const items_info: StructIterator.NodeInfo = .{
            .node = @ptrCast(list.items.ptr),
            .parent_info = info,
            .enumerate_struct = null, // `[]Value` has no walking function.
            .type_name = @typeName([]Value),
            .as_string = null,
        };
        try ctx.vtable.visit_node(ctx, &items_info, "items");

        const items_helper: ChildWalkHelper = .{ .ctx = ctx, .info = &items_info };
        for (list.items) |item| try items_helper.followValue("items", item);
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .free_internal_rep = freeInternalRep,
        .update_string = updateString,
        .make_crossthread = makeCrossthread,
        .enumerate_struct = enumerateStruct,
        .name = "dict",
    };
};

fn testDicts(ta: std.mem.Allocator) !void {
    try heap.testStart(ta, testing.io);
    defer heap.testFinish();

    var det: ErrorDetails = undefined;

    const key_foo = try String.newValue("foo");
    defer key_foo.release();
    const value1 = try String.newValue("1");
    defer value1.release();
    const key_bar = try String.newValue("bar");
    defer key_bar.release();
    const value2 = try String.newValue("2");
    defer value2.release();

    const dict1 = try Dictionary.new(&.{ key_foo, value1, key_bar, value2 });
    defer dict1.asHead().release();

    const good_key = try String.newValue("foo");
    defer good_key.release();
    const bad_key = try String.newValue("bogus");
    defer bad_key.release();

    try testing.expectEqualStrings("1", try (try dict1.get(good_key)).asValue().?.getString());
    try testing.expectEqual(OptionalValue.none, try dict1.get(bad_key));

    // Dict with duplicate entries.
    var dup_wb: Mutable = .{ .original = try String.newValue("foo 5 bar 10 foo 15") };
    defer dup_wb.deinit();
    const dup_dict = try Dictionary.shimmerFrom(&det, dup_wb.asShimmerable());
    try testing.expectEqual(@as(usize, 3), dup_dict.items.len / 2);
    // A duplicate key maps to its last value.
    try testing.expectEqualStrings("15", try (try dup_dict.get(key_foo)).asValue().?.getString());

    const as_dict = try Dictionary.shimmerFrom(null, dup_wb.asShimmerable());
    _ = Dictionary.removeDuplicates(as_dict, null);
    try testing.expectEqual(@as(usize, 2), as_dict.items.len / 2);

    // Dict put.
    const dict_for_put = try Dictionary.new(&.{ key_foo, value1, key_bar, value2 });
    defer dict_for_put.asHead().release();
    const key3 = try String.newValue("baz");
    defer key3.release();
    const value3 = try String.newValue("3");
    defer value3.release();

    var put_wb: Mutable = .{ .original = dict_for_put.asHead().asValue() };
    defer put_wb.discardChanges();
    try testing.expectEqual(@as(usize, 2), put_wb.current().asType(Dictionary).?.items.len / 2);
    // Replace an existing key's value; pair count stays the same.
    _ = try Dictionary.put(null, &put_wb, key_bar, value3.borrow());
    try testing.expectEqual(@as(usize, 2), put_wb.current().asType(Dictionary).?.items.len / 2);
    // Add a new key; pair count grows.
    _ = try Dictionary.put(null, &put_wb, key3, value3.borrow());
    try testing.expectEqual(@as(usize, 3), put_wb.current().asType(Dictionary).?.items.len / 2);
    try testing.expectEqualStrings(
        "3",
        try (try put_wb.current().asType(Dictionary).?.get(key3)).asValue().?.getString(),
    );

    // Dict remove. Tcl removes all matching keys, so both "foo" pairs go.
    var remove_wb: Mutable = .{
        .original = (try Dictionary.new(&.{ key_foo, value1, key_bar, value2, key_foo, value3 })).asHead().asValue(),
    };
    defer remove_wb.deinit();
    try testing.expect(try Dictionary.remove(null, &remove_wb, key_foo));
    try testing.expectEqualStrings("bar 2", try remove_wb.current().getString());

    // Edge cases: using internal objects as keys and values.
    const edge_dict = try Dictionary.new(&.{ key_foo, value1, key_bar, value2 });
    defer edge_dict.asHead().release();
    var edge_wb: Mutable = .{ .original = edge_dict.asHead().asValue() };
    defer edge_wb.discardChanges();

    // Use a value as a key, and a key as the value.
    {
        const cur = edge_wb.current().asType(Dictionary).?;
        _ = try Dictionary.put(null, &edge_wb, cur.items[1], cur.items[2].borrow());
    }
    try testing.expectEqualStrings(
        "bar",
        try (try edge_wb.current().asType(Dictionary).?.get(value1)).asValue().?.getString(),
    );

    // Alias a key by using it as both key and value.
    {
        const cur = edge_wb.current().asType(Dictionary).?;
        _ = try Dictionary.put(null, &edge_wb, cur.items[0], cur.items[0].borrow());
    }
    try testing.expectEqualStrings(
        "foo",
        try (try edge_wb.current().asType(Dictionary).?.get(key_foo)).asValue().?.getString(),
    );

    // Alias a value by using it as both key and value.
    {
        const cur = edge_wb.current().asType(Dictionary).?;
        _ = try Dictionary.put(null, &edge_wb, cur.items[3], cur.items[3].borrow());
    }
    try testing.expectEqualStrings(
        "2",
        try (try edge_wb.current().asType(Dictionary).?.get(value2)).asValue().?.getString(),
    );
}

test "dicts" {
    try testing.checkAllAllocationFailures(testing.allocator, testDicts, .{});
}

fn testRecursiveDicts(ta: std.mem.Allocator) !void {
    try heap.testStart(ta, testing.io);
    defer heap.testFinish();

    const key_foo = try String.newValue("foo");
    defer key_foo.release();
    const key_bar = try String.newValue("bar");
    defer key_bar.release();
    const key_baz = try String.newValue("baz");
    defer key_baz.release();
    const key_qux = try String.newValue("qux");
    defer key_qux.release();
    const bad_key = try String.newValue("bogus");
    defer bad_key.release();
    const value2 = try String.newValue("2");
    defer value2.release();
    const value3 = try String.newValue("3");
    defer value3.release();

    // Build {foo {bar 2}} as a nested dict.
    const inner_dict = try Dictionary.new(&.{ key_bar, value2 });
    defer inner_dict.asHead().release();
    const outer_dict = try Dictionary.new(&.{ key_foo, inner_dict.asHead().asValue() });
    var rec_wb: Mutable = .{ .original = outer_dict.asHead().asValue() };
    defer rec_wb.deinit();

    // getRecursively walks a {b 2} and reads b.
    const path_foo_bar = ValueSliceContext{ .items = &.{ key_foo, key_bar } };
    try testing.expectEqualStrings(
        "2",
        try (try Dictionary.getRecursively(null, rec_wb.asShimmerable(), path_foo_bar)).asValue().?.getString(),
    );

    // A missing leaf, and a missing top-level key, both yield none.
    const path_foo_bogus = ValueSliceContext{ .items = &.{ key_foo, bad_key } };
    try testing.expectEqual(OptionalValue.none, try Dictionary.getRecursively(null, rec_wb.asShimmerable(), path_foo_bogus));
    const path_bogus = ValueSliceContext{ .items = &.{bad_key} };
    try testing.expectEqual(OptionalValue.none, try Dictionary.getRecursively(null, rec_wb.asShimmerable(), path_bogus));

    // putRecursively into an existing nested key creates a new leaf beside the old one.
    const path_foo_baz = ValueSliceContext{ .items = &.{ key_foo, key_baz } };
    _ = try Dictionary.putRecursively(null, &rec_wb, path_foo_baz, value3.borrow());
    try testing.expectEqualStrings(
        "3",
        try (try Dictionary.getRecursively(null, rec_wb.asShimmerable(), path_foo_baz)).asValue().?.getString(),
    );
    // The pre-existing sibling is untouched.
    try testing.expectEqualStrings(
        "2",
        try (try Dictionary.getRecursively(null, rec_wb.asShimmerable(), path_foo_bar)).asValue().?.getString(),
    );

    // putRecursively creating a wholly new child dict at a fresh top-level key.
    const path_qux_baz = ValueSliceContext{ .items = &.{ key_qux, key_baz } };
    _ = try Dictionary.putRecursively(null, &rec_wb, path_qux_baz, value3.borrow());
    try testing.expectEqualStrings(
        "3",
        try (try Dictionary.getRecursively(null, rec_wb.asShimmerable(), path_qux_baz)).asValue().?.getString(),
    );

    // removeRecursively drops the nested leaf.
    try testing.expect(try Dictionary.removeRecursively(null, &rec_wb, path_foo_bar));
    try testing.expectEqual(OptionalValue.none, try Dictionary.getRecursively(null, rec_wb.asShimmerable(), path_foo_bar));

    // removeRecursively on a missing intermediate key errors. With no `det`, the
    // error path does no allocation, so this is deterministic under OOM injection.
    const path_bogus_baz = ValueSliceContext{ .items = &.{ bad_key, key_baz } };
    try testing.expectError(error.PathNonexistent, Dictionary.removeRecursively(null, &rec_wb, path_bogus_baz));
}

test "dict recursive" {
    try testing.checkAllAllocationFailures(testing.allocator, testRecursiveDicts, .{});
}

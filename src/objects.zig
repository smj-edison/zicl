const std = @import("std");
const math = std.math;
const testing = std.testing;
const mem = std.mem;
const assert = std.debug.assert;

const pcre2 = @import("pcre2");

const ioutil = @import("ioutil.zig");
const strutil = @import("strutil.zig");
const memutil = @import("memutil.zig");
const StructIterator = memutil.StructIterator;
const heap = @import("heap.zig");
const leak_check = @import("leak_check.zig");
const hashutil = heap.hashutil;
const Value = heap.Value;
const OptionalValue = heap.OptionalValue;
const Object = heap.Object;
const Tokenizer = @import("Tokenizer.zig");
// const expr_parse = @import("expr_parse.zig");

pub const interned_tilde_parent = heap.createInternedString("~parent");

pub const ErrorDetails = struct {
    message: [:0]u8,
    index: ?u32 = null,
};

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

    pub fn ensureShimmerable(self: *Shimmerable) error{OutOfMemory}!void {
        switch (self.current().expandedValue()) {
            .ptr => |ptr| if (!ptr.canShimmer()) self.shimmered.swap((try ptr.duplicate()).asValue()),
            else => self.shimmered.swap((try self.current().box()).asValue()),
        }
    }

    pub fn prepareToShimmer(self: *Shimmerable) !*Object {
        try self.ensureShimmerable();

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

    pub fn getMutable(self: *Shimmerable, T: type, det: ?*ErrorDetails) !*T {
        _ = try T.shimmerFrom(det, self);

        // Even if `original` or `shimmered` can mutate due to their ref count
        // being 1, we've been tasked with making sure this object doesn't
        // mutate, since the purpose of `Shimmer` is to ensure that we only ever
        // write back something that has the same string (or will have the same
        // string when generated).
        if (self.shimmered.asValue()) |value| {
            if (value.canMutate()) {
                self.shimmered = .none;
                return value.asType(T).?;
            }
        }

        return (try self.current().duplicate()).asType(T).?;
    }
};

/// `T` must never mutate after this point, but it can shimmer.
pub fn AlwaysCanBeType(T: type) type {
    return struct {
        const Self = @This();

        inner: *Object,

        pub fn init(value: *T) Self {
            return .{ .inner = Object.from(T, value).borrow() };
        }

        pub fn initOwning(value: *T) Self {
            return .{ .inner = Object.from(T, value) };
        }

        pub fn deinit(self: *Self) void {
            self.inner.release();
            self.* = undefined;
        }

        pub fn duplicate(self: *const Self) Self {
            self.inner.incrRefCount();
            return self.*;
        }

        pub fn get(self: *Self) error{OutOfMemory}!*const T {
            var shim: Shimmerable = .{ .original = self.inner.asValue() };
            const result: *const T = T.shimmerFrom(null, &shim) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => unreachable,
            };
            if (shim.shimmered.asValue()) |val| {
                // Got a new value, probably since `inner` became crossthread.
                if (val.asPtr()) |obj| Object.swap(&self.inner, obj);
                // If `shim.shimmered` is a primitive, we can safely drop it.
            }
            return result;
        }

        pub fn getMutable(self: *Self) error{OutOfMemory}!*T {
            if (self.inner.canMutate()) {
                // Since we own it, we know it should never have changed types.
                return self.inner.castTo(T);
            } else {
                const duped = try self.inner.duplicate();
                errdefer duped.release();
                var shim: Shimmerable = .{ .original = duped.asValue() };
                defer shim.discardChanges();

                // Duplicated objects may not always have the same type, so we
                // need to shimmer it to the type the caller is expecting.
                _ = T.shimmerFrom(null, &shim) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => unreachable,
                };

                if (shim.shimmered.asValue()) |val| if (val.asPtr()) |obj| Object.swap(&self.inner, obj);

                assert(self.inner.canMutate());
                return self.inner.castTo(T);
            }
        }
    };
}

/// Helpers to work with struct iteration, used for walking the heap if a leak occured.
pub const IterHelper = struct {
    ctx: StructIterator,
    info: *const StructIterator.NodeInfo,

    pub fn follow(helper: *const IterHelper, T: type, field_name: []const u8, ptr: *const T) StructIterator.Error!void {
        if (@hasDecl(T, "vtable") and @TypeOf(T.vtable) == Object.VTable)
            @compileError("Can't follow an object body directly, follow its *Object instead.");
        try helper.ctx.followNode(T, helper.info, field_name, ptr);
    }

    pub fn followOptional(helper: *const IterHelper, T: type, field_name: []const u8, ptr: ?*const T) StructIterator.Error!void {
        if (ptr) |val| try helper.ctx.followNode(T, helper.info, field_name, val);
    }

    fn followValueInner(
        ctx: StructIterator,
        info: *const StructIterator.NodeInfo,
        field_name: []const u8,
        value: Value,
    ) StructIterator.Error!void {
        if (value.asPtr()) |obj| {
            try ctx.followNode(Object, info, field_name, obj);
        } else {
            var buf: [350]u8 = undefined;
            const str = value.getStringWithBuffer(&buf) catch unreachable;
            try ctx.addFieldString(Value, info, field_name, str);
        }
    }

    pub fn followValue(helper: *const IterHelper, field_name: []const u8, value: Value) StructIterator.Error!void {
        try followValueInner(helper.ctx, helper.info, field_name, value);
    }

    pub fn followValueSlice(helper: *const IterHelper, field_name: []const u8, values: []const Value) StructIterator.Error!void {
        const items_info: StructIterator.NodeInfo = .{
            .node = @ptrCast(values.ptr),
            .parent_info = helper.info,
            .enumerate_struct = null, // `[]Value` has no walking function.
            .type_name = @typeName([]Value),
            .as_string = null,
        };
        try helper.ctx.vtable.visit_node(helper.ctx, &items_info, field_name);

        for (values, 0..) |item, i| {
            const rendered_index = try std.fmt.allocPrint(helper.ctx.arena, "{}", .{i});
            try followValueInner(helper.ctx, &items_info, rendered_index, item);
        }
    }

    pub fn followOptionalValue(
        helper: *const IterHelper,
        field_name: []const u8,
        optional: OptionalValue,
    ) StructIterator.Error!void {
        if (optional.asValue()) |val| try helper.followValue(field_name, val);
    }

    pub fn addField(
        helper: *const IterHelper,
        T: type,
        edge_coming_from: []const u8,
        comptime fmt: []const u8,
        val: T,
    ) StructIterator.Error!void {
        try helper.ctx.addField(T, helper.info, edge_coming_from, fmt, val);
    }
};

pub fn allocPrintZ(comptime fmt: []const u8, args: anytype) error{OutOfMemory}![:0]u8 {
    return try std.fmt.allocPrintSentinel(heap.global_gpa, fmt, args, 0);
}

pub const None = struct {
    pub fn new(bytes: [:0]const u8) !*None {
        const new_obj = try Object.newObjectUninitialized(None);
        errdefer new_obj.head.freeBacking();
        const duped = try heap.global_gpa.dupeSentinel(u8, bytes, 0);
        errdefer heap.global_gpa.free(duped);
        try new_obj.head.setStringLocalObject(duped);

        return new_obj.body;
    }

    pub fn asHead(self: *None) *Object {
        return Object.from(None, self);
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
        .name = @typeName(None),
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

    /// Frees `bytes` in error cases.
    pub fn newOwning(bytes: [:0]u8) !*String {
        errdefer heap.global_gpa.free(bytes);

        return try newOwningNoFree(bytes);
    }

    pub fn newOwningNoFree(bytes: [:0]u8) !*String {
        const new_obj = try Object.newObjectUninitialized(String);
        errdefer new_obj.head.freeBacking();
        try new_obj.head.setStringLocalObject(bytes);

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
        // Unescaped will be equal or shorter than escaped version (including null).
        var unescaped = try heap.global_gpa.alloc(u8, escaped.len + 1);
        errdefer heap.global_gpa.free(unescaped);
        const written = strutil.removeEscaping(escaped, unescaped);

        unescaped = try heap.global_gpa.realloc(unescaped, written + 1);
        unescaped[written] = 0x00;

        return try newOwningNoFree(unescaped[0..written :0]);
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
        _ = try String.shimmerFrom(null, shim);
        const as_str = shim.current().asType(String).?; // Get non-const pointer to the String.

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

    pub fn shimmerFrom(det: ?*ErrorDetails, shim: *Shimmerable) !*const String {
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

        new_obj.body.codepoint_length = .init(src.constCastTo(String).codepoint_length.load(.monotonic));

        return new_obj.head;
    }

    fn enumerateStruct(obj: *const Object, ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const string = obj.constCastTo(String);
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

pub const Source = struct {
    file_name: OptionalValue,
    line_no: u32,
    hash: std.atomic.Value(?*u256),

    pub fn new(bytes: []const u8, file_name: OptionalValue, line: u32) !*Source {
        const obj = try String.newObject(bytes);

        obj.vtable = &vtable;
        const as_source = obj.castTo(Source);
        as_source.* = .{
            .file_name = file_name.borrow(),
            .line_no = line,
            .hash = .init(null),
        };

        return as_source;
    }

    pub fn newFromEscaped(escaped: []const u8, file_name: OptionalValue, line: u32) !*Source {
        const obj = (try String.newFromEscaped(escaped)).asHead();

        obj.vtable = &vtable;
        const as_source = obj.castTo(Source);
        as_source.* = .{
            .file_name = file_name.borrow(),
            .line_no = line,
            .hash = .init(null),
        };

        return as_source;
    }

    pub fn asHead(self: *Source) *Object {
        return Object.from(Source, self);
    }

    fn duplicate(src: *const Object) !*Object {
        const new_obj = try Object.newObjectUninitialized(Source);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj.head);

        const cast_src = src.constCastTo(Source);
        new_obj.body.file_name = cast_src.file_name.borrow();
        new_obj.body.line_no = cast_src.line_no;

        return new_obj.head;
    }

    fn freeInternalRep(obj: *Object) void {
        const as_source = obj.castTo(Source);
        as_source.file_name.release();
        if (as_source.hash.load(.acquire)) |hash_ptr| heap.global_gpa.destroy(hash_ptr);
    }

    fn makeCrossthread(obj: *Object) void {
        obj.castTo(Source).file_name.makeCrossthread();
    }

    fn enumerateStruct(obj: *const Object, ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const source = obj.constCastTo(Source);
        const helper: IterHelper = .{ .ctx = ctx, .info = info };
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

pub const HashReference = struct {
    /// This is of type `*ObjectType` instead of `Value`, because a
    /// hash reference can only ever point to a heap `Object`.
    ref: *Object,

    pub fn new(referent: *Object) !*HashReference {
        const new_obj = try Object.newObject(HashReference);
        new_obj.body.* = .{ .ref = referent.borrow() };
        return new_obj.body;
    }

    pub fn shimmerFrom(det: ?*ErrorDetails, shim: *Shimmerable) !*const HashReference {
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
        const target = heap.registered_hashes.getAndBorrow(hash) orelse {
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
        as_hash_ref.* = .{ .ref = target };
        return as_hash_ref;
    }

    /// Helper function, as hash references are often resolved to dictionaries.
    pub fn resolveAsDictionary(det: ?*ErrorDetails, shim: *Shimmerable) error{ LinkLookupFailed, OutOfMemory }!*const Dictionary {
        const as_hash_ref = shimmerFrom(det, shim) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.LinkLookupFailed,
        };
        const resolved = as_hash_ref.ref;
        var resolved_shim: Shimmerable = .{ .original = resolved.asValue() };
        defer resolved_shim.discardChanges();
        const dict = Dictionary.shimmerFrom(det, &resolved_shim) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadDict => return error.LinkLookupFailed,
        };

        if (resolved_shim.shimmered.asValue()) |new_dict| {
            shim.shimmered.swap((try new(new_dict.asPtr().?)).asHead().asValue());
        }

        return dict;
    }

    pub fn asHead(self: *HashReference) *Object {
        return Object.from(HashReference, self);
    }

    fn duplicate(src: *const Object) !*Object {
        const new_obj = try Object.newObject(HashReference);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj.head);
        errdefer new_obj.head.invalidateString();

        new_obj.body.ref = src.constCastTo(HashReference).ref.borrow();

        return new_obj.head;
    }

    fn freeInternalRep(obj: *Object) void {
        const as_hash_ref = obj.castTo(HashReference);
        as_hash_ref.ref.release();
    }

    fn updateString(obj: *Object) !void {
        const as_hash_ref = obj.castTo(HashReference);
        const target_hash = try as_hash_ref.ref.getHashRegistering();
        var encoded: [hashutil.hash_and_prepend_len]u8 = undefined;
        _ = hashutil.hash_encoder.encode(encoded[hashutil.hash_prepend.len..], &@as([32]u8, @bitCast(target_hash)));
        @memcpy(encoded[0..hashutil.hash_prepend.len], hashutil.hash_prepend);
        try obj.setStringDuplicatingIgnoreRace(&encoded);
    }

    fn enumerateStruct(obj: *const Object, ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const hash_ref = obj.constCastTo(HashReference);
        const helper: IterHelper = .{ .ctx = ctx, .info = info };
        try helper.follow(Object, "ref", hash_ref.ref);
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .update_string = updateString,
        .free_internal_rep = freeInternalRep,
        .make_crossthread = null,
        .enumerate_struct = enumerateStruct,
        .name = @typeName(HashReference),
    };
};

pub const Regexp = struct {
    regexp: *pcre2.pcre2_code_8,

    fn freeInternalRep(obj: *Object) void {
        const as_regexp = obj.castTo(Regexp);
        pcre2.pcre2_code_free_8(as_regexp.regexp);
    }

    fn enumerateStruct(obj: *const Object, ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const regexp = obj.constCastTo(Regexp);
        ctx.followNode(pcre2.pcre2_code_8, info, "regexp", regexp.regexp);
    }

    pub const vtable: Object.VTable = .{
        .duplicate = Object.duplicateStringOnly,
        .update_string = null,
        .free_internal_rep = freeInternalRep,
        .make_crossthread = null,
        .enumerate_struct = enumerateStruct,
        .name = @typeName(Regexp),
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
                "bad index \"{s}\": must be intexpr or end?[+-]intexpr?",
                .{bytes},
                0,
            ),
        };

        return error.BadIndex;
    }

    pub fn shimmerFrom(det: ?*ErrorDetails, shim: *Shimmerable) !*const Index {
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
        // Fast case: if it's an integer, we can quickly cast it (don't
        // shimmer though, as it'll probably still be used for its
        // original purpose).

        switch (shim.current().expandedValue()) {
            .inline_int => |int| {
                return .{ .index = int, .is_relative = false };
            },
            else => return (try shimmerFrom(det, shim)).*,
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

        const as_index = src.constCastTo(Index);
        new_obj.body.index = as_index.index;
        new_obj.body.is_relative = as_index.is_relative;

        return new_obj.head;
    }

    fn updateString(obj: *Object) !void {
        const as_index = obj.castTo(Index);
        const bytes = blk: {
            if (as_index.is_relative) {
                const sign = if (as_index.index >= 0) "+" else "";
                break :blk try std.fmt.allocPrintSentinel(heap.global_gpa, "end{s}{}", .{ sign, as_index.index }, 0);
            } else {
                break :blk try std.fmt.allocPrintSentinel(heap.global_gpa, "{}", .{as_index.index}, 0);
            }
        };
        try obj.setStringIgnoreRace(bytes);
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .free_internal_rep = null,
        .update_string = updateString,
        .make_crossthread = null,
        .enumerate_struct = null,
        .name = @typeName(Index),
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

    pub fn asHead(self: *Float) *Object {
        return Object.from(Float, self);
    }

    pub fn newBoxed(value: f64) !*Float {
        const new_obj = try Object.newObject(Float);
        new_obj.body.value = value;
        return new_obj.body;
    }

    pub fn asFloat(value: Value) ?f64 {
        if (value.asInlineFloat()) |float| return float;
        if (value.asType(Float)) |float| return float.value;
        return null;
    }

    pub fn parse(det: ?*ErrorDetails, bytes: []const u8) !f64 {
        if (std.fmt.parseFloat(f64, bytes)) |parsed| {
            return parsed;
        } else |_| {
            if (det) |details| details.* = .{
                .message = try allocPrintZ("expected float but got \"{s}\"", .{bytes}),
            };
            return error.BadFloat;
        }
    }

    pub fn shimmer(det: ?*ErrorDetails, shim: *Shimmerable) !void {
        if (shim.current().asInlineFloat() != null) return;
        if (shim.current().asType(Float) != null) return;

        const bytes = try shim.current().getString();
        const parsed = try parse(det, bytes);

        // Compare the original input string to the regenerated string, and
        // if identical, shimmer to an inline float value. This is because
        // float parsing is not bijective, since something like "1e3" and
        // "1000.0" will both generate 1000.0.
        var buf: [350]u8 = undefined;
        const regenerated = renderFloat(parsed, &buf);

        if (mem.eql(u8, bytes, regenerated)) {
            // The two strings are identical, so we can use a float value.
            shim.shimmered.swap(Value.newFloat(parsed));
            return;
        }

        const obj = try shim.prepareToShimmer();
        obj.vtable = &vtable;
        obj.castTo(Float).* = .{ .value = parsed };
    }

    pub fn get(det: ?*ErrorDetails, shim: *Shimmerable) !f64 {
        try shimmer(det, shim);

        if (shim.current().asInlineFloat()) |float| return float;
        if (shim.current().asType(Float)) |boxed| return boxed.value;
        unreachable;
    }

    fn updateString(obj: *Object) !void {
        const as_float = obj.castTo(Float);
        const bytes = try std.fmt.allocPrintSentinel(heap.global_gpa, "{}", .{as_float.value}, 0);
        try obj.setStringIgnoreRace(bytes);
    }

    fn duplicate(src: *const Object) !*Object {
        const new_obj = try Object.newObject(Float);
        errdefer new_obj.head.deinit();
        try src.duplicateHeadOnto(new_obj.head);

        const as_float = src.constCastTo(Float);
        new_obj.body.value = as_float.value;

        return new_obj.head;
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .free_internal_rep = null,
        .update_string = updateString,
        .make_crossthread = null,
        .enumerate_struct = null,
        .name = @typeName(Float),
    };
};

pub const Integer = struct {
    value: i64,

    pub fn new(value: i64) !Value {
        if (value >= math.minInt(i32) and value <= math.maxInt(i32)) {
            return Value.newInt(@intCast(value));
        }
        return (try newBoxed(value)).asHead().asValue();
    }

    pub fn newBoxed(value: i64) !*Integer {
        const new_obj = try Object.newObject(Integer);
        new_obj.body.value = value;
        return new_obj.body;
    }

    pub fn asHead(self: *Integer) *Object {
        return Object.from(Integer, self);
    }

    pub fn asInt(value: Value) ?i64 {
        if (value.asInlineInt()) |val| return val;
        if (value.asType(Integer)) |val| return val.value;
        return null;
    }

    pub fn overflowErrorString(det: ?*ErrorDetails, rendered_int: []const u8) error{ OutOfMemory, IntegerOverflow } {
        if (det) |details| details.* = .{
            .message = try allocPrintZ("integer value \"{s}\" too big to be represented", .{rendered_int}),
        };
        return error.IntegerOverflow;
    }

    pub fn overflowError(IntType: type, det: ?*ErrorDetails, rendered_int: IntType) error{ OutOfMemory, IntegerOverflow } {
        if (det) |details| details.* = .{
            .message = try allocPrintZ("integer value \"{}\" too big to be represented", .{rendered_int}),
        };
        return error.IntegerOverflow;
    }

    pub fn parse(det: ?*ErrorDetails, bytes: []const u8) !i64 {
        if (std.fmt.parseInt(i64, bytes, 0)) |integer| {
            return integer;
        } else |err| switch (err) {
            error.InvalidCharacter => {
                if (det) |details| details.* = .{
                    .message = try allocPrintZ("expected integer but got \"{s}\"", .{bytes}),
                };
                return error.BadInteger;
            },
            error.Overflow => {
                return overflowErrorString(det, bytes);
            },
        }
    }

    pub fn shimmerFrom(det: ?*ErrorDetails, shim: *Shimmerable) !i64 {
        if (asInt(shim.current())) |int| return int;

        const bytes = try shim.current().getString();
        const parsed = try parse(det, bytes);

        if (parsed >= math.minInt(i32) and parsed <= math.maxInt(i32)) {
            // Compare the original input string to the regenerated string, and
            // if identical, shimmer to an inline int value. This is because
            // integer parsing is not bijective, since something like "10" and
            // "0xA" will both generate 10. TODO PERF if we have our own int
            // parser, we could see if it was a normal parse, and bypass the
            // byte comparison.
            var buf: [32]u8 = undefined;
            const regenerated = std.fmt.bufPrint(&buf, "{d}", .{parsed}) catch unreachable;

            if (mem.eql(u8, bytes, regenerated)) {
                // The two strings are identical, so we can use an int value.
                shim.shimmered.swap(Value.newInt(@intCast(parsed)));
            }
            return parsed;
        }

        const obj = try shim.prepareToShimmer();
        obj.vtable = &vtable;
        const as_boxed_int = obj.castTo(Integer);
        as_boxed_int.* = .{ .value = parsed };
        return parsed;
    }

    fn updateString(obj: *Object) !void {
        const bytes = try std.fmt.allocPrintSentinel(heap.global_gpa, "{}", .{obj.castTo(Integer).value}, 0);
        try obj.setStringIgnoreRace(bytes);
    }

    fn duplicate(src: *const Object) !*Object {
        const new_obj = try Object.newObjectUninitialized(Integer);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj.head);

        new_obj.body.value = src.constCastTo(Integer).value;

        return new_obj.head;
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .free_internal_rep = null,
        .update_string = updateString,
        .make_crossthread = null,
        .enumerate_struct = null,
        .name = @typeName(Integer),
    };
};

/// Generic helper functions to deal with numbers.
pub const Number = union(enum) {
    integer: i64,
    float: f64,

    pub const negative_denom_message = heap.createInternedString("negative denominator");
    pub const division_by_zero_message = heap.createInternedString("division by zero");

    pub fn getAsIntOrFloat(det: ?*ErrorDetails, shim: *Shimmerable) !Number {
        if (Integer.asInt(shim.current())) |int| return .{ .integer = int };
        if (shim.current().asInlineFloat()) |float| return .{ .float = float };

        const as_int = Integer.shimmerFrom(null, shim) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .float = try Float.shimmer(det, shim) },
        };
        return .{ .integer = as_int };
    }

    pub fn asInt(number: Number) ?i64 {
        return switch (number) {
            .integer => |int| int,
            else => null,
        };
    }

    pub fn asFloat(number: Number) f64 {
        return switch (number) {
            .float => |float| float,
            .integer => |int| @floatFromInt(int),
        };
    }
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

        pub fn shimmerFrom(det: ?*ErrorDetails, shim: *Shimmerable) !*const Self {
            if (shim.current().asType(Self)) |self| return self;

            const bytes = try shim.current().getString();
            if (map.get(bytes)) |variant| {
                const obj = try shim.prepareToShimmer();
                obj.vtable = &vtable;
                const self = obj.castTo(Self);
                self.variant = variant;
                return self;
            } else {
                if (det) |details| details.* = .{
                    .message = try allocPrintZ("bad {s} \"{s}\": must be {s}", .{ enum_name, bytes, names }),
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

            new_obj.body.variant = src.constCastTo(Self).variant;

            return new_obj.head;
        }

        pub const vtable: Object.VTable = .{
            .duplicate = duplicate,
            .free_internal_rep = null,
            .update_string = null,
            .make_crossthread = null,
            .enumerate_struct = null,
            .name = @typeName(Self),
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
                    .message = try allocPrintZ(
                        \\wrong # args: should be "{s} command ..."
                        \\Use "{s} -help ?command?" for help
                    , .{ bytes, bytes }),
                };
                return error.WrongUsage;
            }

            if (try args[1].current().equalsString("-help")) {
                if (args.len >= 3) {
                    const subcommand_queried = &args[2];

                    // Generate help for a specific subcommand, if the subcommand exists.
                    if (NameToEnum.get(null, subcommand_queried)) |val| {
                        const subcommand = EnumToSubcommand.get(val);
                        if (det) |details| details.* = .{ .message = try allocPrintZ(
                            "Usage: \"{s} {s} {s}\"",
                            .{
                                try args[0].current().getString(),
                                try subcommand_queried.current().getString(),
                                subcommand.usage,
                            },
                        ) };
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
                    if (det) |details| details.* = .{ .message = try allocPrintZ(
                        "{s}, unknown command \"{s}\": should be {s}",
                        .{
                            try args[0].current().getString(),
                            try args[1].current().getString(),
                            space_joined_names,
                        },
                    ) };
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
                    .message = try allocPrintZ("wrong # args: should be \"{s}\"", .{subcommand.usage}),
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

/// `Boolean` is a namespace of helpers, not a heap object type. Bools are
/// bijective with their canonical string rep ("true"/"false"), so they live
/// entirely inline as the `.true`/`.false` `Value` tags -- there is never a
/// reason to box one. When a bool primitive needs an `*Object` handle (to
/// shimmer to another type), `Value.box` boxes it as a `String` instead. The
/// functions below parse and produce inline bool values.
pub const Boolean = struct {
    pub fn new(value: bool) Value {
        return Value.newBool(value);
    }

    pub fn fromString(det: ?*ErrorDetails, bytes: []const u8) !bool {
        if (std.mem.eql(u8, bytes, "true")) {
            return true;
        } else if (std.mem.eql(u8, bytes, "false")) {
            return false;
        }

        if (det) |details| details.* = .{
            .message = try allocPrintZ("expected boolean but got \"{s}\"", .{bytes}),
        };
        return error.BadBoolean;
    }

    pub fn getFromValue(det: ?*ErrorDetails, value: Value) !Value {
        return try fromString(det, try value.getString());
    }

    pub fn shimmerFrom(det: ?*ErrorDetails, shim: *Shimmerable) !bool {
        const as_bool = try fromString(det, try shim.current().getString());
        shim.shimmered.swap(Value.newBool(as_bool));
        return as_bool;
    }
};

fn quoteValues(gpa: std.mem.Allocator, items: []const Value) ![:0]u8 {
    var fallback = std.heap.stackFallback(64, gpa);
    // `stackFallback.get()` asserts it's called once, so reuse the stored allocator for both alloc and free.
    const fb = fallback.get();
    var quoting_types = try fb.alloc(strutil.QuotingType, items.len);
    defer fb.free(quoting_types);

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

    /// `list` must be mutable.
    pub fn append(list: *List, value: Value) !void {
        if (list.capacity < list.items.len + 1) try list.ensureCapacity(@max(4, list.capacity * 2));
        list.appendAssumeCapacity(value);
    }

    pub fn appendAssumeCapacity(list: *List, value: Value) void {
        assert(list.asHead().canMutate());

        const old_len = list.items.len;
        list.items = list.backingSlice()[0..(old_len + 1)];
        list.items[old_len] = value.borrow();
    }

    /// `list` must be mutable.
    pub fn set(list: *List, index: usize, value: Value) !void {
        assert(list.asHead().canMutate());
        list.items[index].swap(value);
    }

    /// `list` must be mutable.
    fn ensureCapacity(list: *List, new_capacity: usize) !void {
        assert(list.asHead().canMutate());
        if (new_capacity > list.capacity) {
            const new_backing = try heap.global_gpa.realloc(list.backingSlice(), new_capacity);
            list.items = new_backing[0..list.items.len];
            list.capacity = new_capacity;
        }
    }

    pub fn shimmerFrom(det: ?*ErrorDetails, shim: *Shimmerable) !*const List {
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
                if (det) |details| details.* = .{ .message = try Tokenizer.convertTokenizerError(heap.global_gpa, err) };
                return error.BadList;
            };
            switch (next_token.tag) {
                .simple_string, .escaped_string => {
                    const token_value = bytes[next_token.loc.start..next_token.loc.end];
                    const source = if (next_token.tag == .escaped_string)
                        try Source.newFromEscaped(token_value, file_name.borrow(), line_no)
                    else
                        try Source.new(token_value, file_name.borrow(), line_no);
                    defer source.asHead().release();

                    try new_items.append(heap.global_gpa, source.asHead().asValue());
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

    pub fn asHead(self: *List) *Object {
        return Object.from(List, self);
    }

    fn updateString(obj: *Object) !void {
        const as_list = obj.castTo(List);
        const bytes = try quoteValues(heap.global_gpa, as_list.items);
        try obj.setStringIgnoreRace(bytes);
    }

    fn duplicate(src: *const Object) !*Object {
        const as_list = src.constCastTo(List);
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
        if (obj.metadata.cross_thread) return;
        const as_list = obj.castTo(List);
        for (as_list.items) |item| item.makeCrossthread();
    }

    fn enumerateStruct(obj: *const Object, ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const as_list = obj.constCastTo(List);
        if (as_list.items.len == 0) return;

        const helper: IterHelper = .{ .ctx = ctx, .info = info };
        try helper.followValueSlice("items", as_list.items);
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .free_internal_rep = freeInternalRep,
        .update_string = updateString,
        .make_crossthread = makeCrossthread,
        .enumerate_struct = enumerateStruct,
        .name = @typeName(List),
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

    try list1.append(to_append);
    try testing.expectEqualStrings("appended item", try list1.items[2].getString());

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

        const item_backing = try heap.global_gpa.alloc(Value, capacity);
        errdefer heap.global_gpa.free(item_backing);

        const new_items = item_backing[0..items.len];
        for (items, new_items) |item, *new_item| {
            new_item.* = item.borrow();
        }
        errdefer for (new_items) |item| item.release();

        new_dict.body.* = .{
            .items = new_items,
            .capacity = capacity,
            .table = try generateTable(new_items, capacity),
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

    pub fn shimmerFrom(det: ?*ErrorDetails, shim: *Shimmerable) !*const Dictionary {
        if (shim.current().asType(Dictionary)) |dict| return dict;

        const list = List.shimmerFrom(det, shim) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadList => return error.BadDict,
        };
        // A dict needs an even number of elements.
        if (list.items.len % 2 != 0) {
            if (det) |details| details.* = .{ .message = try allocPrintZ(
                "Missing value to go with key when converting \"{s}\" to a dictionary.",
                .{try shim.current().getString()},
            ) };
            return error.BadDict;
        }

        const table = try generateTable(list.items, list.capacity);

        const old_items = list.items;
        const old_capacity = list.capacity;
        const obj = shim.current().asPtr().?;
        obj.vtable = &vtable;
        const as_dict = obj.castTo(Dictionary);
        as_dict.* = .{
            .items = old_items,
            .capacity = old_capacity,
            .table = table,
        };
        return as_dict;
    }

    pub fn getNoFollow(self: *const Dictionary, key: Value) !OptionalValue {
        if (key.asPtr()) |obj| _ = try obj.getHashNoRegister();
        if (self.table.get(key)) |idx| return self.items[idx].asOptional();
        return .none;
    }

    pub fn getPtrNoFollow(self: *const Dictionary, key: Value) !?*Value {
        if (key.asPtr()) |obj| _ = try obj.getHashNoRegister();
        if (self.table.get(key)) |idx| return &self.items[idx];
        return .none;
    }

    /// `dict` must be mutable.
    pub fn put(dict: *Dictionary, key: Value, value: Value) !usize {
        assert(dict.asHead().canMutate());
        const result = try dict.putInner(key, value, true);
        dict.asHead().invalidateString();
        return result;
    }

    /// Does not invalidate the string. Used in cases where a `put` operation doesn't affect
    /// how the string is generated, such as switching out a shimmered hash reference.
    pub fn putInner(dict: *Dictionary, key: Value, value: Value, remove_duplicates: bool) !usize {
        assert(!dict.asHead().metadata.cross_thread);

        // Ensure the key already has a hash, since the table requires everything used
        // to have a precomputed hash.
        if (key.asPtr()) |obj| _ = try obj.getHashNoRegister();

        if (dict.table.get(key)) |existing_value_index| {
            // Key exists, so replace the value in place.
            const old = dict.items[existing_value_index];
            dict.items[existing_value_index] = value.borrow();
            old.release();

            if (remove_duplicates) {
                const shifted_index = removeDuplicates(dict, existing_value_index).?;
                return shifted_index;
            } else return existing_value_index;
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

            if (remove_duplicates) {
                const shifted_index = removeDuplicates(dict, new_value_index);
                return shifted_index.?;
            } else return new_value_index;
        }
    }

    /// Dict must be shimmerable.
    pub fn resolveParentDict(dict: *Dictionary, det: ?*ErrorDetails) error{ LinkLookupFailed, OutOfMemory }!?*const Dictionary {
        assert(dict.asHead().canShimmer());

        const tilde_parent = interned_tilde_parent.get();
        if ((try dict.getNoFollow(tilde_parent)).asValue()) |hash_ref| {
            var hash_ref_shim: Shimmerable = .{ .original = hash_ref };
            defer hash_ref_shim.discardChanges();
            const parent_dict = try HashReference.resolveAsDictionary(det, &hash_ref_shim);
            if (hash_ref_shim.shimmered.asValue()) |new_hash_ref| {
                _ = try dict.putInner(tilde_parent, new_hash_ref, false);
            }
            return parent_dict;
        }

        return null;
    }

    /// Remove all pairs with key `key`. Returns true if any were removed, and
    /// keeps the table live (clearing and re-putting into the same allocation).
    pub fn remove(dict: *Dictionary, det: ?*ErrorDetails, key: Value) error{ OutOfMemory, LinkLookupFailed }!bool {
        assert(dict.asHead().canMutate());
        if (key.asPtr()) |obj| _ = try obj.getHashNoRegister();

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
        var dict_shim: Shimmerable = .{ .original = dict.asHead().asValue() };
        const in_parent_dict = try getFollowingLinks(det, &dict_shim, key);
        assert(dict_shim.shimmered == .none); // We already checked that `dict` is mutable.

        if (in_parent_dict != .none) {
            // Key was found in the parent, so we do need to flatten.
            dict.flatten(det) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.BadDict, error.NotHashReference, error.HashLookupFailed => return error.LinkLookupFailed,
            };

            // Flattening may change indicies, so we need to rescan for the first key.
            first_key_index = 0;
            while (first_key_index < dict.items.len) : (first_key_index += 2) {
                if (key.equals(dict.items[first_key_index]) catch unreachable) break;
            } else {
                return false; // No matching key.
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

        // Rebuild the table in place. If we use swap removal this would be a
        // lot easier, but I do like having dictionaries preserve their
        // ordering.
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
        assert(dict.asHead().canMutate());

        const orig_len = dict.items.len;
        if (dict.table.count() * 2 == orig_len) return to_track; // No duplicates.

        // Walk from the end into a fresh "seen keys" set, so the first sighting of
        // each key is its canonical (last) pair and earlier ones are duplicates.
        // Reusing the old table would dangle: it stores each key's first occurrence
        // (a duplicate), which a later `get` could probe after we free it. Keys are
        // never mutated, so cross-thread keys still free through their real vtable.
        dict.table.clearRetainingCapacity();

        var to_track_new_location: ?usize = null;
        var new_len: usize = 0;
        var item_index: usize = orig_len;
        while (item_index > 0) {
            item_index -= 2;
            const key = dict.items[item_index];
            const value = dict.items[item_index + 1];
            if (dict.table.contains(key)) {
                // A later pair already claimed this key.
                key.release();
                value.release();
            } else {
                // Canonical. Build the kept region back-to-front.
                new_len += 2;
                const new_key_index = orig_len - new_len;
                dict.items[new_key_index] = key;
                dict.items[new_key_index + 1] = value;
                dict.table.putAssumeCapacity(key, new_key_index + 1);
                if (item_index == to_track) to_track_new_location = new_key_index;
                if (item_index + 1 == to_track) to_track_new_location = new_key_index + 1;
            }
        }

        // Slide the kept region to the front; adjust value indices instead of
        // rebuilding, since stored keys survive the slide.
        const shift = orig_len - new_len;
        if (shift > 0) {
            std.mem.copyForwards(Value, dict.items[0..new_len], dict.items[shift..orig_len]);
            if (to_track_new_location) |loc| to_track_new_location = loc - shift;
            var table_iter = dict.table.valueIterator();
            while (table_iter.next()) |entry| entry.* -= shift;
        }
        dict.items.len = new_len;

        return to_track_new_location;
    }

    pub fn flatten(dict: *Dictionary, det: ?*ErrorDetails) !void {
        assert(dict.asHead().canMutate());
        if (try dict.flattenInner(det)) |new_dict| {
            // Steal the values from `new_dict` directly.
            freeInternalRep(dict.asHead());
            dict.* = .{
                .items = new_dict.items,
                .capacity = new_dict.capacity,
                .table = new_dict.table,
            };
            new_dict.asHead().freeBacking();
            dict.asHead().invalidateString();
        }
    }

    /// Remove all links from a dict and combine them into one dict.
    pub fn flattenInner(dict: *const Dictionary, det: ?*ErrorDetails) !?*Dictionary {
        if ((try dict.getNoFollow(interned_tilde_parent.get())).asValue()) |parent_hash_ref| {
            var parent_hash_ref_shim: Shimmerable = .{ .original = parent_hash_ref };
            defer parent_hash_ref_shim.discardChanges();
            const parent = (try HashReference.shimmerFrom(det, &parent_hash_ref_shim)).ref; // Resolve to value of hash.
            var parent_shim: Shimmerable = .{ .original = parent.asValue() };
            defer parent_shim.discardChanges();
            const parent_as_dict = try shimmerFrom(det, &parent_shim);

            const new_dict = try parent_as_dict.flattenInner(det);
            const to_add_to = if (new_dict) |val| val else (try parent_shim.current().duplicate()).asType(Dictionary).?;
            errdefer to_add_to.asHead().release();

            var pair_index: u32 = 0;
            while (pair_index < dict.items.len) : (pair_index += 2) {
                if (try dict.items[pair_index].equalsString("~parent")) continue;
                _ = try to_add_to.put(dict.items[pair_index], dict.items[pair_index + 1]);
            }

            return to_add_to;
        } else {
            return null; // We've reached the end, so no need to flatten.
        }
    }

    pub fn getFollowingLinks(det: ?*ErrorDetails, shim: *Shimmerable, key: Value) error{ OutOfMemory, LinkLookupFailed }!OptionalValue {
        if (key.asPtr()) |obj| _ = try obj.getHashNoRegister();

        var dict = shimmerFrom(det, shim) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadDict => return error.LinkLookupFailed,
        };

        // See if it's immediately in this dictionary.
        if ((try dict.getNoFollow(key)).asValue()) |val| return val.asOptional();

        // Wasn't in this dictionary, so check if it's in a parent dict.
        const tilde_parent = interned_tilde_parent.get();
        const parent_dict: ?*const Dictionary = blk: {
            if ((try dict.getNoFollow(tilde_parent)).asValue()) |hash_ref| {
                var hash_ref_shim: Shimmerable = .{ .original = hash_ref };
                defer hash_ref_shim.discardChanges();
                const parent_dict = try HashReference.resolveAsDictionary(det, &hash_ref_shim);
                if (hash_ref_shim.shimmered.asValue()) |new_hash_ref| {
                    try shim.ensureShimmerable();
                    const as_shimmerable_dict = shim.current().asType(Dictionary).?;
                    _ = try as_shimmerable_dict.putInner(tilde_parent, new_hash_ref, false);
                    dict = as_shimmerable_dict;
                }
                break :blk parent_dict;
            } else break :blk null;
        };

        if (parent_dict) |parent| {
            var parent_shim: Shimmerable = .{ .original = @constCast(parent).asHead().asValue() };
            defer parent_shim.discardChanges();
            const looked_up = try getFollowingLinks(det, &parent_shim, key);
            if (parent_shim.shimmered.asValue()) |value| {
                try shim.ensureShimmerable();
                const as_shimmerable_dict = shim.current().asType(Dictionary).?;
                _ = try as_shimmerable_dict.putInner(tilde_parent, value, false);
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
            if (child_shim.shimmered.asValue()) |new_child| {
                try shim.ensureShimmerable();
                // The child dict changed, propagate back up.
                const as_dict = shim.current().asType(Dictionary).?;
                _ = try as_dict.putInner(context.get(0), new_child, false);
            }
            return child_result;
        } else {
            return .none;
        }
    }

    pub fn putRecursively(dict: *Dictionary, det: ?*ErrorDetails, context: anytype, value: Value) !void {
        assert(dict.asHead().canMutate());
        assert(context.len() > 0);

        if (context.len() == 1) {
            _ = try dict.put(context.get(0), value);
            return;
        }

        // Find/create the child dict.
        const child_dict = blk: {
            if ((try dict.getNoFollow(context.get(0))).asValue()) |existing_dict| {
                break :blk existing_dict;
            } else {
                // Create a new child dictionary.
                const new_child_dict = (try new(&.{})).asHead().asValue();
                defer new_child_dict.release();

                _ = try dict.put(context.get(0), new_child_dict);
                break :blk new_child_dict;
            }
        };

        var child_dict_shim: Shimmerable = .{ .original = child_dict };
        _ = try Dictionary.shimmerFrom(det, &child_dict_shim);
        if (child_dict_shim.shimmered == .none and child_dict_shim.original.canMutate()) {
            // Mutate in place, if possible.
            const as_dict = child_dict_shim.original.asType(Dictionary).?;
            try as_dict.putRecursively(det, context.sliceAfter(1), value);
        } else {
            const child_dict_mut = try child_dict_shim.getMutable(Dictionary, det);
            defer child_dict_mut.asHead().release();
            try child_dict_mut.putRecursively(det, context.sliceAfter(1), value);
            _ = try dict.put(context.get(0), child_dict_mut.asHead().asValue());
        }

        dict.asHead().invalidateString();
    }

    pub fn removeRecursively(dict: *Dictionary, det: ?*ErrorDetails, context: anytype) !bool {
        assert(dict.asHead().canMutate());
        assert(context.len() > 0);
        if (context.len() == 1) return try dict.remove(det, context.get(0));

        if ((try dict.getNoFollow(context.get(0))).asValue()) |child_dict| {
            var child_dict_shim: Shimmerable = .{ .original = child_dict };
            _ = try Dictionary.shimmerFrom(det, &child_dict_shim);

            const did_remove = blk: {
                if (child_dict_shim.shimmered == .none and child_dict_shim.original.canMutate()) {
                    // Mutate in place, if possible.
                    const as_dict = child_dict_shim.original.asType(Dictionary).?;
                    break :blk try as_dict.removeRecursively(det, context.sliceAfter(1));
                } else {
                    const child_dict_mut = try child_dict_shim.getMutable(Dictionary, det);
                    defer child_dict_mut.asHead().release();
                    const did_remove = try child_dict_mut.removeRecursively(det, context.sliceAfter(1));
                    _ = try dict.put(context.get(0), child_dict_mut.asHead().asValue());
                    break :blk did_remove;
                }
            };

            dict.asHead().invalidateString();

            return did_remove;
        } else {
            if (det) |details| details.* = .{ .message = try allocPrintZ(
                "key \"{s}\" not known in dictionary \"{s}\"",
                .{ try context.get(0).getString(), try dict.asHead().getString() },
            ) };
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
        const as_dict = src.constCastTo(Dictionary);
        const new_obj = try Object.newObjectUninitialized(Dictionary);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj.head);
        errdefer new_obj.head.invalidateString();

        const item_backing = try heap.global_gpa.alloc(Value, as_dict.capacity);
        errdefer heap.global_gpa.free(item_backing);

        const new_items = item_backing[0..as_dict.items.len];
        for (as_dict.items, new_items) |item, *new_item| {
            new_item.* = item.borrow();
        }
        errdefer for (new_items) |item| item.release();

        new_obj.body.* = .{
            .items = new_items,
            .capacity = as_dict.capacity,
            .table = try generateTable(new_items, as_dict.capacity),
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
        try obj.setStringIgnoreRace(bytes);
    }

    fn enumerateStruct(obj: *const Object, ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const as_dict = obj.constCastTo(Dictionary);
        if (as_dict.items.len == 0) return;

        const helper: IterHelper = .{ .ctx = ctx, .info = info };
        try helper.followValueSlice("items", as_dict.items);
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .free_internal_rep = freeInternalRep,
        .update_string = updateString,
        .make_crossthread = makeCrossthread,
        .enumerate_struct = enumerateStruct,
        .name = @typeName(Dictionary),
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

    try testing.expectEqualStrings("1", try (try dict1.getNoFollow(good_key)).asValue().?.getString());
    try testing.expectEqual(OptionalValue.none, try dict1.getNoFollow(bad_key));

    // Dict with duplicate entries.
    var dup_shim: Shimmerable = .{ .original = try String.newValue("foo 5 bar 10 foo 15") };
    defer dup_shim.deinit();
    const dup_dict = try Dictionary.shimmerFrom(&det, &dup_shim);
    try testing.expectEqual(3, dup_dict.items.len / 2);
    // A duplicate key maps to its last value.
    try testing.expectEqualStrings("15", try (try dup_dict.getNoFollow(key_foo)).asValue().?.getString());

    const as_dict_mut = dup_shim.current().asType(Dictionary).?;
    _ = as_dict_mut.removeDuplicates(null);
    try testing.expectEqual(2, as_dict_mut.items.len / 2);

    // Dict put.
    const dict_for_put = try Dictionary.new(&.{ key_foo, value1, key_bar, value2 });
    defer dict_for_put.asHead().release();
    const key3 = try String.newValue("baz");
    defer key3.release();
    const value3 = try String.newValue("3");
    defer value3.release();

    try testing.expectEqual(2, dict_for_put.items.len / 2);
    // Replace an existing key's value; pair count stays the same.
    // `put` borrows the value into the dict, so the caller retains its handle
    // (released by `defer value3.release()` above) -- no extra `.borrow()` or
    // the call leaks a ref.
    _ = try dict_for_put.put(key_bar, value3);
    try testing.expectEqual(2, dict_for_put.items.len / 2);
    // Add a new key; pair count grows.
    _ = try dict_for_put.put(key3, value3);
    try testing.expectEqual(@as(usize, 3), dict_for_put.items.len / 2);
    try testing.expectEqualStrings("3", try (try dict_for_put.getNoFollow(key3)).asValue().?.getString());

    // Dict remove. Tcl removes all matching keys, so both "foo" pairs go.
    const dict_for_remove = try Dictionary.new(&.{ key_foo, value1, key_bar, value2, key_foo, value3 });
    defer dict_for_remove.asHead().deinit();
    try testing.expect(try dict_for_remove.remove(null, key_foo));
    try testing.expectEqualStrings("bar 2", try dict_for_remove.asHead().getString());

    // Edge cases: using internal objects as keys and values.
    const dict_edge_cases = try Dictionary.new(&.{ key_foo, value1, key_bar, value2 });
    defer dict_edge_cases.asHead().release();

    // Use a value as a key, and a key as the value.
    _ = try dict_edge_cases.put(dict_edge_cases.items[1], dict_edge_cases.items[2]);
    try testing.expectEqualStrings("bar", try (try dict_edge_cases.getNoFollow(value1)).asValue().?.getString());

    // Alias a key by using it as both key and value.
    _ = try dict_edge_cases.put(dict_edge_cases.items[0], dict_edge_cases.items[0]);
    try testing.expectEqualStrings("foo", try (try dict_edge_cases.getNoFollow(key_foo)).asValue().?.getString());

    // Alias a value by using it as both key and value.
    _ = try dict_edge_cases.put(dict_edge_cases.items[3], dict_edge_cases.items[3]);
    try testing.expectEqualStrings("2", try (try dict_edge_cases.getNoFollow(value2)).asValue().?.getString());
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
    defer outer_dict.asHead().release();
    var outer_shim: Shimmerable = .{ .original = outer_dict.asHead().asValue() };
    defer outer_shim.discardChanges();

    // getRecursively walks a {b 2} and reads b.
    const path_foo_bar = ValueSliceContext{ .items = &.{ key_foo, key_bar } };
    try testing.expectEqualStrings(
        "2",
        try (try Dictionary.getRecursively(null, &outer_shim, path_foo_bar)).asValue().?.getString(),
    );

    // A missing leaf, and a missing top-level key, both yield none.
    const path_foo_bogus = ValueSliceContext{ .items = &.{ key_foo, bad_key } };
    try testing.expectEqual(.none, try Dictionary.getRecursively(null, &outer_shim, path_foo_bogus));
    const path_bogus = ValueSliceContext{ .items = &.{bad_key} };
    try testing.expectEqual(.none, try Dictionary.getRecursively(null, &outer_shim, path_bogus));

    // putRecursively into an existing nested key creates a new leaf beside the old one.
    const path_foo_baz = ValueSliceContext{ .items = &.{ key_foo, key_baz } };
    _ = try outer_dict.putRecursively(null, path_foo_baz, value3);
    try testing.expectEqualStrings("3", try (try Dictionary.getRecursively(null, &outer_shim, path_foo_baz)).asValue().?.getString());
    // The pre-existing sibling is untouched.
    try testing.expectEqualStrings("2", try (try Dictionary.getRecursively(null, &outer_shim, path_foo_bar)).asValue().?.getString());

    // putRecursively creating a wholly new child dict at a fresh top-level key.
    const path_qux_baz = ValueSliceContext{ .items = &.{ key_qux, key_baz } };
    _ = try outer_dict.putRecursively(null, path_qux_baz, value3);
    try testing.expectEqualStrings("3", try (try Dictionary.getRecursively(null, &outer_shim, path_qux_baz)).asValue().?.getString());

    // removeRecursively drops the nested leaf.
    try testing.expect(try outer_dict.removeRecursively(null, path_foo_bar));
    try testing.expectEqual(.none, try Dictionary.getRecursively(null, &outer_shim, path_foo_bar));

    // removeRecursively on a missing intermediate key errors.
    const path_bogus_baz = ValueSliceContext{ .items = &.{ bad_key, key_baz } };
    try testing.expectError(error.PathNonexistent, outer_dict.removeRecursively(null, path_bogus_baz));
}

test "dict recursive" {
    try testing.checkAllAllocationFailures(testing.allocator, testRecursiveDicts, .{});
}

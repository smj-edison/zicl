const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const builtin = @import("builtin");
const math = std.math;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const options = @import("options");
const memutil = @import("memutil.zig");
const objutil = @import("objutil.zig");

// Debugging
var result: std.ArrayList(u8) = .empty;
export const ptr_to_result: *std.ArrayList(u8) = &result;

// These numbers are final, and can be depended on to be their current values.
pub const special_string_count = 2;
pub const null_string = 0;
pub const empty_string = 1;
pub const special_object_count = 2;
pub const null_object_idx: u32 = 0;
pub const empty_object_idx: u32 = 1;

pub const HeapSettings = struct {
    /// Maximum of `1 << heap_order` items.
    object_heap_order: u6 = 16,
    /// Maximum of `1 << heap_order` bytes for all strings.
    string_heap_order: u6 = 16,
    /// Maximum number of evaluating scripts.
    max_scripts: usize = 65536,
    /// Maximum number of heaps (not necessarily initialized).
    max_heaps: usize = 128,
    /// Parsed script cache size.
    cache_size: usize = 512,
};
const cfg: HeapSettings = .{};

pub var next_open_heap: usize = 0;
pub var global_gpa: std.mem.Allocator = undefined;
pub var global_io: std.Io = undefined;
pub var heaps: [cfg.max_heaps]Heap = undefined;
pub threadlocal var local_heap: *Heap = undefined;

const Heap = @This();

const object_heap_max_count: usize = @as(usize, 1) << cfg.object_heap_order;
const object_heap_max_bytes: usize = ObjectList.capacityInBytes(object_heap_max_count);
const string_heap_max_bytes: usize = @as(usize, 1) << cfg.string_heap_order;

object_tracking: ObjectTracker,
objects: ObjectList,
string_tracking: StringTracker,
strings: StringList,

/// If an object can't store all its information in 8 bytes, it can throw extra data on here.
extra: ExtraDataPool,

pub const HeapId = u16;

const ObjectTracker = memutil.BuddyUnmanaged(.{
    .max_order = cfg.object_heap_order,
    .max_pool_order = 6,
    .pool_size = 64,
});
const ObjectList = std.MultiArrayList(ObjectAndMetadata);
const StringTracker = memutil.BuddyUnmanaged(.{
    .max_order = cfg.string_heap_order,
    .max_pool_order = 10,
    .pool_size = 64,
});
const StringList = std.ArrayList(u8);

const ExtraDataPool = memutil.IndexedMemoryPool(ExtraDataValue);
const FullHashContext = struct {
    pub fn hash(self: @This(), full_hash: u256) u64 {
        _ = self;
        return @truncate(full_hash);
    }
    pub fn eql(self: @This(), a: u256, b: u256) bool {
        _ = self;
        return a == b;
    }
};

pub const Object = packed struct(u128) {
    pub const null_string: StrOrPtr = .{
        .u = .{ .str = .{ .index = 0, .len = 0 } },
        .is_ptr = false,
    };
    pub const empty_string: StrOrPtr = .{
        .u = .{ .str = .{ .index = 1, .len = 0 } },
        .is_ptr = false,
    };

    pub const StrOrPtr = packed struct(u59) {
        u: packed union {
            str: packed struct {
                index: u32,
                len: u26,
            },
            /// Be sure to >> 6 before setting, and << 6 when reading. Must be non-null.
            /// TODO when/if aligned pointers in packed structs become a thing, switch
            /// over to that system.
            ptr: u58,
        },
        is_ptr: bool,

        pub fn deinit(str: StrOrPtr, heap: *Heap) void {
            switch (heap.getLocalStringDetails(str)) {
                .normal => {
                    heap.freeString(str.u.str.index, str.u.str.len);
                },
                .null, .empty => {},
            }
        }

        pub fn format(self: StrOrPtr, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            assert(!self.is_ptr);
            try writer.print("{}", .{self.u.str});
        }
    };

    pub const Head = packed struct(u64) {
        str: StrOrPtr = Object.null_string,
        tag: Tag,
    };

    head: Head,
    body: Body,

    pub fn deinitSingle(obj: *Object, heap: *Heap) void {
        obj.deinitBodySingle(heap);
        obj.deinitString(heap);
    }

    pub fn deinitString(obj: *Object, heap: *Heap) void {
        obj.head.str.deinit(heap);

        // Be sure to set the null string afterwards (we can directly assign,
        // as we've already checked that we can shimmer).
        obj.head.str = Object.null_string;
    }

    /// Only deinitializes if this is a single object, panics otherwise. Can
    /// be used to deinit a stack-allocated object. `heap` is used to reference
    /// the strings/extra data this object contains.
    pub fn deinitBodySingle(obj: *Object, heap: *Heap) void {
        // Deinit body
        switch (obj.head.tag) {
            .reference => {
                obj.body.reference.decrRefCount();
            },
            .string => {
                // How come string is a no-op? Because the string is separate
                // from its cached length.
            },
            .source => {},
            .cached_lexical_var => {},
            .closure => {},
            .upvar_link => {
                const upvar_link = obj.body.upvar_link;
                heap.getHandle(upvar_link.linked_name).decrRefCount();
            },
            .dict_sugar => {
                const dict_sugar = obj.body.dict_sugar;
                heap.getHandle(dict_sugar.dict_name_index).decrRefCount();
                heap.getHandle(dict_sugar.path_index).decrRefCount();
            },
            .none,
            .index,
            .integer,
            .float,
            .bool,
            .marked,
            .invalid,
            .cached_local_var,
            => {},
            .dict, .list, .custom_type => unreachable,
        }

        obj.body = undefined;
        obj.head.tag = .none;
    }
};

pub const Tag = enum(u5) {
    none,
    /// Set this if an object's contents are no longer usable.
    invalid,
    marked,
    index,
    integer,
    float,
    bool,
    string,
    source,
    list,
    dict,
    dict_sugar,
    reference,
    cached_local_var,
    cached_lexical_var,
    upvar_link,
    closure,
    custom_type,
};

pub const Body = packed union(u64) {
    const Empty = packed struct { padding: u64 = 0 };

    none: Empty,
    invalid: Empty,
    /// Used internally in places where a value needs to be temporarily marked.
    marked: Empty,
    /// List index.
    index: packed struct { data: ListIndex, padding: u30 = 0 },
    integer: i64,
    float: f64,
    bool: packed struct { data: bool, padding: u63 = 0 },
    string: packed struct {
        utf8_length: u32,
        length_determined: bool,
        padding: u31 = 0,
    },
    source: packed struct {
        extra_data: ExtraData,
        padding: u32 = 0,
    },
    list: packed struct {
        len: u32,
        padding: u32 = 0,
    },
    /// Items of the dictionary are stored directly after, similar to a list.
    /// Keys and values alternate. Allows for duplicate keys when shimmering
    /// from a list, but duplicates will be removed when any writing operation
    /// happens.
    dict: packed struct {
        /// Length of dictionaries' backing list, including potential duplicated
        /// keys when shimmering from list.
        len: u32,
        extra_data: ExtraData,
    },
    /// Both objects must be in the parent object's heap. `dict_name_index` points
    /// to an object that contains the name of the dictionary (and most likely
    /// specializes to whatever type of variable caching is necessary), while
    /// `path_index` points to a list containing all parts of the path. For
    /// example, `foo::bar::baz` would turn into roughly
    /// ```
    /// dict_name_index: "foo"
    /// path_index: ["bar", "baz"]
    /// ```
    dict_sugar: packed struct {
        dict_name_index: HeapIndex,
        path_index: HeapIndex,
    },
    reference: Handle,
    cached_local_var: packed struct {
        cached_index: HeapIndex,
        padding: u32 = 0,
    },
    /// Value from lexical scope lookup. In zicl, parent scopes are immutable,
    /// so we can outright borrow this value.
    cached_lexical_var: packed struct {
        /// Used to invalidate the cached value, if it doesn't match
        /// the current call frame's epoch. The only thing that can
        /// invalidate a lexical lookup is shadowing it with a local
        /// variable.
        call_epoch: u32,
        extra_data: ExtraData,
    },
    upvar_link: packed struct {
        /// The call frame this linked variable lives in.
        call_frame: u32,
        /// An object containing the name of the variable in the linked
        /// scope. Whenever someone shimmers this to a variable, they should
        /// always do it in `call_frame`.
        linked_name: HeapIndex,
    },
    closure: packed struct {
        extra_data: ExtraData,
        padding: u32 = 0,
    },
    custom_type: packed struct {
        type_id: u32,
        extra_data: ExtraData,
    },
};

comptime {
    assert(@sizeOf(Body) == 8);

    // Make sure Tag and Body have the same fields.
    const tag_fields = @typeInfo(Tag).@"enum".fields;
    const body_fields = @typeInfo(Body).@"union".fields;

    assert(tag_fields.len == body_fields.len);
    for (tag_fields, body_fields) |tag_field, body_field| {
        assert(std.mem.eql(u8, tag_field.name, body_field.name));
    }
}

pub const ExtraData = enum(u32) { _ };

/// Extra data, for when you can't store enough in the main object.
pub const ExtraDataValue = union(enum) {
    pub const Dictionary = struct {
        pub const Table = std.HashMapUnmanaged(Handle, u32, struct {
            pub fn hash(ctx: @This(), key: Handle) u64 {
                _ = ctx;

                const str = key.getString() catch unreachable;
                return std.hash_map.hashString(str);
            }

            pub fn eql(ctx: @This(), a: Handle, b: Handle) bool {
                _ = ctx;

                return checkIfEqual(a, b) catch unreachable;
            }
        }, 80);

        /// Caller needs to ensure that any string this is called with
        /// is valid, as hash map methods don't return errors.
        table: ?Table,

        /// Used during variable lookup to walk the parent scopes. References
        /// the dict if present.
        parent_link: OptionalHandle,
    };

    /// This does not store the key/value pairs directly, instead it
    /// is a mapping of key to value index.
    dict: Dictionary,
    lexical_variable: struct {
        /// Borrows the value it references.
        ref: Handle,
    },
    source: struct {
        file_name: OptionalHandle,
        line_no: u32,
        /// Computed hash for faster script lookup.
        hash: struct {
            state: std.atomic.Value(enum(u8) {
                not_computed,
                computed,
            }) = .init(.not_computed),
            hash: u256,
        },
    },
    custom_type: struct {
        first_ptr: *anyopaque,
        second_ptr: *anyopaque,
    },
    closure: Closure,
    none: void,
};

pub const IndexError = error{BadIndex};
/// Tcl list index. Indexes are inclusive both for start and end in Tcl. Additionally,
/// an index may be relative, such as "end" or "end-1".
pub const ListIndex = packed struct(u34) {
    u: packed union {
        index: packed struct { data: u32, padding: u1 = 0 },
        end_offset: i33,
    },
    /// Whether this is a relative index, such as "end", "end-1", "end+5", etc.
    is_relative: bool,

    pub const end: ListIndex = .{ .u = .{ .end_offset = 0 }, .is_relative = true };

    pub fn asAbsoluteIndex(self: ListIndex, list_len: u32) i33 {
        if (self.is_relative) {
            return self.u.end_offset + (list_len -| 1);
        } else {
            return self.u.index;
        }
    }
};

/// Monotonic counter for parsed script and expression cache keys.
/// Ensures that closures at different call sites don't share cached
/// variable lookups, even if their bodies are identical.
var next_cache_id: std.atomic.Value(u64) = .init(1);

pub fn nextCacheId() u64 {
    return next_cache_id.fetchAdd(1, .monotonic);
}

pub const Closure = struct {
    /// Handle to the argument list of the procedure.
    args: Handle,
    /// Handle to the script's body.
    body: Handle,
    /// We do our best to track the closure's name.
    name: OptionalHandle,
    /// Handle to the closure's scope (linked dictionary).
    scope: OptionalHandle,
    /// Required number of arguments.
    required_arity: u32,
    /// Unique identifier for cache keying.
    cache_id: u64,

    pub fn borrow(closure: Closure) Closure {
        return .{
            .args = closure.args.borrow(),
            .body = closure.body.borrow(),
            .name = closure.name.borrowOptional(),
            .scope = closure.scope.borrowOptional(),
            .required_arity = closure.required_arity,
            .cache_id = closure.cache_id,
        };
    }

    pub fn deinit(closure: Closure) void {
        closure.args.decrRefCount();
        closure.body.decrRefCount();
        closure.name.decrOptional();
        closure.scope.decrOptional();
    }
};

const HeapIndex = u32;
const HandleBacking = u64;

pub const OptionalIndex = enum(HeapIndex) {
    none = 0,
    _,

    pub fn toOptional(index: OptionalIndex, heap: *Heap) OptionalHandle {
        if (index == .none) return .none;
        const unwrapped_index: HeapIndex = @intFromEnum(index);
        return heap.getHandle(unwrapped_index).toOptional();
    }

    pub fn getIndex(index: OptionalIndex) ?HeapIndex {
        if (index != .none) {
            return @intFromEnum(index);
        } else return null;
    }
};

pub const OptionalHandle = enum(HandleBacking) {
    none = 0,
    _,

    pub fn toHandle(optional: OptionalHandle) ?Handle {
        if (optional != .none) {
            return @bitCast(@as(HandleBacking, @intFromEnum(optional)));
        } else return null;
    }

    pub fn fromHandle(handle: ?Handle) OptionalHandle {
        if (handle) |val| {
            return val.toOptional();
        } else return .none;
    }

    pub fn getIndex(optional: OptionalHandle) OptionalIndex {
        if (optional.toHandle()) |val| {
            return @enumFromInt(val.index);
        } else return .none;
    }

    pub fn toHandleRef(optional: *OptionalHandle) ?*Handle {
        if (optional.* != .none) {
            return @as(*Handle, @ptrCast(optional));
        } else return null;
    }

    pub fn swapRef(ref: *OptionalHandle, new_handle: Handle) void {
        if (ref.toHandle()) |handle| {
            handle.decrRefCount();
        }
        ref.* = @enumFromInt(@as(HandleBacking, @bitCast(new_handle)));
    }

    pub fn swapRefIfNew(ref: *OptionalHandle, new_handle: OptionalHandle) void {
        if (new_handle != .none) {
            if (ref.toHandle()) |val| val.decrRefCount();
            ref.* = new_handle;
        }
    }

    pub fn swapWithNone(ref: *OptionalHandle) void {
        if (ref.toHandle()) |val| val.decrRefCount();
        ref.* = .none;
    }

    pub fn orElse(ref: OptionalHandle, other: Handle) Handle {
        return ref.toHandle() orelse other;
    }

    pub fn orEmpty(ref: OptionalHandle) Handle {
        return ref.orElse(Heap.local_heap.emptyHandle());
    }

    pub fn borrowOptional(ref: OptionalHandle) OptionalHandle {
        if (ref.toHandle()) |val| val.incrRefCount();
        return ref;
    }

    pub fn decrOptional(ref: OptionalHandle) void {
        if (ref.toHandle()) |val| val.decrRefCount();
    }

    pub fn format(self: OptionalHandle, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.toHandle()) |handle| {
            try handle.format(writer);
        } else {
            try writer.writeAll("<none>");
        }
    }
};

pub const Handle = packed struct(HandleBacking) {
    index: HeapIndex,
    heap: HeapId,
    _padding: u16 = 0,

    pub fn format(
        self: Handle,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const str = getString(self) catch "<oom string>";
        try writer.writeAll(str);
    }

    pub fn peek(handle: Handle) *Object {
        return getHeap(handle).getLocalObject(handle.index);
    }

    pub fn tag(handle: Handle) Tag {
        return handle.peek().head.tag;
    }

    pub fn getHeap(handle: Handle) *Heap {
        return &heaps[handle.heap];
    }

    pub fn toOptional(handle: Handle) OptionalHandle {
        return @enumFromInt(@as(HandleBacking, @bitCast(handle)));
    }

    pub fn toOptionalRef(ref: *Handle) *OptionalHandle {
        return @ptrCast(ref);
    }

    /// Must be shimmerable.
    pub fn prepareToShimmer(handle: Handle) !void {
        handle.assert(handle.canShimmer());
        // Make sure the object has a string rep before we free its body. That is, if
        // it has a string rep. `.none` objects are brand new, so they obviously don't
        // have a string rep yet.
        if (handle.tag() != .none) _ = try handle.getString();
        handle.invalidateBody();
    }

    pub fn canShimmer(handle: Handle) bool {
        // Specialty objects can't shimmer.
        if (handle.index < special_object_count) return false;

        // Can't shimmer if it's shared between threads.
        return !handle.getHeap().objects.get(handle.index).metadata.cross_thread;
    }

    pub fn canMutate(handle: Handle) bool {
        // Note: a crossthread object can _never_ mutate. A lot of asserts around
        // the codebase assume that `canMutate` means that an object is not crossthread.

        // Special objects can never be mutated.
        if (handle.index < special_object_count) return false;

        const obj_heap = handle.getHeap();
        const metadata = obj_heap.getLocalMetadata(handle.index);

        const mutable = metadata.mutable;
        const cross_thread = metadata.cross_thread;
        const multiple_refs = obj_heap.getLocalRefCount(handle.index) > 1;

        if (!mutable) return false;
        if (cross_thread) return false;
        if (multiple_refs) return false;
        if (metadata.order > 1) {
            const head = allocHead(handle);
            if (head != handle) return head.canMutate();
        }

        return true;
    }

    pub fn swap(ref: *Handle, new: Handle) void {
        const before_duplicating = ref.*;
        ref.* = new;
        before_duplicating.decrRefCount();
    }

    /// If `optional` is non-null, it will transfer ownership to `ref` and be set to null.
    pub fn swapAndClear(ref: *Handle, optional: *OptionalHandle) void {
        if (optional.toHandle()) |handle| ref.swap(handle);
        optional.* = .none;
    }

    /// Helper to swap handle if `new_handle` is non-null, releasing the old value of
    /// `ref` in the process.
    pub fn swapIfNew(ref: *Handle, new_handle: OptionalHandle) void {
        if (new_handle.toHandle()) |new| {
            const old = ref.*;
            ref.* = new;
            old.decrRefCount();
        }
    }

    pub fn getMetadata(handle: Handle) *ObjectAndMetadata.Metadata {
        return handle.getHeap().getLocalMetadata(handle.index);
    }

    /// This should not be used for checking if an object is shared, use `isShared` instead.
    pub fn getRefCount(handle: Handle) u32 {
        return handle.getHeap().objects.items(.ref_count)[handle.index];
    }

    pub fn borrow(handle: Handle) Handle {
        handle.incrRefCount();
        return handle;
    }

    pub fn incrRefCount(handle: Handle) void {
        if (handle.index < special_object_count) return;
        // Make sure we never try to borrow a freed object.
        handle.assert(handle.getRefCount() > 0);
        handle.assert(handle.tag() != .reference);

        handle.getHeap().objects.items(.ref_count)[handle.index] += 1;
    }

    pub fn referenceTakeOwnership(handle: Handle) Object {
        // Make sure we're never making a reference to a reference.
        handle.assert(handle.tag() != .reference);

        return .{
            // References are guaranteed to always have a null representation.
            .head = .{
                .str = Object.null_string,
                .tag = .reference,
            },
            .body = .{
                .reference = handle,
            },
        };
    }

    pub fn reference(handle: Handle) Object {
        handle.incrRefCount();
        return handle.referenceTakeOwnership();
    }

    pub fn dupOrRef(handle: Handle) Object {
        return local_heap.dupOrReference(handle);
    }

    pub fn invalidateBoth(handle: Handle) void {
        handle.invalidateBody();
        handle.invalidateString();
    }

    pub fn invalidateBody(handle: Handle) void {
        handle.assert(handle.canShimmer());

        invalidateBodyInner(handle);
    }

    pub fn invalidateString(handle: Handle) void {
        handle.assert(handle.canMutate());

        invalidateStringInner(handle);
    }

    pub fn decrRefCount(handle: Handle) void {
        if (handle.index < special_object_count) return;

        const ref_count = &handle.getHeap().objects.items(.ref_count)[handle.index];
        ref_count.* -= 1;
        if (ref_count.* == 0) freeObject(handle);
    }

    pub fn isAllocHead(handle: Handle) bool {
        if (handle.index < special_object_count) return false;

        return handle == handle.allocHead();
    }

    fn allocHead(handle: Handle) Handle {
        handle.assert(handle.index >= special_object_count);

        const order = handle.getMetadata().order;
        return .{
            .index = (handle.index >> order) << order,
            .heap = handle.heap,
        };
    }

    pub fn getStringDetails(handle: Handle) StringDetails {
        return handle.getHeap().getLocalStringDetails(handle.peek().head.str);
    }

    pub fn getDictExtraData(handle: Handle) *ExtraDataValue.Dictionary {
        handle.assert(handle.tag() == .dict);
        return &handle.getHeap().getExtraData(handle.peek().body.dict.extra_data).dict;
    }

    pub fn getClosureExtraData(handle: Handle) *Closure {
        handle.assert(handle.tag() == .closure);
        return &handle.getHeap().getExtraData(handle.peek().body.closure.extra_data).closure;
    }

    const empty_string_value = "";
    /// This returns a temporary string. Whenever the object is mutated, it
    /// may become invalid. Guaranteed to be valid, barring OOM.
    pub fn getString(handle: Handle) error{OutOfMemory}![:0]const u8 {
        switch (handle.getStringDetails()) {
            .normal => |str| {
                return str;
            },
            .empty => {
                return empty_string_value;
            },
            .null => {
                // Keep going in code.
            },
        }

        // No representation, so we better generate it.
        try setString(handle, "intentionally blank");

        // Rerun this function to figure out where the new string is.
        return handle.getString();
    }

    /// Helper function that dumps the object's trace if the assertion fails.
    pub fn assert(handle: Handle, ok: bool) void {
        _ = handle;
        if (!ok) {
            unreachable;
        }
    }
};

fn invalidateBothInner(handle: Handle) void {
    invalidateStringInner(handle);
    invalidateBodyInner(handle);
}

fn invalidateStringInner(handle: Handle) void {
    handle.peek().deinitString(handle.getHeap());
}

fn invalidateCollection(handle: Handle) void {
    assert(handle.tag() == .dict or handle.tag() == .list);

    const len = memutil.getOrderSize(handle.getMetadata().order) - 1;

    // First, we need to check if any of the items have been referenced.
    const any_elems_referenced = blk: {
        for (0..len) |i| {
            const item_handle: Handle = .{
                .index = @intCast(handle.index + 1 + i),
                .heap = handle.heap,
            };

            if (item_handle.getRefCount() > 1) {
                break :blk true;
            }
        } else break :blk false;
    };

    if (any_elems_referenced) {
        // Since an item was referenced, we'll need to split this allocation
        // into individual objects.
        handle.getHeap().splitAlloc(handle.index, 0);
    }

    for (0..len) |i| {
        const elem_handle: Handle = .{
            .index = @intCast(handle.index + 1 + i),
            .heap = handle.heap,
        };

        if (!any_elems_referenced) {
            // Case 1: this dictionary owns all items, so we can free all items.
            invalidateBothInner(elem_handle);
        } else {
            // Case 2: there were shared items in the dictionary, so all the items
            // were split into individual items. We need to decrement the dictionary's
            // ownership of every item.
            elem_handle.decrRefCount();
        }
    }
}

fn invalidateBodyInner(handle: Handle) void {
    std.debug.print("Handle: {any}, ptr: {*}\n", .{ handle, &handle.peek().head });

    switch (handle.tag()) {
        .list => {
            invalidateCollection(handle);
        },
        .dict => {
            invalidateCollection(handle);
        },
        else => handle.peek().deinitBodySingle(handle.getHeap()),
    }

    handle.peek().body = undefined;
    handle.peek().head.tag = .invalid;
}

const ObjectAndMetadata = struct {
    pub const Metadata = packed struct(u8) {
        /// Order can be u5 instead of u6, because the heap size must be < 2^32.
        order: u5,
        /// Whether this object is shared across threads.
        cross_thread: bool,
        /// Used to indicate that an object cannot be modified, even when not shared
        /// (currently used to prevent dictionary keys from being modified, as that
        /// would mess up the index).
        mutable: bool,
        /// Whether this object is currently being used (used to track double frees).
        in_use: bool,
    };

    object: Object,
    ref_count: u32,
    metadata: Metadata,
};

pub fn init(heap: *Heap) !void {
    heap.* = undefined;

    // Init objects.
    heap.object_tracking = try .init(global_gpa, global_io, cfg.object_heap_order);

    heap.objects = .empty;
    heap.objects.bytes = (try memutil.vmemMap(object_heap_max_bytes)).ptr;
    heap.objects.capacity = object_heap_max_count;
    heap.objects.len = object_heap_max_count;

    // Init strings.
    heap.string_tracking = try .init(global_gpa, global_io, cfg.string_heap_order);
    heap.strings = .empty;
    heap.strings.items = try memutil.vmemMap(string_heap_max_bytes);
    heap.strings.capacity = heap.strings.items.len;

    heap.extra = try .initWithCapacity(object_heap_max_count);

    // Done initializing heap fields, so now we'll create all the specialty objects.

    // Null string is guaranteed to have index 0.
    const null_string_idx = try heap.string_tracking.alloc(0);
    assert(null_string_idx == null_string);
    // Empty string is guaranteed to have index 1.
    const empty_string_idx = try heap.string_tracking.alloc(0);
    assert(empty_string_idx == empty_string);

    // Specialty objects.
    // Null object is guaranteed to have index 0.
    const null_object = try heap.createObject();
    assert(null_object.index == null_object_idx);
    // Empty object is guaranteed to have index 1.
    const empty_object = try heap.createObject();
    assert(empty_object.index == empty_object_idx);
    empty_object.peek().head.str = Object.empty_string;
}

pub fn heapId(self: *Heap) HeapId {
    return @intCast(self - &heaps);
}

pub fn emptyObject() Object {
    return .{
        .head = .{ .str = Object.empty_string, .tag = .none },
        .body = undefined,
    };
}

pub fn emptyHandle(self: *Heap) Handle {
    return .{
        .index = empty_object_idx,
        .heap = self.heapId(),
    };
}

pub fn createObject(self: *Heap) !Handle {
    const index = try self.createObjects(1);
    return .{
        .index = index,
        .heap = self.heapId(),
    };
}

/// Splits an existing allocation.
pub fn splitAlloc(self: *Heap, index: u32, new_order: u5) void {
    const metadata = self.objects.items(.metadata)[index]; // Copy

    assert(metadata.in_use);
    assert(metadata.order > new_order);

    self.object_tracking.splitBlock(metadata.order, new_order);

    for (self.objects.items(.metadata)[index..][0..memutil.getOrderSize(metadata.order)]) |*new_metadata| {
        new_metadata.order = new_order;
    }
}

/// `createObjects` does not initialize objects, but does initialize
/// reference counts.
pub fn createObjects(self: *Heap, count: u32) !u32 {
    const order = memutil.getOrder(count);
    const aligned_count = @as(u32, 1) << order;

    const index: u32 = try self.object_tracking.alloc(order);

    const end = index + aligned_count;

    // Make sure object list has space for new objects.
    if (self.objects.len < index + aligned_count) {
        const start_of_new = self.objects.len;
        if (!options.threading) try self.objects.resize(memutil.null_allocator, index + aligned_count);
        @memset(self.objects.items(.metadata)[start_of_new..self.objects.len], .{
            .order = 31,
            .cross_thread = false,
            .in_use = false,
            .mutable = false,
        });
    }

    // Make sure the items we're allocating are free (used to
    // ensure our allocator hasn't reached a broken state).
    for (self.objects.items(.metadata)[index..end]) |metadata| assert(metadata.in_use == false);

    // Initialize all as empty objects.
    @memset(self.objectSlice(index, end), .{
        .head = .{
            .str = Object.null_string,
            .tag = .none,
        },
        .body = .{
            .integer = 0,
        },
    });

    // Initialize ref counts.
    @memset(self.objects.items(.ref_count)[index..end], 1);

    // Initialize metadata.
    self.objects.items(.metadata)[index] = .{
        .order = order,
        .cross_thread = false,
        .mutable = true,
        .in_use = true,
    };

    if (aligned_count > 1) @memset(
        self.objects.items(.metadata)[(index + 1)..end],
        .{
            .order = order,
            .cross_thread = false,
            .mutable = true,
            .in_use = true,
        },
    );

    return index;
}

pub fn freeObjectBacking(handle: Handle) void {
    const obj_heap = handle.getHeap();
    const metadata = obj_heap.getLocalMetadata(handle.index).*; // Copy

    if (!metadata.in_use) {
        @panic("Double free!");
    }

    // Mark as free in metadata.
    const alloc_size = memutil.getOrderSize(metadata.order);
    @memset(obj_heap.objects.items(.metadata)[handle.index..][0..alloc_size], .{
        .order = 31,
        .cross_thread = false,
        .mutable = false,
        .in_use = false,
    });

    obj_heap.object_tracking.free(handle.index, metadata.order);
}

pub fn freeObject(handle: Handle) void {
    invalidateBothInner(handle);

    freeObjectBacking(handle);
}

pub fn ensureMutableOrDup(handle: Handle, new_handle: *OptionalHandle) !void {
    if (!handle.canMutate()) {
        // It's very sketchy to modify a collection item in place if
        // its parent is shared, so if this isn't the head this is
        // probably incorrect.
        assert(handle.isAllocHead());
        new_handle.swapRef(try Heap.duplicate(local_heap, handle));
    }
}

/// If the object can't shimmer, this will return a duplicate.
pub fn ensureShimmerableOrDup(handle: Handle, new_handle: *OptionalHandle) !void {
    if (!handle.canShimmer()) {
        new_handle.swapRef(try Heap.duplicate(local_heap, handle));
    }
}

/// Get a string slice from heap string storage.
pub fn getHeapString(self: *Heap, start: u32, end: u32) [:0]u8 {
    return self.strings.items[start..end :0];
}

/// Allocates 1 + length, in order to make space for the null byte.
pub fn createString(self: *Heap, len: u32) !u32 {
    const length_with_null = len + 1;
    const order = memutil.getOrder(length_with_null);

    const new_string = try self.string_tracking.alloc(order);
    self.strings.items[new_string + len] = 0; // Set null byte.
    return new_string;
}

pub fn freeString(self: *Heap, index: u32, len: u32) void {
    assert(index >= special_string_count);

    const length_with_null = len + 1;
    const order = memutil.getOrder(length_with_null);
    self.string_tracking.free(index, order);
}

pub fn checkIfEqual(a: Handle, b: Handle) !bool {
    if (a == b) return true;

    const a_str = try a.getString();
    const b_str = try b.getString();

    return std.mem.eql(u8, a_str, b_str);
}

pub fn duplicateObjString(dest_heap: *Heap, handle: Handle) !Object.StrOrPtr {
    switch (handle.getStringDetails()) {
        .normal => |bytes| {
            const new_string = try dest_heap.createString(@intCast(bytes.len));
            const len: u26 = @intCast(bytes.len);
            @memcpy(dest_heap.getHeapString(new_string, new_string + len), bytes);

            return .{
                .u = .{ .str = .{ .index = new_string, .len = len } },
                .is_ptr = false,
            };
        },
        .null, .empty => {
            return handle.peek().head.str;
        },
    }
}

/// Duplicates the object if it's a fast duplication, else references it.
pub fn dupOrReference(dest_heap: *Heap, handle: Handle) Object {
    _ = dest_heap;

    const tag = handle.tag();
    if (tag == .reference) {
        // We can't reference a reference, so we'll create a new reference.
        return handle.peek().body.reference.reference();
    } else {
        return handle.reference();
    }
}

/// If called with a multi-item object, will return `error.MultiItemObject`.
pub fn duplicateSingle(dest_heap: *Heap, handle: Handle) error{ OutOfMemory, MultiItemObject }!Object {
    const src = handle.peek();
    switch (handle.tag()) {
        .none, .index, .integer, .float, .string, .bool, .marked => {
            return .{
                .head = .{
                    .str = try dest_heap.duplicateObjString(handle),
                    .tag = handle.tag(),
                },
                .body = src.body,
            };
        },
        .reference => {
            // Try to duplicate what it's referencing, else create a new reference to it.
            return dest_heap.duplicateSingle(src.body.reference) catch |err| switch (err) {
                error.MultiItemObject => return src.body.reference.reference(),
                error.OutOfMemory => return error.OutOfMemory,
            };
        },
        .custom_type, .source, .dict_sugar => unreachable,
        .cached_local_var, .cached_lexical_var => {
            // Variable lookup is not stable between threads.
            return .{
                .head = .{ .str = try dest_heap.duplicateObjString(handle), .tag = .none },
                .body = undefined,
            };
        },
        .closure => {
            const closure = handle.getClosureExtraData();
            const new_extra_data = try dest_heap.createExtraData();
            dest_heap.getExtraData(new_extra_data).* = .{ .closure = closure.borrow() };

            return .{
                .head = .{
                    .str = try dest_heap.duplicateObjString(handle),
                    .tag = .closure,
                },
                .body = .{ .closure = .{ .extra_data = new_extra_data } },
            };
        },
        .list, .dict => {
            return error.MultiItemObject;
        },
        .upvar_link => @panic("Cannot duplicate an upvar"),
        .invalid => @panic("Tried to duplicate an invalid object."),
    }
}

pub fn duplicate(dest_heap: *Heap, src_handle: Handle) error{OutOfMemory}!Handle {
    const src = src_handle.peek();

    switch (src_handle.tag()) {
        .list => unreachable,
        .dict => {
            const old_len = src.body.dict.len;
            const old_start = src_handle.index + 1;
            const old_metadata = src_handle.getDictExtraData();

            const new_dict_idx = try dest_heap.createObjects(1 + old_len);
            errdefer dest_heap.getHandle(new_dict_idx).decrRefCount();
            const new_head = dest_heap.getHandle(new_dict_idx);
            const new_start = new_dict_idx + 1;
            const new_items = dest_heap.objectSlice(new_start, new_start + old_len);

            // Duplicate head of dict.
            {
                const new_str = try dest_heap.duplicateObjString(src_handle);
                errdefer new_str.deinit(dest_heap);
                const new_extra_data = try dest_heap.createExtraData();

                new_head.peek().* = .{
                    .head = .{
                        .str = new_str,
                        .tag = .dict,
                    },
                    .body = .{ .dict = .{
                        .extra_data = new_extra_data,
                        .len = old_len,
                    } },
                };
                dest_heap.getExtraData(new_extra_data).* = .{ .dict = .{
                    .table = null,
                    .parent_link = old_metadata.parent_link.borrowOptional(),
                } };
            }

            // Duplicate items of dict.
            for (new_items, 0..) |*new_item, i| {
                new_item.* = dest_heap.duplicateSingle(.{
                    .index = @intCast(old_start + i),
                    .heap = src_handle.heap,
                }) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    // Dicts can't contain multi item objects.
                    error.MultiItemObject => unreachable,
                };
            }

            return dest_heap.getHandle(new_dict_idx);
        },
        else => {
            const new_object = try dest_heap.createObject();
            new_object.peek().* = dest_heap.duplicateSingle(src_handle) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                // We already checked if it was a multi-item object (i.e. a list).
                error.MultiItemObject => unreachable,
            };
            return new_object;
        },
    }
}

pub fn getHandle(self: *Heap, index: u32) Handle {
    return .{
        .heap = self.heapId(),
        .index = index,
    };
}

pub fn getLocalObject(self: *Heap, index: u32) *Object {
    return &self.objects.items(.object)[index];
}

pub fn objectSlice(self: *Heap, start: u32, end: u32) []Object {
    return self.objects.items(.object)[start..end];
}

pub fn getLocalMetadata(self: *Heap, index: u32) *ObjectAndMetadata.Metadata {
    return &self.objects.items(.metadata)[index];
}

fn getLocalRefCount(self: *Heap, index: u32) u32 {
    const ptr = &self.objects.items(.ref_count)[index];

    if (self.getLocalMetadata(index).cross_thread) {
        return @atomicLoad(u32, ptr, .monotonic);
    } else {
        return ptr.*;
    }
}

/// Copies provided string.
pub fn setString(handle: Handle, bytes: []const u8) Allocator.Error!void {
    const heap = handle.getHeap();
    assert(try heap.setNormalString(handle.index, bytes));
}

/// Get the string to modify (must not write any longer than current len).
/// Not threadsafe.
pub fn getStringMut(handle: Handle) ![:0]u8 {
    switch (handle.getStringDetails()) {
        .normal => {
            const str = handle.peek().head.str.u.str;
            return handle.getHeap().getHeapString(str.index, str.index + str.len);
        },
        .null, .empty => return error.NotMutable,
    }
}

/// Low-level function, to exchange one value of an object's string to another.
/// Returns whether the exchange was successful (if not, caller is responsible
/// for cleaning up).
pub fn exchangeString(self: *Heap, index: u32, expected: Object.StrOrPtr, to_set_to: Object.StrOrPtr) bool {
    _ = expected;

    const obj: *Object = self.getLocalObject(index);
    obj.head.str = to_set_to;

    return true;
}

pub fn setNormalString(self: *Heap, index: u32, bytes: []const u8) !bool {
    if (bytes.len == 0) {
        // No need to check the result of the exchange, as there's nothing to clean up
        assert(self.exchangeString(index, Object.null_string, Object.empty_string));
        return true;
    } else {
        const string = try self.createString(@intCast(bytes.len));
        const len: u26 = @intCast(bytes.len);
        @memcpy(
            self.getHeapString(string, string + len),
            bytes,
        );

        const string_header: Object.StrOrPtr = .{
            .u = .{
                .str = .{ .index = string, .len = len },
            },
            .is_ptr = false,
        };

        const did_win = self.exchangeString(index, Object.null_string, string_header);
        if (!did_win) {
            self.freeString(string, len);
        }

        return true;
    }
}

const StringDetails = union(enum) {
    null: void,
    empty: void,
    normal: [:0]u8,
};

fn getLocalStringDetails(heap: *Heap, str_or_ptr: Object.StrOrPtr) StringDetails {
    // Normal string or long string?
    assert(!str_or_ptr.is_ptr);

    const str = str_or_ptr.u.str;
    if (str.index == null_string) {
        return .null;
    } else if (str.index == empty_string) {
        return .empty;
    } else {
        return .{
            .normal = heap.getHeapString(str.index, str.index + str.len),
        };
    }
}

pub fn createExtraData(self: *Heap) !ExtraData {
    const new_index = try self.extra.create();
    if (new_index >= object_heap_max_count) return error.OutOfMemory;

    return @enumFromInt(new_index);
}

pub fn getExtraData(self: *Heap, index: ExtraData) *ExtraDataValue {
    return &self.extra.items[@intFromEnum(index)];
}

pub fn initGlobals(gpa: Allocator, io: std.Io) !void {
    global_io = io;
    global_gpa = gpa;
}

pub fn initLocalHeap() !void {
    const slot_index = next_open_heap;
    next_open_heap += 1;

    const new_heap = &heaps[slot_index];
    try new_heap.init();
    local_heap = new_heap;
}
pub fn deinitAll() void {
    // Deinit heaps without holding the mutex, as they may lock.
    for (heaps[0..next_open_heap]) |*heap| {
        heap.deinit();
    }
}

pub fn testStart(gpa: Allocator, io: std.Io) !*Heap {
    try initGlobals(gpa, io);
    try initLocalHeap();

    return local_heap;
}

pub fn testFinish() void {
    Heap.deinitAll();
}

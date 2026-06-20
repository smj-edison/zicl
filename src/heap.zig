const std = @import("std");
const mem = std.mem;
const debug = std.debug;
const testing = std.testing;
const builtin = @import("builtin");
const math = std.math;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const options = @import("options");
const memutil = @import("memutil.zig");
const ioutil = @import("ioutil.zig");
const objects = @import("objects.zig");
const objutil = @import("objutil.zig");

threadlocal var debugging_buffer: if (options.trace_mem) [16 * 1024 * 1024]u8 else void = undefined;
threadlocal var debugging_gpa: if (options.trace_mem) memutil.RingBufferAllocator else void = undefined;
/// Use this for debugging objects (traces, etc) that can afford to leak.
threadlocal var debug_gpa: Allocator = undefined;

pub var initialized: bool = false;
/// Use to lock `custom_types` or `script_metadata` when adding or removing
/// (no need to lock when using).
pub var init_mutex: std.Io.Mutex = .init;
/// Used to turn some panics into useful messages.
pub var running_leak_check: bool = false;

pub var global_gpa: mem.Allocator = undefined;
pub threadlocal var local_arena: mem.Allocator = undefined;
pub var global_io: std.Io = undefined;
pub var nativefn_registry: NativeFnRegistry = .{};
pub var registered_hashes: HashRegistry = .{};

var trace_mutex: std.Io.Mutex = .init;
/// Preallocated fallback used by `[catch]` when a script OOMs and building
/// the real opts dict also OOMs. Pinned at init, released via `freeOomOptsDict`.
var oom_error_options_dict: ?Value = null;

pub const ObjectType = struct {
    duplicate: ?*const fn (src: *const ObjectHead, min_size: usize) error{OutOfMemory}!*ObjectHead,
    free_internal_rep: ?*const fn (obj: *ObjectHead) void,
    update_string: ?*const fn (obj: *ObjectHead) error{ OutOfMemory, OtherThreadSet }!void,
    name: [:0]const u8,
};

/// Signature for a lazy native command initializer. The interpreter pointer
/// is opaque here to avoid a circular dependency on Interp.zig.
pub const NativeInitFn = *const fn (interp: *anyopaque) callconv(.c) void;
/// Registry for lazily loaded functions. Will call `init_fn` when the function doesn't
/// exist as a nativefn.
pub const NativeFnRegistry = struct {
    mutex: std.Io.Mutex = .init,
    entries: std.StringHashMapUnmanaged(NativeInitFn) = .empty,

    pub fn register(self: *NativeFnRegistry, gpa: Allocator, name: []const u8, init_fn: NativeInitFn) !void {
        self.mutex.lockUncancelable(global_io);
        defer self.mutex.unlock(global_io);
        if (self.entries.contains(name)) {
            return error.DuplicateNativeFn;
        }
        try self.entries.put(gpa, name, init_fn);
    }

    pub fn get(self: *NativeFnRegistry, name: []const u8) ?NativeInitFn {
        self.mutex.lockUncancelable(global_io);
        defer self.mutex.unlock(global_io);
        return self.entries.get(name);
    }

    pub fn deinit(self: *NativeFnRegistry, gpa: Allocator) void {
        self.entries.deinit(gpa);
    }
};

/// The hash registry is the lifeblood of how Zicl deals with hashes. I think it's first
/// useful to understand the requirements that brought the hash registry about, to
/// contextualize the design decisions made:
///
/// 1. If someone has a hash of something in the Zicl heap, it must resolve to that
///    thing in the heap.
/// 2. If that hash no longer exists anywhere in the Zicl heap, that object needs to be
///    able to be freed, so that objects aren't leaked when nothing refers to them.
/// 3. Registering and unregistering a hash needs to be fast, since hashes will
///    be made and destroyed constantly.
///
/// (1) rules out an LRU cache, since an object could be evicted even though it still
/// had a live hash reference. (2) rules out an infinitely growing cache. (3) rules out
/// duplicating the value to have it be exclusively owned by the registry.
///
/// The above requirements have brought me to the following design:
/// a. We assume a closed world. If a hash reference does not exist in this global heap,
///    then we don't hang onto the object just because some other computer could contain
///    a hash to the object. This way we have reclaimation.
/// b. Every time an object is registered, we set a flag on the object called
///    `hash_registered`. This way we can register a hash idempotently, and quickly
///    determine whether the object needs to be unregistered before locking the RwLock.
/// c. Multiple objects may resolve to the same hash, so we choose the first one registered
///    to be called the "representative". The representative will have an identical value
///    to every other object by virtue of hashing, so we only need to hold onto the
///    representative. What gets tricky though is that we need the representative to stay
///    alive, even when everyone else has released the representative, since a second object
///    could resolve to the representative's hash and then cause a UAF. Hence, the registry
///    borrows the representative until every instance of the hash reference has disappeared.
///    You might wonder then, won't that mean that there's a circular reference between the
///    hash registry and the representative? The representative only unregisters when it's
///    freed, but the hash registry owns the representative. The way around this is that
///    an object will unregister itself in `decrRefCount` when the new ref count is less than
///    _or equal_ to 1. That way the representative can unregister itself when nobody else
///    besides the registry owns it.
/// d. This registry is in the global heap, not in the threadlocal heap. I couldn't figure
///    out a good way to have object references moving between threads and have a threadlocal
///    heap. In particular, the `hash_registered` field makes no sense with multiple heaps,
///    because it would have to check what heaps it's been registered with.
/// e. We use an RwLock, not a Mutex, since in many cases a caller just wants to look up a
///    hash, not register it. And in some cases, if a hash already has a representative, we
///    can just bump the instances count.
pub const HashRegistry = struct {
    pub const Entry = struct {
        /// Registry owns a reference to the representative.
        representative: *ObjectHead,
        instances: std.atomic.Value(usize),
    };

    rw_lock: std.Io.RwLock = .init,
    entries: std.HashMapUnmanaged(u256, Entry, struct {
        pub fn hash(self: @This(), full_hash: u256) u64 {
            _ = self;
            return @truncate(full_hash);
        }
        pub fn eql(self: @This(), a: u256, b: u256) bool {
            _ = self;
            return a == b;
        }
    }, 80) = .empty,

    pub fn get(registry: *HashRegistry, hash: u256) ?*ObjectHead {
        registry.rw_lock.lockSharedUncancelable(global_io);
        defer registry.rw_lock.unlockShared(global_io);

        if (registry.entries.getPtr(hash)) |entry| {
            assert(entry.instances.load(.monotonic) > 0);
            return entry.representative;
        } else return null;
    }

    pub fn register(registry: *HashRegistry, key: u256, obj: *ObjectHead) !void {
        registry.rw_lock.lockSharedUncancelable(global_io);

        if (registry.entries.getPtr(key)) |entry| {
            if (obj.metadata.cmpxchgStrongHashRegistered(false, true, .release, .acquire)) |_| {
                // Someone else registered this already, so no need to do anything.
            } else {
                // We were the ones to successfully set `value` as registered.
                _ = entry.instances.fetchAdd(1, .monotonic);
            }

            registry.rw_lock.unlockShared(global_io);
            return;
        }

        // Entry doesn't exist, so we'll create it.
        registry.rw_lock.unlockShared(global_io);
        registry.rw_lock.lockUncancelable(global_io);
        defer registry.rw_lock.unlock(global_io);

        const new_entry = try registry.entries.getOrPut(global_gpa, key);
        if (new_entry.found_existing) {
            if (obj.metadata.cmpxchgStrongHashRegistered(false, true, .release, .acquire)) |_| {
                // Someone registered it in-between upgrading the shared lock to an exclusive lock.
            } else {
                // We successfully marked it as registered, so we can increment the instances count.
                _ = new_entry.value_ptr.instances.fetchAdd(1, .monotonic);
            }
            return;
        }

        new_entry.key_ptr.* = key;
        new_entry.value_ptr.* = .{
            .representative = obj.borrow(),
            .instances = .init(1),
        };

        // We have an exclusive lock on rw_lock, so nobody else could have registered this value.
        assert(obj.metadata.cmpxchgStrongHashRegistered(false, true, .release, .acquire) == null);
    }

    pub fn unregister(registry: *HashRegistry, key: u256, obj: *ObjectHead) void {
        registry.rw_lock.lockSharedUncancelable(global_io);

        if (registry.entries.getPtr(key)) |entry| {
            if (obj.metadata.cmpxchgStrongHashRegistered(true, false, .release, .acquire)) |_| {
                // Someone else unregistered this already, so no need to do anything.
                registry.rw_lock.unlockShared(global_io);
            } else {
                // We were the ones to successfully set `value` as not registered.
                const instance_count = entry.instances.fetchSub(1, .monotonic) - 1;
                if (instance_count == 0) {
                    // This was the last instance of this hash, so we can now clean it up.

                    registry.rw_lock.unlockShared(global_io);
                    registry.rw_lock.lockUncancelable(global_io);

                    // The entry should still exist here, as we were the ones who set instances
                    // to 0. It could have moved locations though, when upgrading to an exclusive
                    // lock.
                    const entry_second_check = registry.entries.getPtr(key).?.*;
                    assert(registry.entries.remove(key));
                    registry.rw_lock.unlock(global_io);

                    // Make sure to `decrRefCount` only after unlocking the mutex, to avoid
                    // recursive locking.
                    entry_second_check.representative.decrRefCount();
                } else {
                    registry.rw_lock.unlockShared(global_io);
                }
            }

            return;
        } else {
            // Was already unregistered by the time we checked, so nothing to do.
            registry.rw_lock.unlockShared(global_io);
        }
    }
};

const ValueBacking = u64;
const ValueRep = packed struct(ValueBacking) {
    pub const Tag = enum(u3) {
        canonical_nan = 0,
        none,
        ptr,
        int,
        false,
        true,
        interned,
    };

    /// First 2 bytes of the f64. We store the tag here, as well as
    /// use `nan_value` to check if this is a tagged NaN, a canonical
    /// NaN, or a float.
    pub const Head = packed struct(u16) {
        tag: Tag,
        nan_value: u13 = 0xFFF,
    };

    value: packed union(u48) {
        ptr: u48,
        int: packed struct { data: i32, padding: u16 = 0 },
        padding: u48,
        /// Pointer to the interned string, where the string is prefixed with its length.
        interned: u48,
    } = .{ .padding = 0 },
    head: Head,

    pub const none_value: ValueRep = .{
        .tag = .none,
    };
};

pub const OptionalValue = enum(ValueBacking) {
    none = @bitCast(ValueRep.none_value),
    _,

    pub fn asValue(optional: OptionalValue) ?Value {
        if (optional != .none) {
            return @bitCast(@intFromEnum(optional));
        } else return null;
    }

    pub fn fromValue(value: ?Value) OptionalValue {
        if (value) |val| {
            val.assert(val.asRep() != ValueRep.none_value);
            return val.asOptional();
        } else {
            return .none;
        }
    }

    pub fn borrow(optional: OptionalValue) OptionalValue {
        if (optional.asValue()) |val| return val.borrow().asOptional();
        return .none;
    }

    pub fn release(optional: OptionalValue) void {
        if (optional.asValue()) |val| val.release();
    }

    pub fn orElse(optional: OptionalValue, otherwise: Value) Value {
        return optional.asValue() orelse otherwise;
    }

    pub fn swap(ref: *OptionalValue, new: Value) void {
        if (ref.asValue()) |obj| obj.release();
        ref.* = @enumFromInt(@as(ValueBacking, @bitCast(new)));
    }

    pub fn swapWithNone(ref: *OptionalValue) void {
        if (ref.asValue()) |val| val.release();
        ref.* = .none;
    }
};

pub const Value = enum(ValueBacking) {
    _,

    /// Helper function that dumps the object's trace if the assertion fails.
    pub fn assert(value: Value, ok: bool) void {
        _ = value;
        if (!ok) {
            unreachable;
        }
    }

    pub fn trace(value: Value, comptime fmt: []const u8, args: anytype) void {
        if (value.asPtr()) |val| val.trace(fmt, args);
    }

    pub fn asOptional(value: Value) OptionalValue {
        return @enumFromInt(@as(ValueBacking, @bitCast(value)));
    }

    pub fn asRep(value: *Value) *ValueRep {
        return @ptrCast(value);
    }

    pub fn isFloat(value: Value) bool {
        const is_nan = value.asRep().head.nan_value == 0x0FFF;
        return !is_nan or (is_nan and value.asRep().head.tag == .canonical_nan);
    }

    pub fn isPrimitive(value: Value) bool {
        if (value.isFloat()) return true;
        return value.asRep().head.tag != .ptr;
    }

    pub fn isPtr(value: Value) bool {
        return !value.isPrimitive();
    }

    pub fn asPtr(value: Value) ?*ObjectHead {
        if (value.isPtr()) return @ptrFromInt(value.asRep().value.ptr);
        return null;
    }

    pub fn tag(value: Value) ValueRep.Tag {
        debug.assert(!value.isFloat());
        return value.asRep().head.tag;
    }

    pub fn asInt(value: Value) ?i32 {
        if (value.tag() == .int) return value.asRep().value.int.data;
        return null;
    }

    pub fn asFloat(value: Value) ?f64 {
        if (value.isFloat()) return @bitCast(value);
        return null;
    }

    pub fn canShimmer(value: Value, new_size: usize) bool {
        if (value.asPtr()) |obj| {
            return !obj.metadata.cross_thread and new_size <= obj.alloc_size;
        } else {
            // Primitives can't shimmer.
            return false;
        }
    }

    pub fn canMutate(value: Value) bool {
        // Note: a crossthread object can _never_ mutate. A lot of asserts around
        // the codebase assume that `canMutate` means that an object is not crossthread.

        if (value.asPtr()) |obj| {
            // Cross thread objects can't be mutated, even if the ref count is 1, because
            // objects can be indirectly accessed by traversing lists. Imagine thread 1
            // is traversing a list, while thread 2 is modifying the list elements.
            // Thread 2 sees that the list element only has ref count one (since it's only
            // owned by the list), so it figures it's safe to modify. Wrong! It's not safe
            // to modify, because thread 1 is also reading the list. This is why crossthread
            // objects are never safe to modify, or even shimmer.
            if (obj.metadata.cross_thread) return false;
            // If the hash is registered, it means it is considered frozen. We can't very
            // well mutate something that has a fixed value.
            if (obj.metadata.hash_registered) return false;
            if (obj.getRefCount() > 1) return false;
        } else {
            // Primitives can't mutate.
            return false;
        }

        return true;
    }

    /// Must be shimmerable.
    pub fn prepareToShimmer(value: Value, new_size: usize) !void {
        value.assert(value.canShimmer(new_size));
        // Make sure the object has a string rep before we free its body. That is, if
        // it has a string rep. `.none` objects are brand new, so they obviously don't
        // have a string rep yet.
        if (value.tag() != .none) _ = try value.getString();
        if (value.asPtr()) |val| val.invalidateInternalRep();

        value.trace("Prepared to shimmer", .{});
    }

    pub fn borrow(value: Value) Value {
        if (value.asPtr()) |obj| obj.incrRefCount();
        return value;
    }

    pub fn release(value: Value) void {
        if (value.asPtr()) |obj| obj.release();
    }

    pub fn duplicate(value: Value) !Value {
        if (value.asPtr()) |obj| {
            if (obj.obj_type.duplicate) |duplicate_fn| {
                const new_obj = try duplicate_fn(obj);
                return Value.fromObjectPtr(new_obj);
            } else {
                debug.panic("Could not duplicate {}", .{obj.obj_type.name});
            }
        } else {
            return value;
        }
    }

    /// Must not be a packed pointer.
    pub fn box(value: Value) !*ObjectHead {
        if (value.asFloat()) |float_value| {
            const obj = try objects.BoxedFloatObject.new(float_value);
            return &obj.head;
        }

        switch (value.tag()) {
            .canonical_nan => unreachable,
            .none => unreachable, // .none is the null value, which is impossible for a `Value` to contain.
            .ptr => unreachable,
            .int => {
                const obj = try objects.BoxedIntObject.new(value.asInt().?);
                return &obj.head;
            },
            .false => {
                const obj = try ObjectHead.newObject(objects.StringObject);
                errdefer obj.head.freeBacking();
                try obj.head.setStringLocalObject("false");
                return &obj.head;
            },
            .true => {
                const obj = try ObjectHead.newObject(objects.StringObject);
                errdefer obj.head.freeBacking();
                try obj.head.setStringLocalObject("true");
                return &obj.head;
            },
            .interned => {
                const bytes_ptr = @as([*]u8, @ptrFromInt(value.asRep().value.interned));
                const len_ptr = bytes_ptr - @sizeOf(usize);
                const len = mem.readInt(usize, len_ptr[0..@sizeOf(usize)], .native);
                const bytes = bytes_ptr[0..len :0];

                const obj = try ObjectHead.newObject(objects.StringObject);
                errdefer obj.head.freeBacking();
                try obj.head.setStringLocalObject(bytes);
                return &obj.head;
            },
        }
    }

    pub fn duplicateBoxed(value: Value) !*ObjectHead {
        if (value.asPtr()) |obj| {
            if (obj.obj_type.duplicate) |duplicate_fn| {
                return try duplicate_fn(obj);
            } else {
                debug.panic("Could not duplicate {}", .{obj.obj_type.name});
            }
        } else {
            return try value.box();
        }
    }

    pub fn swap(ref: *Value, new: Value) void {
        const old = ref.*;
        ref.* = new;
        old.release();
    }

    pub fn fromRep(rep: ValueRep) Value {
        debug.assert(rep != ValueRep.none_value);
        return @enumFromInt(@as(ValueBacking, rep));
    }

    pub fn fromObjectPtr(obj: *ObjectHead) Value {
        return Value.fromRep(.{
            .head = .{ .tag = .ptr },
            .value = .{ .ptr = @intCast(@intFromPtr(obj)) },
        });
    }

    pub fn getString(value: Value) ![:0]const u8 {
        if (value.isFloat()) {
            return try std.fmt.allocPrintSentinel(local_arena, "{}", .{@as(f64, @bitCast(value))}, 0);
        } else switch (value.asRep().head.tag) {
            .canonical_nan => unreachable,
            .none => unreachable,
            .ptr => {
                const obj_head: *ObjectHead = @ptrFromInt(value.asRep().value.ptr);
                return try obj_head.getString();
            },
            .int => return try std.fmt.allocPrintSentinel(local_arena, "{}", .{value.asRep().value.int}, 0),
            .false => return "false",
            .true => return "true",
            .interned => {
                // Length of interned string is stored right before.
                const bytes_ptr = @as([*]u8, @ptrFromInt(value.asRep().value.interned));
                const len_ptr = bytes_ptr - @sizeOf(usize);
                const len = mem.readInt(usize, len_ptr, .native);
                return bytes_ptr[0..len :0];
            },
        }
    }

    pub fn equals(a: Value, b: Value) error{OutOfMemory}!bool {
        // If they're both primitives, we can compare their values directly.
        if (a.isPrimitive() and b.isPrimitive()) return a == b;

        if (a.asPtr()) |a_ptr| if (b.asPtr()) |b_ptr| {
            // If both strings are special strings, we can compare their hashes, to avoid
            // potentially expensive comparisons.
            const a_details = a_ptr.getStringDetails();
            const b_details = b_ptr.getStringDetails();
            if (std.meta.activeTag(a_details) == .special and std.meta.activeTag(b_details) == .special) {
                return try a_details.special.getHash() == try b_details.special.getHash();
            }
        };

        return try a.getString() == try b.getString();
    }

    pub fn getHashNoRegister(value: Value) !u256 {
        if (value.asPtr()) |obj| return obj.getHashNoRegister();

        // We don't save the hash when it's a primitive, since
        // it should be pretty cheap to compute it again.
        return hashutil.hashBytes(try value.getString());
    }
};

/// Special strings are strings that have special properties, such as being large,
/// having a different allocation backing then what's visible, or (in the future)
/// being memory mapped. This means that they have some more specialized handling,
/// so this is the structure that encapsulates that behavior.
pub const SpecialString = struct {
    // Special strings are special in that they can have extended properties
    // (mmaping is in the plans, for example). Since it has special properties,
    // we have to track them so it can be freed correctly.

    pub const HashAndInfo = struct {
        str_index: usize,
        value: ?*ObjectHead,
    };

    pub const Type = union(enum) {
        normal: [:0]u8,
        /// If the string was allocated with a different capacity
        /// than its current reported length, set this field.
        different_capacity: struct {
            string: [:0]u8,
            original_capacity: u64,
        },
    };
    value: Type,
    /// Length has not been determined if == `maxInt(u64)`.
    utf8_length: u64 = math.maxInt(u64),

    hashes: []HashAndInfo,
    hash: std.atomic.Value(?*u256),
    ref_count: std.atomic.Value(u32) = 1,

    pub fn deinit(self: *SpecialString) void {
        switch (self.value) {
            .normal => |string| global_gpa.free(string),
            .different_capacity => |info| {
                global_gpa.free(info.string.ptr[0..info.original_capacity :0]);
            },
            .temp => {
                // We don't want to free the string, as it's managed by someone else.
            },
        }
        if (self.hashes) |hashes| {
            for (hashes) |hash| if (hash.value) |val| val.decrRefCount();
        }

        global_gpa.destroy(self);
    }

    pub fn getHash(self: *SpecialString) error{OutOfMemory}!u256 {
        if (self.hash.load(.acquire)) |hash| {
            return hash.*;
        } else {
            const hash_alloc = try global_gpa.create(u256);
            hash_alloc.* = hashutil.hashBytes(self.getString());
            if (self.hash.cmpxchgStrong(null, hash_alloc, .release, .acquire)) |other_won| {
                global_gpa.destroy(hash_alloc);
                return other_won.?;
            }
            return hash_alloc.*;
        }
    }

    pub fn getCodepointLen(self: *SpecialString) ?u64 {
        const value = @atomicLoad(u64, &self.utf8_length, .monotonic);
        if (value == std.math.maxInt(u64)) return null else return value;
    }

    /// Value is `u64`, not `?u64`, since utf8 length should not ever
    /// change (excluding `LongString` temp strings).
    pub fn setCodepointLen(self: *SpecialString, value: u64) void {
        assert(value != std.math.maxInt(u64));
        @atomicStore(u64, &self.utf8_length, value, .monotonic);
    }

    pub fn getString(self: *SpecialString) [:0]const u8 {
        switch (self.string_type) {
            .normal => |string| return string,
            .temp => |temp| return temp,
            .different_capacity => |info| return info.string,
        }
    }

    pub fn incrRefCount(self: *SpecialString) void {
        incrRefCountOf(usize, &self.ref_count, options.threading);
    }

    pub fn decrRefCount(self: *SpecialString) void {
        if (decrRefCountOf(usize, &self.ref_count, options.threading) == 0) {
            self.deinit();
        }
    }
};

pub const ObjectHead = extern struct {
    pub const Metadata = packed struct(u8) {
        cross_thread: bool = false,
        hash_registered: bool = false,
        padding: u6 = 0,

        pub fn cmpxchgStrongHashRegistered(
            metadata: *Metadata,
            expected_registered_value: bool,
            new_registered_value: bool,
            comptime success_order: std.builtin.AtomicOrder,
            comptime fail_order: std.builtin.AtomicOrder,
        ) ?bool {
            var current = @atomicLoad(Metadata, metadata, fail_order);
            while (current.hash_registered == expected_registered_value) {
                var new_value = current;
                new_value.hash_registered = new_registered_value;
                const result = @cmpxchgWeak(Metadata, metadata, current, new_value, success_order, fail_order);
                if (result) |val| {
                    current = val; // Failed load was done with `fail_order`.
                } else return null; // Success!
            }
            return current.hash_registered;
        }
    };

    pub const StringMetadata = packed struct(u32) {
        len: u16 = 0,
        has_value: bool = false,
        is_special: bool = false,
        padding: u14,
    };

    /// See `setString` for an explanation of how the sequencing of
    /// `string` and `string_metadata` works.
    string: std.atomic.Value(?*anyopaque),
    string_metadata: std.atomic.Value(StringMetadata),
    metadata: Metadata,

    obj_type: *ObjectType,
    ref_count: u32,

    trace_values: ioutil.ConfigurableTrace(30, 16, options.trace_mem),

    pub const object_size = 64 + @sizeOf(@FieldType(ObjectHead, "trace_values"));
    comptime {
        assert(@sizeOf(ObjectHead) < object_size);
    }

    pub fn trace(obj: *ObjectHead, comptime fmt: []const u8, args: anytype) void {
        if (options.trace_mem) {
            // We need to create the message before locking the mutex, since `allocPrint` may
            // call `getString`, which in turn traces setting the string.
            const msg = std.fmt.allocPrint(debug_gpa, "\n" ++ fmt, args) catch unreachable;

            trace_mutex.lockUncancelable(global_io);
            defer trace_mutex.unlock(global_io);
            obj.trace_values.addAddr(@returnAddress(), msg);
        }
    }

    pub fn newObjectUninitialized(T: type) !*T {
        comptime assert(@bitOffsetOf(T, "head") == 0);
        comptime assert(@FieldType(T, "head") == ObjectHead);
        comptime assert(@sizeOf(T) <= object_size);

        const bytes = try global_gpa.alignedAlloc(u8, .of(ObjectHead), object_size);
        const obj: *ObjectHead = @ptrCast(bytes.ptr);
        obj.obj_type = &objects.NoneObject.Type;
        obj.ref_count = 1;

        return @ptrCast(bytes.ptr);
    }

    pub fn newObject(T: type) !*T {
        const new_obj = try newObjectUninitialized(T);
        new_obj.head.string = .init(null);
        new_obj.head.string_metadata = .init(.{});
        new_obj.head.metadata = .{};
        new_obj.head.obj_type = &@field(T, "Type");

        return new_obj;
    }

    pub fn freeBacking(obj: *ObjectHead) void {
        global_gpa.free(@as([*]u8, obj)[0..obj.alloc_size]);
        obj.* = undefined;
    }

    pub fn deinit(obj: *ObjectHead) void {
        obj.invalidateInternalRep();
        obj.invalidateString();
        obj.freeBacking();
    }

    pub const StringDetails = union(enum) {
        none,
        special: *SpecialString,
        normal: [:0]const u8,
    };
    pub fn getStringDetails(obj: *ObjectHead) StringDetails {
        const str_metadata = obj.string_metadata.load(if (obj.metadata.cross_thread) .acquire else .unordered);
        const str_value = obj.string.load(if (obj.metadata.cross_thread) .monotonic else .unordered);

        // We check `has_value` instead of `current_str`, since only `string_metadata` is
        // acquired. We could potentially read `current_str` with a value, but read
        // `string_metadata` with its old value. Hence, `string_metadata` is the source
        // of truth.
        if (str_metadata.has_value) {
            const current_str = str_value.?;

            if (str_metadata.is_special) {
                const as_special: *SpecialString = @ptrCast(current_str);
                return .{ .special = as_special };
            } else {
                const as_normal: [*]const u8 = @ptrCast(current_str);
                return .{ .normal = as_normal[0..str_metadata.len] };
            }
        } else {
            return .none;
        }
    }

    pub fn getString(obj: *ObjectHead) error{OutOfMemory}![:0]const u8 {
        switch (obj.getStringDetails()) {
            .special => |special| return special.getString(),
            .normal => |normal| return normal,
            .none => {
                // No string set (at least that we saw), so we'll go ahead and generate it
                // and attempt to set it. If we fail it's fine, since strings are always
                // generated the same way.
                const update_str_fn = obj.obj_type.update_string orelse {
                    debug.panic("Can't generate string for {} (should always have a string rep)", .{obj.obj_type.name});
                };
                update_str_fn(obj) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.OtherThreadSet => {},
                };

                switch (obj.getStringDetails()) {
                    .special => |special| return special.getString(),
                    .normal => |normal| return normal,
                    .none => unreachable,
                }
            },
        }
    }

    pub fn setString(obj: *ObjectHead, bytes: [:0]u8) error{ OutOfMemory, OtherThreadSet }!void {
        const hashes = try hashutil.scanAndResolveHashRefs(global_gpa, bytes);
        errdefer global_gpa.free(hashes);
        for (hashes) |hash| if (hash.value) |val| val.incrRefCount();
        errdefer for (hashes) |hash| if (hash.value) |val| val.release();

        if (hashes.len > 0 or bytes.len > 1024) {
            const special_string = try global_gpa.create(SpecialString);
            errdefer global_gpa.destroy(special_string);

            special_string.* = .{
                .value = .{ .normal = bytes },
                .hashes = hashes,
                .hash = null,
            };

            // Attempt to set the string.
            if (obj.string.cmpxchgStrong(null, special_string, .monotonic, .monotonic) != null) {
                return error.OtherThreadSet;
            }

            // If setting the string succeeded, we know we were the ones to win the race. Hence,
            // we can do a normal store for `string_metadata`. It needs to be .release though, so
            // other threads synchronize with the new string value.
            obj.string_metadata.store(.{
                .has_value = true,
                .is_special = true,
                // `.len` shouldn't be used in the case of a `SpecialString`, so we pick a value
                // that should hopefully blow things up if it is touched in this case.
                .len = std.math.maxInt(u16),
            }, .release);
        } else {
            // Attempt to set the string.
            if (obj.string.cmpxchgStrong(null, bytes.ptr, .monotonic, .monotonic) != null) {
                return error.OtherThreadSet;
            }

            // Similar logic to above.
            obj.string_metadata.store(.{
                .has_value = true,
                .is_special = false,
                .len = @intCast(bytes.len),
            }, .release);
        }
    }

    pub fn setStringLocalObject(obj: *ObjectHead, bytes: [:0]u8) error{OutOfMemory}!void {
        assert(obj.metadata.cross_thread == false);

        obj.setString(bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.OtherThreadSet => unreachable,
        };
    }

    pub fn getRefCount(obj: *ObjectHead) u32 {
        if (obj.metadata.cross_thread) {
            return @atomicLoad(u32, &obj.ref_count, .monotonic);
        } else {
            return obj.ref_count;
        }
    }

    pub fn incrRefCount(obj: *ObjectHead) void {
        incrRefCountOf(u32, &obj.ref_count, obj.metadata.cross_thread);
    }

    pub fn borrow(obj: *ObjectHead) *ObjectHead {
        obj.incrRefCount();
        return obj;
    }

    pub fn release(obj: *ObjectHead) void {
        const new_ref_count = decrRefCountOf(u32, &obj.ref_count, obj.metadata.cross_thread);

        // You may be wondering, why the heck `<= 1`, and not `== 0`? Because hash representatives
        // are owned by the hash registry, so there's a circular reference. But, hash representatives
        // can be safely freed if nobody else references them, so this is the needed logic to deal
        // with the circular reference created by the hash registry.
        if (new_ref_count <= 1 and @atomicLoad(ObjectHead.Metadata, &obj.metadata, .monotonic).hash_registered) {
            // It's impossible for this to not have a string, since if the hash
            // was registered, we know that it has a string.
            const hash = obj.getHashNoRegister() catch unreachable;
            registered_hashes.unregister(hash, obj);
        }

        if (new_ref_count == 0) obj.deinit();
    }

    pub fn invalidateString(obj: *ObjectHead) void {
        switch (obj.getStringDetails()) {
            .null => {},
            .normal => |normal| global_gpa.free(normal),
            .special => |special| special.decrRefCount(),
        }
        obj.string = .null;
    }

    pub fn invalidateInternalRep(obj: *ObjectHead) void {
        obj.obj_type.free_internal_rep(obj);
    }

    pub fn getHashNoRegister(obj: *ObjectHead) !u256 {
        switch (obj.getStringDetails()) {
            .special => |special| return special.getHash(),
            .none, .normal => {
                // Fall through.
            },
        }

        if (obj.obj_type == &objects.SourceObject.Type) {
            // If it's a source object, it may contain a cached hash.
            const as_source: *objects.SourceObject = @ptrCast(obj);
            if (as_source.hash.load(.monotonic)) |hash| {
                return hash.*;
            } else {
                const hash = hashutil.hashBytes(try obj.getString());
                const hash_ptr = try global_gpa.create(u256);
                hash_ptr.* = hash;
                if (as_source.hash.cmpxchgStrong(null, hash_ptr, .release, .acquire)) |other_set| {
                    global_gpa.free(hash_ptr);
                    return other_set.*;
                }
                return hash_ptr.*;
            }
        }
    }

    pub fn getHash(obj: *ObjectHead) !u256 {
        const hash = obj.getHashNoRegister();
        try registered_hashes.register(hash, obj); // Idempotent.
        return hash;
    }

    /// Does not initialize `alloc_len`.
    pub fn duplicateHeadOnto(src: *const ObjectHead, dest: *ObjectHead) error{OutOfMemory}!void {
        dest.obj_type = src.obj_type;
        dest.metadata = .{
            .cross_thread = false,
            .hash_registered = false,
        };

        switch (src.getStringDetails()) {
            .normal => |normal| {
                const new_str = try global_gpa.dupeSentinel(u8, normal, 0);
                dest.string.store(new_str.ptr, .unordered);
                dest.string_metadata = .{
                    .has_value = true,
                    .is_special = false,
                    .len = @intCast(new_str.len),
                };
            },
            .special => |special| {
                special.incrRefCount();
                dest.string.store(special.ptr, .unordered);
                dest.string_metadata = .{
                    .has_value = true,
                    .is_special = true,
                    .len = math.maxInt(u16),
                };
            },
            .none => {},
        }

        dest.ref_count = 1;
    }

    /// Assumes that `src` has a string.
    pub fn duplicateStringOnly(src: *const ObjectHead) error{OutOfMemory}!*ObjectHead {
        // Downgrade the duplicate to a non-specialized string.
        assert(std.meta.activeTag(src.getStringDetails()) != .none);
        const new_obj = try ObjectHead.newObjectUninitialized(objects.NoneObject);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj);
        return &new_obj.head;
    }
};

pub const hashutil = struct {
    pub const hash_prepend = "blake3~";
    pub const hash_chars = std.base64.url_safe_alphabet_chars;
    pub const hash_encoder = std.base64.Base64Encoder.init(hash_chars, null);
    pub const hash_decoder = std.base64.Base64Decoder.init(hash_chars, null);
    pub const hash_len = hash_encoder.calcSize(32);
    pub const hash_and_prepend_len = hash_prepend.len + hash_len;
    pub const HashInstance = struct { index: usize, hash: u256 };

    /// Uses blake3 to make a hash that, in theory, should never
    /// overlap with any other byte string.
    pub fn hashBytes(bytes: []const u8) u256 {
        var out: [32]u8 = @splat(0);
        std.crypto.hash.Blake3.hash(bytes, &out, .{});
        return @bitCast(out);
    }

    pub fn scanStringForHashRefs(arena: Allocator, bytes: []const u8) !std.ArrayList(HashInstance) {
        var found_hashes: std.ArrayList(HashInstance) = .empty;
        errdefer found_hashes.deinit(arena);

        if (bytes.len < hash_and_prepend_len) return found_hashes;

        var current_index: usize = 0;
        while (true) {
            if (std.mem.findPos(u8, bytes, current_index, hash_prepend)) |next| {
                if (bytes.len - next >= hash_and_prepend_len) {
                    var output: [32]u8 = undefined;
                    hash_decoder.decode(&output, bytes[(next + hash_prepend.len)..][0..hash_len]) catch {
                        current_index = next + hash_and_prepend_len;
                        continue;
                    };

                    try found_hashes.append(arena, .{ .index = current_index, .hash = @bitCast(output) });
                    current_index = next + hash_and_prepend_len;
                } else break;
            } else break;
        }

        return found_hashes;
    }

    /// Parse a string that is exactly a single hash reference.
    /// The string must start with `blake3^` at position 0, followed by a valid
    /// base64-encoded 32-byte hash.
    pub fn parseHashReference(bytes: []const u8) ?u256 {
        if (!std.mem.startsWith(u8, bytes, hash_prepend)) return null;
        if (bytes.len != hash_and_prepend_len) return null;

        var output: [32]u8 = undefined;
        hash_decoder.decode(&output, bytes[hash_prepend.len..]) catch return null;
        return @bitCast(output);
    }

    pub fn scanAndResolveHashRefs(arena: Allocator, bytes: []const u8) error{OutOfMemory}![]SpecialString.HashAndInfo {
        var found_hashes = try scanStringForHashRefs(arena, bytes);
        defer found_hashes.deinit(arena);

        // Look up all the found hashes.
        var resolved_hashes: []SpecialString.HashAndInfo = try arena.alloc(SpecialString.HashAndInfo, found_hashes.items.len);
        {
            registered_hashes.rw_lock.lockSharedUncancelable(global_io);
            defer registered_hashes.rw_lock.unlockShared(global_io);

            for (found_hashes.items, &resolved_hashes) |found_hash, *resolved_hash| {
                if (registered_hashes.entries.get(found_hash)) |resolved| {
                    resolved_hash.* = resolved.representative;
                } else {
                    resolved_hash.* = null;
                }
            }
        }

        return resolved_hashes;
    }
};

pub fn incrRefCountOf(comptime T: type, ref: *T, is_atomic: bool) void {
    if (is_atomic) {
        _ = @atomicRmw(T, ref, .Add, 1, .monotonic);
    } else {
        ref.* += 1;
    }
}

/// Returns value after decrementing. Multithreaded safe.
pub fn decrRefCountOf(comptime T: type, ref: *T, is_atomic: bool) T {
    var after_sub: T = undefined;
    if (is_atomic) {
        const before_sub = @atomicRmw(T, ref, .Sub, 1, .release);
        after_sub = before_sub - 1;

        if (after_sub == 0) {
            _ = @atomicLoad(T, ref, .acquire);
        }
    } else {
        ref.* -= 1;
        after_sub = ref.*;
    }

    return after_sub;
}

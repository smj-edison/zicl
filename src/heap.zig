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
const StructIterator = memutil.StructIterator;
const ioutil = @import("ioutil.zig");
const objects = @import("objects.zig");
const leak_check = @import("leak_check.zig");

pub var initialized: bool = false;
/// Use to lock `custom_types` or `script_metadata` when adding or removing
/// (no need to lock when using).
pub var init_mutex: std.Io.Mutex = .init;
/// Used to turn some panics into useful messages.
pub var running_leak_check: bool = false;

pub var global_gpa: mem.Allocator = undefined;
threadlocal var local_arena_instance: std.heap.ArenaAllocator = undefined;
pub threadlocal var local_arena: mem.Allocator = undefined;
pub var global_io: std.Io = undefined;
pub var nativefn_registry: NativeFnRegistry = .{};
pub var registered_hashes: HashRegistry = .{};

var trace_mutex: std.Io.Mutex = .init;
/// Preallocated fallback used by `[catch]` when a script OOMs and building
/// the real opts dict also OOMs.
var oom_error_options_dict: ?Value = null;

/// Initialize global heap state. Must be called once per process (or test).
pub fn initGlobals(gpa: Allocator, io: std.Io) !void {
    init_mutex.lockUncancelable(io);
    defer init_mutex.unlock(io);

    if (initialized) return;

    global_gpa = gpa;
    global_io = io;

    nativefn_registry = .{};
    registered_hashes = .{};

    leak_check.init();

    initialized = true;
}

/// Tear down global heap state. After this call, `initGlobals` may be called again.
pub fn deinitGlobals() void {
    init_mutex.lockUncancelable(global_io);
    defer init_mutex.unlock(global_io);

    if (!initialized) return;

    leak_check.deinit();

    nativefn_registry.deinit(global_gpa);
    registered_hashes.entries.deinit(global_gpa);

    initialized = false;
}

pub fn initThread(arena_gpa: Allocator) void {
    local_arena_instance = std.heap.ArenaAllocator.init(arena_gpa);
    local_arena = local_arena_instance.allocator();
}

pub fn deinitThread() void {
    local_arena_instance.deinit();
    local_arena = undefined;
}

pub fn testStart(gpa: Allocator, io: std.Io) !void {
    try initGlobals(gpa, io);
    initThread(gpa);
}

pub fn testFinish() void {
    if (options.trace_mem) leak_check.dumpLeaks() catch {};
    deinitThread();
    deinitGlobals();
}

pub export fn dumpLastTouchedTrace(fd: i32) void {
    leak_check.dumpLastTouchedTrace(fd);
}

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
        representative: *Object,
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

    pub fn getAndBorrow(registry: *HashRegistry, hash: u256) ?*Object {
        registry.rw_lock.lockSharedUncancelable(global_io);
        defer registry.rw_lock.unlockShared(global_io);

        if (registry.entries.getPtr(hash)) |entry| {
            assert(entry.instances.load(.monotonic) > 0);
            return entry.representative.borrow(); // Borrow while still locked.
        } else return null;
    }

    pub fn register(registry: *HashRegistry, key: u256, obj: *Object) !void {
        registry.rw_lock.lockSharedUncancelable(global_io);
        obj.makeCrossthread();

        if (registry.entries.getPtr(key)) |entry| {
            if (obj.hash_metadata.fetchOr(.{ .hash_registered = true }, .acq_rel).hash_registered == true) {
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
            if (obj.hash_metadata.fetchOr(.{ .hash_registered = true }, .acq_rel).hash_registered == true) {
                // Someone registered it in-between upgrading the shared lock to an exclusive lock.
            } else {
                // We successfully marked it as registered, so we can increment the instances count.
                _ = new_entry.value_ptr.instances.fetchAdd(1, .monotonic);
            }
        } else {
            new_entry.key_ptr.* = key;
            new_entry.value_ptr.* = .{
                .representative = obj.borrow(),
                .instances = .init(1),
            };

            // We have an exclusive lock on rw_lock, so nobody else could have registered this value.
            const expected: Object.HashMetadata = .{ .hash_registered = false, .is_representative = false };
            assert(obj.hash_metadata.fetchOr(.{ .hash_registered = true, .is_representative = true }, .acq_rel) == expected);
        }
    }

    pub fn unregister(registry: *HashRegistry, key: u256, obj: *Object) void {
        registry.rw_lock.lockSharedUncancelable(global_io);

        if (registry.entries.getPtr(key)) |entry| {
            if (obj.hash_metadata.fetchAnd(.{ .is_representative = true }, .acq_rel).hash_registered == false) {
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
                    const entry_second_check = registry.entries.getPtr(key).?;
                    const entry_derefed = entry_second_check.*;
                    if (entry_second_check.instances.load(.monotonic) != 0) {
                        // Someone was able to re-register this value when upgrading
                        // to an exclusive lock.
                        registry.rw_lock.unlock(global_io);
                        return;
                    }

                    entry_derefed.representative.hash_metadata.fetchAdd(.{}, .acq_rel);
                    assert(registry.entries.remove(key));
                    registry.rw_lock.unlock(global_io);

                    // Make sure to `decrRefCount` only after unlocking the mutex, to avoid
                    // recursive locking.
                    entry_derefed.representative.release();
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
        .head = .{ .tag = .none },
    };
};

pub const OptionalValue = enum(ValueBacking) {
    none = @bitCast(ValueRep.none_value),
    _,

    pub fn asValue(optional: OptionalValue) ?Value {
        if (optional != .none) {
            return @enumFromInt(@intFromEnum(optional));
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

    pub fn makeCrossthread(optional: OptionalValue) void {
        const val = optional.asValue() orelse return;
        const obj = val.asPtr() orelse return;
        obj.makeCrossthread();
    }

    pub fn release(optional: OptionalValue) void {
        if (optional.asValue()) |val| val.release();
    }

    pub fn orElse(optional: OptionalValue, otherwise: Value) Value {
        return optional.asValue() orelse otherwise;
    }

    pub fn swap(ref: *OptionalValue, new: Value) void {
        if (ref.asValue()) |obj| obj.release();
        ref.* = new.asOptional();
    }

    pub fn swapWithNone(ref: *OptionalValue) void {
        if (ref.asValue()) |val| val.release();
        ref.* = .none;
    }
};

pub const Value = enum(ValueBacking) {
    _,

    pub fn asOptional(value: Value) OptionalValue {
        return @enumFromInt(@intFromEnum(value));
    }

    pub fn asRep(value: Value) ValueRep {
        return @bitCast(@intFromEnum(value));
    }

    pub fn isFloat(value: Value) bool {
        const rep = value.asRep();
        const is_nan = rep.head.nan_value == 0x0FFF;
        return !is_nan or (is_nan and rep.head.tag == .canonical_nan);
    }

    const Expanded = union(enum) {
        ptr: *Object,
        int: i32,
        false,
        true,
        interned: [:0]const u8,
        float: f64,
    };
    pub fn expandedValue(value: Value) Expanded {
        const rep = value.asRep();
        if (value.isFloat()) return .{ .float = @bitCast(rep) };
        switch (rep.head.tag) {
            .canonical_nan => unreachable, // Already handled by `.isFloat()`.
            .none => unreachable,
            .ptr => return .{ .ptr = @ptrFromInt(rep.value.ptr) },
            .int => return .{ .int = rep.value.int.data },
            .false => return .false,
            .true => return .true,
            .interned => {
                const bytes_ptr = @as([*]const u8, @ptrFromInt(value.asRep().value.interned));
                const len_ptr = bytes_ptr - @sizeOf(usize);
                const len = mem.readInt(usize, len_ptr[0..@sizeOf(usize)], .native);
                const bytes = bytes_ptr[0..len :0];
                return .{ .interned = bytes };
            },
        }
    }

    pub fn asPtr(value: Value) ?*Object {
        switch (value.expandedValue()) {
            .ptr => |val| return val,
            else => return null,
        }
    }

    pub fn asInt(value: Value) ?i32 {
        switch (value.expandedValue()) {
            .int => |val| return val,
            else => return null,
        }
    }

    pub fn asFloat(value: Value) ?f64 {
        switch (value.expandedValue()) {
            .float => |val| return val,
            else => return null,
        }
    }

    pub fn asType(value: Value, T: type) ?*T {
        const obj = value.asPtr() orelse return null;
        if (obj.vtable == &T.vtable) return obj.castTo(T);
        return null;
    }

    pub fn canShimmer(value: Value) bool {
        if (value.asPtr()) |obj| {
            return obj.canShimmer();
        } else {
            // Primitives can't shimmer.
            return false;
        }
    }

    pub fn canMutate(value: Value) bool {
        // Note: a crossthread object can _never_ mutate. A lot of asserts around
        // the codebase assume that `canMutate` means that an object is not crossthread.

        if (value.asPtr()) |obj| {
            return obj.canMutate();
        } else {
            // Primitives can't mutate.
            return false;
        }

        return true;
    }

    pub fn incrRefCount(value: Value) void {
        if (value.asPtr()) |obj| obj.incrRefCount();
    }

    pub fn borrow(value: Value) Value {
        value.incrRefCount();
        return value;
    }

    pub fn release(value: Value) void {
        if (value.asPtr()) |obj| obj.release();
    }

    pub fn duplicate(value: Value) !Value {
        if (value.asPtr()) |obj| {
            return (try obj.duplicate()).asValue();
        } else {
            return value;
        }
    }

    pub inline fn trace(value: Value, comptime fmt: []const u8, args: anytype) void {
        leak_check.globalTrace(.other, value, fmt, args);
    }

    pub fn duplicateAsBoxed(value: Value) !*Object {
        if (value.asPtr()) |obj| {
            return (try obj.duplicate()).asValue();
        } else {
            return try value.box();
        }
    }

    /// Must be a primitive.
    pub fn box(value: Value) !*Object {
        switch (value.expandedValue()) {
            .ptr => unreachable,
            .int => |int| {
                const obj = try objects.Integer.newBoxed(int);
                return Object.from(objects.Integer, obj);
            },
            .false => {
                const obj = try objects.Boolean.newBoxed(false);
                return Object.from(objects.Boolean, obj);
            },
            .true => {
                const obj = try objects.Boolean.newBoxed(true);
                return Object.from(objects.Boolean, obj);
            },
            .interned => |bytes| {
                const obj = try Object.newObject(objects.String);
                errdefer obj.head.freeBacking();
                const duped = try global_gpa.dupeSentinel(u8, bytes, 0);
                errdefer global_gpa.free(duped);
                try obj.head.setStringLocalObject(duped);
                return obj.head;
            },
            .float => |float| {
                const obj = try objects.Float.newBoxed(float);
                return Object.from(objects.Float, obj);
            },
        }
    }

    pub fn duplicateBoxed(value: Value) !*Object {
        if (value.asPtr()) |obj| {
            if (obj.vtable.duplicate) |duplicate_fn| {
                return try duplicate_fn(obj);
            } else {
                debug.panic("Could not duplicate {s}", .{obj.vtable.name});
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
        return @enumFromInt(@as(ValueBacking, @bitCast(rep)));
    }

    pub fn makeCrossthread(value: Value) void {
        if (value.asPtr()) |obj| obj.makeCrossthread();
    }

    pub fn newInt(value: i32) Value {
        return Value.fromRep(.{
            .head = .{ .tag = .int },
            .value = .{ .int = .{ .data = value } },
        });
    }

    pub fn newFloat(value: f64) Value {
        const rep: ValueRep = @bitCast(value);
        if (rep.head.nan_value == 0x0FFF) assert(rep.head.tag == .canonical_nan);
        return @enumFromInt(@as(ValueBacking, @bitCast(value)));
    }

    pub fn newBool(value: bool) Value {
        return Value.fromRep(.{
            .head = .{ .tag = if (value) .true else .false },
        });
    }

    pub fn getString(value: Value) ![:0]const u8 {
        switch (value.expandedValue()) {
            .float => |float| {
                var buf: [350]u8 = undefined;
                const rendered = objects.Float.renderFloat(float, &buf);
                return try local_arena.dupeSentinel(u8, rendered, 0);
            },
            .ptr => |obj| return try obj.getString(),
            .int => |int| return try std.fmt.allocPrintSentinel(local_arena, "{}", .{int}, 0),
            .false => return "false",
            .true => return "true",
            .interned => {
                // Length of interned string is stored right before.
                const bytes_ptr = @as([*]u8, @ptrFromInt(value.asRep().value.interned));
                const len_ptr = bytes_ptr - @sizeOf(usize);
                const len = mem.readInt(usize, len_ptr[0..@sizeOf(usize)], .native);
                return bytes_ptr[0..len :0];
            },
        }
    }

    /// Guaranteed to return error.OutOfMemory if and only if the `Value` is
    /// an object pointer, and that Object OOM'd while generating its string.
    pub fn getStringWithBuffer(value: Value, buf: *[350]u8) ![:0]const u8 {
        comptime assert(std.fmt.count("{}", .{-std.math.floatMin(f64)}) + 1 <= 350); // + 1 for null.
        comptime assert(std.fmt.count("{}", .{-std.math.floatMax(f64)}) + 1 <= 350);

        switch (value.expandedValue()) {
            .float => |float| return objects.Float.renderFloat(float, buf),
            .ptr => |obj| return try obj.getString(),
            .int => |int| return std.fmt.bufPrintSentinel(buf, "{}", .{int}, 0) catch unreachable,
            .false => return "false",
            .true => return "true",
            .interned => {
                // Length of interned string is stored right before.
                const bytes_ptr = @as([*]u8, @ptrFromInt(value.asRep().value.interned));
                const len_ptr = bytes_ptr - @sizeOf(usize);
                const len = mem.readInt(usize, len_ptr[0..@sizeOf(usize)], .native);
                return bytes_ptr[0..len :0];
            },
        }
    }

    /// Guaranteed to return error.OutOfMemory if and only if one of the value `Value`'s
    /// is an object pointer, and that Object OOM'd while generating its string.
    pub fn equals(a: Value, b: Value) error{OutOfMemory}!bool {
        // If they're both primitives, we can compare their values directly. Note that we can't compare
        // interned string values directly, since they're not guaranteed to be unique.
        const is_a_primitive = switch (a.expandedValue()) {
            .int, .false, .true, .interned, .float => true,
            else => false,
        };
        const is_b_primitive = switch (b.expandedValue()) {
            .int, .false, .true, .interned, .float => true,
            else => false,
        };
        if (is_a_primitive and is_b_primitive) return a == b;

        if (a.asPtr()) |a_ptr| if (b.asPtr()) |b_ptr| {
            // If both strings are special strings, we can compare their hashes, to avoid
            // potentially expensive comparisons.
            const a_details = a_ptr.getStringDetails();
            const b_details = b_ptr.getStringDetails();
            if (std.meta.activeTag(a_details) == .special and std.meta.activeTag(b_details) == .special) {
                return try a_details.special.getHash() == try b_details.special.getHash();
            }
        };

        var buf_a: [350]u8 = undefined;
        const a_bytes = try a.getStringWithBuffer(&buf_a);
        var buf_b: [350]u8 = undefined;
        const b_bytes = try b.getStringWithBuffer(&buf_b);
        return mem.eql(u8, a_bytes, b_bytes);
    }

    pub fn equalsString(value: Value, str: []const u8) error{OutOfMemory}!bool {
        const bytes = try value.getString();
        return mem.eql(u8, bytes, str);
    }

    pub fn getHashNoRegister(value: Value) !u256 {
        if (value.asPtr()) |obj| return obj.getHashNoRegister();

        // We don't save the hash when it's a primitive, since
        // it should be pretty cheap to compute it again.
        var buf: [350]u8 = undefined;
        return hashutil.hashBytes(value.getStringWithBuffer(&buf) catch unreachable);
    }
};

/// Produces a type that owns a length-prefixed, NUL-terminated interned string
/// buffer in rodata. The layout is `[@sizeOf(usize) bytes of length][bytes][0]`,
/// matching how `getString` reads the length from just before the bytes pointer.
/// The buffer's address is stable for the life of the program but is only known
/// at run time, so the `Value` is built by `value()` at run time -- it can't be
/// a comptime `const`, since the final rodata address isn't known at compile.
pub fn createInternedString(comptime bytes: []const u8) type {
    const len_bytes = comptime blk: {
        var b: [@sizeOf(usize)]u8 = undefined;
        std.mem.writeInt(usize, &b, bytes.len, .native);
        break :blk b;
    };
    const null_byte: [1]u8 = .{0};
    const combined = len_bytes ++ bytes ++ null_byte;
    return struct {
        const interned_str = combined;

        /// Pointer to the bytes (just past the length prefix), NUL-terminated.
        pub fn get() [*:0]const u8 {
            const s = interned_str.ptr[@sizeOf(usize)..(interned_str.len - 1) :0];
            return s.ptr;
        }

        pub fn value() Value {
            const ptr = get();
            return Value.fromRep(.{
                .head = .{ .tag = .interned },
                .value = .{ .interned = @intCast(@intFromPtr(ptr)) },
            });
        }
    };
}

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
        value: ?*Object,
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
    utf8_length: std.atomic.Value(u64) = .init(math.maxInt(u64)),

    tracked_hashes: []HashAndInfo,
    hash: std.atomic.Value(?*u256),
    ref_count: std.atomic.Value(u32) = .init(1),

    pub fn deinit(self: *SpecialString) void {
        switch (self.value) {
            .normal => |string| global_gpa.free(string),
            .different_capacity => |info| {
                global_gpa.free(info.string.ptr[0..info.original_capacity :0]);
            },
        }
        for (self.tracked_hashes) |hash| if (hash.value) |val| val.release();
        global_gpa.free(self.tracked_hashes);
        if (self.hash.load(.monotonic)) |hash| global_gpa.destroy(hash);

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
                return other_won.?.*;
            }
            return hash_alloc.*;
        }
    }

    pub fn getCodepointLength(self: *SpecialString) ?u64 {
        const value = self.utf8_length.load(.monotonic);
        if (value == std.math.maxInt(u64)) return null else return value;
    }

    /// Value is `u64`, not `?u64`, since utf8 length should not ever
    /// change.
    pub fn setCodepointLength(self: *SpecialString, value: u64) void {
        assert(value != std.math.maxInt(u64));
        self.utf8_length.store(value, .monotonic);
    }

    pub fn getString(self: *SpecialString) [:0]const u8 {
        switch (self.value) {
            .normal => |string| return string,
            .different_capacity => |info| return info.string,
        }
    }

    pub fn incrRefCount(self: *SpecialString) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    pub fn decrRefCount(self: *SpecialString) void {
        if (self.ref_count.fetchSub(1, .release) == 1) {
            // The release store above synchronizes with this acquire load to
            // ensure all prior operations on this string (from other threads)
            // are visible before we deinit and free it.
            _ = self.ref_count.load(.acquire);
            self.deinit();
        }
    }
};

pub const Object = struct {
    pub const VTable = struct {
        duplicate: ?*const fn (src: *const Object) error{OutOfMemory}!*Object,
        free_internal_rep: ?*const fn (obj: *Object) void,
        update_string: ?*const fn (obj: *Object) error{ OutOfMemory, OtherThreadSet }!void,
        make_crossthread: ?*const fn (obj: *Object) void,
        enumerate_struct: ?*const fn (
            obj: *const Object,
            ctx: StructIterator,
            node_info: *const StructIterator.NodeInfo,
        ) StructIterator.Error!void,
        name: [:0]const u8,
    };

    pub const Metadata = packed struct(u8) {
        cross_thread: bool = false,
        padding: u7 = 0,
    };

    pub const HashMetadata = packed struct(u8) {
        hash_registered: bool = false,
        is_representative: bool = false,
        padding: u6 = 0,
    };

    pub const StringMetadata = packed struct(u32) {
        len: u16 = 0,
        has_value: bool = false,
        is_special: bool = false,
        padding: u14 = 0,
    };

    /// See `setString` for an explanation of how the sequencing of
    /// `string` and `string_metadata` works.
    string: std.atomic.Value(?*anyopaque),
    string_metadata: std.atomic.Value(StringMetadata),
    metadata: Metadata,
    hash_metadata: std.atomic.Value(HashMetadata),

    vtable: *const VTable,
    ref_count: u32,

    pub const object_size: usize = 80;
    comptime {
        assert(@sizeOf(Object) < object_size);
    }

    pub fn from(T: type, ptr: *T) *Object {
        const aligned_bytes: [*]align(@alignOf(Object)) u8 = @ptrCast(@alignCast(ptr));
        return @ptrCast(aligned_bytes - @sizeOf(Object));
    }

    pub fn fromConst(T: type, ptr: *const T) *const Object {
        const aligned_bytes: [*]align(@alignOf(Object)) const u8 = @ptrCast(@alignCast(ptr));
        return @ptrCast(aligned_bytes - @sizeOf(Object));
    }

    pub fn castToInner(obj: *Object) *align(@alignOf(Object)) anyopaque {
        const aligned_bytes: [*]align(@alignOf(Object)) u8 = @ptrCast(@alignCast(obj));
        return @ptrCast(aligned_bytes + @sizeOf(Object));
    }

    /// Asserts that `obj` has type `T.vtable`.
    pub fn castTo(obj: *Object, T: type) *T {
        assert(obj.vtable == &T.vtable);
        const aligned_bytes: [*]align(@alignOf(Object)) u8 = @ptrCast(@alignCast(obj));
        return @ptrCast(aligned_bytes + @sizeOf(Object));
    }

    pub fn constCastTo(obj: *const Object, T: type) *const T {
        assert(obj.vtable == &T.vtable);
        const aligned_bytes: [*]align(@alignOf(Object)) const u8 = @ptrCast(@alignCast(obj));
        return @ptrCast(aligned_bytes + @sizeOf(Object));
    }

    pub fn asValue(obj: *Object) Value {
        return Value.fromRep(.{
            .head = .{ .tag = .ptr },
            .value = .{ .ptr = @intCast(@intFromPtr(obj)) },
        });
    }

    pub fn canMutate(obj: *const Object) bool {
        if (obj.getRefCount() > 1) return false;
        // Cross thread objects can't be mutated, even if the ref count is 1, because
        // objects can be indirectly accessed by traversing lists. Imagine thread 1
        // is traversing a list, while thread 2 is modifying the list elements.
        // Thread 2 sees that the list element only has ref count one (since it's only
        // owned by the list), so it figures it's safe to modify. Wrong! It's not safe
        // to modify, because thread 1 is also reading the list. This is why crossthread
        // objects are never safe to modify, or even shimmer.
        if (obj.metadata.cross_thread) return false;
        // If the hash is registered, it means it is considered frozen. We can't very
        // well mutate something that has a fixed value. Note we can load this as
        // unordered, since it's not a crossthread object, as we just checked above.
        if (obj.hash_metadata.load(.unordered).hash_registered) return false;
        return true;
    }

    pub fn canShimmer(obj: *const Object) bool {
        return !obj.metadata.cross_thread;
    }

    pub fn newObjectUninitialized(T: type) !struct { head: *Object, body: *T } {
        comptime assert(@sizeOf(Object) + @sizeOf(T) <= object_size);
        comptime assert(@alignOf(T) <= @alignOf(Object));

        const bytes = try global_gpa.alignedAlloc(u8, .of(Object), object_size);
        const obj: *Object = @ptrCast(bytes.ptr);
        obj.vtable = &T.vtable;
        obj.ref_count = 1;
        obj.metadata = .{};
        obj.hash_metadata = .init(.{});

        leak_check.globalTrace(.alloc, obj.asValue(), "Created object of type {s}", .{@typeName(T)});

        return .{
            .head = @ptrCast(bytes),
            .body = @ptrCast(bytes.ptr + @sizeOf(Object)),
        };
    }

    pub fn newObject(T: type) !struct { head: *Object, body: *T } {
        const new_obj = try newObjectUninitialized(T);
        new_obj.head.string = .init(null);
        new_obj.head.string_metadata = .init(.{});
        return .{ .head = new_obj.head, .body = new_obj.body };
    }

    pub fn duplicate(obj: *Object) !*Object {
        if (obj.vtable.duplicate) |duplicate_fn| {
            return try duplicate_fn(obj);
        } else {
            debug.panic("Could not duplicate {s}", .{obj.vtable.name});
        }
    }

    pub fn makeCrossthread(obj: *Object) void {
        if (obj.vtable.make_crossthread) |make_crossthread_fn| make_crossthread_fn(obj);
        obj.metadata.cross_thread = true;
    }

    pub fn enumerateStruct(
        ctx: StructIterator,
        info: *const StructIterator.NodeInfo,
    ) StructIterator.Error!void {
        const obj: *const Object = @ptrCast(@alignCast(info.node));
        switch (obj.getStringDetails()) {
            .special => |special| try ctx.followNode(SpecialString, info, "string", special),
            .normal => |normal| {
                const child_node: StructIterator.NodeInfo = .{
                    .parent_info = info,
                    .node = normal.ptr,
                    .enumerate_struct = null,
                    .type_name = @typeName([:0]const u8),
                    .as_string = normal,
                };
                try ctx.vtable.visit_node(ctx, &child_node, "string");
            },
            .none => {},
        }
        try ctx.addField(Metadata, info, "metadata", "{any}", obj.metadata);
        try ctx.addField(u32, info, "ref_count", "{}", obj.getRefCount());
        if (obj.vtable.enumerate_struct) |walk_fn| try walk_fn(obj, ctx, info);
    }

    pub fn freeBacking(obj: *Object) void {
        leak_check.globalTrace(.free, obj.asValue(), "Freed", .{});
        const bytes: [*]align(@alignOf(Object)) u8 = @ptrCast(@alignCast(obj));
        const slice: []align(@alignOf(Object)) u8 = bytes[0..object_size];
        global_gpa.free(slice);
    }

    pub fn deinit(obj: *Object) void {
        obj.invalidateInternalRep();
        obj.freeStringInner();
        obj.freeBacking();
    }

    pub const StringDetails = union(enum) {
        none,
        special: *SpecialString,
        normal: [:0]const u8,
    };
    pub fn getStringDetails(obj: *const Object) StringDetails {
        const str_metadata = if (obj.metadata.cross_thread)
            obj.string_metadata.load(.acquire)
        else
            obj.string_metadata.raw;
        const str_value = if (obj.metadata.cross_thread)
            obj.string.load(.monotonic)
        else
            obj.string.raw;

        // We check `has_value` instead of `current_str`, since only `string_metadata` is
        // acquired. We could potentially read `current_str` with a value, but read
        // `string_metadata` with its old value. Hence, `string_metadata` is the source
        // of truth.
        if (str_metadata.has_value) {
            const current_str = str_value.?;

            if (str_metadata.is_special) {
                const as_special: *SpecialString = @ptrCast(@alignCast(current_str));
                return .{ .special = as_special };
            } else {
                const as_normal: [*]const u8 = @ptrCast(current_str);
                return .{ .normal = as_normal[0..str_metadata.len :0] };
            }
        } else {
            return .none;
        }
    }

    pub fn getString(obj: *Object) error{OutOfMemory}![:0]const u8 {
        switch (obj.getStringDetails()) {
            .special => |special| return special.getString(),
            .normal => |normal| return normal,
            .none => {
                // No string set (at least that we saw), so we'll go ahead and generate it
                // and attempt to set it. If we fail it's fine, since strings are always
                // generated the same way.
                const update_str_fn = obj.vtable.update_string orelse {
                    debug.panic("Can't generate string for {s} (should always have a string rep)", .{obj.vtable.name});
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

    /// Takes ownership of `bytes` and sets it as the object's string representation.
    /// On error.OtherThreadSet, frees `bytes` and returns normally.
    /// On error.OutOfMemory, frees `bytes` and propagates the error.
    pub fn setStringIgnoreRace(obj: *Object, bytes: [:0]u8) error{OutOfMemory}!void {
        obj.setStringOwning(bytes) catch |err| switch (err) {
            error.OutOfMemory => {
                global_gpa.free(bytes);
                return error.OutOfMemory;
            },
            error.OtherThreadSet => {
                global_gpa.free(bytes);
            },
        };
    }

    pub fn setStringDuplicatingIgnoreRace(obj: *Object, bytes: []const u8) error{OutOfMemory}!void {
        const owned_bytes = try global_gpa.dupeSentinel(u8, bytes, 0);
        obj.setStringOwning(owned_bytes) catch |err| {
            global_gpa.free(owned_bytes);
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.OtherThreadSet => {},
            }
        };
    }

    pub fn setStringDuplicating(obj: *Object, bytes: []const u8) error{ OutOfMemory, OtherThreadSet }!void {
        const owned_bytes = try global_gpa.dupeSentinel(u8, bytes, 0);
        errdefer global_gpa.free(owned_bytes);
        try obj.setStringOwning(owned_bytes);
    }

    pub fn setStringOwning(obj: *Object, bytes: [:0]u8) error{ OutOfMemory, OtherThreadSet }!void {
        const hashes = try hashutil.scanAndResolveHashRefs(global_gpa, bytes);
        errdefer global_gpa.free(hashes);
        errdefer for (hashes) |hash| if (hash.value) |val| val.release();

        if (hashes.len > 0 or bytes.len > 1024) {
            const special_string = try global_gpa.create(SpecialString);
            errdefer global_gpa.destroy(special_string);

            special_string.* = .{
                .value = .{ .normal = bytes },
                .tracked_hashes = hashes,
                .hash = .init(null),
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

        obj.asValue().trace("Set string to \"{s}\"", .{bytes});
    }

    /// Takes ownership of `bytes`.
    pub fn setStringLocalObject(obj: *Object, bytes: [:0]u8) error{OutOfMemory}!void {
        assert(obj.metadata.cross_thread == false);

        const hashes = try hashutil.scanAndResolveHashRefs(global_gpa, bytes);
        errdefer global_gpa.free(hashes);
        errdefer for (hashes) |hash| if (hash.value) |val| val.release();

        if (hashes.len > 0 or bytes.len > 1024) {
            const special_string = try global_gpa.create(SpecialString);
            errdefer global_gpa.destroy(special_string);

            special_string.* = .{
                .value = .{ .normal = bytes },
                .tracked_hashes = hashes,
                .hash = .init(null),
            };

            obj.string = .init(@ptrCast(special_string));
            obj.string_metadata = .init(.{
                .has_value = true,
                .is_special = true,
                // `.len` shouldn't be used in the case of a `SpecialString`, so we pick a value
                // that should hopefully blow things up if it is touched in this case.
                .len = std.math.maxInt(u16),
            });
        } else {
            obj.string = .init(@ptrCast(bytes.ptr));
            obj.string_metadata = .init(.{
                .has_value = true,
                .is_special = false,
                .len = @intCast(bytes.len),
            });
        }

        obj.asValue().trace("Set string to \"{s}\"", .{bytes});
    }

    pub fn getRefCount(obj: *const Object) u32 {
        if (obj.metadata.cross_thread) {
            return @atomicLoad(u32, &obj.ref_count, .monotonic);
        } else {
            return obj.ref_count;
        }
    }

    pub fn incrRefCount(obj: *Object) void {
        const new_count = incrRefCountOf(u32, &obj.ref_count, obj.metadata.cross_thread);
        obj.asValue().trace("Incremented ref count (now {})", .{new_count});
    }

    pub fn borrow(obj: *Object) *Object {
        obj.incrRefCount();
        return obj;
    }

    pub fn release(obj: *Object) void {
        const new_ref_count = decrRefCountOf(u32, &obj.ref_count, obj.metadata.cross_thread);
        obj.asValue().trace("Decremented ref count (now {})", .{new_ref_count});

        // You may be wondering, why the heck `<= 1`, and not `== 0`? Because hash representatives
        // are owned by the hash registry, so there's a circular reference. But, hash representatives
        // can be safely freed if nobody else references them, so this is the needed logic to deal
        // with the circular reference created by the hash registry.
        if (new_ref_count <= 1) {
            const metadata = obj.hash_metadata.load(.monotonic);
            if (metadata.is_representative) {
                // It's impossible for this to not have a string, since if the hash
                // was registered, we know that it has a string.
                const hash = obj.getHashNoRegister() catch unreachable;
                registered_hashes.unregister(hash, obj);
            }

            if (new_ref_count == 0) {
                if (metadata.hash_registered) {
                    const hash = obj.getHashNoRegister() catch unreachable;
                    registered_hashes.unregister(hash, obj);
                }
                obj.deinit();
            }
        }
    }

    fn freeStringInner(obj: *Object) void {
        switch (obj.getStringDetails()) {
            .none => {},
            .normal => |normal| global_gpa.free(normal),
            .special => |special| special.decrRefCount(),
        }
        obj.string.store(null, .unordered);
        obj.string_metadata.store(.{}, .unordered);
    }

    pub fn invalidateString(obj: *Object) void {
        assert(obj.canShimmer());
        switch (obj.getStringDetails()) {
            .special => |special| obj.asValue().trace("Invalidate string (was {s})", .{special.getString()}),
            .normal => |bytes| obj.asValue().trace("Invalidate string (was {s})", .{bytes}),
            .none => {},
        }
        obj.freeStringInner();
    }

    pub fn invalidateInternalRep(obj: *Object) void {
        obj.asValue().trace("Invalidate body", .{});
        if (obj.vtable.free_internal_rep) |free_fn| free_fn(obj);
    }

    pub fn getHashNoRegister(obj: *Object) !u256 {
        switch (obj.getStringDetails()) {
            .special => |special| return special.getHash(),
            .none, .normal => {
                // Fall through.
            },
        }

        if (obj.vtable == &objects.Source.vtable) {
            // If it's a source object, it may contain a cached hash.
            const as_source: *objects.Source = Object.castTo(obj, objects.Source);
            if (as_source.hash.load(.monotonic)) |hash| {
                return hash.*;
            } else {
                const hash = hashutil.hashBytes(try obj.getString());
                const hash_ptr = try global_gpa.create(u256);
                hash_ptr.* = hash;
                if (as_source.hash.cmpxchgStrong(null, hash_ptr, .release, .acquire)) |other_set| {
                    global_gpa.destroy(hash_ptr);
                    return other_set.?.*;
                }
                return hash_ptr.*;
            }
        }

        return hashutil.hashBytes(try obj.getString());
    }

    pub fn getHashRegistering(obj: *Object) !u256 {
        const hash = try obj.getHashNoRegister();
        try registered_hashes.register(hash, obj); // Idempotent.
        return hash;
    }

    pub fn duplicateHeadOnto(src: *const Object, dest: *Object) error{OutOfMemory}!void {
        dest.vtable = src.vtable;
        dest.metadata = .{
            .cross_thread = false,
        };
        dest.hash_metadata = .init(.{
            .hash_registered = false,
            .is_representative = false,
        });

        switch (src.getStringDetails()) {
            .normal => |normal| {
                const new_str = try global_gpa.dupeSentinel(u8, normal, 0);
                dest.string = .init(new_str.ptr);
                dest.string_metadata = .init(.{
                    .has_value = true,
                    .is_special = false,
                    .len = @intCast(new_str.len),
                });
            },
            .special => |special| {
                special.incrRefCount();
                dest.string = .init(special);
                dest.string_metadata = .init(.{
                    .has_value = true,
                    .is_special = true,
                    .len = math.maxInt(u16),
                });
            },
            .none => {},
        }

        dest.ref_count = 1;
    }

    pub fn duplicateStringOnly(src: *const Object) !*Object {
        const new_obj = try newObjectUninitialized(objects.None);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj.head);

        return new_obj.head;
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
    /// The string must start with `blake3~` at position 0, followed by a valid
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
        const resolved_hashes: []SpecialString.HashAndInfo = try arena.alloc(SpecialString.HashAndInfo, found_hashes.items.len);
        {
            registered_hashes.rw_lock.lockSharedUncancelable(global_io);
            defer registered_hashes.rw_lock.unlockShared(global_io);

            for (found_hashes.items, resolved_hashes) |found_hash, *resolved_hash| {
                resolved_hash.* = .{
                    .str_index = found_hash.index,
                    .value = if (registered_hashes.entries.get(found_hash.hash)) |resolved| resolved.representative.borrow() else null,
                };
            }
        }

        return resolved_hashes;
    }
};

pub fn incrRefCountOf(comptime T: type, ref: *T, is_atomic: bool) T {
    if (is_atomic) {
        const old = @atomicRmw(T, ref, .Add, 1, .monotonic);
        return old + 1;
    } else {
        ref.* += 1;
        return ref.*;
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

fn testBoxInteger(ta: std.mem.Allocator) !void {
    try testStart(ta, testing.io);
    defer testFinish();

    const obj = try Value.newInt(42).box();
    defer obj.release();
    try testing.expectEqualStrings("42", try obj.getString());
}

test "value box int" {
    try testing.checkAllAllocationFailures(testing.allocator, testBoxInteger, .{});
}

fn testBoxFloat(ta: std.mem.Allocator) !void {
    try testStart(ta, testing.io);
    defer testFinish();

    const obj = try Value.newFloat(3.14).box();
    defer obj.release();
    try testing.expectEqualStrings("3.14", try obj.getString());
}

test "value box float" {
    try testing.checkAllAllocationFailures(testing.allocator, testBoxFloat, .{});
}

fn testBoxBool(ta: std.mem.Allocator) !void {
    try testStart(ta, testing.io);
    defer testFinish();

    const true_obj = try Value.newBool(true).box();
    defer true_obj.release();
    try testing.expectEqualStrings("true", try true_obj.getString());

    const false_obj = try Value.newBool(false).box();
    defer false_obj.release();
    try testing.expectEqualStrings("false", try false_obj.getString());
}

test "value box bool" {
    try testing.checkAllAllocationFailures(testing.allocator, testBoxBool, .{});
}

fn testReferenceCounting(ta: std.mem.Allocator) !void {
    try testStart(ta, testing.io);
    defer testFinish();

    const obj = (try objects.String.new("foo")).asHead();
    try testing.expectEqual(@as(u32, 1), obj.getRefCount());
    _ = obj.borrow();
    try testing.expectEqual(@as(u32, 2), obj.getRefCount());
    obj.release();
    try testing.expectEqual(@as(u32, 1), obj.getRefCount());
    obj.release();
}

test "object ref count" {
    try testing.checkAllAllocationFailures(testing.allocator, testReferenceCounting, .{});
}

fn testDuplicateObject(ta: std.mem.Allocator) !void {
    try testStart(ta, testing.io);
    defer testFinish();

    const original = (try objects.String.new("to duplicate")).asHead();
    defer original.release();
    const dup_obj = try original.duplicate();
    defer dup_obj.release();
    try testing.expectEqualStrings("to duplicate", try dup_obj.getString());
}

test "object duplicate" {
    try testing.checkAllAllocationFailures(testing.allocator, testDuplicateObject, .{});
}

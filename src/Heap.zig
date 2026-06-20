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
const ioutil = @import("ioutil.zig");
const strutil = @import("strutil.zig");
const memutil = @import("memutil.zig");
const StringAllocator = @import("StringAllocator.zig");
const Tokenizer = @import("Tokenizer.zig");
const expr_parse = @import("expr_parse.zig");
const regex = @import("regex.zig");
const pcre2 = @import("pcre2");
const objutil = @import("objutil.zig");

threadlocal var debugging_buffer: if (options.trace_mem) [16 * 1024 * 1024]u8 else void = undefined;
threadlocal var debugging_gpa: if (options.trace_mem) memutil.RingBufferAllocator else void = undefined;
/// Use this for debugging objects (traces, etc) that can afford to leak.
threadlocal var debug_gpa: Allocator = undefined;

pub const GlobalHeapState = struct {
    initialized: bool = false,
    /// Use to lock `custom_types` or `script_metadata` when adding or removing
    /// (no need to lock when using).
    mutex: std.Io.Mutex = .init,
    /// Used to turn some panics into useful messages.
    running_leak_check: bool = false,
};

pub var state: GlobalHeapState = .{};
pub var global_gpa: mem.Allocator = undefined;
pub threadlocal var local_arena: mem.Allocator = undefined;
pub var global_io: std.Io = undefined;
pub var nativefn_registry: NativeFnRegistry = .{};
pub var registered_hashes: HashRegistry = .{};

const ObjectType = struct {
    duplicate: ?*const fn (src: *const ObjectHead) error{OutOfMemory}!*ObjectHead,
    free_internal_rep: ?*const fn (obj: *ObjectHead) void,
    update_string: ?*const fn (obj: *ObjectHead) error{ OutOfMemory, OtherThreadSet }!void,
    name: [:0]const u8,
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
        if (!self.current().canShimmer()) {
            self.shimmered.swap(self.current().duplicate());
        }
    }

    pub fn prepareToShimmer(self: *Shimmerable) !void {
        try self.ensureShimmerable();
        try self.current().prepareToShimmer();
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

/// Used to create and destroy extra data.
extra_data_mutex: std.Io.Mutex,
/// Used for locking when adding trace info.
trace_mutex: std.Io.Mutex,

/// Preallocated fallback used by `[catch]` when a script OOMs and building
/// the real opts dict also OOMs. Pinned at init; released via `freeOomOptsDict`.
oom_error_options_dict: ?Value,

parsed_scripts: ParsedScripts,
parsed_exprs: ParsedExpressions,
parsed_closures: ParsedClosures,
parsed_substs: ParsedSubstitutions,

const FullHashContext = struct {
    pub fn hash(_: @This(), full_hash: u256) u64 {
        return @truncate(full_hash);
    }
    pub fn eql(_: @This(), a: u256, b: u256) bool {
        return a == b;
    }
};
const ParsedScripts = memutil.LruCache(u256, struct { script: ParsedScript }, FullHashContext);
const ParsedExpressions = memutil.LruCache(u256, struct { expr: ParsedExpression }, FullHashContext);
const ParsedClosures = memutil.LruCache(u256, struct { closure: ClosureObject }, FullHashContext);
pub const Substitution = struct {
    subst: ParsedScript,
    /// Mainly used for integrity checks.
    flags: Tokenizer.SubstFlags,
};
const ParsedSubstitutions = memutil.LruCache(u256, Substitution, FullHashContext);

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
        for (script.tags.items, objutil.listItems(script.values), 0..) |token, value, i| {
            switch (token) {
                .start_of_command => {
                    line = value.body.parsed_script_command.line;
                    ioutil.debug(formatting ++ "{}\n", .{ i, line, @tagName(token), value.body.parsed_script_command });
                },
                .start_of_word => ioutil.debug(formatting ++ "{}\n", .{ i, line, @tagName(token), value.body.integer }),
                else => {
                    const item = objutil.listItem(script.values, @intCast(i));
                    const str = item.getString() catch "<oom string>";
                    ioutil.debug(formatting ++ "{s}\n", .{ i, line, @tagName(token), str });
                },
            }
        }
    }

    pub fn deinit(parsed: *ParsedScript) void {
        parsed.tags.deinit(global_gpa);
        for (parsed.values) |value| value.decrRefCount();
    }
};

pub const ParsedExpression = struct {
    root_node: expr_parse.Node.Index,
    nodes: std.MultiArrayList(expr_parse.Node),

    pub fn deinit(expr: *ParsedExpression) void {
        expr_parse.deinitNodes(global_gpa, &expr.nodes);
        expr.* = undefined;
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

    pub fn canShimmer(value: Value) bool {
        if (value.asPtr()) |obj| {
            return !obj.metadata.cross_thread;
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
    pub fn prepareToShimmer(value: Value) !void {
        value.assert(value.canShimmer());
        // Make sure the object has a string rep before we free its body. That is, if
        // it has a string rep. `.none` objects are brand new, so they obviously don't
        // have a string rep yet.
        if (value.tag() != .none) _ = try value.getString();
        value.invalidateBody();

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
                return try duplicate_fn(value);
            } else {
                debug.panic("Could not duplicate {}", .{obj.obj_type.name});
            }
        } else {
            return value;
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
                const bytes = @as([*]u8, @ptrFromInt(value.asRep().value.interned)) - @sizeOf(usize);
                const len = mem.readInt(usize, bytes, .native);
                return bytes[0..len :0];
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
        return memutil.hashBytes(try value.getString());
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
        switch (self.string_type) {
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
            hash_alloc.* = memutil.hashBytes(self.getString());
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

    alloc_len: usize,
    obj_type: *ObjectType,
    ref_count: u32,

    pub const min_object_size = 64;
    comptime {
        assert(@sizeOf(ObjectHead) <= min_object_size);
    }

    pub fn newObjectUninitialized(T: type) !*T {
        comptime assert(@bitOffsetOf(T, "head") == 0);
        comptime assert(@FieldType(T, "head") == ObjectHead);

        const size = @max(T, ObjectHead.min_object_size);
        const bytes = try global_gpa.alignedAlloc(u8, .of(ObjectHead), size);
        const obj: *ObjectHead = @ptrCast(bytes.ptr);
        obj.alloc_len = size;
        obj.obj_type = &NoneObject.Type;
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
        global_gpa.free(@as([*]u8, obj)[0..obj.alloc_len]);
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
        const hashes = try scanAndResolveHashRefs(global_gpa, bytes);
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

    pub fn getRefCount(obj: *ObjectHead) void {
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

        if (obj.obj_type == &SourceObject.Type) {
            // If it's a source object, it may contain a cached hash.
            const as_source: *SourceObject = @ptrCast(obj);
            if (as_source.hash.load(.monotonic)) |hash| {
                return hash.*;
            } else {
                const hash = memutil.hashBytes(try obj.getString());
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
            .none => .none,
        }

        dest.ref_count = 1;
    }

    /// Assumes that `src` has a string.
    pub fn duplicateStringOnly(src: *const ObjectHead) error{OutOfMemory}!*ObjectHead {
        // Downgrade the duplicate to a non-specialized string.
        assert(std.meta.activeTag(src.getStringDetails()) != .none);
        const new_obj = try ObjectHead.newObject(NoneObject);
        errdefer new_obj.head.deinit();
        try src.duplicateHeadOnto(new_obj);
        return &new_obj.head;
    }
};

pub const NoneObject = extern struct {
    head: ObjectHead,

    pub fn new(bytes: [:0]const u8) !*NoneObject {
        const new_obj = try ObjectHead.newObjectUninitialized(NoneObject);
        errdefer new_obj.head.freeBacking();
        try new_obj.head.setStringLocalObject(bytes);
        errdefer new_obj.head.invalidateString();

        return new_obj;
    }

    pub const Type: ObjectType = .{
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
        const new_obj = try ObjectHead.newObjectUninitialized(StringObject);
        errdefer new_obj.head.freeBacking();
        try new_obj.head.setStringLocalObject(bytes);
        errdefer new_obj.head.invalidateString();

        return new_obj;
    }

    fn duplicate(src: *const ObjectHead) !*ObjectHead {
        assert(std.meta.activeTag(src.getStringDetails()) != .none);
        const new_obj = try ObjectHead.newObjectUninitialized(StringObject);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(&new_obj.head);
        errdefer new_obj.head.invalidateString();

        const as_string: *StringObject = @ptrCast(src);
        new_obj.codepoint_length = .init(as_string.codepoint_length.load(.monotonic));

        return &new_obj.head;
    }

    pub const Type: ObjectType = .{
        .duplicate = duplicate,
        .free_internal_rep = null,
        .update_string = null,
        .name = "string",
    };
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
        var encoded: [hash_and_prepend_len]u8 = undefined;
        _ = hash_encoder.encode(encoded[hash_prepend.len..], &@as([32]u8, @bitCast(target_hash)));
        @memcpy(encoded[0..hash_prepend.len], hash_prepend);
        return try global_gpa.dupeSentinel(u8, &encoded, 0);
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

    fn updateString(obj: *ObjectHead) !void {
        const as_float: *BoxedFloatObject = @ptrCast(obj);
        const bytes = try std.fmt.allocPrintSentinel(global_gpa, "{}", .{as_float.value}, 0);
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

    fn updateString(obj: *ObjectHead) !void {
        const as_float: *BoxedIntObject = @ptrCast(obj);
        const bytes = try std.fmt.allocPrintSentinel(global_gpa, "{}", .{as_float.value}, 0);
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
        const bytes = try global_gpa.alignedAlloc(u8, .of(ObjectHead), layout);

        const as_list: *ListObject = @ptrCast(bytes.ptr);
        as_list.len = items.len;

        for (items, as_list.getItems()) |to_add, *list_item| {
            list_item.* = to_add.borrow();
        }

        return as_list;
    }

    fn updateString(obj: *ObjectHead) !void {
        const as_list: *ListObject = @ptrCast(obj);
        const items = as_list.getItems();

        // We need to calculate the quoting type for each item. This
        // will also let us calculate the upper bound of the string's
        // length.
        var fallback = std.heap.stackFallback(64, global_gpa);
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
        var unfinished_str = try global_gpa.alloc(u8, upper_bound_len + 1);
        errdefer global_gpa.free(unfinished_str);
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
        const finished_str = try global_gpa.realloc(unfinished_str, written + 1);
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
            return areValuesEqual(a, b) catch unreachable;
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

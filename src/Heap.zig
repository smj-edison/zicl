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
const ioutil = @import("ioutil.zig");
const strutil = @import("strutil.zig");
const memutil = @import("memutil.zig");
const Tokenizer = @import("Tokenizer.zig");
const expr_parse = @import("expr_parse.zig");
const regex = @import("regex.zig");
const pcre2 = @import("pcre2");
const objutil = @import("objutil.zig");

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
    string_heap_order: u6 = 28,
    /// Maximum number of custom types.
    max_custom_types: usize = 65536,
    /// Maximum number of evaluating scripts.
    max_scripts: usize = 65536,
    /// Maximum number of heaps (not necessarily initialized).
    max_heaps: usize = 128,
    /// Parsed script cache size.
    cache_size: usize = 512,
};
const cfg: HeapSettings = .{};

threadlocal var debugging_buffer: [16 * 1024 * 1024]u8 = undefined;
threadlocal var debugging_gpa: if (builtin.mode == .Debug) memutil.RingBufferAllocator else void = undefined;
/// Use this for debugging objects (traces, etc) that can afford to leak.
threadlocal var debug_gpa: Allocator = undefined;
/// Set this right before doing an operation that may cause a panic. The runtime will dump its
/// traces on panic if set.
pub threadlocal var last_touched: ?Handle = null;

pub const GlobalHeapState = struct {
    initialized: bool = false,
    /// Use to lock `custom_types` or `script_metadata` when adding or removing
    /// (no need to lock when using).
    mutex: std.Io.Mutex = .init,
    next_open_heap: usize = 0,
    /// Used to turn some panics into useful messages.
    running_leak_check: bool = false,
};

pub var state: GlobalHeapState = .{};
pub var global_gpa: std.mem.Allocator = undefined;
pub var global_io: std.Io = undefined;
pub var heaps: [cfg.max_heaps]Heap = undefined;
pub var custom_types: memutil.IndexedMemoryPool(CustomType, options.threading) = undefined;
pub var nativefn_registry: NativeFnRegistry = .{};
pub var registered_hashes: HashRegistry = .{};

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
        representative: Handle,
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

    pub fn get(registry: *HashRegistry, hash: u256) ?Handle {
        registry.rw_lock.lockSharedUncancelable(global_io);
        defer registry.rw_lock.unlockShared(global_io);

        if (registry.entries.getPtr(hash)) |entry| {
            assert(entry.instances.load(.monotonic) > 0);
            return entry.representative;
        } else return null;
    }

    pub fn register(registry: *HashRegistry, key: u256, value: Handle) !void {
        const metadata = value.getMetadata();

        registry.rw_lock.lockSharedUncancelable(global_io);

        if (registry.entries.getPtr(key)) |entry| {
            if (metadata.cmpxchgStrongHashRegistered(false, true, .release, .acquire)) |_| {
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
            if (metadata.cmpxchgStrongHashRegistered(false, true, .release, .acquire)) |_| {
                // Someone registered it inbetween upgrading the shared lock to an exclusive lock.
            } else {
                // We successfully marked it as registered, so we can increment the instances count.
                _ = new_entry.value_ptr.instances.fetchAdd(1, .monotonic);
            }
            return;
        }

        new_entry.key_ptr.* = key;
        new_entry.value_ptr.* = .{
            .representative = value.borrow(),
            .instances = .init(1),
        };

        // We have an exclusive lock on rw_lock, so nobody else could have registered this value.
        value.assert(metadata.cmpxchgStrongHashRegistered(false, true, .release, .acquire) == null);
    }

    pub fn unregister(registry: *HashRegistry, key: u256, value: Handle) void {
        const metadata = value.getMetadata();

        registry.rw_lock.lockSharedUncancelable(global_io);

        if (registry.entries.getPtr(key)) |entry| {
            if (metadata.cmpxchgStrongHashRegistered(true, false, .release, .acquire)) |_| {
                // Someone else unregistered this already, so no need to do anything.
                registry.rw_lock.unlockShared(global_io);
            } else {
                // We were the ones to successfully set `value` as not registered.
                const instance_count = entry.instances.fetchSub(1, .monotonic) - 1;
                if (instance_count == 0) {
                    // This was the last instance of this hash, so we can now clean it up.

                    registry.rw_lock.unlockShared(global_io);
                    registry.rw_lock.lockUncancelable(global_io);
                    defer registry.rw_lock.unlock(global_io);

                    // The entry should still exist here, as we were the ones who set instances
                    // to 0. It could have moved locations though, when upgrading to an exclusive
                    // lock.
                    const entry_second_check = registry.entries.getPtr(key).?;
                    // Note that we don't need to worry about this `decrRefCount` calling `unregister`
                    // recursively, since the only way recursion could happen is if
                    // 1. There were circular references (in which case a global invariant has been
                    //    violated and we're screwed anyways)
                    // 2. `representative == value`, but we've just set `value.hash_registered`
                    //    as false, so it won't call `unregister`.
                    entry_second_check.representative.decrRefCount();

                    assert(registry.entries.remove(key));
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

const Heap = @This();
pub threadlocal var local_heap: *Heap = undefined;

const object_heap_max_count: usize = @as(usize, 1) << cfg.object_heap_order;
const object_heap_max_bytes: usize = ObjectList.capacityInBytes(object_heap_max_count);
const string_heap_max_bytes: usize = @as(usize, 1) << cfg.string_heap_order;

/// Used to create and destroy extra data.
extra_data_mutex: std.Io.Mutex,
/// Used for locking when adding trace info.
trace_mutex: std.Io.Mutex,

object_tracking: ObjectTracker,
objects: ObjectList,
string_tracking: StringTracker,
strings: StringList,
interned_strings: std.EnumArray(InternedString, Heap.Handle),
/// Preallocated fallback used by `[catch]` when a script OOMs and building
/// the real opts dict also OOMs. Pinned at init; released via `freeOomOptsDict`.
oom_error_options_dict: ?Handle,

/// If an object can't store all its information in 8 bytes, it can throw extra data on here.
extra: ExtraDataPool,
parsed_scripts: ParsedScripts,
parsed_exprs: ParsedExpressions,
parsed_closures: ParsedClosures,
parsed_substs: ParsedSubstitutions,

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

const ExtraDataPool = memutil.IndexedMemoryPool(ExtraDataValue, options.threading);
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
const ParsedScripts = memutil.LruCache(u256, struct { script: ParsedScript }, FullHashContext);
const ParsedExpressions = memutil.LruCache(u256, struct { expr: ParsedExpression }, FullHashContext);
const ParsedClosures = memutil.LruCache(u256, struct { closure: Closure }, FullHashContext);
pub const Substitution = struct {
    subst: ParsedScript,
    /// Mainly used for integrity checks.
    flags: Tokenizer.SubstFlags,
};
const ParsedSubstitutions = memutil.LruCache(u256, Substitution, FullHashContext);

pub const InternedString = enum {
    @"apply lambdaExpr",
    @"fn",
    method,
    impl,
    scope,
    @"^parent",
    name,
    type,
    file,
    line,
    level,
    regexp,
    @"division by zero",
    // Error handling.
    NONE,
    @"ZICL OOM",
    @"ZICL LOOKUP VARNAME",
    @"out of memory",
    @"-code",
    @"-level",
    @"-errorstack",
    @"-errorcode",
    @"-during",
    // Signal names, for use in the signal mask list.
    SIGHUP,
    SIGINT,
    SIGQUIT,
    SIGILL,
    SIGTRAP,
    SIGABRT,
    SIGBUS,
    SIGFPE,
    SIGKILL,
    SIGUSR1,
    SIGSEGV,
    SIGUSR2,
    SIGPIPE,
    SIGALRM,
    SIGTERM,
    SIGCHLD,
    SIGCONT,
    SIGSTOP,
    SIGTSTP,
    SIGTTIN,
    SIGTTOU,
    SIGURG,
    SIGXCPU,
    SIGXFSZ,
    SIGVTALRM,
    SIGPROF,
    SIGWINCH,
    SIGIO,
    SIGPWR,
    SIGSYS,
};

const interned_string_count = std.enums.values(InternedString).len;

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
    /// A handle pointing to a Tcl list that has the same length as `tokens`,
    /// that stores all the string values that the script references.
    values: Handle,
    /// Tokens array.
    tags: std.ArrayList(Tokenizer.Token.Tag),

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
        parsed.values.decrRefCount();
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

pub const Object = packed struct(u128) {
    pub const null_string: StrOrPtr = .{
        .u = .{ .str = .{ .index = 0, .len = 0, .hash_count = 0 } },
        .is_ptr = false,
    };
    pub const empty_string: StrOrPtr = .{
        .u = .{ .str = .{ .index = 1, .len = 0, .hash_count = 0 } },
        .is_ptr = false,
    };

    pub const StrOrPtr = packed struct(u59) {
        pub const NormalLength = u16;

        u: packed union {
            /// Normal strings store both the bytes and the hash references inline in the
            /// same allocation. Check `heapStringLayout` for details.
            str: packed struct {
                index: u32,
                len: NormalLength,
                /// Number of Handle references stored inline after the null byte (and
                /// potentially padding).
                hash_count: u10,
            },
            /// Be sure to >> 6 before setting, and << 6 when reading. Must be non-null.
            ptr: u58,
        },
        is_ptr: bool,

        pub fn deinit(str: StrOrPtr, heap: *Heap) void {
            switch (heap.getLocalStringDetails(str)) {
                .long => |long_str| {
                    long_str.decrRefCount(global_gpa);
                },
                .normal => {
                    heap.freeHeapString(str.u.str.index, str.u.str.len, str.u.str.hash_count);
                },
                .null, .empty => {},
            }
        }

        pub fn format(self: StrOrPtr, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            if (self.is_ptr) {
                try writer.print(".{{ .ptr = {*} }}", .{SpecialString.fromInt(self.u.ptr)});
            } else {
                try writer.print("{}", .{self.u.str});
            }
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
            .custom_type => {
                const custom_type = obj.body.custom_type;
                const type_fns = custom_types.items[custom_type.type_id];

                type_fns.invalidate_body(heap, obj);
            },
            .reference => {
                obj.body.reference.decrRefCount();
            },
            .string => {
                // How come string is a no-op? Because the string is separate
                // from its cached length.
            },
            .source => {
                heap.destroyExtraData(obj.body.source.extra_data);
            },
            .cached_lexical_var => {
                heap.destroyExtraData(obj.body.cached_lexical_var.extra_data);
            },
            .closure => {
                heap.destroyExtraData(obj.body.closure.extra_data);
            },
            .upvar_link => {
                const upvar_link = obj.body.upvar_link;
                heap.getHandle(upvar_link.linked_name).decrRefCount();
            },
            .dict_sugar => {
                const dict_sugar = obj.body.dict_sugar;
                heap.getHandle(dict_sugar.dict_name_index).decrRefCount();
                heap.getHandle(dict_sugar.path_index).decrRefCount();
            },
            .hash_reference => {
                obj.body.hash_reference.decrRefCount();
            },
            .regexp => {
                heap.destroyExtraData(obj.body.regexp.extra_data);
            },
            .none,
            .index,
            .integer,
            .float,
            .bool,
            .parsed_script_command,
            .marked,
            .invalid,
            .cached_local_var,
            => {},
            .dict, .list => unreachable,
        }

        obj.body = undefined;
        obj.head.tag = .none;
    }

    pub fn format(self: Object, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print(
            ".{{ .head = {{ .str = {f} }}, .body = .{{ .{s}",
            .{ self.head.str, @tagName(self.head.tag) },
        );
        switch (self.head.tag) {
            .invalid,
            .none,
            .marked,
            => {},
            .index => try writer.print(" = {}", .{self.body.index}),
            .integer => try writer.print(" = {}", .{self.body.integer}),
            .float => try writer.print(" = {}", .{self.body.float}),
            .bool => try writer.print(" = {}", .{self.body.bool}),
            .string => try writer.print(" = {}", .{self.body.string}),
            .source => try writer.print(" = {}", .{self.body.source}),
            .list => try writer.print(" = {}", .{self.body.list}),
            .dict => try writer.print(" = {}", .{self.body.dict}),
            .dict_sugar => try writer.print(" = {}", .{self.body.dict_sugar}),
            .parsed_script_command => try writer.print(" = {}", .{self.body.parsed_script_command}),
            .reference => try writer.print(" = {any}", .{self.body.reference}),
            .cached_local_var => try writer.print(" = {}", .{self.body.cached_local_var}),
            .cached_lexical_var => try writer.print(" = {}", .{self.body.cached_lexical_var}),
            .upvar_link => try writer.print(" = {}", .{self.body.upvar_link}),
            .closure => try writer.print(" = {}", .{self.body.closure}),
            .custom_type => try writer.print(" = {}", .{self.body.custom_type}),
            .hash_reference => try writer.print(" = {any}", .{self.body.hash_reference}),
            .regexp => try writer.writeAll(" = <regexp>"),
        }
        try writer.writeAll(" } }");
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
    parsed_script_command,
    reference,
    cached_local_var,
    cached_lexical_var,
    upvar_link,
    closure,
    custom_type,
    hash_reference,
    regexp,
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
    /// Information about a parsed command.
    parsed_script_command: packed struct {
        line: u32,
        arg_count: u32,
    },
    reference: Handle,
    cached_local_var: packed struct {
        /// Used to invalidate `index`'s cached value, if it doesn't match
        /// the current call frame's epoch.
        call_epoch: u32,
        cached_index: HeapIndex,
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
    hash_reference: Handle,
    regexp: packed struct {
        options: u32,
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
    regexp: *pcre2.pcre2_code_8,
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
            return self.u.index.data;
        }
    }
};

pub const VariableValue = union(enum) {
    local_variable: struct {
        target: Handle,
    },
    /// Variable in a parent scope. Immutable.
    lexical_variable: struct {
        target: Handle,
    },
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
    /// Handle to the closure's scope as a hash reference.
    scope_hash_ref: OptionalHandle,
    /// Required number of arguments.
    required_arity: u32,
    /// Optional number of arguments.
    optional_arity: u32,
    /// Default values of optional arguments, if any.
    optional_values: OptionalHandle,
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
            .name = closure.name.borrowOptional(),
            .scope_hash_ref = closure.scope_hash_ref.borrowOptional(),
            .required_arity = closure.required_arity,
            .optional_arity = closure.optional_arity,
            .optional_values = closure.optional_values.borrowOptional(),
            .has_args_parameter = closure.has_args_parameter,
            .is_method = closure.is_method,
            .cache_id = closure.cache_id,
        };
    }

    pub fn deinit(closure: Closure) void {
        closure.args.decrRefCount();
        closure.body.decrRefCount();
        closure.name.decrOptional();
        closure.scope_hash_ref.decrOptional();
        closure.optional_values.decrOptional();
    }
};

pub const CustomType = struct {
    /// Type name.
    name: []u8,
    /// Must be threadsafe.
    invalidate_body: *const fn (heap: *Heap, obj: *Object) void,
    duplicate: *const fn (heap: *Heap, src: *const Object) Allocator.Error!Object,
    get_string: *const fn (heap: *Heap, obj: *const Object) Allocator.Error![:0]u8,
    make_immutable: *const fn (heap: *Heap, obj: *Object) Allocator.Error!void,
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

    pub fn swapIfNew(ref: *OptionalHandle, new_handle: OptionalHandle) void {
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

    pub fn makeCrossthread(ref: OptionalHandle) !void {
        if (ref.toHandle()) |val| try val.makeCrossthread();
    }

    pub fn borrowOptional(ref: OptionalHandle) OptionalHandle {
        if (ref.toHandle()) |val| val.incrRefCount();
        return ref;
    }

    pub fn incrOptional(ref: OptionalHandle) void {
        if (ref.toHandle()) |val| val.incrRefCount();
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
        const str = getString(self) catch return error.WriteFailed;
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
        // You should never be shimmering a reference directly. Instead, you should
        // shimmer the object it points to. Might consider relaxing this in the future,
        // but it can cause a lot of issues.
        handle.assert(handle.tag() != .reference);
        // Make sure the object has a string rep before we free its body. That is, if
        // it has a string rep. `.none` objects are brand new, so they obviously don't
        // have a string rep yet.
        if (handle.tag() != .none) _ = try handle.getString();
        handle.invalidateBody();

        handle.trace("Prepared to shimmer", .{});
    }

    pub fn canShimmer(handle: Handle) bool {
        // Specialty objects can't shimmer.
        if (handle.index < special_object_count + interned_string_count) return false;

        // Can't shimmer if it's shared between threads.
        return !handle.getHeap().objects.get(handle.index).metadata.cross_thread;
    }

    pub fn canMutate(handle: Handle) bool {
        // Note: a crossthread object can _never_ mutate. A lot of asserts around
        // the codebase assume that `canMutate` means that an object is not crossthread.

        // Special objects can never be mutated.
        if (handle.index < special_object_count + interned_string_count) return false;

        const obj_heap = handle.getHeap();
        const metadata = obj_heap.getLocalMetadata(handle.index);

        // Cross thread objects can't be mutated, even if the ref count is 1, because
        // objects can be indirectly accessed by traversing lists. Imagine thread 1
        // is traversing a list, while thread 2 is modifying the list elements.
        // Thread 2 sees that the list element only has ref count one (since it's only
        // owned by the list), so it figures it's safe to modify. Wrong! It's not safe
        // to modify, because thread 1 is also reading the list. This is why crossthread
        // objects are never safe to modify, or even shimmer.
        const cross_thread = metadata.cross_thread;
        // If the hash is registered, it means it is considered frozen. We can't very
        // well mutate something that has a fixed value.
        const hash_registered = @atomicLoad(ObjectAndMetadata.Metadata, metadata, .acquire).hash_registered;
        const multiple_refs = obj_heap.getLocalRefCount(handle.index) > 1;

        if (cross_thread) return false;
        if (hash_registered) return false;
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

    pub fn swapIntermediate(ref: *Handle, provided_handle: Handle, maybe_new: OptionalHandle) void {
        if (maybe_new.toHandle()) |new| {
            const old = ref.*;
            ref.* = new;
            if (old != provided_handle) old.decrRefCount();
        }
    }

    pub fn getMetadata(handle: Handle) *ObjectAndMetadata.Metadata {
        return handle.getHeap().getLocalMetadata(handle.index);
    }

    /// This should not be used for checking if an object can shimmer, use `canShimmer` instead.
    pub fn refCount(handle: Handle) u32 {
        return getLocalRefCount(handle.getHeap(), handle.index);
    }

    /// This is only for internal checks, you probably want `canMutate` instead for the full set
    /// of asserts.
    pub fn isShared(handle: Handle) bool {
        if (handle.index < special_object_count + interned_string_count) return false;
        return handle.getMetadata().cross_thread or handle.refCount() > 1;
    }

    pub fn borrow(handle: Handle) Handle {
        handle.incrRefCount();
        return handle;
    }

    pub fn incrRefCount(handle: Handle) void {
        if (handle.index < special_object_count + interned_string_count) return;
        // Make sure we never try to borrow a freed object.
        handle.assert(handle.refCount() > 0);
        handle.assert(handle.tag() != .reference);

        const metadata = handle.getMetadata();
        incrRefCountOf(u32, &handle.getHeap().objects.items(.ref_count)[handle.index], metadata.cross_thread);

        handle.trace("Incr ref count of index {} (now {})", .{ handle.index, handle.refCount() });
    }

    // TODO PERF might be worthwhile doing something like Jim's compared string type.
    pub fn equalsString(handle: Handle, value: []const u8) !bool {
        const bytes = try handle.getString();
        return std.mem.eql(u8, bytes, value);
    }

    pub fn referenceOwning(handle: Handle) Object {
        // Make sure we're never making a reference to a reference.
        handle.assert(handle.tag() != .reference);
        // .upvar_link can't be referenced either, since it always
        // needs to be stored directly.
        handle.assert(handle.tag() != .upvar_link);

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
        return handle.referenceOwning();
    }

    pub fn hashReference(handle: Handle) Object {
        return .{
            .head = .{
                .str = Object.null_string,
                .tag = .hash_reference,
            },
            .body = .{
                .hash_reference = handle.borrow(),
            },
        };
    }

    pub fn dupOrRef(handle: Handle) Object {
        return local_heap.dupOrReference(handle);
    }

    pub fn duplicate(handle: Handle) !Handle {
        return local_heap.duplicate(handle);
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
        if (handle.index < special_object_count + interned_string_count) return;

        const metadata = handle.getMetadata();
        const obj_heap = handle.getHeap();

        // We should never go below one for an item owned by another object.
        if (!handle.isAllocHead()) {
            if (handle.getMetadata().in_use) {
                handle.assert(handle.refCount() > 1);
            } else {
                // If it's not in use, we want to fall through to the UAF panic.
            }
        }

        handle.trace("Decr ref count of index {} (now {})", .{ handle.index, @as(i64, handle.refCount()) - 1 });

        if (options.trace_mem) last_touched = handle;
        const new_ref_count = decrRefCountOf(u32, &obj_heap.objects.items(.ref_count)[handle.index], metadata.cross_thread);

        // You may be wondering, why the heck `<= 1`, and not `== 0`? Because hash representatives
        // are owned by the hash registry, so there's a circular reference. But, hash representatives
        // can be safely freed if nobody else references them, so this is the needed logic to deal
        // with the circular reference created by the hash registry.
        if (new_ref_count <= 1 and @atomicLoad(ObjectAndMetadata.Metadata, metadata, .acquire).hash_registered == true) {
            // It's impossible for this to not have a string, since if the hash
            // was registered, we know that it has a string.
            const hash = handle.getHash() catch unreachable;
            registered_hashes.unregister(hash, handle);
        }

        if (new_ref_count == 0) {
            freeObject(handle);
        }
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

    pub fn getStringIfExists(handle: Handle) ?[:0]const u8 {
        switch (handle.getStringDetails()) {
            .null => return null,
            .empty => return "",
            .normal => |str| return str.bytes,
            .long => |long_str| return long_str.getString(),
        }
    }

    pub fn getStringDetails(handle: Handle) StringDetails {
        const str_or_ptr: Object.StrOrPtr = blk: {
            // TODO PERF I should probably benchmark whether it's faster
            // to check the metadata, or just to do an acquire load.
            if (options.threading and handle.getMetadata().cross_thread) {
                const head = @atomicLoad(Object.Head, @as(*Object.Head, @ptrCast(&handle.peek().head)), .acquire);
                break :blk head.str;
            } else {
                break :blk handle.peek().head.str;
            }
        };

        return handle.getHeap().getLocalStringDetails(str_or_ptr);
    }

    pub fn getSourceExtraData(handle: Handle) *@FieldType(ExtraDataValue, "source") {
        handle.assert(handle.tag() == .source);
        return &handle.getHeap().getExtraData(handle.peek().body.source.extra_data).source;
    }

    pub fn getDictExtraData(handle: Handle) *ExtraDataValue.Dictionary {
        handle.assert(handle.tag() == .dict);
        return &handle.getHeap().getExtraData(handle.peek().body.dict.extra_data).dict;
    }

    pub fn getClosureExtraData(handle: Handle) *Closure {
        handle.assert(handle.tag() == .closure);
        return &handle.getHeap().getExtraData(handle.peek().body.closure.extra_data).closure;
    }

    pub fn getRegexpExtraData(handle: Handle) *pcre2.pcre2_code_8 {
        handle.assert(handle.tag() == .regexp);
        return handle.getHeap().getExtraData(handle.peek().body.regexp.extra_data).regexp;
    }

    threadlocal var recursion_depth: usize = 0;
    const empty_string_value = "";
    /// This returns a temporary string. Whenever the object is mutated, it
    /// may become invalid. Guaranteed to be valid, barring OOM.
    pub fn getString(handle: Handle) error{OutOfMemory}![:0]const u8 {
        recursion_depth += 1;
        defer recursion_depth -= 1;

        if (recursion_depth > 50) {
            last_touched = handle;
            std.debug.panic("Infinite recursion in getString, handle: {any}, type: {}, ref: {any}, body ptr: {*}", .{
                handle,
                handle.tag(),
                handle.peek().body.reference,
                &handle.peek().body,
            });
        }

        const obj = handle.peek();

        switch (handle.getStringDetails()) {
            .long => |long_str| {
                return long_str.getString();
            },
            .normal => |str| {
                return str.bytes;
            },
            .empty => {
                return empty_string_value;
            },
            .null => {
                // Keep going in code.
            },
        }

        // No representation, so we better generate it.
        const new_str = blk: switch (obj.head.tag) {
            .index => {
                break :blk try std.fmt.allocPrintSentinel(global_gpa, "{}", .{obj.body.index}, 0);
            },
            .integer => {
                break :blk try std.fmt.allocPrintSentinel(global_gpa, "{}", .{obj.body.integer}, 0);
            },
            .float => {
                break :blk try std.fmt.allocPrintSentinel(global_gpa, "{}", .{obj.body.float}, 0);
            },
            .bool => {
                break :blk try std.fmt.allocPrintSentinel(global_gpa, "{}", .{@intFromBool(obj.body.bool.data)}, 0);
            },
            .list => {
                const list = obj.body.list;
                break :blk try getListString(handle.getHeap(), handle.index + 1, list.len);
            },
            .dict => {
                break :blk try generateDictString(handle);
            },
            .closure => {
                const closure = handle.getClosureExtraData();
                const heap = handle.getHeap();
                const total_args = objutil.listLengthRaw(closure.args);
                const opt_values = closure.optional_values.toHandle();

                // Build the args spec list. Required/args params use the name directly;
                // optional params become 2-element lists {name default}.
                const args_spec = try objutil.newListWithCapacity(total_args);
                defer args_spec.decrRefCount();
                args_spec.peek().body.list.len = total_args;
                const arg_items = objutil.listItems(args_spec);

                for (0..total_args) |i| {
                    const arg_name = objutil.listItem(closure.args, @intCast(i));
                    const is_args_param = closure.has_args_parameter and i == total_args - 1;
                    const is_optional = !is_args_param and i >= closure.required_arity;

                    if (is_optional) {
                        const opt_idx = i - closure.required_arity;
                        const default_val = objutil.listItem(opt_values.?, @intCast(opt_idx));
                        const spec = try objutil.newList(&.{ arg_name, default_val });
                        arg_items[i] = spec.referenceOwning();
                    } else {
                        arg_items[i] = heap.dupOrReference(arg_name);
                    }
                }

                // impl is a 2-element list: {args_spec body}.
                const impl_val = try objutil.newList(&.{ args_spec, closure.body });
                defer impl_val.decrRefCount();

                // Build the outer list: fn|method ?name <name>? impl <impl> ?scope <scope>?
                const outer = try objutil.newListWithCapacity(7);
                defer outer.decrRefCount();

                objutil.listAppendAssumeCapacity(outer, heap.internedStringRef(if (closure.is_method) .method else .@"fn"));

                if (closure.name.toHandle()) |name_handle| {
                    objutil.listAppendAssumeCapacity(outer, heap.internedStringRef(.name));
                    objutil.listAppendAssumeCapacity(outer, name_handle.dupOrRef());
                }

                objutil.listAppendAssumeCapacity(outer, heap.internedStringRef(.impl));
                objutil.listAppendAssumeCapacity(outer, impl_val.dupOrRef());

                if (closure.scope_hash_ref.toHandle()) |scope_handle| {
                    objutil.listAppendAssumeCapacity(outer, heap.internedStringRef(.scope));
                    objutil.listAppendAssumeCapacity(outer, scope_handle.dupOrRef());
                }

                const result = try getListString(heap, outer.index + 1, objutil.listLengthRaw(outer));
                break :blk result;
            },
            .custom_type => {
                const custom_type = obj.body.custom_type;
                break :blk try custom_types.items[custom_type.type_id].get_string(handle.getHeap(), handle.peek());
            },
            .reference => {
                // Intentionally return early, since we should always use
                // the reference's string, not our own.
                return getString(obj.body.reference);
            },
            .parsed_script_command => {
                if (builtin.mode == .Debug and state.running_leak_check) {
                    const script_command = obj.body.parsed_script_command;
                    break :blk try std.fmt.allocPrintSentinel(
                        global_gpa,
                        "<script command: args: {}, line: {}>",
                        .{ script_command.arg_count, script_command.line },
                        0,
                    );
                } else @panic("Script line is an internal object only");
            },
            .none => {
                if (builtin.mode == .Debug and state.running_leak_check) {
                    break :blk try std.fmt.allocPrintSentinel(global_gpa, "<none>", .{}, 0);
                } else {
                    last_touched = handle;
                    @panic("Tried to generate a string for .none");
                }
            },
            .invalid => {
                if (builtin.mode == .Debug and state.running_leak_check) {
                    break :blk try std.fmt.allocPrintSentinel(global_gpa, "<invalid>", .{}, 0);
                } else {
                    last_touched = handle;
                    @panic("Tried to generate a string for .invalid");
                }
            },
            .marked => {
                if (builtin.mode == .Debug and state.running_leak_check) {
                    break :blk try std.fmt.allocPrintSentinel(global_gpa, "<marked>", .{}, 0);
                } else @panic("Tried to generate a string for .marked");
            },
            .upvar_link => {
                if (builtin.mode == .Debug and state.running_leak_check) {
                    break :blk try std.fmt.allocPrintSentinel(global_gpa, "<upvar_link>", .{}, 0);
                } else @panic("Tried to generate a string for .upvar_link");
            },
            .hash_reference => {
                const target_hash = try obj.body.hash_reference.getHash();
                var encoded: [hash_and_prepend_len]u8 = undefined;
                @memcpy(encoded[0..hash_prepend.len], hash_prepend);
                _ = hash_encoder.encode(encoded[hash_prepend.len..], &@as([32]u8, @bitCast(target_hash)));
                break :blk try global_gpa.dupeZ(u8, &encoded);
            },
            .string,
            .source,
            .dict_sugar,
            .cached_local_var,
            .cached_lexical_var,
            .regexp,
            => {
                last_touched = handle;
                std.debug.panic("{} should always have a string representation", .{obj.head.tag});
            },
        };

        // Ensure new_str is freed if setStringOwning fails (e.g. OOM during LongString allocation).
        {
            errdefer global_gpa.free(new_str);
            // TODO PERF no need to scan for hashes in the string every time,
            // as we can pass them upwards from the child objects.
            var resolved_hashes = try scanAndResolveHashRefs(global_gpa, new_str);
            defer resolved_hashes.deinit(global_gpa);
            const took_ownership = setStringOwning(handle, new_str, resolved_hashes.items) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.OtherThreadSet => blk: {
                    // Since string generation should always produce the same results, it's fine
                    // if a different thread beat us to generating this.
                    break :blk false;
                },
            };
            if (!took_ownership) global_gpa.free(new_str);
        }

        // Rerun this function to figure out where the new string is.
        return handle.getString();
    }

    pub fn getHash(handle: Handle) !u256 {
        const hash = try handle.getHashNoRegister();
        if (!@atomicLoad(ObjectAndMetadata.Metadata, handle.getMetadata(), .acquire).hash_registered) {
            try registered_hashes.register(hash, handle);
        }
        return hash;
    }

    pub fn getHashNoRegister(handle: Handle) !u256 {
        switch (handle.getStringDetails()) {
            .empty => {
                return comptime blk: {
                    @setEvalBranchQuota(10000);
                    break :blk memutil.hashBytes("");
                };
            },
            .long => |long_str| {
                return long_str.getHash();
            },
            .null, .normal => {
                // Fall through.
            },
        }

        if (handle.tag() == .source) {
            const source = handle.getSourceExtraData();
            // If it's a source object, it may contain a cached hash.
            const hash_state = source.hash.state.load(.acquire);
            if (hash_state == .computed) {
                return source.hash.hash;
            } else {
                const hash = memutil.hashBytes(try handle.getString());
                source.hash.hash = hash;
                source.hash.state.store(.computed, .release);
                return hash;
            }
        }

        // We don't save the hash when it's not a special string, since
        // it should be pretty cheap to compute it again.
        return memutil.hashBytes(try handle.getString());
    }

    pub fn makeCrossthread(handle: Handle) !void {
        handle.assert(handle.canShimmer());
        switch (handle.tag()) {
            .none,
            .index,
            .integer,
            .float,
            .bool,
            .string,
            .source,
            .regexp,
            => {},
            .list => {
                for (0..objutil.listLengthRaw(handle)) |i| {
                    try objutil.listItemNoFollow(handle, @intCast(i)).makeCrossthread();
                }
            },
            .dict => {
                for (0..objutil.dictItemLength(handle)) |i| {
                    try objutil.dictItem(handle, @intCast(i)).makeCrossthread();
                }
                // Make sure it has a generated table before sharing.
                _ = try objutil.dictGetTable(handle);
            },
            .reference => {
                try handle.peek().body.reference.makeCrossthread();
            },
            .closure => {
                const closure = handle.getClosureExtraData();
                try closure.args.makeCrossthread();
                try closure.body.makeCrossthread();
                try closure.name.makeCrossthread();
                try closure.optional_values.makeCrossthread();
                try closure.scope_hash_ref.makeCrossthread();
            },
            .dict_sugar, .cached_lexical_var, .cached_local_var => {
                try handle.prepareToShimmer();
                handle.peek().head.tag = .none;
                handle.peek().body = undefined;
            },
            .custom_type => @panic("unimplemented"),
            .upvar_link,
            .parsed_script_command,
            .invalid,
            .marked,
            => unreachable,
        }
        // No need for atomics, because the caller is responsible for synchronizing the object
        // to wherever it's going.
        handle.getMetadata().cross_thread = true;
    }

    pub fn trace(handle: Handle, comptime fmt: []const u8, args: anytype) void {
        if (options.trace_mem) {
            // We need to create the message before locking the mutex, since `allocPrint` may
            // call `getString`, which in turn traces setting the string.
            const msg = std.fmt.allocPrint(debug_gpa, "\n" ++ fmt, args) catch unreachable;

            handle.getHeap().trace_mutex.lockUncancelable(global_io);
            defer handle.getHeap().trace_mutex.unlock(global_io);
            const trace_field = &handle.getHeap().objects.items(.trace)[handle.index];
            trace_field.addAddr(@returnAddress(), msg);
        }
    }

    /// Helper function that dumps the object's trace if the assertion fails.
    pub fn assert(handle: Handle, ok: bool) void {
        if (!ok) {
            if (options.trace_mem) {
                last_touched = handle;
            }
            unreachable;
        }
    }
};

fn invalidateBothInner(handle: Handle) void {
    invalidateStringInner(handle);
    invalidateBodyInner(handle);
}

fn invalidateStringInner(handle: Handle) void {
    switch (handle.getStringDetails()) {
        .null, .empty => {
            // Don't print anything, else the traces get completely spammed.
        },
        .normal => |str| handle.trace("Invalidate string (was {s})", .{str.bytes}),
        .long => |long_str| handle.trace("Invalidate string (was {s})", .{long_str.getString()}),
    }
    if (handle.tag() == .source) {
        // Why store unordered? Because there's no way to do the atomics
        // correctly here, so I'd much rather tsan complained. It _shouldn't_
        // be an issue, since strings shared between threads can't be invalidated,
        // except in the case of deiniting an object.
        handle.getSourceExtraData().hash.state.store(.not_computed, .unordered);
    }
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

            if (item_handle.isShared()) {
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
    handle.trace("Invalidate body", .{});

    switch (handle.tag()) {
        .list => {
            invalidateCollection(handle);
        },
        .dict => {
            invalidateCollection(handle);

            handle.getHeap().destroyExtraData(handle.peek().body.dict.extra_data);
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
        /// Whether this object is currently being used (used to track double frees).
        in_use: bool,
        /// Whether the hash of this value is being tracked in the central registry.
        hash_registered: bool,

        pub fn cmpxchgStrongHashRegistered(
            metadata: *Metadata,
            expected_hash_value: bool,
            new_hash_value: bool,
            comptime success_order: std.builtin.AtomicOrder,
            comptime fail_order: std.builtin.AtomicOrder,
        ) ?bool {
            var current = @atomicLoad(Metadata, metadata, fail_order);
            while (current.hash_registered == expected_hash_value) {
                var new_value = current;
                new_value.hash_registered = new_hash_value;
                const result = @cmpxchgWeak(Metadata, metadata, current, new_value, success_order, fail_order);
                if (result) |val| {
                    current = val; // Failed load was done with `fail_order`.
                } else return null; // Success!
            }
            return current.hash_registered;
        }
    };

    object: Object,
    ref_count: u32,
    metadata: Metadata,
    trace: ioutil.ConfigurableTrace(30, 16, options.trace_mem),
};

/// Used for the big backing objects, such as Heap.objects or Heap.strings.
/// These are backed by vmem if possible, or need to be fully pre-allocated
/// if threading is enabled.
fn heapBackingAlloc() Allocator {
    if (options.threading) {
        return memutil.null_allocator;
    } else {
        return global_gpa;
    }
}

fn createInternedString(heap: *Heap, expected_index: u32, str: []const u8) !Handle {
    const interned = try heap.createObject();
    errdefer freeObjectBackingInner(interned);
    const cast_len: Object.StrOrPtr.NormalLength = @intCast(str.len);
    const str_index = try heap.createHeapString(cast_len, &.{});
    errdefer heap.freeHeapString(str_index, cast_len, 0);
    assert(interned.index == (expected_index + special_object_count));

    @memcpy(heap.getHeapString(str_index, str_index + cast_len), str);
    assert(heap.exchangeString(interned.index, Object.null_string, .{
        .is_ptr = false,
        .u = .{ .str = .{ .index = str_index, .len = cast_len, .hash_count = 0 } },
    }));

    return interned;
}

fn createInternedStrings(heap: *Heap) !void {
    @setEvalBranchQuota(10000);
    const values = comptime blk: {
        break :blk std.enums.values(InternedString);
    };
    var converted_mapping: std.enums.EnumFieldStruct(InternedString, Handle, null) = undefined;

    // Init all the interned strings, handling failure as needed.
    var converted: usize = 0;
    errdefer {
        // Since we can't loop up to `converted` at comptime, we'll generate
        // an if-ladder that only deinits fields that have been initialized.
        inline for (0..values.len) |i| {
            const key = @tagName(values[i]);
            if (i < converted) {
                const handle: Handle = @field(converted_mapping, key);
                handle.peek().head.str.deinit(heap);
                freeObjectBackingInner(handle);
            }
        }
    }
    // Fill the mapping.
    inline for (0..values.len) |i| {
        const value = @tagName(values[i]);
        const new_str = try heap.createInternedString(i, value);
        converted += 1; // After `new_str` is successfully created
        @field(converted_mapping, value) = new_str;
    }

    heap.interned_strings = .init(converted_mapping);
}

pub fn init(heap: *Heap) !void {
    heap.* = undefined;
    // Clean up if we hit an error.
    errdefer heap.* = undefined;

    heap.trace_mutex = .init;
    heap.extra_data_mutex = .init;

    // Init objects.
    heap.object_tracking = try .init(global_gpa, global_io, cfg.object_heap_order);
    errdefer if (heap.object_tracking.deinit() == .leaked) {
        ioutil.debug("^^^ Heap objects leaked when cleaning up after partial init\n\n", .{});
    };

    heap.objects = .empty;
    if (options.threading) {
        heap.objects.bytes = (try memutil.vmemMap(object_heap_max_bytes)).ptr;
        heap.objects.capacity = object_heap_max_count;
        heap.objects.len = object_heap_max_count;
    } else if (options.threading) {
        // if multithreading, we can't have objects moving around. We better allocate
        // everything up front.
        try heap.objects.ensureTotalCapacity(global_gpa, object_heap_max_count);
        heap.objects.len = object_heap_max_count;
    } else {
        try heap.objects.ensureTotalCapacity(global_gpa, 32);
    }
    errdefer {
        if (options.threading) {
            memutil.vmemUnmap(@alignCast(heap.objects.bytes[0..object_heap_max_bytes]));
        } else {
            heap.objects.deinit(global_gpa);
        }
    }

    // Init strings.
    heap.string_tracking = try .init(global_gpa, global_io, cfg.string_heap_order);
    errdefer if (heap.string_tracking.deinit() == .leaked) {
        ioutil.debug("^^^ Heap strings leaked when cleaning up after partial init\n\n", .{});
    };

    heap.strings = .empty;
    if (options.threading) {
        const string_vmem = try memutil.vmemMap(string_heap_max_bytes);
        heap.strings.items = string_vmem.ptr[0..string_vmem.len];
        heap.strings.capacity = string_vmem.len;
    } else {
        try heap.strings.ensureTotalCapacity(global_gpa, 32);
    }
    errdefer {
        if (options.threading) {
            memutil.vmemUnmap(@alignCast(heap.strings.items.ptr[0..heap.strings.capacity]));
        } else {
            heap.strings.deinit(global_gpa);
        }
    }

    const object_capacity = if (options.threading) object_heap_max_count else 32;

    heap.extra = try .initWithCapacity(global_gpa, object_capacity);
    errdefer heap.extra.deinit(global_gpa);

    heap.parsed_scripts = try .initWithCapacity(global_gpa, cfg.cache_size);
    errdefer heap.parsed_scripts.deinit(global_gpa);
    heap.parsed_exprs = try .initWithCapacity(global_gpa, cfg.cache_size);
    errdefer heap.parsed_exprs.deinit(global_gpa);
    heap.parsed_closures = try .initWithCapacity(global_gpa, cfg.cache_size);
    errdefer heap.parsed_closures.deinit(global_gpa);
    heap.parsed_substs = try .initWithCapacity(global_gpa, cfg.cache_size);
    errdefer heap.parsed_substs.deinit(global_gpa);

    // Done initializing heap fields, so now we'll create all the specialty objects.

    // Null string is guaranteed to have index 0.
    const null_string_idx = try heap.string_tracking.allocFromOwningThread(0);
    assert(null_string_idx == null_string);
    errdefer heap.string_tracking.freeFromOwningThread(null_string_idx, 0);
    // Empty string is guaranteed to have index 1.
    const empty_string_idx = try heap.string_tracking.allocFromOwningThread(0);
    assert(empty_string_idx == empty_string);
    errdefer heap.string_tracking.freeFromOwningThread(empty_string_idx, 0);

    // This is to remember to update this section whenever the special
    // objects change.
    comptime assert(special_object_count == 2);

    // Specialty objects.
    // Null object is guaranteed to have index 0.
    const null_object = try heap.createObject();
    assert(null_object.index == null_object_idx);
    errdefer freeObjectBackingInner(null_object);
    // Empty object is guaranteed to have index 1.
    const empty_object = try heap.createObject();
    assert(empty_object.index == empty_object_idx);
    empty_object.peek().head.str = Object.empty_string;
    errdefer freeObjectBackingInner(empty_object);

    // Create all the interned strings.
    try heap.createInternedStrings();
    errdefer {
        for (special_object_count..(special_object_count + interned_string_count)) |i| {
            // Need to free these objects directly, since they're not normally allowed
            // to be mutated.
            const interned = heap.getHandle(@intCast(i));
            interned.peek().head.str.deinit(heap);
            freeObjectBackingInner(interned);
        }
    }

    const oom_dict = try createOomErrorOptionsDict(heap);
    // Pin so it stays immutable.
    oom_dict.incrRefCount();
    heap.oom_error_options_dict = oom_dict;
    errdefer {
        oom_dict.decrRefCount();
        oom_dict.decrRefCount();
    }
}

fn clearParsedScripts(self: *Heap) void {
    var parsed_script_iter = self.parsed_scripts.valueIterator();
    while (parsed_script_iter.next()) |parsed_script| {
        parsed_script.script.deinit();
    }
    self.parsed_scripts.clearRetainingCapacity();

    var parsed_expr_iter = self.parsed_exprs.valueIterator();
    while (parsed_expr_iter.next()) |parsed_expr| {
        parsed_expr.expr.deinit();
    }
    self.parsed_exprs.clearRetainingCapacity();

    var parsed_closure_iter = self.parsed_closures.valueIterator();
    while (parsed_closure_iter.next()) |entry| {
        entry.closure.deinit();
    }
    self.parsed_closures.clearRetainingCapacity();

    var parsed_substs_iter = self.parsed_substs.valueIterator();
    while (parsed_substs_iter.next()) |entry| {
        entry.subst.deinit();
    }
    self.parsed_substs.clearRetainingCapacity();
}

pub fn deinit(heap: *Heap) void {
    // Parsed scripts have references to objects, so we'll deinit scripts before objects.
    heap.clearParsedScripts();
    heap.parsed_scripts.deinit(global_gpa);
    heap.parsed_exprs.deinit(global_gpa);
    heap.parsed_closures.deinit(global_gpa);
    heap.parsed_substs.deinit(global_gpa);

    for ((special_object_count + interned_string_count)..heap.objects.len) |i| {
        const metadata = heap.objects.get(i).metadata;
        if (metadata.in_use) {
            // We don't use free object here, as it may cause a double-free when
            // freeing recursive structures. For example, if there was a list with
            // two items, we'll free the list (first free of items), then free
            // the items individually (second free).
            invalidateBothInner(heap.getHandle(@intCast(i)));
        }
    }

    for (special_object_count..(special_object_count + interned_string_count)) |i| {
        // Need to free these objects directly, since they're not normally allowed
        // to be mutated.
        const interned = heap.getHandle(@intCast(i));
        interned.peek().head.str.deinit(heap);
        freeObjectBackingInner(interned);
    }

    // Clean up the OOM error dict.
    heap.deinitOomErrorOptions();

    // Be sure to free the specialty objects and strings.
    assert(special_object_count == 2);
    heap.object_tracking.freeFromOwningThread(0, 0);
    heap.object_tracking.freeFromOwningThread(1, 0);
    assert(special_string_count == 2);
    heap.string_tracking.freeFromOwningThread(0, 0);
    heap.string_tracking.freeFromOwningThread(1, 0);

    if (options.threading) {
        memutil.vmemUnmap(@alignCast(heap.strings.items));
        memutil.vmemUnmap(@alignCast(heap.objects.bytes[0..object_heap_max_bytes]));
    } else {
        // Don't use `heapBackingAlloc()` in this case, as that will error
        // with the null allocator.
        heap.strings.deinit(global_gpa);
        heap.objects.deinit(global_gpa);
    }

    if (heap.object_tracking.deinit() == .leaked) @panic("Heap object leaks when deiniting");
    if (heap.string_tracking.deinit() == .leaked) @panic("Heap string leaks when deiniting");

    heap.extra.deinit(global_gpa);
    heap.* = undefined;
}

fn deinitOomErrorOptions(heap: *Heap) void {
    if (heap.oom_error_options_dict) |dict| {
        dict.decrRefCount();
        dict.decrRefCount();
        heap.oom_error_options_dict = null;
    }
}

pub inline fn heapId(self: *Heap) HeapId {
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

pub fn getInternedString(heap: *Heap, string: InternedString) Heap.Handle {
    return heap.interned_strings.get(string);
}

pub fn internedStringRef(heap: *Heap, string: InternedString) Heap.Object {
    return heap.getInternedString(string).reference();
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

    for (self.objects.items(.metadata)[index..][0..memutil.getOrderSize(metadata.order)], 0..) |*new_metadata, i| {
        new_metadata.order = new_order;

        self.getHandle(@intCast(index + i)).trace(
            "Split from index {} (order {}) to order {}",
            .{ index, metadata.order, new_order },
        );
    }
}

test "split allocations" {
    defer Heap.testFinish();
    var heap = try Heap.testStart(testing.allocator, testing.io);

    const index = try heap.createObjects(8);
    heap.splitAlloc(index, 1);

    for (index..(index + 8)) |i| {
        try testing.expectEqual(1, heap.objects.get(i).metadata.order);
    }

    for (0..4) |i| {
        heap.getHandle(@intCast(index + i * 2)).decrRefCount();
    }
}

/// `createObjects` does not initialize objects, but does initialize
/// reference counts.
pub fn createObjects(self: *Heap, count: u32) !u32 {
    const order = memutil.getOrder(count);
    const aligned_count = @as(u32, 1) << order;

    const index: u32 = blk: {
        if (self == local_heap) {
            break :blk try self.object_tracking.allocFromOwningThread(order);
        } else {
            break :blk try self.object_tracking.allocFromAnyThread(order);
        }
    };

    const end = index + aligned_count;

    // Make sure object list has space for new objects.
    if (self.objects.len < index + aligned_count) {
        const start_of_new = self.objects.len;
        if (!options.threading) try self.objects.resize(heapBackingAlloc(), index + aligned_count);
        @memset(self.objects.items(.metadata)[start_of_new..self.objects.len], .{
            .order = 31,
            .cross_thread = false,
            .in_use = false,
            .hash_registered = false,
        });
    }

    self.getHandle(index).trace(
        "Alloc at index {} of order {} with ref count 1 in heap {}",
        .{ index, order, self.heapId() },
    );
    if (aligned_count > 1) {
        for ((index + 1)..end) |collection_item| {
            self.getHandle(@intCast(collection_item)).trace(
                "Item {} allocated while allocating at {} of order {} with ref count 1",
                .{ collection_item, index, order },
            );
        }
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
        .in_use = true,
        .hash_registered = false,
    };

    if (aligned_count > 1) @memset(
        self.objects.items(.metadata)[(index + 1)..end],
        .{
            .order = order,
            .cross_thread = false,
            .in_use = true,
            .hash_registered = false,
        },
    );

    return index;
}

fn freeObjectBackingInner(handle: Handle) void {
    const obj_heap = handle.getHeap();
    const metadata = obj_heap.getLocalMetadata(handle.index).*; // Copy

    if (options.trace_mem) last_touched = handle;
    handle.trace("Free {} of order {}", .{ handle.index, metadata.order });
    for ((handle.index + 1)..(handle.index + memutil.getOrderSize(metadata.order))) |index| {
        obj_heap.getHandle(@intCast(index)).trace("Item {} freed while freeing {} of order {}", .{ index, handle.index, metadata.order });
    }

    if (!metadata.in_use) {
        @panic("Double free!");
    }

    // Mark as free in metadata.
    const alloc_size = memutil.getOrderSize(metadata.order);
    @memset(obj_heap.objects.items(.metadata)[handle.index..][0..alloc_size], .{
        .order = 31,
        .cross_thread = false,
        .in_use = false,
        .hash_registered = false,
    });

    if (obj_heap == local_heap) {
        obj_heap.object_tracking.freeFromOwningThread(handle.index, metadata.order);
    } else {
        obj_heap.object_tracking.freeFromAnyThread(handle.index, metadata.order);
    }
}

/// Does not run any destructors, frees the object directly.
pub fn freeObjectBacking(handle: Handle) void {
    // HACK: should use a custom panic handler for this.
    if (options.trace_mem) last_touched = handle;
    assert(handle.isAllocHead());

    freeObjectBackingInner(handle);
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
pub fn ensureShimmerableOrDup(original: Handle, new: *OptionalHandle) !void {
    const current = new.orElse(original);
    if (!current.canShimmer()) {
        new.swapRef(try Heap.duplicate(local_heap, current));
    }
}

pub fn ensureSameHeapOrDup(handle: Handle, new_handle: *OptionalHandle) !void {
    if (handle.heap != local_heap.heapId()) {
        new_handle.swapRef(try local_heap.duplicate(handle));
    }
}

/// Get a string slice from heap string storage.
pub fn getHeapString(self: *Heap, start: u32, end: u32) [:0]u8 {
    return self.strings.items[start..end :0];
}

/// Returns the total length of the string, including the null byte and the hash handles.
/// This will always align the `Handle`s to their alignment, assuming that the first index
/// of the string is aligned by `Handle`s alignment as well.
fn heapStringLayout(len: u32, hash_count: u10) struct { total_len: u32, handle_start: u32 } {
    const length_with_null = len + 1;
    if (hash_count > 0) {
        // The handles need to be aligned, so we may need some padding.
        const handle_start: u32 = @intCast(mem.alignForward(usize, length_with_null, @alignOf(Handle)));
        return .{
            .total_len = handle_start + hash_count * @sizeOf(Handle),
            .handle_start = handle_start,
        };
    } else {
        // No alignment needed.
        return .{
            .total_len = length_with_null,
            .handle_start = math.maxInt(u32), // No handle start, so use something that will blow up.
        };
    }
}

/// Additionally allocates space for the null byte and for the hash handles. Aligns
/// `Handle`s according to their alignment.
pub fn createHeapString(heap: *Heap, len: u32, hash_handles: []const OptionalHandle) !u32 {
    const layout = heapStringLayout(len, @intCast(hash_handles.len));
    const order = memutil.getOrder(layout.total_len);

    const new_string = blk: {
        if (heap == local_heap) {
            break :blk try heap.string_tracking.allocFromOwningThread(order);
        } else {
            break :blk try heap.string_tracking.allocFromAnyThread(order);
        }
    };
    errdefer heap.string_tracking.freeFromAnyThread(new_string, order);
    // Make sure the returned allocation is aligned to Handle, so that our earlier
    // aligning relative to the string start is valid. Should always be valid with
    // the buddy allocator, but this should catch any regressions.
    if (hash_handles.len > 0) assert(@mod(new_string, @alignOf(Handle)) == 0);

    if (!options.threading) {
        try heap.strings.ensureTotalCapacity(heapBackingAlloc(), new_string + layout.total_len);
        heap.strings.items.len = @max(heap.strings.items.len, new_string + layout.total_len);
    }

    heap.strings.items[new_string + len] = 0; // Set null byte.

    // Copy handles in and borrows them.
    for (hash_handles, 0..) |handle, i| {
        mem.writeInt(
            HandleBacking,
            heap.strings.items[(new_string + layout.handle_start + @sizeOf(Handle) * i)..][0..@sizeOf(Handle)],
            @bitCast(@intFromEnum(handle)),
            .native,
        );
        _ = handle.borrowOptional();
    }

    return new_string;
}

pub fn freeHeapString(self: *Heap, index: u32, len: u32, hash_count: u10) void {
    assert(index >= special_string_count);

    const layout = heapStringLayout(len, hash_count);
    const order = memutil.getOrder(layout.total_len);

    // Release handles.
    if (hash_count > 0) {
        const handles: [*]const OptionalHandle = @ptrCast(@alignCast(&self.strings.items[index + layout.handle_start]));
        for (handles[0..hash_count]) |handle| handle.decrOptional();
    }

    if (self == local_heap) {
        self.string_tracking.freeFromOwningThread(index, order);
    } else {
        self.string_tracking.freeFromAnyThread(index, order);
    }
}

pub fn checkIfEqual(a: Handle, b: Handle) !bool {
    if (a == b) return true;

    // Make sure they have a string rep before checking the details.
    const a_str = try a.getString();
    const b_str = try b.getString();
    const a_details = a.getStringDetails();
    const b_details = b.getStringDetails();

    blk: {
        const a_long_str = switch (a_details) {
            .long => |unwrapped| unwrapped,
            // The only case where an object can have a null string after getting
            // its string value is a reference.
            .null => {
                assert(a.tag() == .reference);
                break :blk;
            },
            else => break :blk,
        };

        const b_long_str = switch (b_details) {
            .long => |unwrapped| unwrapped,
            .null => {
                assert(b.tag() == .reference);
                break :blk;
            },
            else => break :blk,
        };

        // If both strings are special strings, we can just
        // compare their hashes instead of the whole string.
        return a_long_str.getHash() == b_long_str.getHash();
    }

    return std.mem.eql(u8, a_str, b_str);
}

/// Steal an object. This allocates a new object and sets its contents to the
/// provided object's contents. Be very careful when using this.
///
/// Some things to keep in mind:
///  * Caller is responsible for freeing the object's previous allocation,
///    _without_ triggering `invalidateBody` or `invalidateString`. You'll
///    want to use `freeObjectBacking` instead of `freeObject`.
///  * This allocates a single object, not a range, so you can't use this to
///    steal a list or dict.
///  * This can't be used with a shared object.
pub fn steal(handle: Handle) !Handle {
    assert(local_heap.heapId() == handle.heap);
    assert(handle.canMutate());

    const new_obj = try local_heap.createObject();
    new_obj.peek().* = handle.peek().*;

    return new_obj;
}

pub fn duplicateObjString(dest_heap: *Heap, handle: Handle) !Object.StrOrPtr {
    switch (handle.getStringDetails()) {
        .long => |long_str| {
            long_str.incrRefCount();
            return .{
                .u = .{ .ptr = SpecialString.toInt(long_str) },
                .is_ptr = true,
            };
        },
        .normal => |normal_str| {
            const new_string = try dest_heap.createHeapString(@intCast(normal_str.bytes.len), normal_str.hash_handles);
            const len: Object.StrOrPtr.NormalLength = @intCast(normal_str.bytes.len);
            @memcpy(dest_heap.getHeapString(new_string, new_string + len), normal_str.bytes);

            return .{
                .u = .{ .str = .{ .index = new_string, .len = len, .hash_count = @intCast(normal_str.hash_handles.len) } },
                .is_ptr = false,
            };
        },
        .null, .empty => {
            return handle.peek().head.str;
        },
    }
}

pub fn dupSingleOrReference(dest_heap: *Heap, handle: Handle) !Object {
    if (dest_heap.duplicateSingle(handle)) |new_obj| {
        return new_obj;
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MultiItemObject => return handle.reference(),
    }
}

/// Duplicates the object if it's a fast duplication, else references it.
pub fn dupOrReference(dest_heap: *Heap, handle: Handle) Object {
    _ = dest_heap;

    const tag = handle.tag();
    if (tag == .reference) {
        // We can't reference a reference, so we'll create a new reference.
        return handle.peek().body.reference.reference();
    } else if (tag == .upvar_link) {
        handle.assert(Heap.local_heap == handle.getHeap());
        const upvar_link = handle.peek().body.upvar_link;
        const linked_name = Heap.local_heap.getHandle(upvar_link.linked_name);
        return .{
            .head = .{ .str = Heap.Object.null_string, .tag = .upvar_link },
            .body = .{ .upvar_link = .{
                .call_frame = upvar_link.call_frame,
                .linked_name = linked_name.borrow().index,
            } },
        };
    } else if (handle.peek().head.str == Object.null_string and tag == .float or tag == .integer) {
        // We can't just use a number if it has a string rep, because the string may
        // be different than how the number will be rendered.
        return .{
            .head = .{
                .str = Object.null_string,
                .tag = tag,
            },
            .body = handle.peek().body,
        };
    } else {
        return handle.reference();
    }
}

/// If called with a multi-item object, will return `error.MultiItemObject`.
pub fn duplicateSingle(dest_heap: *Heap, handle: Handle) error{ OutOfMemory, MultiItemObject }!Object {
    const src = handle.peek();
    if (options.trace_mem) last_touched = handle;
    switch (handle.tag()) {
        .none, .index, .integer, .float, .string, .bool, .parsed_script_command, .marked => {
            return .{
                .head = .{
                    .str = try dest_heap.duplicateObjString(handle),
                    .tag = handle.tag(),
                },
                .body = src.body,
            };
        },
        .source => {
            const source = src.body.source;
            const src_extra_data = handle.getHeap().getExtraData(source.extra_data).source;
            const extra_data_index = try dest_heap.createExtraData();
            errdefer dest_heap.destroyExtraData(extra_data_index);

            const new_extra_data = dest_heap.getExtraData(extra_data_index);
            new_extra_data.* = .{
                .source = .{
                    .file_name = src_extra_data.file_name.borrowOptional(),
                    .line_no = src_extra_data.line_no,
                    .hash = .{
                        .state = undefined,
                        .hash = undefined,
                    },
                },
            };

            const parsed_state = src_extra_data.hash.state.load(.acquire);
            switch (parsed_state) {
                .not_computed => {
                    new_extra_data.source.hash.state.store(.not_computed, .release);
                },
                .computed => {
                    new_extra_data.source.hash.hash = src_extra_data.hash.hash;
                    new_extra_data.source.hash.state.store(.computed, .release);
                },
            }

            return .{
                .head = .{
                    .str = try dest_heap.duplicateObjString(handle),
                    .tag = .source,
                },
                .body = .{ .source = .{ .extra_data = extra_data_index } },
            };
        },
        .reference => {
            // Try to duplicate what it's referencing, else create a new reference to it.
            return dest_heap.duplicateSingle(src.body.reference) catch |err| switch (err) {
                error.MultiItemObject => return src.body.reference.reference(),
                error.OutOfMemory => return error.OutOfMemory,
            };
        },
        .custom_type => {
            const custom_type = src.body.custom_type;

            var new_object: Object = .{
                // TODO make sure this doesn't leak
                .head = .{ .str = try dest_heap.duplicateObjString(handle), .tag = .custom_type },
                .body = .{
                    .custom_type = .{
                        .extra_data = try dest_heap.createExtraData(),
                        .type_id = custom_type.type_id,
                    },
                },
            };
            new_object = try custom_types.items[custom_type.type_id].duplicate(dest_heap, src);

            return new_object;
        },
        .dict_sugar, .cached_local_var, .cached_lexical_var => {
            // Variable lookup is not stable between threads.
            return .{
                .head = .{ .str = try dest_heap.duplicateObjString(handle), .tag = .none },
                .body = undefined,
            };
        },
        .regexp => {
            // PCRE2 compiled code is immutable and thread-safe, but duplicating the pointer
            // would cause a double-free when both copies are destroyed. The pattern string
            // is preserved; it will recompile on next use.
            return .{
                .head = .{ .str = try dest_heap.duplicateObjString(handle), .tag = .none },
                .body = undefined,
            };
        },
        .closure => {
            const closure = handle.getClosureExtraData();
            const new_extra_data = try dest_heap.createExtraData();
            errdefer dest_heap.destroyExtraData(new_extra_data);
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
        .hash_reference => {
            return .{
                .head = .{
                    .str = try dest_heap.duplicateObjString(handle),
                    .tag = .hash_reference,
                },
                .body = .{ .hash_reference = src.body.hash_reference.borrow() },
            };
        },
        .upvar_link => @panic("Cannot duplicate an upvar"),
        .invalid => @panic("Tried to duplicate an invalid object."),
    }
}

pub fn duplicate(dest_heap: *Heap, src_handle: Handle) error{OutOfMemory}!Handle {
    const src = src_handle.peek();

    switch (src_handle.tag()) {
        .list => {
            const old_body = src.body.list;
            const old_start = src_handle.index + 1;

            const new_list_idx = try dest_heap.createObjects(1 + old_body.len);
            errdefer {
                // Free elements before freeing the head, as the head could
                // be swapped out if freed too early.
                for (0..old_body.len) |i| {
                    freeObject(.{
                        .index = @intCast(new_list_idx + 1 + i),
                        .heap = src_handle.heap,
                    });
                }
                freeObject(.{ .index = new_list_idx, .heap = src_handle.heap });
            }
            const new_head: *Object = dest_heap.getLocalObject(new_list_idx);
            const new_start = new_list_idx + 1;
            const new_items = dest_heap.objectSlice(new_start, new_start + old_body.len);

            // Duplicate head of list.
            new_head.* = .{
                .head = .{
                    .str = try dest_heap.duplicateObjString(src_handle),
                    .tag = .list,
                },
                .body = .{
                    .list = .{ .len = old_body.len },
                },
            };

            // Duplicate items of list.
            for (new_items, 0..) |*new_item, i| {
                new_item.* = dest_heap.duplicateSingle(.{
                    .heap = src_handle.heap,
                    .index = @intCast(old_start + i),
                }) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    // Lists can't contain multi item objects
                    error.MultiItemObject => unreachable,
                };
            }

            return dest_heap.getHandle(new_list_idx);
        },
        .dict => {
            const old_len = src.body.dict.len;
            const old_start = src_handle.index + 1;

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
                errdefer dest_heap.destroyExtraData(new_extra_data);

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

const hash_prepend = "blake3^";
const hash_chars = std.base64.url_safe_alphabet_chars;
const hash_encoder = std.base64.Base64Encoder.init(hash_chars, null);
const hash_decoder = std.base64.Base64Decoder.init(hash_chars, null);
const hash_len = hash_encoder.calcSize(32);
const hash_and_prepend_len = hash_prepend.len + hash_len;
fn scanStringForHashRefs(arena: Allocator, bytes: []const u8) !std.ArrayList(u256) {
    var found_hashes: std.ArrayList(u256) = .empty;
    errdefer found_hashes.deinit(arena);

    var current_index: usize = 0;
    while (true) {
        if (std.mem.findPos(u8, bytes, current_index, hash_prepend)) |next| {
            if (bytes.len - next >= hash_and_prepend_len) {
                defer current_index = next + hash_and_prepend_len;

                var output: [32]u8 = undefined;
                hash_decoder.decode(&output, bytes[(next + hash_prepend.len)..][0..hash_len]) catch |err| switch (err) {
                    error.InvalidCharacter,
                    error.InvalidPadding,
                    error.NoSpaceLeft,
                    => continue,
                };

                try found_hashes.append(arena, @bitCast(output));
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

fn scanAndResolveHashRefs(arena: Allocator, bytes: []const u8) error{OutOfMemory}!std.ArrayList(OptionalHandle) {
    var found_hashes = try scanStringForHashRefs(arena, bytes);
    defer found_hashes.deinit(arena);

    // Look up all the found hashes.
    var resolved_hashes: std.ArrayList(OptionalHandle) = try .initCapacity(arena, found_hashes.items.len);
    {
        registered_hashes.rw_lock.lockSharedUncancelable(global_io);
        defer registered_hashes.rw_lock.unlockShared(global_io);

        for (found_hashes.items) |found_hash| {
            if (registered_hashes.entries.get(found_hash)) |resolved| {
                resolved_hashes.appendAssumeCapacity(resolved.representative.toOptional());
            } else {
                resolved_hashes.appendAssumeCapacity(.none);
            }
        }
    }

    return resolved_hashes;
}

pub fn setString(handle: Handle, bytes: []const u8) error{ OutOfMemory, OtherThreadSet }!void {
    var resolved = try scanAndResolveHashRefs(global_gpa, bytes);
    defer resolved.deinit(global_gpa);
    try setStringKnownHashHandles(handle, bytes, resolved.items);
}

/// Copies provided string.
pub fn setStringKnownHashHandles(
    handle: Handle,
    bytes: []const u8,
    hash_handles: []const OptionalHandle,
) error{ OutOfMemory, OtherThreadSet }!void {
    const heap = handle.getHeap();

    // Try setting as a normal string first.
    if (heap.setNormalString(handle.index, bytes, hash_handles)) {
        // Success!
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OtherThreadSet => return error.OtherThreadSet,
        error.TooBig => {
            // Setting it as a special string will most likely take ownership,
            // so we need to copy.
            const new_str = try global_gpa.dupeSentinel(u8, bytes, 0);
            errdefer global_gpa.free(new_str);
            errdefer for (hash_handles) |val| val.decrOptional();
            try heap.setSpecialString(handle.index, .{ .normal = new_str }, hash_handles);
        },
    }
}

/// Get the string to modify (must not write any longer than current len).
/// Not threadsafe.
pub fn getStringMut(handle: Handle) ![:0]u8 {
    switch (handle.getStringDetails()) {
        .long => |long_str| {
            switch (long_str.string_type) {
                .normal => |normal| return normal,
                .temp => @panic("Can't modify a temp object"),
                .different_capacity => |info| return info.string,
            }
        },
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
    const success = blk: {
        const obj: *Object = self.getLocalObject(index);
        if (options.threading and self.objects.get(index).metadata.cross_thread) {
            const object_head: *align(8) Object.Head = @ptrCast(&obj.head);
            var current_head = @atomicLoad(Object.Head, object_head, .acquire);
            while (true) {
                // Is the string pointer what we expected?
                if (current_head.str != expected) {
                    // If not, somebody else must've won this, so let the caller know.
                    break :blk false;
                }

                // Preserve type tag from current_head.
                var new_head = current_head;
                new_head.str = to_set_to;

                const res: ?Object.Head =
                    @cmpxchgWeak(Object.Head, object_head, current_head, new_head, .release, .acquire);
                if (res) |winning_head| {
                    current_head = winning_head;
                    continue; // Try again.
                } else {
                    // Successfully swapped.
                    break :blk true;
                }
            }
        } else {
            obj.head.str = to_set_to;
            break :blk true;
        }
    };

    if (success) {
        const handle = self.getHandle(index);
        handle.trace("Set string to \"{f}\"", .{handle});
    }

    return success;
}

/// Returns whether the heap took ownership. It may copy the bytes into
/// the heap, so it can succeed while also not taking ownership.
pub fn setStringOwning(handle: Handle, bytes: [:0]u8, hash_handles: []const OptionalHandle) error{ OutOfMemory, OtherThreadSet }!bool {
    const heap = handle.getHeap();

    heap.setNormalString(handle.index, bytes, hash_handles) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OtherThreadSet => return error.OtherThreadSet,
        error.TooBig => {
            try heap.setSpecialString(handle.index, .{ .normal = bytes }, hash_handles);
            return true;
        },
    };

    // Successfully set as normal string.
    return false;
}

/// Low-level function. You probably want `Heap.setString()`.
/// Attempts to copy the provided string into the object heap.
/// Returns false if the string is too big.
pub fn setNormalString(
    self: *Heap,
    obj_index: u32,
    bytes: []const u8,
    hash_handles: []const OptionalHandle,
) error{ OutOfMemory, TooBig, OtherThreadSet }!void {
    if (bytes.len == 0) {
        // No need to check the result of the exchange, as there's nothing to clean up
        assert(self.exchangeString(obj_index, Object.null_string, Object.empty_string));
        return;
    }

    if (bytes.len >= SpecialString.split_point) return error.TooBig;

    const string = try self.createHeapString(@intCast(bytes.len), hash_handles);
    const len: Object.StrOrPtr.NormalLength = @intCast(bytes.len);
    @memcpy(
        self.getHeapString(string, string + len),
        bytes,
    );

    const string_header: Object.StrOrPtr = .{
        .u = .{
            .str = .{ .index = string, .len = len, .hash_count = @intCast(hash_handles.len) },
        },
        .is_ptr = false,
    };

    const did_win = self.exchangeString(obj_index, Object.null_string, string_header);
    if (!did_win) {
        self.freeHeapString(string, len, @intCast(hash_handles.len));
        return error.OtherThreadSet;
    }
}

/// Low-level function. You probably want `Heap.setString()`.
/// The only case where this would fail is OOM or if someone else
/// exchanged the string right before us.
pub fn setSpecialString(
    self: *Heap,
    obj_index: u32,
    string: SpecialString.Type,
    hash_handles: []const OptionalHandle,
) error{ OutOfMemory, OtherThreadSet }!void {
    const special_string_backing = try global_gpa.alignedAlloc(SpecialString, SpecialString.align_type, 1);
    const special_string = &special_string_backing[0];
    errdefer global_gpa.free(special_string_backing);
    var owned_hash_handles = std.ArrayList(OptionalHandle).empty;
    errdefer owned_hash_handles.deinit(global_gpa);
    try owned_hash_handles.appendSlice(global_gpa, hash_handles);
    special_string.* = .{
        .string_type = string,
        .hash_handles = owned_hash_handles,
    };

    for (hash_handles) |handle| handle.incrOptional();
    errdefer for (hash_handles) |handle| handle.decrOptional();

    const string_header = Object.StrOrPtr{
        .u = .{ .ptr = SpecialString.toInt(special_string) },
        .is_ptr = true,
    };

    if (!self.exchangeString(obj_index, Object.null_string, string_header)) {
        return error.OtherThreadSet;
    }
}

fn getListString(self: *Heap, index: u32, len: u32) ![:0]u8 {
    var fallback = std.heap.stackFallback(64, global_gpa);
    var stack_alloc = fallback.get();
    var quoting_types = try stack_alloc.alloc(strutil.QuotingType, len);
    defer stack_alloc.free(quoting_types);

    // Step 1: calculate the list's string length.
    var total_length: usize = 0;
    for (0..len) |i| {
        const element_string = try self.getHandle(@intCast(index + i)).getString();

        quoting_types[i] = strutil.calculateNeededQuotingType(element_string);
        if (i == 0 and quoting_types[i] == .bare and
            element_string.len > 0 and element_string[0] == '#')
        {
            // Make sure the first element has # escaped in braces
            quoting_types[i] = .brace;
        }
        total_length += strutil.quoteSize(quoting_types[i], element_string.len);
        total_length += 1; // space between each element
    }

    // Step 2: actually create said string.
    var unfinished_str = try global_gpa.alloc(u8, total_length + 1);
    errdefer global_gpa.free(unfinished_str);
    var written: usize = 0;

    for (0..len) |i| {
        const element_string = try self.getHandle(@intCast(index + i)).getString();
        written += strutil.quoteString(
            quoting_types[i],
            element_string,
            unfinished_str[written..],
            i == 0,
        );

        // Add a space (except at the end of the list).
        if (i + 1 < len) {
            unfinished_str[written] = ' ';
            written += 1;
        }
    }

    // Slap a nul on the end.
    unfinished_str[written] = 0x00;
    written += 1;

    // We actually need to realloc, because allocator.free needs the
    // original slice length (and we don't track the original slice
    // length, only the accessible length).
    const finished_str = try global_gpa.realloc(unfinished_str, written);
    return finished_str[0..(written - 1) :0];
}

fn generateDictString(handle: Handle) ![:0]u8 {
    return try getListString(handle.getHeap(), handle.index + 1, handle.peek().body.dict.len);
}

const StringDetails = union(enum) {
    null: void,
    empty: void,
    normal: struct { bytes: [:0]u8, hash_handles: []const OptionalHandle },
    long: *align(SpecialString.align_amt) SpecialString,
};

fn getLocalStringDetails(heap: *Heap, str_or_ptr: Object.StrOrPtr) StringDetails {
    // Normal string or special string?
    if (str_or_ptr.is_ptr) {
        // Convert to LongString ptr (guaranteed to be non-null).
        return .{
            .long = SpecialString.fromInt(str_or_ptr.u.ptr),
        };
    } else {
        const str = str_or_ptr.u.str;
        if (str.index == null_string) {
            return .null;
        } else if (str.index == empty_string) {
            return .empty;
        } else {
            const layout = heapStringLayout(str.len, str.hash_count);
            const hash_handles: []const OptionalHandle = if (str.hash_count > 0) blk: {
                const raw: [*]const OptionalHandle = @ptrCast(@alignCast(&heap.strings.items[str.index + layout.handle_start]));
                break :blk raw[0..str.hash_count];
            } else &.{};

            return .{
                .normal = .{
                    .bytes = heap.getHeapString(str.index, str.index + str.len),
                    .hash_handles = hash_handles,
                },
            };
        }
    }
}

/// Special strings are strings that have special properties, such as being large,
/// having a different allocation backing then what's visible, or (in the future)
/// being memory mapped. This means that they have some more specialized handling,
/// so this is the structure that encapsulates that behavior.
pub const SpecialString = struct {
    /// At what point should we switch to using a special string?
    /// Whenever the string length >= `split_point`.
    pub const split_point = math.maxInt(Object.StrOrPtr.NormalLength);
    /// This needs to be aligned to 128, due to how pointers are stored in StrOrPtr.
    pub const align_amt = 128;
    pub const align_type = std.mem.Alignment.fromByteUnits(align_amt);

    /// Special strings are special in that they can have
    /// extended properties (mmaping is in the plans,
    /// for example). Since it has special properties,
    /// we have to track them so it can be freed correctly.
    pub const Type = union(enum) {
        normal: [:0]u8,
        /// A temporary string has its bytes managed by someone else,
        /// so when this `LongString` is freed, we won't free the string.
        temp: [:0]const u8,
        /// If the string was allocated with a different capacity
        /// than its current reported length, set this field.
        different_capacity: struct {
            string: [:0]u8,
            original_capacity: u64,
        },
    };
    /// This is contains the handles to the hashes referenced in the string.
    /// They are in order as appearing in the string, and are not deduplicated.
    hash_handles: std.ArrayList(OptionalHandle),

    string_type: Type,
    /// Length has not been determined if == `maxInt(u64)`.
    utf8_length: u64 = math.maxInt(u64),
    hash: struct {
        value: ?u256 = null,
        // TODO PERF this probably can be done with acquire/release, the mutex is a bit overkill.
        mutex: std.Io.Mutex = .init,
    } = .{},
    ref_count: usize = 1,

    pub fn fromInt(int: u58) *align(align_amt) SpecialString {
        return @ptrFromInt(int << 6);
    }

    pub fn toInt(ptr: *align(align_amt) SpecialString) u58 {
        return @intCast(@intFromPtr(ptr) >> 6);
    }

    pub fn getHash(self: *align(align_amt) SpecialString) u256 {
        self.hash.mutex.lockUncancelable(global_io);
        defer self.hash.mutex.unlock(global_io);

        if (self.hash.value) |hash| {
            return hash;
        } else {
            const hash = memutil.hashBytes(self.getString());
            self.hash.value = hash;
            return hash;
        }
    }

    pub fn getUtf8Length(self: *align(align_amt) SpecialString) ?u64 {
        const value = @atomicLoad(u64, &self.utf8_length, .monotonic);
        if (value == std.math.maxInt(u64)) return null else return value;
    }

    /// Value is `u64`, not `?u64`, since utf8 length should not ever
    /// change (excluding `LongString` temp strings).
    pub fn setUtf8Length(self: *align(align_amt) SpecialString, value: u64) void {
        assert(value != std.math.maxInt(u64));
        @atomicStore(u64, &self.utf8_length, value, .monotonic);
    }

    pub fn getString(self: *align(align_amt) SpecialString) [:0]const u8 {
        switch (self.string_type) {
            .normal => |string| return string,
            .temp => |temp| return temp,
            .different_capacity => |info| return info.string,
        }
    }

    pub fn incrRefCount(self: *align(align_amt) SpecialString) void {
        incrRefCountOf(usize, &self.ref_count, options.threading);
    }

    pub fn decrRefCount(self: *align(align_amt) SpecialString, gpa: Allocator) void {
        if (decrRefCountOf(usize, &self.ref_count, options.threading) == 0) {
            self.freeInner(gpa);
        }
    }

    pub fn freeInner(self: *align(align_amt) SpecialString, gpa: Allocator) void {
        switch (self.string_type) {
            .normal => |string| gpa.free(string),
            .different_capacity => |info| {
                gpa.free(info.string.ptr[0..info.original_capacity :0]);
            },
            .temp => {
                // We don't want to free the string, as it's managed by someone else.
            },
        }
        for (self.hash_handles.items) |handle| handle.decrOptional();
        self.hash_handles.deinit(gpa);

        gpa.destroy(self);
    }
};

pub fn createExtraData(self: *Heap) !ExtraData {
    // TODO PERF make a fast case where this uses a heap-local list of
    // available extra data.
    self.extra_data_mutex.lockUncancelable(global_io);
    defer self.extra_data_mutex.unlock(global_io);

    const new_index = try self.extra.create(heapBackingAlloc());
    if (new_index >= object_heap_max_count) return error.OutOfMemory;

    return @enumFromInt(new_index);
}

pub fn getExtraData(self: *Heap, index: ExtraData) *ExtraDataValue {
    return &self.extra.items[@intFromEnum(index)];
}

pub fn destroyExtraData(self: *Heap, index: ExtraData) void {
    switch (self.getExtraData(index).*) {
        .lexical_variable => |lexical_var| {
            lexical_var.ref.decrRefCount();
        },
        .dict => |*dict| {
            if (dict.table) |*table| table.deinit(global_gpa);
        },
        .source => |*source| {
            source.file_name.decrOptional();
        },
        .custom_type => {
            @panic("Need to clean up custom type");
        },
        .closure => |*closure| {
            closure.deinit();
        },
        .regexp => |re| {
            pcre2.pcre2_code_free_8(re);
        },
        .none => {},
    }

    self.extra_data_mutex.lockUncancelable(global_io);
    defer self.extra_data_mutex.unlock(global_io);

    self.getExtraData(index).* = undefined;
    self.extra.destroy(@intFromEnum(index));
}

pub fn initGlobals(gpa: Allocator, io: std.Io) !void {
    global_io = io;

    state.mutex.lockUncancelable(global_io);
    defer state.mutex.unlock(global_io);

    global_gpa = gpa;
    custom_types = try .initWithCapacity(global_gpa, if (options.threading) cfg.max_custom_types else 32);
    errdefer custom_types.deinit(global_gpa);

    try regex.initGlobals();
    errdefer regex.deinitGlobals();

    registered_hashes = .{};
    nativefn_registry = .{};

    state.initialized = true;
}

pub fn initLocalHeap() !void {
    if (builtin.mode == .Debug) {
        debugging_gpa = memutil.RingBufferAllocator.init(debugging_buffer[0..]);
        debug_gpa = debugging_gpa.allocator();
    }

    const slot_index = blk: {
        state.mutex.lockUncancelable(global_io);
        defer state.mutex.unlock(global_io);

        assert(state.initialized);

        const heap_index = state.next_open_heap;
        state.next_open_heap += 1;

        break :blk heap_index;
    };
    errdefer {
        // Roll back heap index if it failed to initialize correctly.
        state.mutex.lockUncancelable(global_io);
        state.next_open_heap -= 1;
        state.mutex.unlock(global_io);
    }

    if (slot_index < cfg.max_heaps) {
        const new_heap = &heaps[slot_index];
        try new_heap.init();
        local_heap = new_heap;
        errdefer new_heap.deinit();
    } else {
        return error.OutOfMemory;
    }
}

fn createOomErrorOptionsDict(heap: *Heap) !Handle {
    const zero = try objutil.newInteger(heap, 0);
    defer zero.decrRefCount();
    const one = try objutil.newInteger(heap, 1);
    defer one.decrRefCount();

    const pairs = [_]Handle{
        heap.getInternedString(.@"-code"),      one,
        heap.getInternedString(.@"-level"),     zero,
        heap.getInternedString(.@"-errorcode"), heap.getInternedString(.@"ZICL OOM"),
    };

    const new_dict = try objutil.newDictInner(heap, &pairs);
    errdefer new_dict.decrRefCount();

    // Make sure it has a dict and a string rep, so it's useful in an
    // OOM situation.
    _ = try new_dict.getString();
    _ = try objutil.dictGetTable(new_dict);

    return new_dict;
}

pub fn deinitAll() void {
    state.mutex.lockUncancelable(global_io);
    const heap_count = state.next_open_heap;
    state.next_open_heap = 0;
    state.mutex.unlock(global_io);

    // Deinit heaps without holding the mutex, as they may lock.
    for (heaps[0..heap_count]) |*heap| {
        heap.deinit();
    }

    // Deinit global state.
    state.mutex.lockUncancelable(global_io);
    if (state.initialized) {
        custom_types.deinit(global_gpa);
        nativefn_registry.deinit(global_gpa);
        registered_hashes.entries.deinit(global_gpa);
        regex.deinitGlobals();
        state.initialized = false;
    }
    state.mutex.unlock(global_io);
}

pub fn createCustomType(custom_type: CustomType) ?*CustomType {
    state.mutex.lock();
    const slot_index = try state.custom_types.create(global_gpa);
    state.mutex.unlock();

    if (slot_index < cfg.max_custom_types) {
        state.custom_types.items[slot_index] = custom_type;
        return &state.custom_types.items[slot_index];
    } else {
        return null;
    }
}

test "object duplication" {
    const ta = std.testing.allocator;
    defer Heap.testFinish();
    var heap = try Heap.testStart(ta, std.testing.io);

    // Number object.
    const obj = try heap.createObject();
    defer obj.decrRefCount();
    var ref = obj.peek();
    ref.head.tag = .integer;
    ref.body.integer = 10;

    const new_obj = try heap.duplicate(obj);
    defer new_obj.decrRefCount();

    try expectEqual(.integer, new_obj.tag());
    try expectEqual(10, new_obj.peek().body.integer);

    // Try borrowing.
    new_obj.incrRefCount();
    try expectEqual(2, new_obj.refCount());

    new_obj.decrRefCount();
    try expectEqual(1, heap.objects.get(new_obj.index).ref_count);
}

test "get string" {
    const ta = std.testing.allocator;
    defer Heap.testFinish();
    var heap = try Heap.testStart(ta, testing.io);

    const obj = try heap.createObject();
    defer obj.decrRefCount();
    var ref = obj.peek();
    ref.head.tag = .integer;
    ref.body.integer = 10;

    try expectEqualSlices(u8, "10", try obj.getString());
}

test "scanStringForHashRefs finds no tokens in plain text" {
    const ta = std.testing.allocator;
    var found = try scanStringForHashRefs(ta, "hello world");
    defer found.deinit(ta);
    try std.testing.expectEqual(0, found.items.len);
}

test "scanStringForHashRefs finds a single token" {
    const ta = std.testing.allocator;
    var hash_bytes: [32]u8 = undefined;
    @memset(&hash_bytes, 0xAB);
    var encoded: [hash_len]u8 = undefined;
    _ = hash_encoder.encode(&encoded, &hash_bytes);

    const input = try std.fmt.allocPrint(ta, "prefix blake3^{s} suffix", .{encoded});
    defer ta.free(input);

    var found = try scanStringForHashRefs(ta, input);
    defer found.deinit(ta);
    try std.testing.expectEqual(1, found.items.len);
    try std.testing.expectEqual(@as(u256, @bitCast(hash_bytes)), found.items[0]);
}

test "scanStringForHashRefs finds multiple tokens" {
    const ta = std.testing.allocator;
    var hash_a: [32]u8 = undefined;
    @memset(&hash_a, 0x01);
    var hash_b: [32]u8 = undefined;
    @memset(&hash_b, 0x02);
    var enc_a: [hash_len]u8 = undefined;
    var enc_b: [hash_len]u8 = undefined;
    _ = hash_encoder.encode(&enc_a, &hash_a);
    _ = hash_encoder.encode(&enc_b, &hash_b);

    const input = try std.fmt.allocPrint(ta, "blake3^{s} and blake3^{s}", .{ enc_a, enc_b });
    defer ta.free(input);

    var found = try scanStringForHashRefs(ta, input);
    defer found.deinit(ta);
    try std.testing.expectEqual(2, found.items.len);
    try std.testing.expectEqual(@as(u256, @bitCast(hash_a)), found.items[0]);
    try std.testing.expectEqual(@as(u256, @bitCast(hash_b)), found.items[1]);
}

test "scanStringForHashRefs skips bad chars" {
    const ta = std.testing.allocator;
    // Invalid base64 character '@' in the hash position.
    const input = "blake3^" ++ "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@";
    var found = try scanStringForHashRefs(ta, input);
    defer found.deinit(ta);
    try std.testing.expectEqual(0, found.items.len);
}

test "scanStringForHashRefs ignores short ending" {
    const ta = std.testing.allocator;
    const input = "blake3^short";
    var found = try scanStringForHashRefs(ta, input);
    defer found.deinit(ta);
    try std.testing.expectEqual(0, found.items.len);
}

test "scanStringForHashRefs duplicates identical tokens" {
    const ta = std.testing.allocator;
    var hash_bytes: [32]u8 = undefined;
    @memset(&hash_bytes, 0xCD);
    var encoded: [hash_len]u8 = undefined;
    _ = hash_encoder.encode(&encoded, &hash_bytes);

    const input = try std.fmt.allocPrint(ta, "blake3^{s} blake3^{s}", .{ encoded, encoded });
    defer ta.free(input);

    var found = try scanStringForHashRefs(ta, input);
    defer found.deinit(ta);
    try std.testing.expectEqual(2, found.items.len);
    try std.testing.expectEqual(@as(u256, @bitCast(hash_bytes)), found.items[0]);
    try std.testing.expectEqual(@as(u256, @bitCast(hash_bytes)), found.items[1]);
}

/// Atomically adds, if multithreading is enabled. Returns value before adding.
pub fn atomicIncr(comptime T: type, ptr: *T) T {
    if (options.threading) {
        return @atomicRmw(T, ptr, .Add, 1, .monotonic);
    } else {
        const before = ptr.*;
        ptr.* += 1;
        return before;
    }
}

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

pub fn testStart(gpa: Allocator, io: std.Io) !*Heap {
    try initGlobals(gpa, io);
    errdefer deinitAll();
    try initLocalHeap();

    return local_heap;
}

pub fn leakCheckAll() void {
    state.mutex.lockUncancelable(global_io);
    state.running_leak_check = true;
    const heap_count = state.next_open_heap;
    state.mutex.unlock(global_io);

    var leaked = false;
    for (heaps[0..heap_count]) |*heap| {
        if (heap.leakCheck() catch false) {
            leaked = true;
        }
    }
}

pub fn testFinish() void {
    Heap.leakCheckAll();
    Heap.deinitAll();
}

pub fn leakCheck(heap: *Heap) !bool {
    return leakCheckWithMode(heap, .dot_graph);
}

pub fn leakCheckWithMode(heap: *Heap, mode: enum { normal, dot_graph }) !bool {
    // Make sure to free any parsed scripts and system fixtures before scanning,
    // as they're allowed to leak (they have references to heap objects, causing false positives).
    heap.clearParsedScripts();
    heap.deinitOomErrorOptions();

    // Go through once to print the summary, then print each individual trace.
    const skip_count = special_object_count + interned_string_count;
    for (heap.objects.items(.metadata)[skip_count..]) |metadata| {
        if (metadata.in_use) break;
    } else return false;

    switch (mode) {
        .normal => leakDumpNormal(heap, skip_count),
        .dot_graph => {
            leakDumpNormal(heap, skip_count);
            try leakDumpDotGraph(heap, skip_count);
        },
    }

    return true;
}

fn leakDumpNormal(heap: *Heap, skip_count: usize) void {
    for (heap.objects.items(.metadata)[skip_count..], skip_count..) |metadata, i| {
        if (metadata.in_use) {
            const handle = heap.getHandle(@intCast(i));
            const str = handle.getString();
            if (str) |val| {
                ioutil.debug("Leaked {}, index {}, order: {}, ref count {}, \"{s}\"\n", .{
                    handle.tag(),
                    i,
                    handle.getMetadata().order,
                    handle.refCount(),
                    val,
                });
            } else |_| {
                ioutil.debug("Leaked {}, index {}, order: {}, ref count {}, <oom>\n", .{
                    handle.tag(),
                    i,
                    handle.getMetadata().order,
                    handle.refCount(),
                });
            }
        }
    }

    if (options.trace_mem) {
        ioutil.debug("\n===== Leak details =====\n\n", .{});

        for (heap.objects.items(.metadata)[skip_count..], skip_count..) |metadata, i| {
            if (metadata.in_use) {
                const handle = heap.getHandle(@intCast(i));
                if (handle.getString()) |val| {
                    ioutil.debug("Trace for {}, index {}, ref count {}, \"{s}\"\n", .{
                        handle.tag(),
                        i,
                        handle.refCount(),
                        val,
                    });
                } else |_| {
                    ioutil.debug("Trace for {}, index {}, ref count {}, <oom>\n", .{
                        handle.tag(),
                        i,
                        handle.refCount(),
                    });
                }

                const trace = heap.objects.get(i).trace;
                trace.dump();
                if (trace.index > 0) ioutil.debug("\n\n", .{});
            }
        }
    }

    ioutil.debug("Leak dump normal 3\n", .{});
}

// Dot rendering is 95% LLM generated.
fn escapeDotString(str: []const u8) !void {
    for (str) |c| switch (c) {
        '"', '\\' => ioutil.debug("\\{c}", .{c}),
        '\n' => ioutil.debug("\\n", .{}),
        '\r' => ioutil.debug("\\r", .{}),
        '\t' => ioutil.debug("\\t", .{}),
        0...8, 11...12, 14...31, 127 => ioutil.debug("\\x{X:0>2}", .{c}),
        else => ioutil.debug("{c}", .{c}),
    };
}

fn getTagColor(tag: Tag) []const u8 {
    return switch (tag) {
        .list => "lightblue",
        .dict => "lightgreen",
        .string => "lightyellow",
        .integer => "lightcoral",
        .float => "lightpink",
        .bool => "plum",
        .reference => "orange",
        .source => "peachpuff",
        .parsed_script_command => "khaki",
        .cached_local_var, .cached_lexical_var => "lightcyan",
        .custom_type => "tan",
        else => "white",
    };
}

fn renderDotNodeLabel(handle: Handle, index: u32, max_str_len: u32) !void {
    const str = handle.getString() catch "oom";
    const truncated_str = if (str.len > max_str_len) str[0..max_str_len] else str;

    ioutil.debug("idx: {} | ", .{index});
    ioutil.debug("{s} | ", .{@tagName(handle.tag())});
    ioutil.debug("rc: {} | ", .{handle.refCount()});
    ioutil.debug("\\\"", .{});
    try escapeDotString(truncated_str);
    if (str.len > max_str_len) ioutil.debug("...", .{});
    ioutil.debug("\\\"", .{});
}

fn renderCollectionSubgraph(heap: *Heap, handle: Handle, index: u32) !void {
    const obj = handle.peek();

    // Get the allocation size to include unallocated slots in the subgraph.
    const allocated_len = memutil.getOrderSize(handle.getMetadata().order) - 1;

    // Get the actual used length for the label.
    const used_len = switch (obj.head.tag) {
        .list => obj.body.list.len,
        .dict => obj.body.dict.len,
        else => unreachable,
    };

    const str = handle.getString() catch "oom";
    const max_str_len = 40;
    const truncated_str = if (str.len > max_str_len) str[0..max_str_len] else str;

    // Subgraph header.
    ioutil.debug("  subgraph cluster_{} {{\n", .{index});
    ioutil.debug("    label=\"{s} obj{} (rc:{}, {}/{} used): ", .{ @tagName(handle.tag()), index, handle.refCount(), used_len, allocated_len });
    try escapeDotString(truncated_str);
    if (str.len > max_str_len) ioutil.debug("...", .{});
    ioutil.debug("\";\n", .{});
    ioutil.debug("    style=outlined;\n", .{});
    ioutil.debug("    fillcolor=\"{s}\";\n", .{if (handle.tag() == .list) "lightblue1" else "lightgreen1"});
    ioutil.debug("    node [style=filled];\n\n", .{});

    // Collection head node.
    ioutil.debug("    obj{} [label=\"{{", .{index});
    ioutil.debug("HEAD | idx: {} | ", .{index});
    ioutil.debug("{s} | rc: {}}}\", fillcolor=\"{s}\"];\n", .{ @tagName(handle.tag()), handle.refCount(), getTagColor(handle.tag()) });

    // Collection items (all allocated slots, including unused ones).
    for (0..allocated_len) |offset| {
        const item_idx = index + 1 + offset;
        const item_handle = heap.getHandle(@intCast(item_idx));

        ioutil.debug("    obj{} [label=\"{{", .{item_idx});
        try renderDotNodeLabel(item_handle, @intCast(item_idx), max_str_len);
        ioutil.debug("}}\", fillcolor=\"{s}\"];\n", .{getTagColor(item_handle.tag())});
    }

    ioutil.debug("  }}\n\n", .{});
}

fn renderObjectEdges(heap: *Heap, handle: Handle, index: u32) !void {
    const obj = handle.peek();

    switch (handle.tag()) {
        .list => {
            const len_including_nones = memutil.getOrderSize(handle.getMetadata().order) - 1;
            for (0..len_including_nones) |item_idx| {
                const item_handle = objutil.listItemNoFollow(handle, @intCast(item_idx));
                ioutil.debug("  obj{} -> obj{} [label=\"[{}]\"];\n", .{ index, item_handle.index, item_idx });
            }
        },
        .dict => {
            var item_idx: u32 = 0;
            while (item_idx < obj.body.dict.len) : (item_idx += 2) {
                const key_handle = objutil.dictItem(handle, item_idx);
                const val_handle = objutil.dictItem(handle, item_idx + 1);

                ioutil.debug("  obj{} -> obj{} [label=\"key\", color=blue];\n", .{ index, key_handle.index });
                ioutil.debug("  obj{} -> obj{} [label=\"val\", color=green];\n", .{ index, val_handle.index });
            }
        },
        .reference => {
            const ref_handle = obj.body.reference;
            ioutil.debug("  obj{} -> obj{} [label=\"ref\", color=red];\n", .{ index, ref_handle.index });
        },
        .source => {
            if (objutil.getSourceInfo(handle).?.file_name.toHandle()) |file_name| {
                ioutil.debug("  obj{} -> obj{} [label=\"file\"];\n", .{ index, file_name.index });
            }
        },
        .cached_local_var => {
            ioutil.debug("  obj{} -> obj{} [label=\"var\", style=dashed];\n", .{ index, obj.body.cached_local_var.cached_index });
        },
        .cached_lexical_var => {
            const lexical_variable = heap.getExtraData(obj.body.cached_lexical_var.extra_data).lexical_variable;
            ioutil.debug("  obj{} -> obj{} [label=\"var\", style=dashed];\n", .{ index, lexical_variable.ref.index });
        },
        .dict_sugar => {
            ioutil.debug("  obj{} -> obj{} [label=\"var\"];\n", .{ index, obj.body.dict_sugar.dict_name_index });
            ioutil.debug("  obj{} -> obj{} [label=\"val\"];\n", .{ index, obj.body.dict_sugar.path_index });
        },
        .upvar_link => {
            const upvar_link = obj.body.upvar_link;
            ioutil.debug(
                "  obj{} -> obj{} [label=\"linked_name\"];\n",
                .{ index, upvar_link.linked_name },
            );
        },
        else => {},
    }
}

fn leakDumpDotGraph(heap: *Heap, skip_count: usize) !void {
    ioutil.debug("digraph LeakGraph {{\n", .{});
    ioutil.debug("  rankdir=LR;\n", .{});
    ioutil.debug("  node [shape=record];\n", .{});
    ioutil.debug("  compound=true;\n\n", .{});

    // First pass: output collections as subgraphs with their items grouped.
    for (heap.objects.items(.metadata)[skip_count..], skip_count..) |metadata, i| {
        if (!metadata.in_use) continue;

        const handle = heap.getHandle(@intCast(i));

        if (handle.tag() == .list or handle.tag() == .dict) {
            try renderCollectionSubgraph(heap, handle, @intCast(i));
        }
    }

    // Second pass: output standalone nodes (not part of any collection).
    for (heap.objects.items(.metadata)[skip_count..], skip_count..) |metadata, i| {
        if (!metadata.in_use) continue;

        const handle = heap.getHandle(@intCast(i));

        // Skip collections (already output as subgraphs) and collection items.
        if (handle.tag() == .list or handle.tag() == .dict) continue;
        if (!handle.isAllocHead()) continue;

        ioutil.debug("  obj{} [label=\"{{", .{i});
        try renderDotNodeLabel(handle, @intCast(i), 60);
        ioutil.debug("}}\", fillcolor=\"{s}\", style=filled];\n", .{getTagColor(handle.tag())});
    }

    ioutil.debug("\n", .{});

    // Third pass: output all edges.
    for (heap.objects.items(.metadata)[skip_count..], skip_count..) |metadata, i| {
        if (!metadata.in_use) continue;
        try renderObjectEdges(heap, heap.getHandle(@intCast(i)), @intCast(i));
    }

    ioutil.debug("}}\n", .{});
}

var already_panicking: std.atomic.Value(bool) = .init(false);
fn printLastTouchedTrace(terminal: std.Io.Terminal) !void {
    if (already_panicking.load(.seq_cst)) return;
    already_panicking.store(true, .seq_cst);

    const w = terminal.writer;
    if (!options.trace_mem) {
        try terminal.setColor(.yellow);
        try w.print("WARNING: no trace collected as it was disabled in options.\n\n", .{});
        return;
    }

    try terminal.setColor(.reset);
    if (last_touched) |val| {
        try w.writeAll("== Last touched details ==\n\n");

        const trace = val.getHeap().objects.get(val.index).trace;
        const end = @min(trace.index, trace.addrs.len);
        for (trace.addrs[0..end], 0..) |frames_array, i| {
            try w.print("{s}:\n", .{trace.notes[i]});
            var frames_array_mutable = frames_array;
            const frames = mem.sliceTo(frames_array_mutable[0..], 0);
            const len = @min(trace.index, frames.len);
            const stack_trace: std.debug.StackTrace = .{
                .return_addresses = frames[0..len],
                .skipped = if (len < frames.len) .none else .unknown,
            };
            std.debug.writeStackTrace(&stack_trace, terminal) catch return;
        }
        if (trace.index > end) {
            w.print("{d} more traces not shown; consider increasing trace size\n", .{
                trace.index - end,
            }) catch return;
        }
        try w.writeAll("== End of last touched details ==\n\n");
    } else {
        try w.writeAll("No last leaked object\n");
    }
}

pub export fn dumpLastTouchedTrace(fd: i32) void {
    if (fd >= 0) {
        const file: std.Io.File = .{ .handle = @intCast(fd), .flags = .{ .nonblocking = false } };
        var file_writer = file.writerStreaming(Heap.global_io, &.{});
        const terminal: std.Io.Terminal = .{ .writer = &file_writer.interface, .mode = .escape_codes };
        printLastTouchedTrace(terminal) catch {};
    } else {
        const stderr = ioutil.lockStderr();
        defer ioutil.unlockStderr();
        var buffer: [64]u8 = undefined;
        var writer = stderr.writer(Heap.global_io, &buffer);
        defer writer.flush() catch {};
        const terminal: std.Io.Terminal = .{ .writer = &writer.interface, .mode = .escape_codes };
        printLastTouchedTrace(terminal) catch {};
    }
}

const std = @import("std");
const builtin = @import("builtin");
const math = std.math;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const stringutil = @import("stringutil.zig");
const memutil = @import("memutil.zig");
const Parser = @import("Parser.zig");
const object = @import("object.zig");

// These numbers are final, and can be depended on to be their current values
pub const null_string = 0;
pub const empty_string = 1;

pub const special_object_count = 2;
pub const null_object_idx = 0;
pub const empty_object_idx = 1;

const global_heap_id = 0;
// --- //

pub const HeapSettings = struct {
    /// threading only works on 64-bit machines, because
    /// the object heads are atomically swapped.
    threading: bool = true,
    use_vmem: bool = true,
    /// Maximum of `1 << heap_order` items.
    object_heap_order: u6 = 24,
    /// Maximum of `1 << heap_order` bytes for all strings.
    string_heap_order: u6 = 28,
    /// Maximum number of custom types.
    max_custom_types: usize = 65536,
    /// Maximum number of evaluating scripts.
    max_scripts: usize = 65536,
    /// Maximum number of heaps (not necessarily initialized).
    max_heaps: usize = 128,
    /// Whether to enable memory tracing (for debugging only, as
    /// it leaks the strings it allocates)
    trace_mem: bool = true,
};
const cfg: HeapSettings = .{};

var debugging_gpa = if (builtin.mode == .Debug) std.heap.GeneralPurposeAllocator(.{}){} else undefined;
/// Use this for debugging objects (traces, etc) that can afford to leak.
var debug_gpa = if (builtin.mode == .Debug) debugging_gpa.allocator() else memutil.null_allocator;

pub const GlobalHeapState = struct {
    initialized: bool = false,
    /// Use to lock custom_types or script_metadata when adding or removing
    /// (no need to lock when using).
    mutex: Mutex = .{},
    /// Used for all global data structures (currently custom_types and script_metadata)
    gpa: std.mem.Allocator = memutil.null_allocator,
    next_open_heap: usize = 0,
    running_leak_check: bool = false,
};
pub var state: GlobalHeapState = .{};
pub var heaps: [cfg.max_heaps]Heap = undefined;
pub var custom_types: memutil.IndexedMemoryPool(CustomType, cfg.use_vmem) = undefined;
pub var script_metadata: memutil.IndexedMemoryPool(ScriptMetadata, cfg.use_vmem) = undefined;

const Heap = @This();

const object_heap_max_count: usize = @as(usize, 1) << cfg.object_heap_order;
const object_heap_max_bytes: usize = ObjectList.capacityInBytes(object_heap_max_count);
const string_heap_max_bytes: usize = @as(usize, 1) << cfg.string_heap_order;

gpa: Allocator,
heap_id: HeapId,

/// Used whenever an allocation or free is happening
mem_mgmt_mutex: Mutex = .{},

object_tracking: ObjectTracker,
objects: ObjectList,
string_tracking: StringTracker,
strings: StringList,

dicts: DictionaryPool,
upvars: UpvarPool,
type_instances: CustomTypeInstancePool,
parsed_scripts: ParsedScripts,

pub const HeapId = u16;
const Mutex = if (cfg.threading) std.Thread.Mutex else DummyMutex;

const ObjectTracker = memutil.BuddyUnmanaged(cfg.object_heap_order);
const ObjectList = std.MultiArrayList(ObjectAndMetadata);
const StringTracker = memutil.BuddyUnmanaged(cfg.string_heap_order);
const StringList = std.ArrayList(u8);

const DictionaryPool = memutil.IndexedMemoryPool(Dictionary, cfg.use_vmem);
const UpvarPool = memutil.IndexedMemoryPool(Upvar, cfg.use_vmem);
const CustomTypeInstancePool = memutil.IndexedMemoryPool(CustomTypeInstance, cfg.use_vmem);
const ScriptMetadataPool = memutil.IndexedMemoryPool(ScriptMetadata, cfg.use_vmem);
const ParsedScripts = std.AutoHashMapUnmanaged(u32, struct { script: ParsedScript, generation: u32 });

pub const DictIndex = u32;
pub const Dictionary = struct {
    /// This does not store the key/value pairs directly, instead it
    /// is an mapping of key to value index.
    dict: std.HashMapUnmanaged(Handle, u32, struct {
        pub fn hash(ctx: @This(), key: Handle) u64 {
            _ = ctx;

            const str = getString(key) catch return 0;
            return std.hash_map.hashString(str);
        }

        pub fn eql(ctx: @This(), a: Handle, b: Handle) bool {
            _ = ctx;

            return checkIfEqual(a, b) catch return false;
        }
    }, 80),
    /// Length of dictionaries' backing list, including potential duplicated
    /// keys when shimmering from list.
    len: u32,
};

pub const Upvar = struct {
    call_frame_idx: u32,
    call_frame_epoch: u31,
    /// Cached index of the target object.
    index: u32,
    dict_sugar: ?struct {
        /// _Non_-cached index of the dictionary name ("foo" of `foo(bar)`).
        dict_name_index: u32,
        /// _Non_-cached index of the key ("bar" of `foo(bar)`).
        dict_key_index: u32,
    },
};

pub const CustomTypeInstance = struct {
    first_ptr: *anyopaque,
    second_ptr: *anyopaque,
};

/// Each script is assigned a unique id when created. Each interpreter
/// has a hashmap that associates a script id with its local parsed
/// representation. This way, when a script is sent between threads,
/// the script doesn't need to be parsed twice. The script parsing
/// is not guaranteed to be idempotent.
pub const ScriptId = packed struct(u64) {
    index: u32,
    generation: u32,

    pub fn next() !ScriptId {
        state.mutex.lock();
        defer state.mutex.unlock();

        const index = try script_metadata.create(state.gpa);
        const generation = @atomicLoad(u32, &script_metadata.items[index].generation, .monotonic);
        @atomicStore(u32, &script_metadata.items[index].ref_count, 1, .monotonic);

        return .{
            .index = @intCast(index),
            .generation = generation,
        };
    }

    pub fn retire(id: ScriptId) void {
        state.mutex.lock();
        defer state.mutex.unlock();

        script_metadata.destroy(id.index);
        // Increment generation.
        _ = @atomicRmw(u32, &script_metadata.items[id.index].generation, .Add, 1, .monotonic);
    }
};

/// This can get a little confusing, as objects are ref counted, but their
/// script metadata is also ref counted. The reason is so that a parsed script
/// isn't freed, even if the script object gets freed, until _all_ script objects
/// for a certain ID are freed.
pub const ScriptMetadata = packed struct(ScriptMetadata.get_full_size()) {
    // This must be backed by a packed u64 (32-bit) or u96 (64-bit),
    // and ref_count must be the first field, as ScriptMetadata is stored
    // in an IndexedMemoryPool, which uses the first usize bits of
    // ScriptMetadata to store a next pointer.

    inline fn get_needed_padding() type {
        const needed_padding = @as(u16, @bitSizeOf(usize)) -| 32;
        return @Type(.{
            .int = .{
                .bits = needed_padding,
                .signedness = .unsigned,
            },
        });
    }

    inline fn get_full_size() type {
        return @Type(.{
            .int = .{
                .bits = @bitSizeOf(usize) + 32,
                .signedness = .unsigned,
            },
        });
    }

    ref_count: u32,
    _padding: get_needed_padding() = 0,
    generation: u32,
};

/// This is the script object internal representation. It is an array
/// of Parser.Tokens alongside a heap-stored list for all tokens' values.
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
/// The scriptObj structure is used to represent both "script" objects
/// and "subst" objects. In the second case, there are no LIN and WRD
/// tokens. Instead SEP and EOL tokens are added as-is.
/// In addition, the field 'substFlags' is used to represent the flags used to turn
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
    /// A handle pointing to a tcl list that has the same length as `tokens`,
    /// that stores the state of the evaluated script. Note, this is not
    /// the same as the stack.
    values: Handle,
    /// Tokens array.
    tags: std.ArrayList(Parser.Token.Tag),
    /// File name.
    file_name_obj: ?Handle,
    /// Line number of the first line.
    first_line: u32,

    pub fn printTokens(script: *const ParsedScript) void {
        const formatting = "[{: >3}@{: >3}]  .{s: <20}  ";

        var line: u64 = 0;
        for (script.tags.items, object.listItemsRaw(script.values), 0..) |token, value, i| {
            switch (token) {
                .start_of_command => {
                    line = value.body.script_command.line;
                    std.debug.print(formatting ++ "{}\n", .{ i, line, @tagName(token), value.body.script_command });
                },
                .start_of_word => std.debug.print(formatting ++ "{}\n", .{ i, line, @tagName(token), value.body.integer }),
                else => {
                    const item = object.listItemRaw(script.values, @intCast(i));
                    std.debug.print(formatting ++ "{s}\n", .{ i, line, @tagName(token), getString(item) catch "<oom string>" });
                },
            }
        }
    }

    pub fn deinit(parsed: *ParsedScript, script_heap: *Heap) void {
        if (parsed.file_name_obj) |file_name| file_name.release();
        parsed.tags.deinit(script_heap.gpa);
        parsed.values.release();
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
            ptr: u58,
        },
        is_ptr: bool,
    };

    str: StrOrPtr,
    tag: Tag,
    body: Body,
};

pub const Tag = enum(u5) {
    none,
    index,
    integer,
    float,
    bool,
    string,
    source,
    list,
    dict,
    dict_subst,
    script_command,
    script,
    reference,
    variable,
    upvar,
    custom_type,
    marked,
};

pub const IndexError = error{BadIndex};
/// Tcl list index. Indexes are inclusive both for start and end in tcl. Additionally,
/// an index may be relative, such as "end" or "end-1".
pub const ListIndex = packed struct {
    u: packed union {
        index: u32,
        end_offset: i33,
    },
    /// Whether this is a relative index, such as "end", "end-1", "end+5", etc
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

pub const Body = packed union {
    none: void,
    /// List index
    index: ListIndex,
    integer: i64,
    float: f64,
    bool: bool,
    string: packed struct {
        /// If = utf8_length > maxInt(u32), it means the length has not been determined
        utf8_length: u33,
    },
    source: packed struct {
        /// Pointer to an object in the same heap that contains the file name.
        file_name_obj: u32,
        line_no: u32,
    },
    list: packed struct {
        len: u32,
    },
    /// Items of the dictionary are stored directly after, similar to a list.
    /// Keys and values alternate. Allows for duplicate keys when shimmering
    /// from a list, but duplicates will be removed when any writing operation
    /// happens.
    dict: DictIndex,
    /// Both objects must be in the same heap.
    dict_subst: packed struct {
        var_name_index: u32,
        dict_value_index: u32,
    },
    /// Information about a command.
    script_command: packed struct {
        line: u32,
        arg_count: u32,
    },
    script: packed struct {
        id: ScriptId,
    },
    reference: Handle,
    variable: packed struct {
        index: u32,
        /// Used to invalidate `index`'s cached value, if it doesn't match
        /// the current evaluator's epoch.
        call_epoch: u31,
        /// Whether the variable is global, e.g. prefixed with ::
        is_global: bool,
    },
    /// Index into Heap.upvars.
    upvar: u32,
    custom_type: packed struct {
        type_id: u32,
        index: u32,
    },
    /// Used internally in places where a value needs to be temporarily marked.
    marked: void,
};

comptime {
    assert(@sizeOf(Body) == 8);

    // Make sure Tag and Body have the same fields
    const tag_fields = @typeInfo(Tag).@"enum".fields;
    const body_fields = @typeInfo(Body).@"union".fields;

    assert(tag_fields.len == body_fields.len);
    for (tag_fields, body_fields) |tag_field, body_field| {
        assert(std.mem.eql(u8, tag_field.name, body_field.name));
    }
}

pub const CustomType = struct {
    /// Type name.
    name: []u8,
    /// Must be threadsafe.
    invalidate_body: *const fn (heap: *Heap, obj: *Object) void,
    duplicate: *const fn (heap: *Heap, src: *const Object, dest: *Object) Allocator.Error!void,
    get_string: *const fn (heap: *Heap, obj: *const Object) Allocator.Error![:0]u8,
    make_immutable: *const fn (heap: *Heap, obj: *Object) Allocator.Error!void,
};

pub const Handle = packed struct(u64) {
    index: u32,
    heap: HeapId,
    /// Whether this object can be ref counted (else it needs to be cloned)
    ref_counted: bool,
    _padding: u15 = 0,

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

    pub fn getHeap(handle: Handle) *Heap {
        return &heaps[handle.heap];
    }

    pub fn canShimmer(handle: Handle) bool {
        // Can't shimmer if it's shared between threads
        return !handle.getHeap().objects.get(handle.index).metadata.cross_thread;
    }

    pub fn isShared(handle: Handle) bool {
        const objects = handle.getHeap().objects;

        const cross_thread = objects.items(.metadata)[handle.index].cross_thread;
        const multiple_owners = objects.items(.ref_count)[handle.index] > 1;
        const is_owned = !handle.ref_counted;
        return cross_thread or multiple_owners or is_owned;
    }

    pub fn hasString(handle: Handle) bool {
        return handle.peek().str != Object.null_string;
    }

    /// This should not be used for checking if an object is shared, use `isShared` instead.
    pub fn debugRefCount(handle: Handle) u32 {
        return handle.getHeap().objects.items(.ref_count)[handle.index];
    }

    pub fn incrRefCount(handle: Handle) void {
        assert(handle.ref_counted);
        incrRefCountOf(u32, &handle.getHeap().objects.items(.ref_count)[handle.index]);
    }

    pub fn reference(handle: Handle) Object {
        handle.incrRefCount();

        return .{
            // References are guaranteed to always have a null representation.
            .str = Object.null_string,
            .tag = .reference,
            .body = .{
                .reference = handle,
            },
        };
    }

    pub const invalidateString = invalidateStringImpl;
    pub const invalidateBody = invalidateBodyImpl;

    pub fn release(handle: Handle) void {
        releaseImpl(handle);
    }
};

const ObjectAndMetadata = struct {
    object: Object,
    ref_count: u32,
    metadata: packed struct {
        /// Order can be u5 instead of u6, because the heap size must be < 2^32
        order: u5,
        /// Whether this object is the front of the allocation
        /// (if not, this index will not be freed, as it's
        /// managed by another object)
        is_alloc_head: bool,
        /// Whether this object is shared across threads
        cross_thread: bool,
        /// Whether this object is currently being used (used to track double frees)
        in_use: bool,
    },
    trace: std.debug.ConfigurableTrace(8, 8, cfg.trace_mem),
};

fn heapAlloc(self: *Heap) Allocator {
    if (cfg.use_vmem or cfg.threading) {
        return memutil.null_allocator;
    } else {
        return self.gpa;
    }
}

pub fn init(gpa: Allocator, heap_id: HeapId) !Heap {
    // Init objects
    var object_tracking = try ObjectTracker.init(gpa, cfg.object_heap_order);
    errdefer object_tracking.deinit(gpa);

    var objects: ObjectList = .{};
    if (cfg.use_vmem) {
        objects.bytes = (try memutil.vmemMap(object_heap_max_bytes)).ptr;
        objects.capacity = object_heap_max_count;
    } else if (cfg.threading) {
        // if multithreading, we can't have objects moving around. We better allocate
        // everything up front.
        try objects.ensureTotalCapacity(gpa, object_heap_max_count);
    } else {
        try objects.ensureTotalCapacity(gpa, 32);
    }
    errdefer {
        if (cfg.use_vmem) {
            memutil.vmemUnmap(@alignCast(objects.bytes[0..object_heap_max_bytes]));
        } else {
            objects.deinit(gpa);
        }
    }

    // Init strings
    var string_tracking = try StringTracker.init(gpa, cfg.string_heap_order);
    errdefer string_tracking.deinit(gpa);

    var strings: StringList = .{};
    if (cfg.use_vmem) {
        strings.items = try memutil.vmemMap(string_heap_max_bytes);
    } else if (cfg.threading) {
        // if multithreading, we can't have strings moving around. We better allocate
        // everything up front.
        try strings.ensureTotalCapacity(gpa, string_heap_max_bytes);
    } else {
        try strings.ensureTotalCapacity(gpa, 32);
    }
    errdefer if (cfg.use_vmem) memutil.vmemUnmap(@alignCast(strings.items)) else strings.deinit(gpa);

    const object_capacity = if (cfg.threading) object_heap_max_count else 32;

    var dictionaries: DictionaryPool = try .initWithCapacity(gpa, object_capacity);
    errdefer dictionaries.deinit(gpa);

    var upvars: UpvarPool = try .initWithCapacity(gpa, object_capacity);
    errdefer upvars.deinit(gpa);

    // Init type instances
    var type_instances: CustomTypeInstancePool = try .initWithCapacity(gpa, object_capacity);
    errdefer type_instances.deinit(gpa);

    var parsed_scripts: ParsedScripts = .empty;
    errdefer parsed_scripts.deinit(gpa);

    // Create heap
    var heap = Heap{
        .gpa = gpa,
        .heap_id = heap_id,

        .object_tracking = object_tracking,
        .objects = objects,
        .string_tracking = string_tracking,
        .strings = strings,

        .dicts = dictionaries,
        .upvars = upvars,
        .type_instances = type_instances,
        .parsed_scripts = parsed_scripts,
    };

    // null string is guaranteed to have index 0
    const null_string_idx = try heap.string_tracking.alloc(gpa, 0);
    assert(null_string_idx == null_string);
    // empty string is guaranteed to have index 1
    const empty_string_idx = try heap.string_tracking.alloc(gpa, 0);
    assert(empty_string_idx == empty_string);

    // Specialty objects
    // null object is guaranteed to have index 0.
    const null_object = try heap.createObject();
    assert(null_object.index == 0);
    // Empty object is guaranteed to have index 1.
    const empty_object = try heap.createObject();
    assert(empty_object.index == 1);

    return heap;
}

fn clearParsedScripts(self: *Heap) void {
    var parsed_script_iter = self.parsed_scripts.valueIterator();
    while (parsed_script_iter.next()) |parsed_script| {
        parsed_script.script.deinit(self);
    }

    self.parsed_scripts.clearRetainingCapacity();
}

pub fn deinit(self: *Heap) void {
    // Parsed scripts have references to objects, so we'll deinit scripts before objects.
    self.clearParsedScripts();
    self.parsed_scripts.deinit(self.gpa);

    for (special_object_count..self.objects.len) |i| {
        const metadata = self.objects.get(i).metadata;
        if (metadata.in_use) {
            // We don't use free object here, as it may cause a double-free when
            // freeing recursive structures. For example, if there was a list with
            // two items, we'll free the list (first free of items), then free
            // the items individually (second free)
            const handle = self.getHandle(@intCast(i), false);
            handle.invalidateBody();
            handle.invalidateString();
        }
    }

    if (cfg.use_vmem) {
        memutil.vmemUnmap(@alignCast(self.strings.items));
        memutil.vmemUnmap(@alignCast(self.objects.bytes[0..object_heap_max_bytes]));
    } else {
        // Don't use self.heapAlloc() in this case, as that will error
        // with the null allocator
        self.strings.deinit(self.gpa);
        self.objects.deinit(self.gpa);
    }
    self.object_tracking.deinit(self.gpa);
    self.string_tracking.deinit(self.gpa);

    self.dicts.deinit(self.gpa);
    self.upvars.deinit(self.gpa);
    self.type_instances.deinit(self.gpa);
}

pub fn nullObject(self: *Heap) Handle {
    return .{
        .index = 0,
        .heap = self.heap_id,
        .ref_counted = false,
    };
}

pub fn emptyObject(self: *Heap) Handle {
    return .{
        .index = 1,
        .heap = self.heap_id,
        .ref_counted = false,
    };
}

pub fn createObject(self: *Heap) !Handle {
    const index = try self.createObjects(1);
    return .{
        .index = index,
        .heap = self.heap_id,
        .ref_counted = true,
    };
}

/// create_objects does not initialize objects, but does initialize
/// reference counts.
pub fn createObjects(self: *Heap, count: u32) !u32 {
    const order: u5 = @intCast(memutil.getOrder(count));
    const aligned_count = memutil.getOrderSize(order);

    const index: u32 = blk: {
        self.mem_mgmt_mutex.lock();
        defer self.mem_mgmt_mutex.unlock();
        break :blk @intCast(try self.object_tracking.alloc(self.gpa, order));
    };

    const end = index + aligned_count;

    // Make object list has space for new objects
    if (self.objects.len < index + aligned_count) {
        const start_of_new = self.objects.len;
        try self.objects.resize(self.heapAlloc(), index + aligned_count);
        @memset(self.objects.items(.metadata)[start_of_new..self.objects.len], .{
            .order = 31,
            .is_alloc_head = false,
            .cross_thread = false,
            .in_use = false,
        });
    }

    if (cfg.trace_mem) {
        self.objects.items(.trace)[index].addAddr(
            @returnAddress(),
            try std.fmt.allocPrint(
                debug_gpa,
                "Alloc {} of order {}",
                .{ index, order },
            ),
        );
    }

    // Make sure the items we're allocating are free (used to
    // ensure our allocator hasn't reached a broken state).
    for (self.objects.items(.metadata)[index..end]) |metadata| assert(metadata.in_use == false);

    // Initialize all as empty objects
    @memset(self.objects.items(.object)[index..end], .{
        .str = Object.null_string,
        .tag = .none,
        .body = .{
            .integer = 0,
        },
    });

    // Initialize ref counts
    @memset(self.objects.items(.ref_count)[index..end], 1);

    // Initialize metadata
    self.objects.items(.metadata)[index] = .{
        .order = order,
        .is_alloc_head = true,
        .cross_thread = false,
        .in_use = true,
    };

    if (aligned_count > 1) @memset(
        self.objects.items(.metadata)[(index + 1)..end],
        .{
            .order = order,
            .is_alloc_head = false,
            .cross_thread = false,
            .in_use = true,
        },
    );

    return index;
}

/// Does not run any destructors, frees the object directly.
pub fn freeObjectBacking(handle: Handle) void {
    const obj_heap = handle.getHeap();
    const metadata = obj_heap.objects.items(.metadata)[handle.index];
    assert(metadata.is_alloc_head);

    obj_heap.mem_mgmt_mutex.lock();
    if (cfg.trace_mem) {
        const trace = &obj_heap.objects.items(.trace)[handle.index];
        trace.addAddr(@returnAddress(), std.fmt.allocPrint(
            debug_gpa,
            "Free {} of order {}",
            .{ handle.index, metadata.order },
        ) catch "OOM");

        if (!metadata.in_use) {
            trace.dump();
            @panic("Double free!");
        }
    }

    obj_heap.object_tracking.free(handle.index, metadata.order);

    // Mark as free in metadata.
    const alloc_size = memutil.getOrderSize(metadata.order);
    @memset(obj_heap.objects.items(.metadata)[handle.index..][0..alloc_size], .{
        .order = 31,
        .is_alloc_head = false,
        .cross_thread = false,
        .in_use = false,
    });

    obj_heap.mem_mgmt_mutex.unlock();
}

pub fn freeObject(handle: Handle) void {
    const obj_heap = handle.getHeap();

    handle.invalidateBody();
    handle.invalidateString();

    const metadata = obj_heap.objects.items(.metadata)[handle.index];
    if (metadata.is_alloc_head) {
        if (!metadata.in_use) @panic("Double free!");

        freeObjectBacking(handle);
    }
}

/// If the object can't be modified, this will duplicate and release
/// the old object.
pub fn ensureModifiable(calling_heap: *Heap, handle: *Handle) !void {
    if (handle.isShared()) {
        const before_duplicating = handle.*;
        handle.* = try calling_heap.duplicate(handle.*);
        before_duplicating.release();
    }
}

/// If the object can't be shimmered, this will duplicate and release
/// the old object.
pub fn ensureShimmerable(calling_heap: *Heap, handle: *Handle) !void {
    if (!handle.canShimmer()) {
        const before_duplicating = handle.*;
        handle.* = try calling_heap.duplicate(handle.*);
        before_duplicating.release();
    }
}

fn invalidateStringImpl(handle: Handle) void {
    assert(handle.canShimmer());

    const obj = handle.peek();
    const obj_heap = handle.getHeap();

    switch (obj_heap.getLocalStringDetails(handle.index)) {
        .long => |long_str| {
            long_str.decrRefCount(obj_heap.gpa);
        },
        .normal => {
            obj_heap.freeString(obj.str.u.str.index, obj.str.u.str.len);
        },
        .null, .empty => {},
    }

    // Be sure to mark as having no string
    obj.str.is_ptr = false;
    obj.str.u.str = .{
        .index = 0,
        .len = 0,
    };
}

fn invalidateBodyImpl(handle: Handle) void {
    assert(handle.canShimmer());

    const obj_heap = handle.getHeap();
    const obj: *Object = &obj_heap.objects.items(.object)[handle.index];

    switch (obj.tag) {
        .list => {
            const list = obj.body.list;

            // Don't free the head (e.g. self)
            for (1..(list.len + 1)) |i| {
                freeObject(.{
                    .index = @intCast(handle.index + i),
                    .heap = handle.heap,
                    .ref_counted = false,
                });
            }
        },
        .dict => {
            const dict_metadata = obj_heap.getDictMetadata(obj.body.dict);

            // Don't free the head (e.g. self)
            for (1..(dict_metadata.len + 1)) |i| {
                freeObject(.{
                    .index = @intCast(handle.index + i),
                    .heap = handle.heap,
                    .ref_counted = false,
                });
            }

            dict_metadata.dict.deinit(obj_heap.gpa);
            obj_heap.destroyDictMetadata(obj.body.dict);
        },
        .custom_type => {
            const custom_type = obj.body.custom_type;
            const type_fns = custom_types.items[custom_type.type_id];

            type_fns.invalidate_body(obj_heap, obj);
        },
        .reference => {
            obj.body.reference.release();
        },
        .string => {
            // How come string is a no-op? Because the string is separate
            // from its cached length.
        },
        .script => {
            const script = obj.body.script; // copy
            if (decrRefCountOf(u32, &script_metadata.items[script.id.index].ref_count)) {
                script.id.retire();
            }
        },
        .source => {
            const source = obj.body.source;
            if (source.file_name_obj != 0) {
                obj_heap.normalHandle(source.file_name_obj).release();
            }
        },
        .none, .index, .integer, .dict_subst, .variable, .float, .bool, .script_command, .marked => {},
    }

    obj.body = undefined;
    obj.tag = .none;
}

/// Get a string slice from heap string storage
pub fn getHeapString(self: *Heap, start: u32, end: u32) [:0]u8 {
    return self.strings.items[start..end :0];
}

/// Get a null-terminated string from heap string storage starting at index
pub fn getHeapStringZ(self: *Heap, index: u32) [:0]u8 {
    const ptr: [*:0]u8 = @ptrCast(&self.strings.items[index]);
    return std.mem.span(ptr);
}

/// Allocates 1 + length, in order to make space for the null byte
pub fn createString(self: *Heap, len: u32) !u32 {
    const length_with_null = len + 1;

    self.mem_mgmt_mutex.lock();
    defer self.mem_mgmt_mutex.unlock();

    const new_string: u32 = @intCast(try self.string_tracking.allocCount(self.gpa, length_with_null));
    self.strings.items[new_string + len] = 0;
    return new_string;
}

pub fn freeString(self: *Heap, index: u32, len: u32) void {
    const length_with_null = len + 1;
    self.mem_mgmt_mutex.lock();
    self.string_tracking.freeCount(index, length_with_null);
    self.mem_mgmt_mutex.unlock();
}

pub fn checkIfEqual(a: Handle, b: Handle) !bool {
    if (a == b) return true;

    // Make sure they have a string rep before checking the details
    const a_str = try getString(a);
    const b_str = try getString(b);
    const a_details = getStringDetails(a);
    const b_details = getStringDetails(b);

    blk: {
        const a_long_str = switch (a_details) {
            .long => |unwrapped| unwrapped,
            // We generated string reps when calling getString, so
            // we know it's not null.
            .null => unreachable,
            else => break :blk,
        };

        const b_long_str = switch (b_details) {
            .long => |unwrapped| unwrapped,
            .null => unreachable,
            else => break :blk,
        };

        // If both strings are long strings, we can just
        // compare their hashes instead of the whole string.
        return a_long_str.getHash() == b_long_str.getHash();
    }

    return std.mem.eql(u8, a_str, b_str);
}

/// Increase ref count if possible, otherwise duplicate onto calling_heap.
pub fn borrow(calling_heap: *Heap, handle: Handle) !Handle {
    // If the object isn't ref counted, then we'll need to clone it (i.e. a list item)
    if (!handle.ref_counted) {
        return try calling_heap.duplicate(handle);
    }

    // This object may have come from another heap
    const obj_heap = handle.getHeap();

    incrRefCountOf(u32, &obj_heap.objects.items(.ref_count)[handle.index]);

    return handle;
}

fn releaseImpl(handle: Handle) void {
    if (!handle.ref_counted) return;

    const obj_heap = handle.getHeap();
    if (decrRefCountOf(u32, &obj_heap.objects.items(.ref_count)[handle.index])) {
        freeObject(handle);
    }
}

fn duplicateObjString(calling_heap: *Heap, handle: Handle) !Object.StrOrPtr {
    switch (getStringDetails(handle)) {
        .long => |long_str| {
            long_str.incrRefCount();
            return .{
                .u = .{ .ptr = LongString.toInt(long_str) },
                .is_ptr = true,
            };
        },
        .normal => |bytes| {
            const new_string = try calling_heap.createString(@intCast(bytes.len));
            const len: u26 = @intCast(bytes.len);
            @memcpy(calling_heap.getHeapString(new_string, new_string + len), bytes);

            return .{
                .u = .{ .str = .{ .index = new_string, .len = len } },
                .is_ptr = false,
            };
        },
        .null, .empty => {
            return handle.peek().str;
        },
    }
}

/// Duplicates the object if it's a single item, otherwise create a reference to it.
pub fn duplicateOrReference(self: *Heap, handle: Handle) !Object {
    return Heap.duplicateSingle(self, handle) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MultiItemObject => {
            // This item can't be duplicated, as it contains multiple objects.
            // We'll create a reference to it instead.
            return handle.reference();
        },
    };
}

/// If called with a multi-item object, will return error.MultiItemObject
pub fn duplicateSingle(self: *Heap, handle: Handle) error{ OutOfMemory, MultiItemObject }!Object {
    const src = handle.peek();
    switch (src.tag) {
        .none, .index, .integer, .float, .string, .bool, .script, .script_command, .marked => {
            return .{
                .str = try self.duplicateObjString(handle),
                .tag = src.tag,
                .body = src.body,
            };
        },
        .source => {
            const source = src.body.source;

            const new_handle = blk: {
                if (source.file_name_obj == 0) {
                    break :blk self.nullObject();
                } else {
                    // Better make sure it's in our heap.
                    if (handle.heap != self.heap_id) {
                        break :blk try self.duplicate(self.normalHandle(source.file_name_obj));
                    } else {
                        const to_break = self.normalHandle(source.file_name_obj);
                        to_break.incrRefCount();
                        break :blk to_break;
                    }
                }
            };

            return .{
                .str = try self.duplicateObjString(handle),
                .tag = .source,
                .body = .{
                    .source = .{
                        .file_name_obj = new_handle.index,
                        .line_no = source.line_no,
                    },
                },
            };
        },
        .reference => {
            return src.body.reference.reference();
        },
        .custom_type => {
            const custom_type = src.body.custom_type;

            var new_object: Object = .{
                // TODO make sure this doesn't leak
                .str = try self.duplicateObjString(handle),
                .tag = .custom_type,
                .body = .{
                    .custom_type = .{
                        .index = try self.createCustomTypeInstance(),
                        .type_id = custom_type.type_id,
                    },
                },
            };
            try custom_types.items[custom_type.type_id].duplicate(self, src, &new_object);

            return new_object;
        },
        .dict_subst, .variable => {
            // Variable lookup is not stable between threads.
            return .{
                .str = try self.duplicateObjString(handle),
                .tag = .none,
                .body = undefined,
            };
        },
        .list, .dict => {
            return error.MultiItemObject;
        },
    }
}

pub fn duplicate(calling_heap: *Heap, handle: Handle) error{OutOfMemory}!Handle {
    const src = handle.peek();

    switch (src.tag) {
        .list => {
            const old_body = src.body.list;
            const old_start = handle.index + 1;

            const new_list_idx = try calling_heap.createObjects(1 + old_body.len);
            errdefer {
                // Free elements before freeing the head, as the head could
                // be swapped out if freed too early
                for (0..old_body.len) |i| {
                    freeObject(.{
                        .index = @intCast(new_list_idx + 1 + i),
                        .heap = handle.heap,
                        .ref_counted = false,
                    });
                }
                freeObject(.{ .index = new_list_idx, .heap = handle.heap, .ref_counted = true });
            }
            const new_head: *Object = &calling_heap.objects.items(.object)[new_list_idx];
            const new_start = new_list_idx + 1;
            const new_items = calling_heap.objects.items(.object)[new_start..][0..old_body.len];

            // Duplicate head of list
            new_head.* = .{
                .str = try calling_heap.duplicateObjString(handle),
                .tag = .list,
                .body = .{
                    .list = .{ .len = old_body.len },
                },
            };

            // Duplicate items of list
            for (new_items, 0..) |*new_item, i| {
                new_item.* = calling_heap.duplicateSingle(.{
                    .heap = handle.heap,
                    .index = @intCast(old_start + i),
                    .ref_counted = false,
                }) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    // Lists can't contain multi item objects
                    error.MultiItemObject => unreachable,
                };
            }

            return calling_heap.normalHandle(new_list_idx);
        },
        .dict => {
            const old_head = calling_heap.getDictMetadata(src.body.dict);
            const old_start = handle.index + 1;

            const new_dict_idx = try calling_heap.createObjects(1 + old_head.len);
            errdefer {
                // Free elements before freeing the head, as the head could
                // be realloced before finishing if freed too early
                for (0..old_head.len) |i| {
                    freeObject(.{
                        .index = @intCast(new_dict_idx + 1 + i),
                        .heap = handle.heap,
                        .ref_counted = false,
                    });
                }
                freeObject(.{ .index = new_dict_idx, .heap = handle.heap, .ref_counted = true });
            }
            const new_head: *Object = &calling_heap.objects.items(.object)[new_dict_idx];
            const new_start = new_dict_idx + 1;
            const new_items = calling_heap.objects.items(.object)[new_start..][0..old_head.len];

            // Duplicate head of dict
            new_head.* = .{
                .str = try calling_heap.duplicateObjString(handle),
                .tag = .dict,
                .body = .{
                    .dict = try calling_heap.createDictMetadata(),
                },
            };
            errdefer calling_heap.dicts.destroy(new_head.body.dict);

            // Duplicate items of dict
            for (new_items, 0..) |*new_item, i| {
                new_item.* = calling_heap.duplicateSingle(.{
                    .heap = handle.heap,
                    .index = @intCast(old_start + i),
                    .ref_counted = false,
                }) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    // Dicts can't contain multi item objects
                    error.MultiItemObject => unreachable,
                };
            }

            const dict = calling_heap.getDictMetadata(new_head.body.dict);
            dict.len = old_head.len;
            try object.dictReindex(calling_heap.normalHandle(new_dict_idx));

            return calling_heap.normalHandle(new_dict_idx);
        },
        else => {
            const new_object = try calling_heap.createObject();
            calling_heap.objects.items(.object)[new_object.index] = calling_heap.duplicateSingle(handle) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                // We already checked if it was a multi-item object (i.e. a list)
                error.MultiItemObject => unreachable,
            };
            return new_object;
        },
    }
}

pub fn normalHandle(self: *Heap, index: u32) Handle {
    return self.getHandle(index, true);
}

pub fn getHandle(self: *Heap, index: u32, ref_counted: bool) Handle {
    assert(index != 0); // Null objects should never exist in a handle.

    return .{
        .heap = self.heap_id,
        .index = index,
        .ref_counted = ref_counted,
    };
}

pub fn getLocalObject(self: *Heap, index: u32) *Object {
    return &self.objects.items(.object)[index];
}

/// Guaranteed to be valid, barring OOM.
pub fn getString(handle: Handle) Allocator.Error![:0]const u8 {
    return try handle.getHeap().getLocalString(handle.index);
}

/// Copies provided string.
pub fn setString(handle: Handle, bytes: []const u8) Allocator.Error!void {
    const heap = handle.getHeap();

    // Try setting as a normal string first
    const did_set = try heap.setNormalString(handle.index, bytes);
    if (!did_set) {
        // Setting it as a long string will most likely take ownership,
        // so we need to copy.
        const new_str = try heap.gpa.dupeZ(u8, bytes);
        errdefer heap.gpa.free(new_str);
        const took_ownership = try heap.setLongString(handle.index, new_str, .normal);
        if (!took_ownership) heap.gpa.free(new_str);
    }
}

/// Get the string to modify (must not write any longer than current len).
/// Not threadsafe.
pub fn getStringMut(handle: Handle) ![:0]u8 {
    const heap = handle.getHeap();
    try heap.getLocalString(handle.index); // generate rep

    const obj = heap.getLocalObject(handle.index);
    switch (heap.getLocalStringDetails(handle.index)) {
        .long => |long_str| {
            return &long_str.string;
        },
        .normal => {
            const str = obj.str.u.str;
            return heap.getHeapString(str.index, str.index + str.len);
        },
        .null, .empty => return error.NotMutable,
    }
}

/// Low-level function, to exchange one value of an object's string to another.
/// Returns whether the exchange was successful (if not, caller is responsible
/// for cleaning up).
pub fn exchangeString(self: *Heap, index: u32, expected: Object.StrOrPtr, to_set_to: Object.StrOrPtr) bool {
    const obj: *Object = self.getLocalObject(index);
    if (cfg.threading and self.objects.get(index).metadata.cross_thread) {
        // Atomically swap only the first half of the object
        if (@sizeOf(Object) - @sizeOf(Body) != 8) @compileError("Object head must be exactly 8 bytes");
        if (@bitSizeOf(Object.StrOrPtr) != 59) @compileError("StrOrPtr must be exactly 59 bits wide");
        if (@bitOffsetOf(Object.StrOrPtr, "is_ptr") != 58) @compileError("Object.StrOrPtr.is_ptr must be in bit position 58");

        const str_mask: u64 = (1 << 59) - 1;

        const object_head: *u64 = @ptrCast(obj);
        var current_head = @atomicLoad(u64, object_head, .acquire);

        while (true) {
            // Is the string pointer what we expected?
            if (current_head & str_mask != @as(u59, @bitCast(expected))) {
                // If not, somebody else must've won this, so let the caller know
                return false;
            }

            const to_set_to_bits: u59 = @bitCast(to_set_to);
            // Preserve type tag from current_head
            var new_head = current_head & ~str_mask;
            new_head |= to_set_to_bits;

            const res: ?u64 = @cmpxchgWeak(u64, object_head, current_head, new_head, .release, .acquire);

            if (res) |winning_head| {
                current_head = winning_head;
                continue;
            } else {
                // Successfully swapped
                return true;
            }
        }
    } else {
        obj.str = to_set_to;
        return true;
    }
}

/// Returns whether the heap took ownership. It may copy the bytes into
/// the heap, so it can succeed while also not taking ownership.
pub fn setStringOwning(handle: Handle, bytes: [:0]u8, details: ?LongString.Details) !bool {
    const heap = handle.getHeap();

    if (details) |unwrapped| {
        // Details provided, so we must wrap it in a long string
        return try heap.setLongString(handle.index, bytes, unwrapped);
    } else if (try heap.setNormalString(handle.index, bytes)) {
        // Successfully set as normal string.
        return false;
    } else {
        return try heap.setLongString(handle.index, bytes, .normal);
    }
}

/// Low-level function. You probably want Heap.setString().
/// Attempts to copy the provided string into the object heap.
/// Returns false if the string is too big.
pub fn setNormalString(self: *Heap, index: u32, bytes: []const u8) !bool {
    if (bytes.len == 0) {
        // No need to check the result of the exchange, as there's nothing to clean up
        _ = self.exchangeString(index, Object.null_string, Object.empty_string);
        return true;
    } else if (bytes.len < LongString.split_point) {
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
    } else {
        return false;
    }
}

/// Low-level function. You probably want Heap.setString().
/// Returns whether the object heap took ownership of the string.
/// The only case where this would fail is OOM or if someone else
/// exchanged the string right before us.
pub fn setLongString(self: *Heap, index: u32, bytes: [:0]u8, details: LongString.Details) Allocator.Error!bool {
    assert(bytes.len > 0);

    const long_string = &(try self.gpa.alignedAlloc(LongString, LongString.align_type, 1))[0];
    errdefer self.gpa.free(long_string);
    long_string.* = .{
        .string = bytes,
        .details = details,
        .ref_count = 1,
        .utf8_length = null,
    };

    const string_header = Object.StrOrPtr{
        .u = .{ .ptr = LongString.toInt(long_string) },
        .is_ptr = true,
    };

    return self.exchangeString(index, Object.null_string, string_header);
}

const empty_string_value = "";
/// This returns a temporary string. Whenever the object is modified, it
/// may become invalid.
fn getLocalString(heap: *Heap, index: u32) error{OutOfMemory}![:0]const u8 {
    const obj: *Object = heap.getLocalObject(index);

    switch (heap.getLocalStringDetails(index)) {
        .long => |long_str| {
            return long_str.string;
        },
        .normal => |str| {
            return str;
        },
        .empty => {
            return empty_string_value;
        },
        .null => {
            // Keep going in code
        },
    }

    // No representation, so we better generate it
    const new_str = blk: switch (obj.tag) {
        .index => {
            break :blk try std.fmt.allocPrintSentinel(heap.gpa, "{}", .{obj.body.index}, 0);
        },
        .integer => {
            break :blk try std.fmt.allocPrintSentinel(heap.gpa, "{}", .{obj.body.integer}, 0);
        },
        .float => {
            break :blk try std.fmt.allocPrintSentinel(heap.gpa, "{}", .{obj.body.float}, 0);
        },
        .bool => {
            break :blk try std.fmt.allocPrintSentinel(heap.gpa, "{}", .{@intFromBool(obj.body.bool)}, 0);
        },
        .list => {
            const list = obj.body.list;
            break :blk try getListString(heap, index + 1, list.len);
        },
        .dict => {
            const dict = heap.getDictMetadata(obj.body.dict);
            break :blk try getListString(heap, index + 1, dict.len);
        },
        .custom_type => {
            const custom_type = obj.body.custom_type;
            break :blk try custom_types.items[custom_type.type_id].get_string(heap, obj);
        },
        .reference => {
            // Intentionally return early, since we should always use
            // the reference's string, not our own.
            return getString(obj.body.reference);
        },
        .script_command => {
            if (builtin.mode == .Debug) {
                const script_command = obj.body.script_command;
                break :blk try std.fmt.allocPrintSentinel(
                    heap.gpa,
                    "<script command: args: {}, line: {}>",
                    .{ script_command.arg_count, script_command.line },
                    0,
                );
            } else @panic("Script line is an internal object only");
        },
        .none => {
            if (builtin.mode == .Debug) {
                break :blk try std.fmt.allocPrintSentinel(heap.gpa, "<none>", .{}, 0);
            } else @panic("Tried to generate a string for .none");
        },
        .marked => {
            if (builtin.mode == .Debug) {
                break :blk try std.fmt.allocPrintSentinel(heap.gpa, "<marked>", .{}, 0);
            } else @panic("Tried to generate a string for .marked");
        },
        .string, .dict_subst, .source, .script, .variable => {
            std.debug.panic("{} should always have a string representation", .{obj.tag});
        },
    };

    const took_ownership = try setStringOwning(heap.normalHandle(index), new_str, null);
    if (!took_ownership) heap.gpa.free(new_str);

    // Rerun this function to figure out where the new string is
    return heap.getLocalString(index);
}

fn getListString(self: *Heap, index: u32, len: u32) ![:0]u8 {
    var fallback = std.heap.stackFallback(64, self.gpa);
    var stack_alloc = fallback.get();
    var quoting_types = try stack_alloc.alloc(stringutil.QuotingType, len);
    defer stack_alloc.free(quoting_types);

    // Step 1: calculate the list's string length.
    var total_length: usize = 0;
    for (0..len) |i| {
        const element_string = try self.getLocalString(@intCast(index + i));
        quoting_types[i] = stringutil.calculateNeededQuotingType(element_string);
        if (i == 0 and quoting_types[i] == .bare and
            element_string.len > 0 and element_string[0] == '#')
        {
            // Make sure the first element has # escaped in braces
            quoting_types[i] = .brace;
        }
        total_length += stringutil.quoteSize(quoting_types[i], element_string.len);
        total_length += 1; // space between each element
    }

    // Step 2: actually create said string.
    var unfinished_str = try self.gpa.alloc(u8, total_length + 1);
    errdefer self.gpa.free(unfinished_str);
    var written: usize = 0;

    for (0..len) |i| {
        const element_string = try self.getLocalString(@intCast(index + i));
        written += stringutil.quoteString(
            quoting_types[i],
            element_string,
            unfinished_str[written..],
            i == 0,
        );

        // Add a space (except at the end of the list)
        if (i + 1 < len) {
            unfinished_str[written] = ' ';
            written += 1;
        }
    }

    // Slap a nul on the end
    unfinished_str[written] = 0x00;
    written += 1;

    // We actually need to realloc, because allocator.free needs the
    // original slice length (and we don't track the original slice
    // length, only the accessible length)
    const finished_str = try self.gpa.realloc(unfinished_str, written);
    return finished_str[0..(written - 1) :0];
}

pub fn leakCheck(heap: *Heap) !bool {
    // Make sure to free any parsed scripts, as they're allowed to leak (they
    // have references to heap objects, so it will cause a false positive).
    heap.clearParsedScripts();

    var leaked = false;

    for (heap.objects.items(.metadata)[special_object_count..], special_object_count..) |metadata, i| {
        if (metadata.in_use) {
            const handle = heap.getHandle(@intCast(i), false);
            std.debug.print("Leaked {} @ {} \"{s}\"\n", .{ handle.peek().tag, i, try getString(handle) });
            if (cfg.trace_mem) {
                const trace = heap.objects.get(i).trace;
                trace.dump();
                if (trace.index > 0) std.debug.print("\n\n", .{});
            }

            leaked = true;
        }
    }

    return leaked;
}

const StringDetails = union(enum) {
    null: void,
    empty: void,
    normal: [:0]u8,
    long: *align(LongString.align_amt) LongString,
};

pub fn getStringDetails(handle: Handle) StringDetails {
    return handle.getHeap().getLocalStringDetails(handle.index);
}

fn getLocalStringDetails(self: *Heap, index: u32) StringDetails {
    const obj = self.getLocalObject(index);

    // Normal string or long string?
    if (obj.str.is_ptr) {
        // Convert to LongString ptr (guaranteed to be non-null)
        return .{
            .long = LongString.fromInt(obj.str.u.ptr),
        };
    } else {
        const str = obj.str.u.str;
        if (str.index == null_string) {
            return .null;
        } else if (str.index == empty_string) {
            return .empty;
        } else {
            return .{
                .normal = self.getHeapString(str.index, str.index + str.len),
            };
        }
    }
}

pub const LongString = struct {
    /// At what point should we switch to using a long string?
    /// Whenever the string length >= split_point
    pub const split_point = 100_000;
    pub const align_amt = 128;
    pub const align_type = std.mem.Alignment.fromByteUnits(align_amt);

    string: [:0]u8,
    utf8_length: ?u64,
    details: Details,
    hash: ?u256 = null,
    ref_count: usize,

    /// Long strings are special in that they can have
    /// extended properties (mmaping is in the plans,
    /// for example). Since it has special properties,
    /// we have to track them so it can be freed correctly.
    pub const Details = union(enum) {
        normal,
        /// If the string was allocated with a different capacity
        /// than its current reported length, set this field
        different_capacity: u64,
    };

    pub fn fromInt(int: u58) *align(align_amt) LongString {
        return @ptrFromInt(int << 6);
    }

    pub fn toInt(ptr: *align(align_amt) LongString) u58 {
        return @intCast(@intFromPtr(ptr) >> 6);
    }

    pub fn getHash(self: *align(align_amt) LongString) u256 {
        if (self.hash) |hash| {
            return hash;
        } else {
            var out: [32]u8 = [_]u8{0} ** 32;
            std.crypto.hash.Blake3.hash(self.string, &out, .{});

            const hash: u256 = @bitCast(out);
            self.hash = hash;
            return hash;
        }
    }

    pub fn incrRefCount(self: *align(align_amt) LongString) void {
        incrRefCountOf(usize, &self.ref_count);
    }

    pub fn decrRefCount(self: *align(align_amt) LongString, gpa: Allocator) void {
        if (decrRefCountOf(usize, &self.ref_count)) {
            self.freeUnchecked(gpa);
        }
    }

    pub fn freeUnchecked(self: *align(align_amt) LongString, gpa: Allocator) void {
        switch (self.details) {
            .normal => gpa.free(self.string),
            .different_capacity => |capacity| {
                gpa.free(self.string.ptr[0..capacity :0]);
            },
        }

        gpa.destroy(self);
    }
};

pub fn createUpvar(self: *Heap) !u32 {
    self.mem_mgmt_mutex.lock();
    defer self.mem_mgmt_mutex.unlock();

    const new_index = try self.upvars.create(self.gpa);
    if (new_index >= object_heap_max_count) return error.OutOfMemory;

    return @intCast(new_index);
}

pub fn getUpvar(self: *Heap, index: u32) *Upvar {
    return &self.upvars.items[index];
}

pub fn destroyUpvar(self: *Heap, index: u32) void {
    self.mem_mgmt_mutex.lock();
    defer self.mem_mgmt_mutex.unlock();

    self.upvars.destroy(index);
}

pub fn createDictMetadata(self: *Heap) !DictIndex {
    self.mem_mgmt_mutex.lock();
    defer self.mem_mgmt_mutex.unlock();

    const new_id = try self.dicts.create(self.gpa);
    if (new_id >= object_heap_max_count) return error.OutOfMemory;

    return @intCast(new_id);
}

pub fn getDictMetadata(self: *Heap, index: DictIndex) *Dictionary {
    return &self.dicts.items[index];
}

pub fn destroyDictMetadata(self: *Heap, index: DictIndex) void {
    self.mem_mgmt_mutex.lock();
    defer self.mem_mgmt_mutex.unlock();

    self.dicts.destroy(index);
}

pub fn createCustomTypeInstance(self: *Heap) !u32 {
    self.mem_mgmt_mutex.lock();
    defer self.mem_mgmt_mutex.unlock();

    const new_id = try self.type_instances.create(self.gpa);
    if (new_id >= object_heap_max_count) return error.OutOfMemory;

    return @intCast(new_id);
}

// Heap instances //

/// Caller is responsible for locking the global mutex.
fn initGlobals(gpa: Allocator) !void {
    state.gpa = gpa;
    custom_types = try .initWithCapacity(gpa, if (cfg.threading) cfg.max_custom_types else 32);
    script_metadata = try .initWithCapacity(gpa, if (cfg.threading) cfg.max_scripts else 32);
    // Create null script. TODO do we need a null script?
    assert(try script_metadata.create(gpa) == 0);
    state.initialized = true;
}

pub fn createHeap(gpa: Allocator) !*Heap {
    const slot_index = blk: {
        state.mutex.lock();
        defer state.mutex.unlock();

        if (!state.initialized) {
            try initGlobals(gpa);
        }

        const heap_index = state.next_open_heap;
        state.next_open_heap += 1;

        break :blk heap_index;
    };
    errdefer {
        // Roll back heap index if it failed to initialize correctly.
        state.mutex.lock();
        state.next_open_heap -= 1;
        state.mutex.unlock();
    }

    if (slot_index < cfg.max_heaps) {
        const new_heap = try init(gpa, @intCast(slot_index));

        heaps[slot_index] = new_heap;
        return &heaps[slot_index];
    } else {
        return error.OutOfMemory;
    }
}

pub fn leakCheckAll() void {
    state.mutex.lock();
    state.running_leak_check = true;
    const heap_count = state.next_open_heap;
    state.mutex.unlock();

    var leaked = false;
    for (heaps[0..heap_count]) |*heap| {
        if (heap.leakCheck() catch false) {
            leaked = true;
        }
    }

    state.mutex.lock();
    state.running_leak_check = false;
    state.mutex.unlock();
}

pub fn deinitAll() void {
    state.mutex.lock();
    for (heaps[0..state.next_open_heap]) |*heap| {
        heap.deinit();
    }
    state.next_open_heap = 0;
    state.mutex.unlock();
}

pub fn testFinish() void {
    Heap.leakCheckAll();
    Heap.deinitAll();
}

pub fn createCustomType(custom_type: CustomType) ?*CustomType {
    state.mutex.lock();
    const slot_index = try state.custom_types.create(state.gpa);
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
    var heap = try createHeap(ta);
    defer Heap.testFinish();

    // Number object
    const obj = try heap.createObject();
    defer obj.release();
    var ref = obj.peek();
    ref.tag = .integer;
    ref.body.integer = 10;

    const new_obj = try heap.duplicate(obj);
    const new_ref = new_obj.peek();
    defer new_obj.release();

    try expectEqual(.integer, new_ref.tag);
    try expectEqual(10, new_ref.body.integer);

    // try borrowing
    const borrowed = try heap.borrow(new_obj);
    try expectEqual(borrowed, new_obj);
    try expectEqual(2, heap.objects.get(new_obj.index).ref_count);

    new_obj.release();
    try expectEqual(1, heap.objects.get(new_obj.index).ref_count);
}

test "get string" {
    const ta = std.testing.allocator;
    var heap = try createHeap(ta);
    defer Heap.testFinish();

    const obj = try heap.createObject();
    defer obj.release();
    var ref = obj.peek();
    ref.tag = .integer;
    ref.body.integer = 10;

    try expectEqualSlices(u8, "10", try getString(obj));
}

const DummyMutex = struct {
    fn lock(self: *DummyMutex) void {
        _ = self;
    }
    fn tryLock(self: *DummyMutex) void {
        _ = self;
    }
    fn unlock(self: *DummyMutex) void {
        _ = self;
    }
};

/// Atomically adds, if multithreading is enabled. Returns value before adding.
pub fn atomicIncr(comptime T: type, ptr: *T) T {
    if (cfg.threading) {
        return @atomicRmw(T, ptr, .Add, 1, .monotonic);
    } else {
        const before = ptr.*;
        ptr.* += 1;
        return before;
    }
}

pub fn incrRefCountOf(comptime T: type, ref: *T) void {
    if (cfg.threading) {
        _ = @atomicRmw(T, ref, .Add, 1, .monotonic);
    } else {
        ref.* += 1;
    }
}

/// Returns true if count has reached zero. Multithreaded safe.
pub fn decrRefCountOf(comptime T: type, ref: *T) bool {
    var after_sub: T = undefined;
    if (cfg.threading) {
        const before_sub = @atomicRmw(T, ref, .Sub, 1, .release);
        after_sub = before_sub - 1;

        if (after_sub == 0) {
            _ = @atomicLoad(T, ref, .acquire);
        }
    } else {
        ref.* -= 1;
        after_sub = ref.*;
    }

    return after_sub == 0;
}

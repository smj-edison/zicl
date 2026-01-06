const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const math = std.math;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const options = @import("options");
const stringutil = @import("stringutil.zig");
const memutil = @import("memutil.zig");
const Tokenizer = @import("Tokenizer.zig");
const expr_parse = @import("expr_parse.zig");
const object = @import("object.zig");
const Interp = @import("Interp.zig");

// These numbers are final, and can be depended on to be their current values
pub const special_string_count = 2;
pub const null_string = 0;
pub const empty_string = 1;
pub const special_object_count = 3;
pub const null_object_idx: u32 = 0;
pub const empty_object_idx: u32 = 1;
pub const temp_object_idx: u32 = 2;

pub const HeapSettings = struct {
    use_vmem: bool = true,
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
};
const cfg: HeapSettings = .{};

var debugging_gpa = if (builtin.mode == .Debug) std.heap.GeneralPurposeAllocator(.{}){} else undefined;
/// Use this for debugging objects (traces, etc) that can afford to leak.
var debug_gpa = if (builtin.mode == .Debug) debugging_gpa.allocator() else memutil.null_allocator;
/// Set this right before doing an operation that may cause a panic. The runtime will dump its
/// traces on panic if set.
threadlocal var last_touched: ?Handle = null;

pub const GlobalHeapState = struct {
    initialized: bool = false,
    /// Use to lock custom_types or script_metadata when adding or removing
    /// (no need to lock when using).
    mutex: memutil.Mutex = .{},
    /// Used for all global data structures (currently custom_types and script_metadata)
    gpa: std.mem.Allocator = memutil.null_allocator,
    next_open_heap: usize = 0,
    /// Used to turn some panics into useful messages.
    running_leak_check: bool = false,
};
pub var state: GlobalHeapState = .{};
pub var heaps: [cfg.max_heaps]Heap = undefined;
pub var custom_types: memutil.IndexedMemoryPool(CustomType, cfg.use_vmem) = undefined;
pub var script_metadata: ScriptMetadataPool = undefined;
const ScriptMetadataPool = memutil.IndexedMemoryPool(ScriptMetadata, cfg.use_vmem);

pub threadlocal var local_heap: *Heap = undefined;

const Heap = @This();

const object_heap_max_count: usize = @as(usize, 1) << cfg.object_heap_order;
const object_heap_max_bytes: usize = ObjectList.capacityInBytes(object_heap_max_count);
const string_heap_max_bytes: usize = @as(usize, 1) << cfg.string_heap_order;

gpa: Allocator,

/// Used whenever an allocation or free is happening.
mem_mgmt_mutex: memutil.Mutex = .{},
/// Used for locking when adding trace info.
trace_mutex: memutil.Mutex = .{},

object_tracking: ObjectTracker,
objects: ObjectList,
string_tracking: StringTracker,
strings: StringList,
interned_strings: std.EnumArray(InternedString, Heap.Handle),

/// If an object can't store all its information in 8 bytes, it can throw extra data on here.
extra: ExtraDataPool,
parsed_scripts: ParsedScripts,
parsed_exprs: ParsedExpressions,

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

const ExtraDataPool = memutil.IndexedMemoryPool(ExtraData, cfg.use_vmem);
const ParsedScripts = std.AutoHashMapUnmanaged(u32, struct { script: ParsedScript, generation: u32 });
const ParsedExpressions = std.AutoHashMapUnmanaged(u32, struct { expr: ParsedExpression, generation: u32 });

const InternedString = enum {
    lambda_apply_expr,
};

const interned_string_count = std.enums.values(InternedString).len;

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

        // Null script should never be retired.
        assert(id.index != 0);

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
    // This must be backed by a packed u64 (32-bit systems) or u96 (64-bit systems),
    // and ref_count must be the first field. Why? This struct is stored
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
    tags: std.ArrayList(Tokenizer.Token.Tag),
    /// File name.
    file_name_obj: ?Handle,
    /// Line number of the first line.
    first_line: u32,

    pub fn printTokens(script: *const ParsedScript) void {
        const formatting = "[{: >3}@{: >3}]  .{s: <20}  ";

        var line: u64 = 0;
        for (script.tags.items, object.listItems(script.values), 0..) |token, value, i| {
            switch (token) {
                .start_of_command => {
                    line = value.body.script_command.line;
                    std.debug.print(formatting ++ "{}\n", .{ i, line, @tagName(token), value.body.script_command });
                },
                .start_of_word => std.debug.print(formatting ++ "{}\n", .{ i, line, @tagName(token), value.body.integer }),
                else => {
                    const item = object.listItem(script.values, @intCast(i));
                    std.debug.print(formatting ++ "{s}\n", .{ i, line, @tagName(token), getString(item) catch "<oom string>" });
                },
            }
        }
    }

    pub fn deinit(parsed: *ParsedScript, script_heap: *Heap) void {
        if (parsed.file_name_obj) |file_name| file_name.decrRefCount();
        parsed.tags.deinit(script_heap.gpa);
        parsed.values.decrRefCount();
    }
};

pub const ParsedExpression = struct {
    root_node: expr_parse.Node.Index,
    nodes: std.MultiArrayList(expr_parse.Node),

    pub fn deinit(expr: *ParsedExpression, gpa: std.mem.Allocator) void {
        expr_parse.deinitNodes(gpa, &expr.nodes);
        expr.* = undefined;
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

        pub fn deinit(str: StrOrPtr, heap: *Heap) void {
            switch (heap.getLocalStringDetails(str)) {
                .long => |long_str| {
                    long_str.decrRefCount(heap.gpa);
                },
                .normal => {
                    heap.freeString(str.u.str.index, str.u.str.len);
                },
                .null, .empty => {},
            }
        }
    };

    // Make sure this stays in sync with Head fields.
    str: StrOrPtr,
    tag: Tag,
    body: Body,

    // Make sure this stays in sync with Object fields.
    pub const Head = packed struct(u64) {
        str: StrOrPtr,
        tag: Tag,
    };

    pub fn asHead(obj: *Object) *Head {
        return @ptrCast(obj);
    }

    pub fn deinitSingle(obj: *Object, heap: *Heap) void {
        obj.deinitBodySingle(heap);
        obj.deinitString(heap);
    }

    pub fn deinitString(obj: *Object, heap: *Heap) void {
        obj.str.deinit(heap);

        // Be sure to set the null string afterwards (we can directly assign,
        // as we've already checked that we can shimmer).
        obj.str = Object.null_string;
    }

    /// Only deinitializes if this is a single object, panics otherwise. Can
    /// be used to deinit a stack-allocated object. `heap` is used to reference
    /// the strings/extra data this object contains.
    pub fn deinitBodySingle(obj: *Object, heap: *Heap) void {
        // Deinit body
        switch (obj.tag) {
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
            .script => {
                const script = obj.body.script;
                if (decrRefCountOf(u32, &script_metadata.items[script.id.index].ref_count, options.threading)) {
                    script.id.retire();
                }
            },
            .expr => {
                const expr = obj.body.expr;
                if (decrRefCountOf(u32, &script_metadata.items[expr.id.index].ref_count, options.threading)) {
                    expr.id.retire();
                }
            },
            .source => {
                const source = obj.body.source;
                if (source.file_name_obj.toNullable(heap).toHandle()) |val| val.decrRefCount();
            },
            .command => {
                const command = obj.body.command;
                if (!command.in_global_namespace) {
                    const extra_data = heap.getExtraData(command.u.other_namespace).command;
                    heap.getHandle(extra_data.namespace).decrRefCount();
                    heap.destroyExtraData(command.u.other_namespace);
                }
            },
            .upvar => {
                const upvar = &heap.getExtraData(obj.body.upvar).upvar;
                switch (upvar.name) {
                    .normal => |var_name| {
                        heap.getHandle(var_name).decrRefCount();
                    },
                    .dict_sugar => |dict_names| {
                        heap.getHandle(dict_names.dict_name_index).decrRefCount();
                        heap.getHandle(dict_names.dict_key_index).decrRefCount();
                    },
                }
            },
            .dict_subst => @panic("Need to free any references"),
            .none,
            .index,
            .integer,
            .float,
            .bool,
            .script_command,
            .marked,
            .variable,
            => {},
            .dict, .list => unreachable,
        }

        obj.body = undefined;
        obj.tag = .none;
    }
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
    command,
    script_command,
    script,
    expr,
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
        utf8_length: u32,
        length_determined: bool,
    },
    source: packed struct {
        /// Pointer to an object in the same heap that contains the file name.
        file_name_obj: NullableIndex,
        line_no: u32,
    },
    list: packed struct {
        len: u32,
    },
    /// Items of the dictionary are stored directly after, similar to a list.
    /// Keys and values alternate. Allows for duplicate keys when shimmering
    /// from a list, but duplicates will be removed when any writing operation
    /// happens.
    dict: ExtraDataIndex,
    /// Both objects must be in the same heap.
    dict_subst: packed struct {
        var_name_index: u32,
        dict_value_index: u32,
    },
    command: packed struct {
        procedure_epoch: u31,
        in_global_namespace: bool,
        u: packed union {
            global_namespace: packed struct {
                command_index: u32,
            },
            other_namespace: ExtraDataIndex,
        },
    },
    /// Information about a command.
    script_command: packed struct {
        line: u32,
        arg_count: u32,
    },
    script: packed struct {
        id: ScriptId,
    },
    expr: packed struct {
        id: ScriptId,
    },
    reference: Handle,
    variable: packed struct {
        index: u32,
        /// Used to invalidate `index`'s cached value, if it doesn't match
        /// the current call frame's epoch.
        call_epoch: u31,
        /// Whether the variable is global, e.g. prefixed with ::
        is_global: bool,
    },
    upvar: ExtraDataIndex,
    custom_type: packed struct {
        type_id: u32,
        index: ExtraDataIndex,
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

pub const ExtraDataIndex = enum(u32) { _ };
/// Extra data, for when you can't store enough in the main object.
pub const ExtraData = union {
    pub const Dictionary = struct {
        /// Caller needs to ensure that any string this is called with
        /// is valid, as hash map methods don't return errors.
        table: std.HashMapUnmanaged(Handle, u32, struct {
            pub fn hash(ctx: @This(), key: Handle) u64 {
                _ = ctx;

                const str = getString(key) catch unreachable;
                return std.hash_map.hashString(str);
            }

            pub fn eql(ctx: @This(), a: Handle, b: Handle) bool {
                _ = ctx;

                return checkIfEqual(a, b) catch unreachable;
            }
        }, 80),
        /// Length of dictionaries' backing list, including potential duplicated
        /// keys when shimmering from list.
        len: u32,
    };

    /// This does not store the key/value pairs directly, instead it
    /// is an mapping of key to value index.
    dict: Dictionary,
    upvar: struct {
        call_frame_idx: u32,
        call_frame_epoch: u31,
        /// Cached index of the target object. Contains the null object if the variable
        /// doesn't exist.
        index: u32,
        name: union(enum) {
            /// An object containing the name of the variable in the variable's scope.
            normal: u32,
            dict_sugar: struct {
                /// _Non_-cached index of the dictionary name ("foo" of `foo(bar)`).
                dict_name_index: u32,
                /// _Non_-cached index of the dictionary key ("bar" of `foo(bar)`).
                dict_key_index: u32,
            },
        },
    },
    custom_type: struct {
        first_ptr: *anyopaque,
        second_ptr: *anyopaque,
    },
    /// Spillover for when command isn't in the global namespace.
    command: struct {
        namespace: u32,
        command_index: u32,
    },
};

pub const CustomType = struct {
    /// Type name.
    name: []u8,
    /// Must be threadsafe.
    invalidate_body: *const fn (heap: *Heap, obj: *Object) void,
    duplicate: *const fn (heap: *Heap, src: *const Object, dest: *Object) Allocator.Error!void,
    get_string: *const fn (heap: *Heap, obj: *const Object) Allocator.Error![:0]u8,
    make_immutable: *const fn (heap: *Heap, obj: *Object) Allocator.Error!void,
};

const HeapIndex = u32;
const HandleBacking = u64;

pub const NullableIndex = enum(HeapIndex) {
    null = 0,
    _,

    pub fn toNullable(index: NullableIndex, heap: *Heap) NullableHandle {
        if (index == .null) return .null;
        const unwrapped_index: HeapIndex = @intFromEnum(index);
        return heap.getHandle(unwrapped_index).toNullable();
    }

    pub fn getIndex(index: NullableIndex) ?HeapIndex {
        if (index != .null) {
            return @intFromEnum(index);
        } else return null;
    }
};

pub const NullableHandle = enum(HandleBacking) {
    null = 0,
    _,

    pub fn toHandle(nullable: NullableHandle) ?Handle {
        if (nullable != .null) {
            return @bitCast(@as(HandleBacking, @intFromEnum(nullable)));
        } else return null;
    }

    pub fn getIndex(nullable: NullableHandle) NullableIndex {
        if (nullable.toHandle()) |val| {
            return @enumFromInt(val.index);
        } else return .null;
    }

    pub fn toHandleRef(nullable: *NullableHandle) ?*Handle {
        if (nullable.* != .null) {
            return @as(*Handle, @ptrCast(nullable));
        } else return null;
    }

    pub fn swapRef(ref: *NullableHandle, new_handle: Handle) void {
        if (ref.toHandle()) |handle| {
            handle.decrRefCount();
        }
        ref.* = @enumFromInt(@as(HandleBacking, @bitCast(new_handle)));
    }

    pub fn swapRefIfNew(ref: *NullableHandle, new_handle: NullableHandle) void {
        if (new_handle != .null) {
            if (ref.toHandle()) |val| val.decrRefCount();
            ref.* = new_handle;
        }
    }

    pub fn swapWithNull(ref: *NullableHandle) void {
        if (ref.toHandle()) |val| val.decrRefCount();
        ref.* = .null;
    }

    pub fn orElse(ref: NullableHandle, other: Handle) Handle {
        return ref.toHandle() orelse other;
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

    pub fn getHeap(handle: Handle) *Heap {
        return &heaps[handle.heap];
    }

    pub fn toNullable(handle: Handle) NullableHandle {
        return @enumFromInt(@as(HandleBacking, @bitCast(handle)));
    }

    pub fn prepareToShimmer(handle: Handle) !void {
        handle.assert(handle.canShimmer());
        // Make sure the object has a string rep before we free its body.
        _ = try Heap.getString(handle);
        handle.invalidateBody();
    }

    pub fn canShimmer(handle: Handle) bool {
        // Specialty objects can't shimmer.
        if (handle.index < special_object_count + interned_string_count) return false;

        // Can't shimmer if it's shared between threads
        return !handle.getHeap().objects.get(handle.index).metadata.cross_thread;
    }

    /// Note: this has a very specific definition (is ref_count > 1 or is cross_thread).
    /// You should probably be using `canMutate` or `canShimmer`, as they have slightly
    /// different but important semantics.
    pub fn isShared(handle: Handle) bool {
        const obj_heap = handle.getHeap();
        const metadata = obj_heap.getLocalMetadata(handle.index);

        if (metadata.cross_thread) return true;
        return obj_heap.getLocalRefCount(handle.index) > 1;
    }

    pub fn canMutate(handle: Handle) bool {
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

    pub const SwapFlags = struct {
        free_old: bool = true,
    };

    pub fn swapThenReleaseOld(ref: *Handle, new: Handle) void {
        const before_duplicating = ref.*;
        ref.* = new;
        before_duplicating.decrRefCount();
    }

    /// Helper to swap handle if new_handle is non-null, releasing the old one.
    pub fn swapIfNew(ref: *Handle, new_handle: ?Handle) void {
        if (new_handle) |new| {
            const old = ref.*;
            ref.* = new;
            old.decrRefCount();
        }
    }

    pub fn hasString(handle: Handle) bool {
        return handle.peek().str != Object.null_string;
    }

    pub fn getMetadata(handle: Handle) *ObjectAndMetadata.Metadata {
        return handle.getHeap().getLocalMetadata(handle.index);
    }

    /// This should not be used for checking if an object is shared, use `isShared` instead.
    pub fn debugRefCount(handle: Handle) u32 {
        return getLocalRefCount(handle.getHeap(), handle.index);
    }

    pub fn borrow(handle: Handle) Handle {
        handle.incrRefCount();
        return handle;
    }

    pub fn borrowOptional(handle: ?Handle) ?Handle {
        if (handle) |val| val.incrRefCount();
        return handle;
    }

    pub fn incrRefCount(handle: Handle) void {
        if (handle.index < special_object_count + interned_string_count) return;
        // Make sure we never try to borrow a freed object.
        handle.assert(handle.debugRefCount() > 0);
        handle.assert(handle.peek().tag != .reference);

        const metadata = handle.getMetadata();
        incrRefCountOf(u32, &handle.getHeap().objects.items(.ref_count)[handle.index], metadata.cross_thread);

        handle.trace("Incr ref count of index {} (now {})", .{ handle.index, handle.debugRefCount() });
    }

    pub fn referenceTakeOwnership(handle: Handle) Object {
        // Make sure we're never making a reference to a reference.
        handle.assert(handle.peek().tag != .reference);

        return .{
            // References are guaranteed to always have a null representation.
            .str = Object.null_string,
            .tag = .reference,
            .body = .{
                .reference = handle,
            },
        };
    }

    pub fn reference(handle: Handle) Object {
        handle.incrRefCount();
        return handle.referenceTakeOwnership();
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
        if (!handle.isAllocHead()) handle.assert(handle.debugRefCount() > 1);

        if (options.trace_mem) last_touched = handle;
        if (decrRefCountOf(u32, &obj_heap.objects.items(.ref_count)[handle.index], metadata.cross_thread)) {
            freeObject(handle);
        }

        handle.trace("Decr ref count of index {} (now {})", .{ handle.index, handle.debugRefCount() });
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

    pub fn trace(handle: Handle, comptime fmt: []const u8, args: anytype) void {
        if (options.trace_mem) {
            handle.getHeap().trace_mutex.lock();
            defer handle.getHeap().trace_mutex.unlock();
            const trace_field = &handle.getHeap().objects.items(.trace)[handle.index];
            trace_field.addAddr(@returnAddress(), std.fmt.allocPrint(debug_gpa, fmt, args) catch unreachable);
        }
    }

    /// Helper function that dumps the object's trace if the assertion fails.
    pub fn assert(handle: Handle, ok: bool) void {
        if (!ok) {
            if (options.trace_mem) {
                last_touched = handle;
                Heap.dumpLastTouchedTrace();
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
    handle.peek().deinitString(handle.getHeap());
}

fn invalidateCollection(handle: Handle) void {
    assert(handle.peek().tag == .dict or handle.peek().tag == .list);

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

        invalidateBothInner(elem_handle);
        if (any_elems_referenced) elem_handle.decrRefCount();
    }
}

fn invalidateBodyInner(handle: Handle) void {
    handle.trace("Invalidate body", .{});

    const obj_heap = handle.getHeap();
    const obj = obj_heap.getLocalObject(handle.index);

    switch (obj.tag) {
        .list => {
            invalidateCollection(handle);
        },
        .dict => {
            const dict_metadata = &obj_heap.getExtraData(obj.body.dict).dict;

            invalidateCollection(handle);

            dict_metadata.table.deinit(obj_heap.gpa);
            obj_heap.destroyExtraData(obj.body.dict);
        },
        else => obj.deinitBodySingle(obj_heap),
    }

    obj.body = undefined;
    obj.tag = .none;
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
    trace: std.debug.ConfigurableTrace(16, 16, options.trace_mem),
};

fn heapAlloc(self: *Heap) Allocator {
    if (cfg.use_vmem or options.threading) {
        return memutil.null_allocator;
    } else {
        return self.gpa;
    }
}

fn createInternedString(heap: *Heap, expected_index: u32, str: []const u8) !Handle {
    const interned = try heap.createObject();
    errdefer freeObjectBackingInner(interned);
    const cast_len: u26 = @intCast(str.len);
    const str_index = try heap.createString(cast_len);
    errdefer heap.freeString(str_index, cast_len);
    assert(interned.index == (expected_index + special_object_count));

    @memcpy(heap.getHeapString(str_index, str_index + cast_len), str);
    assert(heap.exchangeString(interned.index, Object.null_string, .{
        .is_ptr = false,
        .u = .{ .str = .{ .index = str_index, .len = cast_len } },
    }));

    return interned;
}

fn createInternedStrings(heap: *Heap) !void {
    const MappingEntry = struct { InternedString, []const u8 };
    const mapping = [_]MappingEntry{
        .{ .lambda_apply_expr, "apply lambdaExpr" },
    };
    var converted_mapping: std.enums.EnumFieldStruct(InternedString, Handle, null) = undefined;

    // Init all the interned strings, handling failure as needed.
    var converted: usize = 0;
    errdefer {
        // Since we can't loop up to `converted` at comptime, we'll generate
        // an if-ladder that only deinits fields that have been initialized.
        inline for (0..mapping.len) |i| {
            const key = @tagName(mapping[i].@"0");
            if (i < converted) {
                const handle: Handle = @field(converted_mapping, key);
                handle.peek().str.deinit(heap);
                freeObjectBackingInner(handle);
            }
        }
    }
    // Fill the mapping.
    inline for (0..mapping.len) |i| {
        const key = @tagName(mapping[i].@"0");
        const value = mapping[i].@"1";
        const new_str = try heap.createInternedString(i, value);
        converted += 1; // After `new_str` is successfully created
        @field(converted_mapping, key) = new_str;
    }

    heap.interned_strings = .init(converted_mapping);
}

pub fn init(heap: *Heap, gpa: Allocator) !void {
    heap.* = undefined;
    // Clean up if we hit an error.
    errdefer heap.* = undefined;

    heap.gpa = gpa;

    // Init objects
    heap.object_tracking = try .init(gpa, cfg.object_heap_order);
    errdefer _ = heap.object_tracking.deinit();

    heap.objects = .empty;
    if (cfg.use_vmem) {
        heap.objects.bytes = (try memutil.vmemMap(object_heap_max_bytes)).ptr;
        heap.objects.capacity = object_heap_max_count;
    } else if (options.threading) {
        // if multithreading, we can't have objects moving around. We better allocate
        // everything up front.
        try heap.objects.ensureTotalCapacity(gpa, object_heap_max_count);
    } else {
        try heap.objects.ensureTotalCapacity(gpa, 32);
    }
    errdefer {
        if (cfg.use_vmem) {
            memutil.vmemUnmap(@alignCast(heap.objects.bytes[0..object_heap_max_bytes]));
        } else {
            heap.objects.deinit(gpa);
        }
    }

    // Init strings
    heap.string_tracking = try .init(gpa, cfg.string_heap_order);
    errdefer _ = heap.string_tracking.deinit();

    heap.strings = .empty;
    if (cfg.use_vmem) {
        const string_vmem = try memutil.vmemMap(string_heap_max_bytes);
        heap.strings.items = string_vmem.ptr[0..0];
        heap.strings.capacity = string_vmem.len;
    } else if (options.threading) {
        // if multithreading, we can't have strings moving around. We better allocate
        // everything up front.
        try heap.strings.ensureTotalCapacity(gpa, string_heap_max_bytes);
    } else {
        try heap.strings.ensureTotalCapacity(gpa, 32);
    }
    errdefer {
        if (cfg.use_vmem) {
            memutil.vmemUnmap(@alignCast(heap.strings.items.ptr[0..heap.strings.capacity]));
        } else {
            heap.strings.deinit(gpa);
        }
    }

    const object_capacity = if (options.threading) object_heap_max_count else 32;

    heap.extra = try .initWithCapacity(gpa, object_capacity);
    errdefer heap.extra.deinit(gpa);

    heap.parsed_scripts = .empty;
    heap.parsed_exprs = .empty;

    // Done initializing heap fields, so now we'll create all the specialty objects.

    // null string is guaranteed to have index 0
    const null_string_idx = try heap.string_tracking.allocFromOwningThread(0);
    assert(null_string_idx == null_string);
    errdefer heap.string_tracking.freeFromOwningThread(null_string_idx, 0);
    // empty string is guaranteed to have index 1
    const empty_string_idx = try heap.string_tracking.allocFromOwningThread(0);
    assert(empty_string_idx == empty_string);
    errdefer heap.string_tracking.freeFromOwningThread(empty_string_idx, 0);

    // This is to remember to update this section whenever the special
    // objects change.
    comptime assert(special_object_count == 3);

    // Specialty objects
    // null object is guaranteed to have index 0.
    const null_object = try heap.createObject();
    assert(null_object.index == null_object_idx);
    errdefer freeObjectBackingInner(null_object);
    // Empty object is guaranteed to have index 1.
    const empty_object = try heap.createObject();
    assert(empty_object.index == empty_object_idx);
    empty_object.peek().str = Object.empty_string;
    errdefer freeObjectBackingInner(empty_object);
    // Temp object is guaranteed to have index 2.
    const temp_object = try heap.createObject();
    assert(temp_object.index == temp_object_idx);
    errdefer freeObjectBackingInner(temp_object);

    // We need to init the temp object as well by setting its string to a long string.
    assert(try heap.setLongString(temp_object_idx, .{ .temp = "" }));
    errdefer heap.tempObject().peek().str.deinit(heap);

    // Create all the interned strings.
    try heap.createInternedStrings();
}

fn clearParsedScripts(self: *Heap) void {
    var parsed_script_iter = self.parsed_scripts.valueIterator();
    while (parsed_script_iter.next()) |parsed_script| {
        parsed_script.script.deinit(self);
    }
    self.parsed_scripts.clearRetainingCapacity();

    var parsed_expr_iter = self.parsed_exprs.valueIterator();
    while (parsed_expr_iter.next()) |parsed_expr| {
        parsed_expr.expr.deinit(self.gpa);
    }
    self.parsed_exprs.clearRetainingCapacity();
}

pub fn deinit(heap: *Heap) void {
    // Parsed scripts have references to objects, so we'll deinit scripts before objects.
    heap.clearParsedScripts();
    heap.parsed_scripts.deinit(heap.gpa);
    heap.parsed_exprs.deinit(heap.gpa);

    for ((special_object_count + interned_string_count)..heap.objects.len) |i| {
        const metadata = heap.objects.get(i).metadata;
        if (metadata.in_use) {
            // We don't use free object here, as it may cause a double-free when
            // freeing recursive structures. For example, if there was a list with
            // two items, we'll free the list (first free of items), then free
            // the items individually (second free)
            invalidateBothInner(heap.getHandle(@intCast(i)));
        }
    }

    for (special_object_count..(special_object_count + interned_string_count)) |i| {
        // Need to free these objects directly, since they're not normally allowed
        // to be mutated.
        const interned = heap.getHandle(@intCast(i));
        interned.peek().str.deinit(heap);
        freeObjectBackingInner(interned);
    }

    // Be sure to free the specialty objects and strings.
    assert(special_object_count == 3);
    Heap.getStringDetails(heap.tempObject()).long.freeInner(heap.gpa);
    heap.object_tracking.freeFromOwningThread(0, 0);
    heap.object_tracking.freeFromOwningThread(1, 0);
    heap.object_tracking.freeFromOwningThread(2, 0);
    assert(special_string_count == 2);
    heap.string_tracking.freeFromOwningThread(0, 0);
    heap.string_tracking.freeFromOwningThread(1, 0);

    if (cfg.use_vmem) {
        memutil.vmemUnmap(@alignCast(heap.strings.items));
        memutil.vmemUnmap(@alignCast(heap.objects.bytes[0..object_heap_max_bytes]));
    } else {
        // Don't use self.heapAlloc() in this case, as that will error
        // with the null allocator.
        heap.strings.deinit(heap.gpa);
        heap.objects.deinit(heap.gpa);
    }

    if (heap.object_tracking.deinit() == .leaked) @panic("Heap leaks when deiniting");
    if (heap.string_tracking.deinit() == .leaked) @panic("Heap leaks when deiniting");

    heap.extra.deinit(heap.gpa);
    heap.* = undefined;
}

pub inline fn heapId(self: *Heap) HeapId {
    return @intCast(self - &heaps);
}

pub fn emptyObject(self: *Heap) Handle {
    return .{
        .index = empty_object_idx,
        .heap = self.heapId(),
    };
}

pub fn tempObject(self: *Heap) Handle {
    return .{
        .index = temp_object_idx,
        .heap = self.heapId(),
    };
}

pub fn resetTempObject(heap: *Heap) void {
    if (heap.tempObject().hasString()) {
        const long_string = getStringDetails(heap.tempObject()).long;
        long_string.string_type.temp = undefined;
    }
}

pub fn setTempObjectString(heap: *Heap, bytes: [:0]const u8) void {
    const temp_handle = heap.tempObject();
    assert(temp_handle.hasString());
    assert(temp_handle.getMetadata().cross_thread == false);

    const long_string = getStringDetails(temp_handle).long;
    // Avoid churning the LongString allocation by making it
    // extremely unlikely for its ref_count to reach zero.
    long_string.ref_count = std.math.maxInt(usize) / 2;
    // Reset anything that may have previously been computed.
    @atomicStore(u64, &long_string.utf8_length, std.math.maxInt(u64), .monotonic);
    long_string.utf8_length = std.math.maxInt(u64);
    long_string.hash.mutex.lock();
    long_string.hash.value = null;
    long_string.hash.mutex.unlock();

    long_string.string_type = .{
        .temp = bytes,
    };
}

pub fn getInternedString(heap: *Heap, string: InternedString) Heap.Handle {
    return heap.interned_strings.get(string);
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
    var heap = try Heap.testStart(testing.allocator);

    const index = try heap.createObjects(8);
    heap.splitAlloc(index, 1);

    for (index..(index + 8)) |i| {
        try testing.expectEqual(1, heap.objects.get(i).metadata.order);
    }

    for (0..4) |i| {
        heap.getHandle(@intCast(index + i * 2)).decrRefCount();
    }
}

/// create_objects does not initialize objects, but does initialize
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

    // Make object list has space for new objects
    if (self.objects.len < index + aligned_count) {
        const start_of_new = self.objects.len;
        try self.objects.resize(self.heapAlloc(), index + aligned_count);
        @memset(self.objects.items(.metadata)[start_of_new..self.objects.len], .{
            .order = 31,
            .cross_thread = false,
            .in_use = false,
            .mutable = false,
        });
    }

    self.getHandle(index).trace("Alloc at index {} of order {}", .{ index, order });
    if (aligned_count > 1) {
        for ((index + 1)..end) |collection_item| {
            self.getHandle(@intCast(collection_item)).trace(
                "Alloc at index {} of order {} (item of {})",
                .{ collection_item, order, index },
            );
        }
    }

    // Make sure the items we're allocating are free (used to
    // ensure our allocator hasn't reached a broken state).
    for (self.objects.items(.metadata)[index..end]) |metadata| assert(metadata.in_use == false);

    // Initialize all as empty objects
    @memset(self.objectSlice(index, end), .{
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

fn freeObjectBackingInner(handle: Handle) void {
    const obj_heap = handle.getHeap();
    const metadata = obj_heap.getLocalMetadata(handle.index).*; // Copy

    if (options.trace_mem) last_touched = handle;
    handle.trace("Free {} of order {}", .{ handle.index, metadata.order });

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
    if (!handle.isAllocHead()) Heap.dumpLastTouchedTrace();
    assert(handle.isAllocHead());

    freeObjectBackingInner(handle);
}

pub fn freeObject(handle: Handle) void {
    invalidateBothInner(handle);

    freeObjectBacking(handle);
}

pub fn ensureMutableOrDup(handle: Handle, new_handle: *NullableHandle) !void {
    if (!handle.canMutate()) {
        // It's very sketchy to modify a collection item in place if
        // its parent is shared, so if this isn't the head this is
        // probably incorrect.
        assert(handle.isAllocHead());
        new_handle.swapRef(try Heap.duplicate(local_heap, handle));
    }
}

/// If the object can't shimmer, this will return a duplicate.
pub fn ensureShimmerableOrDup(handle: Handle, new_handle: *NullableHandle) !void {
    if (!handle.canShimmer()) {
        new_handle.swapRef(try Heap.duplicate(local_heap, handle));
    }
}

pub fn ensureSameHeapOrDup(handle: Handle, new_handle: *NullableHandle) !void {
    if (handle.heap != local_heap.heapId()) {
        new_handle.swapRef(try local_heap.duplicate(handle));
    }
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
    const order = memutil.getOrder(length_with_null);

    const new_string = blk: {
        if (self == local_heap) {
            break :blk try self.string_tracking.allocFromOwningThread(order);
        } else {
            break :blk try self.string_tracking.allocFromAnyThread(order);
        }
    };
    errdefer self.string_tracking.freeFromAnyThread(new_string, order);
    try self.strings.ensureTotalCapacity(self.heapAlloc(), new_string + length_with_null);
    self.strings.items.len = @max(self.strings.items.len, new_string + length_with_null);

    self.strings.items[new_string + len] = 0; // Set null byte.
    return new_string;
}

pub fn freeString(self: *Heap, index: u32, len: u32) void {
    assert(index >= special_string_count);

    const length_with_null = len + 1;
    const order = memutil.getOrder(length_with_null);
    if (self == local_heap) {
        self.string_tracking.freeFromOwningThread(index, order);
    } else {
        self.string_tracking.freeFromAnyThread(index, order);
    }
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
            // The only case where an object can have a null string after getting
            // its string value is a reference.
            .null => {
                assert(a.peek().tag == .reference);
                break :blk;
            },
            else => break :blk,
        };

        const b_long_str = switch (b_details) {
            .long => |unwrapped| unwrapped,
            .null => {
                assert(b.peek().tag == .reference);
                break :blk;
            },
            else => break :blk,
        };

        // If both strings are long strings, we can just
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
    switch (getStringDetails(handle)) {
        .long => |long_str| {
            long_str.incrRefCount();
            return .{
                .u = .{ .ptr = LongString.toInt(long_str) },
                .is_ptr = true,
            };
        },
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
            return handle.peek().str;
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
pub fn dupOrReference(dest_heap: *Heap, handle: Handle) !Object {
    _ = dest_heap;

    const tag = handle.peek().tag;
    if (tag == .reference) {
        // We can't reference a reference, so we'll create a new reference.
        return handle.peek().body.reference.reference();
    } else if (handle.peek().str == Object.null_string and tag == .float or tag == .integer) {
        // We can't just use a number if it has a string rep, because the string may
        // be different than how the number will be rendered.
        return .{
            .str = Object.null_string,
            .tag = tag,
            .body = handle.peek().body,
        };
    } else {
        return handle.reference();
    }
}

/// If called with a multi-item object, will return error.MultiItemObject
pub fn duplicateSingle(dest_heap: *Heap, handle: Handle) error{ OutOfMemory, MultiItemObject }!Object {
    const src = handle.peek();
    switch (src.tag) {
        .none, .index, .integer, .float, .string, .bool, .script_command, .marked => {
            return .{
                .str = try dest_heap.duplicateObjString(handle),
                .tag = src.tag,
                .body = src.body,
            };
        },
        .script => {
            const script = src.body.script;
            incrRefCountOf(u32, &script_metadata.items[script.id.index].ref_count, options.threading);
            return .{
                .str = try dest_heap.duplicateObjString(handle),
                .tag = src.tag,
                .body = src.body,
            };
        },
        .expr => {
            const expr = src.body.expr;
            incrRefCountOf(u32, &script_metadata.items[expr.id.index].ref_count, options.threading);
            return .{
                .str = try dest_heap.duplicateObjString(handle),
                .tag = src.tag,
                .body = src.body,
            };
        },
        .source => {
            const source = src.body.source;

            const file_name_handle: NullableHandle = blk: {
                if (source.file_name_obj.toNullable(handle.getHeap()).toHandle()) |file_name| {
                    // Better make sure it's in our heap.
                    if (file_name.heap != dest_heap.heapId()) {
                        const duped = try dest_heap.duplicate(file_name);
                        break :blk duped.toNullable();
                    } else {
                        const to_break = file_name.borrow();
                        break :blk to_break.toNullable();
                    }
                } else break :blk .null;
            };

            return .{
                .str = try dest_heap.duplicateObjString(handle),
                .tag = .source,
                .body = .{
                    .source = .{
                        .file_name_obj = file_name_handle.getIndex(),
                        .line_no = source.line_no,
                    },
                },
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
                .str = try dest_heap.duplicateObjString(handle),
                .tag = .custom_type,
                .body = .{
                    .custom_type = .{
                        .index = try dest_heap.createExtraData(),
                        .type_id = custom_type.type_id,
                    },
                },
            };
            try custom_types.items[custom_type.type_id].duplicate(dest_heap, src, &new_object);

            return new_object;
        },
        .dict_subst, .variable, .upvar, .command => {
            // Variable lookup is not stable between threads.
            return .{
                .str = try dest_heap.duplicateObjString(handle),
                .tag = .none,
                .body = undefined,
            };
        },
        .list, .dict => {
            return error.MultiItemObject;
        },
    }
}

pub fn duplicate(dest_heap: *Heap, handle: Handle) error{OutOfMemory}!Handle {
    const src = handle.peek();

    switch (src.tag) {
        .list => {
            const old_body = src.body.list;
            const old_start = handle.index + 1;

            const new_list_idx = try dest_heap.createObjects(1 + old_body.len);
            errdefer {
                // Free elements before freeing the head, as the head could
                // be swapped out if freed too early
                for (0..old_body.len) |i| {
                    freeObject(.{
                        .index = @intCast(new_list_idx + 1 + i),
                        .heap = handle.heap,
                    });
                }
                freeObject(.{ .index = new_list_idx, .heap = handle.heap });
            }
            const new_head: *Object = dest_heap.getLocalObject(new_list_idx);
            const new_start = new_list_idx + 1;
            const new_items = dest_heap.objectSlice(new_start, new_start + old_body.len);

            // Duplicate head of list
            new_head.* = .{
                .str = try dest_heap.duplicateObjString(handle),
                .tag = .list,
                .body = .{
                    .list = .{ .len = old_body.len },
                },
            };

            // Duplicate items of list
            for (new_items, 0..) |*new_item, i| {
                new_item.* = dest_heap.duplicateSingle(.{
                    .heap = handle.heap,
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
            const old_head = dest_heap.getExtraData(src.body.dict).dict;
            const old_start = handle.index + 1;

            const new_dict_idx = try dest_heap.createObjects(1 + old_head.len);
            errdefer dest_heap.getHandle(new_dict_idx).decrRefCount();
            const new_head = dest_heap.getHandle(new_dict_idx);
            const new_start = new_dict_idx + 1;
            const new_items = dest_heap.objectSlice(new_start, new_start + old_head.len);

            // Duplicate head of dict.
            {
                const new_str = try dest_heap.duplicateObjString(handle);
                errdefer new_str.deinit(dest_heap);
                const extra_data = try dest_heap.createExtraData();
                errdefer dest_heap.destroyExtraData(extra_data);

                new_head.peek().* = .{
                    .str = new_str,
                    .tag = .dict,
                    .body = .{
                        .dict = extra_data,
                    },
                };
                dest_heap.getExtraData(extra_data).* = .{
                    .dict = .{ .table = .empty, .len = 0 },
                };
            }

            // Duplicate items of dict
            for (new_items, 0..) |*new_item, i| {
                new_item.* = dest_heap.duplicateSingle(.{
                    .index = @intCast(old_start + i),
                    .heap = handle.heap,
                }) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    // Dicts can't contain multi item objects.
                    error.MultiItemObject => unreachable,
                };
            }

            const dict_metadata = object.dictGetMetadata(new_head);
            dict_metadata.len = old_head.len;
            try object.dictReindex(dest_heap.getHandle(new_dict_idx), null);

            return dest_heap.getHandle(new_dict_idx);
        },
        else => {
            const new_object = try dest_heap.createObject();
            new_object.peek().* = dest_heap.duplicateSingle(handle) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                // We already checked if it was a multi-item object (i.e. a list)
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

/// Guaranteed to be valid, barring OOM.
pub fn getString(handle: Handle) Allocator.Error![:0]const u8 {
    return try handle.getHeap().getLocalString(handle.index);
}

pub fn stringEquals(handle: Handle, value: []const u8) !bool {
    const bytes = try getString(handle);
    return std.mem.eql(u8, bytes, value);
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
        const took_ownership = try heap.setLongString(handle.index, .{ .normal = new_str });
        if (!took_ownership) heap.gpa.free(new_str);
    }
}

/// Get the string to modify (must not write any longer than current len).
/// Not threadsafe.
pub fn getStringMut(handle: Handle) ![:0]u8 {
    switch (Heap.getStringDetails(handle)) {
        .long => |long_str| {
            switch (long_str.string_type) {
                .normal => |normal| return normal,
                .temp => @panic("Can't modify a temp object"),
                .different_capacity => |info| return info.string,
            }
        },
        .normal => {
            const str = handle.peek().str.u.str;
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
                    // If not, somebody else must've won this, so let the caller know.
                    break :blk false;
                }

                const to_set_to_bits: u59 = @bitCast(to_set_to);
                // Preserve type tag from current_head.
                var new_head = current_head & ~str_mask;
                new_head |= to_set_to_bits;

                const res: ?u64 = @cmpxchgWeak(u64, object_head, current_head, new_head, .release, .acquire);

                if (res) |winning_head| {
                    current_head = winning_head;
                    continue;
                } else {
                    // Successfully swapped.
                    break :blk true;
                }
            }
        } else {
            obj.str = to_set_to;
            break :blk true;
        }
    };

    const handle = self.getHandle(index);
    handle.trace("Set string to \"{f}\"", .{handle});

    return success;
}

/// Returns whether the heap took ownership. It may copy the bytes into
/// the heap, so it can succeed while also not taking ownership.
pub fn setStringOwning(handle: Handle, bytes: [:0]u8) error{OutOfMemory}!bool {
    const heap = handle.getHeap();

    if (try heap.setNormalString(handle.index, bytes)) {
        // Successfully set as normal string.
        return false;
    } else {
        return try heap.setLongString(handle.index, .{ .normal = bytes });
    }
}

/// Low-level function. You probably want Heap.setString().
/// Attempts to copy the provided string into the object heap.
/// Returns false if the string is too big.
pub fn setNormalString(self: *Heap, index: u32, bytes: []const u8) !bool {
    if (bytes.len == 0) {
        // No need to check the result of the exchange, as there's nothing to clean up
        assert(self.exchangeString(index, Object.null_string, Object.empty_string));
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
pub fn setLongString(self: *Heap, index: u32, string_type: LongString.Type) Allocator.Error!bool {
    const long_string = &(try self.gpa.alignedAlloc(LongString, LongString.align_type, 1))[0];
    errdefer self.gpa.free(long_string);
    long_string.* = .{ .string_type = string_type };

    const string_header = Object.StrOrPtr{
        .u = .{ .ptr = LongString.toInt(long_string) },
        .is_ptr = true,
    };

    const res = self.exchangeString(index, Object.null_string, string_header);
    return res;
}

const empty_string_value = "";
/// This returns a temporary string. Whenever the object is mutated, it
/// may become invalid.
fn getLocalString(self: *Heap, index: u32) error{OutOfMemory}![:0]const u8 {
    const obj: *Object = self.getLocalObject(index);

    switch (self.getLocalStringDetails(obj.str)) {
        .long => |long_str| {
            return long_str.getString();
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
            break :blk try std.fmt.allocPrintSentinel(self.gpa, "{}", .{obj.body.index}, 0);
        },
        .integer => {
            break :blk try std.fmt.allocPrintSentinel(self.gpa, "{}", .{obj.body.integer}, 0);
        },
        .float => {
            break :blk try std.fmt.allocPrintSentinel(self.gpa, "{}", .{obj.body.float}, 0);
        },
        .bool => {
            break :blk try std.fmt.allocPrintSentinel(self.gpa, "{}", .{@intFromBool(obj.body.bool)}, 0);
        },
        .list => {
            const list = obj.body.list;
            break :blk try getListString(self, index + 1, list.len);
        },
        .dict => {
            const dict = &self.getExtraData(obj.body.dict).dict;
            break :blk try getListString(self, index + 1, dict.len);
        },
        .custom_type => {
            const custom_type = obj.body.custom_type;
            break :blk try custom_types.items[custom_type.type_id].get_string(self, obj);
        },
        .reference => {
            // Intentionally return early, since we should always use
            // the reference's string, not our own.
            return getString(obj.body.reference);
        },
        .script_command => {
            if (builtin.mode == .Debug and state.running_leak_check) {
                const script_command = obj.body.script_command;
                break :blk try std.fmt.allocPrintSentinel(
                    self.gpa,
                    "<script command: args: {}, line: {}>",
                    .{ script_command.arg_count, script_command.line },
                    0,
                );
            } else @panic("Script line is an internal object only");
        },
        .none => {
            if (builtin.mode == .Debug and state.running_leak_check) {
                break :blk try std.fmt.allocPrintSentinel(self.gpa, "<none>", .{}, 0);
            } else {
                last_touched = self.getHandle(index);
                Heap.dumpLastTouchedTrace();
                @panic("Tried to generate a string for .none");
            }
        },
        .marked => {
            if (builtin.mode == .Debug and state.running_leak_check) {
                break :blk try std.fmt.allocPrintSentinel(self.gpa, "<marked>", .{}, 0);
            } else @panic("Tried to generate a string for .marked");
        },
        .string, .source, .script, .expr, .dict_subst, .variable, .upvar, .command => {
            std.debug.panic("{} should always have a string representation", .{obj.tag});
        },
    };

    // Ensure new_str is freed if setStringOwning fails (e.g., OOM during LongString allocation).
    {
        errdefer self.gpa.free(new_str);
        const took_ownership = try setStringOwning(self.getHandle(index), new_str);
        if (!took_ownership) self.gpa.free(new_str);
    }

    // Rerun this function to figure out where the new string is
    return self.getLocalString(index);
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

const StringDetails = union(enum) {
    null: void,
    empty: void,
    normal: [:0]u8,
    long: *align(LongString.align_amt) LongString,
};

pub fn getStringDetails(handle: Handle) StringDetails {
    return handle.getHeap().getLocalStringDetails(handle.peek().str);
}

fn getLocalStringDetails(heap: *Heap, str_or_ptr: Object.StrOrPtr) StringDetails {
    // Normal string or long string?
    if (str_or_ptr.is_ptr) {
        // Convert to LongString ptr (guaranteed to be non-null).
        return .{
            .long = LongString.fromInt(str_or_ptr.u.ptr),
        };
    } else {
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
}

pub const LongString = struct {
    /// At what point should we switch to using a long string?
    /// Whenever the string length >= split_point
    pub const split_point = 100_000;
    pub const align_amt = 128;
    pub const align_type = std.mem.Alignment.fromByteUnits(align_amt);

    /// Long strings are special in that they can have
    /// extended properties (mmaping is in the plans,
    /// for example). Since it has special properties,
    /// we have to track them so it can be freed correctly.
    pub const Type = union(enum) {
        normal: [:0]u8,
        /// A temporary string has its bytes managed by someone else,
        /// so when this LongString is freed, we won't free the string.
        temp: [:0]const u8,
        /// If the string was allocated with a different capacity
        /// than its current reported length, set this field
        different_capacity: struct {
            string: [:0]u8,
            original_capacity: u64,
        },
    };

    string_type: Type,
    /// Length has not been determined if == maxInt(u64). Be sure to use
    /// atomics!
    utf8_length: u64 = std.math.maxInt(u64),
    hash: struct {
        value: ?u256 = null,
        mutex: memutil.Mutex = .{},
    } = .{},
    ref_count: usize = 1,

    pub fn fromInt(int: u58) *align(align_amt) LongString {
        return @ptrFromInt(int << 6);
    }

    pub fn toInt(ptr: *align(align_amt) LongString) u58 {
        return @intCast(@intFromPtr(ptr) >> 6);
    }

    pub fn getHash(self: *align(align_amt) LongString) u256 {
        self.hash.mutex.lock();
        defer self.hash.mutex.unlock();

        if (self.hash.value) |hash| {
            return hash;
        } else {
            var out: [32]u8 = @splat(0);
            std.crypto.hash.Blake3.hash(self.getString(), &out, .{});

            const hash: u256 = @bitCast(out);
            self.hash.value = hash;
            return hash;
        }
    }

    pub fn getUtf8Length(self: *align(align_amt) LongString) ?u64 {
        const value = @atomicLoad(u64, &self.utf8_length, .monotonic);
        if (value == std.math.maxInt(u64)) return null else return value;
    }

    /// Value is u64, not ?u64, since utf8 length should not ever
    /// change (excluding LongString temp strings).
    pub fn setUtf8Length(self: *align(align_amt) LongString, value: u64) void {
        assert(value != std.math.maxInt(u64));
        @atomicStore(u64, &self.utf8_length, value, .monotonic);
    }

    pub fn getString(self: *align(align_amt) LongString) [:0]const u8 {
        switch (self.string_type) {
            .normal => |string| return string,
            .temp => |temp| return temp,
            .different_capacity => |info| return info.string,
        }
    }

    pub fn incrRefCount(self: *align(align_amt) LongString) void {
        incrRefCountOf(usize, &self.ref_count, options.threading);
    }

    pub fn decrRefCount(self: *align(align_amt) LongString, gpa: Allocator) void {
        if (decrRefCountOf(usize, &self.ref_count, options.threading)) {
            self.freeInner(gpa);
        }
    }

    pub fn freeInner(self: *align(align_amt) LongString, gpa: Allocator) void {
        switch (self.string_type) {
            .normal => |string| gpa.free(string),
            .different_capacity => |info| {
                gpa.free(info.string.ptr[0..info.original_capacity :0]);
            },
            .temp => {
                // We don't want to free the string, as it's managed by someone else.
            },
        }

        gpa.destroy(self);
    }
};

pub fn createExtraData(self: *Heap) !ExtraDataIndex {
    self.mem_mgmt_mutex.lock();
    defer self.mem_mgmt_mutex.unlock();

    const new_index = try self.extra.create(self.heapAlloc());
    if (new_index >= object_heap_max_count) return error.OutOfMemory;

    return @enumFromInt(new_index);
}

pub fn getExtraData(self: *Heap, index: ExtraDataIndex) *ExtraData {
    return &self.extra.items[@intFromEnum(index)];
}

pub fn destroyExtraData(self: *Heap, index: ExtraDataIndex) void {
    self.mem_mgmt_mutex.lock();
    defer self.mem_mgmt_mutex.unlock();

    self.extra.destroy(@intFromEnum(index));
}

pub fn initGlobals(gpa: Allocator) !void {
    state.mutex.lock();
    defer state.mutex.unlock();

    state.gpa = gpa;
    custom_types = try .initWithCapacity(gpa, if (options.threading) cfg.max_custom_types else 32);
    errdefer custom_types.deinit(gpa);

    script_metadata = try .initWithCapacity(gpa, if (options.threading) cfg.max_scripts else 32);
    errdefer script_metadata.deinit(gpa);

    // Create null script. TODO do we need a null script?
    assert(try script_metadata.create(gpa) == 0);
    state.initialized = true;
}

pub fn initHeap(gpa: Allocator) !void {
    const slot_index = blk: {
        state.mutex.lock();
        defer state.mutex.unlock();

        assert(state.initialized);

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
        const new_heap = &heaps[slot_index];
        try new_heap.init(gpa);
        local_heap = new_heap;
    } else {
        return error.OutOfMemory;
    }
}

pub fn deinitAll() void {
    state.mutex.lock();
    const heap_count = state.next_open_heap;
    state.next_open_heap = 0;
    state.mutex.unlock();

    // Deinit heaps without holding the mutex, as they may lock.
    for (heaps[0..heap_count]) |*heap| {
        heap.deinit();
    }

    // Deinit global state.
    state.mutex.lock();
    if (state.initialized) {
        script_metadata.deinit(state.gpa);
        custom_types.deinit(state.gpa);
        state.initialized = false;
    }
    state.mutex.unlock();
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
    defer Heap.testFinish();
    var heap = try Heap.testStart(ta);

    // Number object
    const obj = try heap.createObject();
    defer obj.decrRefCount();
    var ref = obj.peek();
    ref.tag = .integer;
    ref.body.integer = 10;

    const new_obj = try heap.duplicate(obj);
    const new_ref = new_obj.peek();
    defer new_obj.decrRefCount();

    try expectEqual(.integer, new_ref.tag);
    try expectEqual(10, new_ref.body.integer);

    // try borrowing
    new_obj.incrRefCount();
    try expectEqual(2, new_obj.debugRefCount());

    new_obj.decrRefCount();
    try expectEqual(1, heap.objects.get(new_obj.index).ref_count);
}

test "get string" {
    const ta = std.testing.allocator;
    defer Heap.testFinish();
    var heap = try Heap.testStart(ta);

    const obj = try heap.createObject();
    defer obj.decrRefCount();
    var ref = obj.peek();
    ref.tag = .integer;
    ref.body.integer = 10;

    try expectEqualSlices(u8, "10", try getString(obj));
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

/// Returns true if count has reached zero. Multithreaded safe.
pub fn decrRefCountOf(comptime T: type, ref: *T, is_atomic: bool) bool {
    var after_sub: T = undefined;
    if (is_atomic) {
        const before_sub = @atomicRmw(T, ref, .Sub, 1, .release);
        after_sub = before_sub - 1;

        if (after_sub == 0) {
            _ = @atomicLoad(T, ref, .acquire);
        }
    } else {
        // HACK: once I figure out how to register a panic handler I don't need this.
        if (ref.* == 0) dumpLastTouchedTrace();
        ref.* -= 1;
        after_sub = ref.*;
    }

    return after_sub == 0;
}

pub fn testStart(gpa: Allocator) !*Heap {
    try initGlobals(gpa);
    try initHeap(gpa);

    return local_heap;
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
    // Make sure that all the global script ids were freed.
    if (script_metadata.count > 1) {
        leaked = true;
        std.debug.print("Script IDs leaked!\n", .{});
        script_metadata.dumpLeaked(state.gpa, "ID: {}, contents: {}\n") catch unreachable;
    }

    state.running_leak_check = false;
    state.mutex.unlock();
}

pub fn testFinish() void {
    Heap.leakCheckAll();
    Heap.deinitAll();
}

pub fn leakCheck(heap: *Heap) !bool {
    return leakCheckWithMode(heap, .dot_graph);
}

pub fn leakCheckWithMode(heap: *Heap, mode: enum { normal, dot_graph }) !bool {
    // Make sure to free any parsed scripts, as they're allowed to leak (they
    // have references to heap objects, so it will cause a false positive).
    heap.clearParsedScripts();

    // Go through once to print the summary, then print each individual trace.
    const skip_count = special_object_count + interned_string_count;
    for (heap.objects.items(.metadata)[skip_count..]) |metadata| {
        if (metadata.in_use) break;
    } else return false;

    switch (mode) {
        .normal => try leakDumpNormal(heap, skip_count),
        .dot_graph => {
            try leakDumpNormal(heap, skip_count);
            try leakDumpDotGraph(heap, skip_count);
        },
    }

    return true;
}

fn leakDumpNormal(heap: *Heap, skip_count: usize) !void {
    for (heap.objects.items(.metadata)[skip_count..], skip_count..) |metadata, i| {
        if (metadata.in_use) {
            const handle = heap.getHandle(@intCast(i));
            std.debug.print("Leaked {}, index {}, order: {}, ref count {}, \"{s}\"\n", .{
                handle.peek().tag,
                i,
                handle.getMetadata().order,
                handle.debugRefCount(),
                try getString(handle),
            });
        }
    }

    if (options.trace_mem) {
        std.debug.print("\n===== Leak details =====\n\n", .{});

        for (heap.objects.items(.metadata)[skip_count..], skip_count..) |metadata, i| {
            if (metadata.in_use) {
                const handle = heap.getHandle(@intCast(i));
                std.debug.print("Trace for {}, index {}, ref count {}, \"{s}\"\n", .{
                    handle.peek().tag,
                    i,
                    handle.debugRefCount(),
                    try getString(handle),
                });

                const trace = heap.objects.get(i).trace;
                trace.dump();
                if (trace.index > 0) std.debug.print("\n\n", .{});
            }
        }
    }
}

// Dot rendering is 95% LLM generated.
fn escapeDotString(str: []const u8, writer: *std.Io.Writer) !void {
    for (str) |c| switch (c) {
        '"', '\\' => try writer.print("\\{c}", .{c}),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0...8, 11...12, 14...31, 127 => try writer.print("\\x{X:0>2}", .{c}),
        else => try writer.writeByte(c),
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
        .script => "lavender",
        .expr => "thistle",
        .source => "peachpuff",
        .command, .script_command => "khaki",
        .variable, .upvar => "lightcyan",
        .custom_type => "tan",
        else => "white",
    };
}

fn renderDotNodeLabel(stderr: *std.Io.Writer, handle: Handle, index: u32, max_str_len: u32) !void {
    const obj = handle.peek();
    const str = try getString(handle);
    const truncated_str = if (str.len > max_str_len) str[0..max_str_len] else str;

    try stderr.print("idx: {} | ", .{index});
    try stderr.print("{s} | ", .{@tagName(obj.tag)});
    try stderr.print("rc: {} | ", .{handle.debugRefCount()});
    try stderr.writeAll("\\\"");
    try escapeDotString(truncated_str, stderr);
    if (str.len > max_str_len) try stderr.writeAll("...");
    try stderr.writeAll("\\\"");
}

fn renderCollectionSubgraph(heap: *Heap, stderr: *std.Io.Writer, handle: Handle, index: u32) !void {
    const obj = handle.peek();

    // Get the allocation size to include unallocated slots in the subgraph.
    const allocated_len = memutil.getOrderSize(handle.getMetadata().order) - 1;

    // Get the actual used length for the label.
    const used_len = if (obj.tag == .list)
        obj.body.list.len
    else
        object.dictGetMetadata(handle).len;

    const str = try getString(handle);
    const max_str_len = 40;
    const truncated_str = if (str.len > max_str_len) str[0..max_str_len] else str;

    // Subgraph header.
    try stderr.print("  subgraph cluster_{} {{\n", .{index});
    try stderr.print("    label=\"{s} obj{} (rc:{}, {}/{} used): ", .{ @tagName(obj.tag), index, handle.debugRefCount(), used_len, allocated_len });
    try escapeDotString(truncated_str, stderr);
    if (str.len > max_str_len) try stderr.writeAll("...");
    try stderr.writeAll("\";\n");
    try stderr.print("    style=outlined;\n", .{});
    try stderr.print("    fillcolor=\"{s}\";\n", .{if (obj.tag == .list) "lightblue1" else "lightgreen1"});
    try stderr.writeAll("    node [style=filled];\n\n");

    // Collection head node.
    try stderr.print("    obj{} [label=\"{{", .{index});
    try stderr.print("HEAD | idx: {} | ", .{index});
    try stderr.print("{s} | rc: {}}}\", fillcolor=\"{s}\"];\n", .{ @tagName(obj.tag), handle.debugRefCount(), getTagColor(obj.tag) });

    // Collection items (all allocated slots, including unused ones).
    for (0..allocated_len) |offset| {
        const item_idx = index + 1 + offset;
        const item_handle = heap.getHandle(@intCast(item_idx));

        try stderr.print("    obj{} [label=\"{{", .{item_idx});
        try renderDotNodeLabel(stderr, item_handle, @intCast(item_idx), max_str_len);
        try stderr.print("}}\", fillcolor=\"{s}\"];\n", .{getTagColor(item_handle.peek().tag)});
    }

    try stderr.writeAll("  }\n\n");
}

fn renderObjectEdges(heap: *Heap, stderr: *std.Io.Writer, handle: Handle, index: u32) !void {
    const obj = handle.peek();

    switch (obj.tag) {
        .list => {
            const len_including_nones = memutil.getOrderSize(handle.getMetadata().order) - 1;
            for (0..len_including_nones) |item_idx| {
                const item_handle = object.listItem(handle, @intCast(item_idx));
                try stderr.print("  obj{} -> obj{} [label=\"[{}]\"];\n", .{ index, item_handle.index, item_idx });
            }
        },
        .dict => {
            const dict_metadata = object.dictGetMetadata(handle);
            var item_idx: u32 = 0;
            while (item_idx < dict_metadata.len) : (item_idx += 2) {
                const key_handle = object.dictItem(handle, item_idx);
                const val_handle = object.dictItem(handle, item_idx + 1);

                try stderr.print("  obj{} -> obj{} [label=\"key\", color=blue];\n", .{ index, key_handle.index });
                try stderr.print("  obj{} -> obj{} [label=\"val\", color=green];\n", .{ index, val_handle.index });
            }
        },
        .reference => {
            const ref_handle = obj.body.reference;
            try stderr.print("  obj{} -> obj{} [label=\"ref\", color=red, style=dashed];\n", .{ index, ref_handle.index });
        },
        .source => {
            if (obj.body.source.file_name_obj.getIndex()) |file_name_index| {
                try stderr.print("  obj{} -> obj{} [label=\"file\"];\n", .{ index, file_name_index });
            }
        },
        .dict_subst => {
            try stderr.print("  obj{} -> obj{} [label=\"var\"];\n", .{ index, obj.body.dict_subst.var_name_index });
            try stderr.print("  obj{} -> obj{} [label=\"val\"];\n", .{ index, obj.body.dict_subst.dict_value_index });
        },
        .command => {
            if (!obj.body.command.in_global_namespace) {
                const extra_data = heap.getExtraData(obj.body.command.u.other_namespace).command;
                try stderr.print("  obj{} -> obj{} [label=\"ns\"];\n", .{ index, extra_data.namespace });
            }
        },
        .upvar => {
            const upvar = &heap.getExtraData(obj.body.upvar).upvar;
            switch (upvar.name) {
                .normal => |var_name| {
                    try stderr.print("  obj{} -> obj{} [label=\"var\"];\n", .{ index, var_name });
                },
                .dict_sugar => |dict_names| {
                    try stderr.print("  obj{} -> obj{} [label=\"dict\"];\n", .{ index, dict_names.dict_name_index });
                    try stderr.print("  obj{} -> obj{} [label=\"key\"];\n", .{ index, dict_names.dict_key_index });
                },
            }
        },
        else => {},
    }
}

fn leakDumpDotGraph(heap: *Heap, skip_count: usize) !void {
    std.debug.print("digraph LeakGraph {{\n", .{});
    std.debug.print("  rankdir=LR;\n", .{});
    std.debug.print("  node [shape=record];\n", .{});
    std.debug.print("  compound=true;\n\n", .{});

    var buf: [1]u8 = @splat(0);
    var stderr = std.debug.lockStderrWriter(&buf);
    defer std.debug.unlockStdErr();

    // First pass: output collections as subgraphs with their items grouped.
    for (heap.objects.items(.metadata)[skip_count..], skip_count..) |metadata, i| {
        if (!metadata.in_use) continue;

        const handle = heap.getHandle(@intCast(i));
        const obj = handle.peek();

        if (obj.tag == .list or obj.tag == .dict) {
            try renderCollectionSubgraph(heap, stderr, handle, @intCast(i));
        }
    }

    // Second pass: output standalone nodes (not part of any collection).
    for (heap.objects.items(.metadata)[skip_count..], skip_count..) |metadata, i| {
        if (!metadata.in_use) continue;

        const handle = heap.getHandle(@intCast(i));
        const obj = handle.peek();

        // Skip collections (already output as subgraphs) and collection items.
        if (obj.tag == .list or obj.tag == .dict) continue;
        if (!handle.isAllocHead()) continue;

        try stderr.print("  obj{} [label=\"{{", .{i});
        try renderDotNodeLabel(stderr, handle, @intCast(i), 60);
        try stderr.print("}}\", fillcolor=\"{s}\", style=filled];\n", .{getTagColor(obj.tag)});
    }

    try stderr.writeAll("\n");

    // Third pass: output all edges.
    for (heap.objects.items(.metadata)[skip_count..], skip_count..) |metadata, i| {
        if (!metadata.in_use) continue;
        try renderObjectEdges(heap, stderr, heap.getHandle(@intCast(i)), @intCast(i));
    }

    try stderr.print("}}\n", .{});
}

pub fn dumpLastTouchedTrace() void {
    if (last_touched) |val| {
        val.getHeap().trace_mutex.lock();
        defer val.getHeap().trace_mutex.unlock();

        val.getHeap().objects.get(val.index).trace.dump();
    } else {
        std.debug.print("No last leaked object\n", .{});
    }
}

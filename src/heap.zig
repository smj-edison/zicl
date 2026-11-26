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
const hashutil = @import("hashutil.zig");
const objects = @import("objects.zig");
const leak_check = @import("leak_check.zig");
const regex = @import("regex.zig");
const Capability = @import("Capability.zig");
const Interp = @import("Interp.zig");
const Threaded = @import("vendor/Threaded.zig");

pub var initialized: bool = false;
/// Use to lock `custom_types` or `script_metadata` when adding or removing
/// (no need to lock when using).
pub var init_mutex: std.Io.Mutex = .init;
/// Used to turn some panics into useful messages.
pub var running_leak_check: bool = false;

pub var global_gpa: mem.Allocator = undefined;
/// Backing of `local_arena`. Used for snapshotting + rewinding to
/// have a scoped arena. Currently snapshotted and rewound at eval boundaries.
pub threadlocal var local_arena_instance: memutil.ScopedArena = undefined;
pub threadlocal var local_arena: mem.Allocator = undefined;
pub var global_io: std.Io = undefined;

pub const EnvironAndOwnership = union(enum) {
    owned: std.process.Environ.Map,
    shared: *const std.process.Environ.Map,

    pub fn get(self: *EnvironAndOwnership) *const std.process.Environ.Map {
        switch (self.*) {
            .owned => |*owned| return owned,
            .shared => |shared| return shared,
        }
    }

    pub fn deinit(self: *EnvironAndOwnership) void {
        switch (self.*) {
            .owned => |*owned| owned.deinit(),
            .shared => {},
        }
    }
};
pub var environ: EnvironAndOwnership = .{ .shared = undefined };

/// Used across multiple tests to avoid the overhead of duplicating the
/// environ per test.
var test_environ: ?struct {
    arena: std.heap.ArenaAllocator,
    map: std.process.Environ.Map,
} = if (builtin.is_test) null else @compileError("not testing");
/// Get the test environment, which is lazily generated.
fn getTestEnviron() *const std.process.Environ.Map {
    if (!builtin.is_test) @compileError("not testing");

    if (test_environ) |*val| return &val.map;
    // Use the heap allocator as it will outlive the provided gpa.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const map = std.testing.environ.createMap(arena.allocator()) catch @panic("oom");
    test_environ = .{ .arena = arena, .map = map };

    return &test_environ.?.map;
}
pub var lazy_fn_registry: LazyFnRegistry = .{};
pub var registered_hashes: hashutil.HashRegistry = .{};

var trace_mutex: std.Io.Mutex = .init;
/// Preallocated fallback used by `[catch]` when a script OOMs and building
/// the real opts dict also OOMs. Built up front precisely because that path
/// cannot allocate, and the `[try]` logic needs a real dictionary rather than
/// something that would have to be shimmered into one.
pub var oom_error_options_dict: ?Value = null;

/// Settings an embedder can override at startup, grouped by the subsystem that
/// reads them. Every field defaults, so `.{}` is the ordinary call. Named
/// `Config` rather than `Options` because `options` here is the build-time
/// options module.
pub const Config = struct {
    capability: Capability.Options = .{},
};

pub const EvalError = error{
    OutOfMemory,
    EvalError,
    PropagateResult,
    Break,
    Continue,
    Exit,
};
pub const Error = EvalError || error{
    WrongUsage,
    Tailcall,
};

/// Return code values matching Tcl's convention.
///
/// Backed by c_int rather than u8 so that functions that return
/// to C callers don't read uninitialzed bits.
pub const ReturnCode = enum(c_int) {
    ok = 0,
    @"error" = 1,
    oom = 2,
    @"return" = 3,
    @"break" = 4,
    @"continue" = 5,
    exit = 6,
    usage = 7,
    tailcall = 8,

    pub fn fromErrorUnion(value: Error!void) ReturnCode {
        if (value) {
            return .ok;
        } else |err| {
            return ReturnCode.fromError(err);
        }
    }

    pub fn fromError(err: Error) ReturnCode {
        return switch (err) {
            error.EvalError => .@"error",
            error.PropagateResult => .@"return",
            error.OutOfMemory => .oom,
            error.Break => .@"break",
            error.Continue => .@"continue",
            error.Exit => .exit,
            error.WrongUsage => .usage,
            error.Tailcall => .tailcall,
        };
    }

    pub fn toError(self: ReturnCode) Error!void {
        switch (self) {
            .ok => return,
            .@"error" => return error.EvalError,
            .@"return" => return error.PropagateResult,
            .@"break" => return error.Break,
            .@"continue" => return error.Continue,
            .exit => return error.Exit,
            .oom => return error.OutOfMemory,
            .usage => return error.WrongUsage,
            .tailcall => return error.Tailcall,
        }
    }
};

/// Initialize global heap state. Must be called once per process (or test).
pub fn initGlobals(
    gpa: Allocator,
    io: std.Io,
    env: EnvironAndOwnership,
    config: Config,
) !void {
    var env_mut = env;
    errdefer env_mut.deinit();

    init_mutex.lockUncancelable(io);
    defer init_mutex.unlock(io);

    if (initialized) return error.AlreadyInitialized;

    global_gpa = gpa;
    errdefer global_gpa = undefined;
    global_io = io;
    errdefer global_io = undefined;
    environ = env_mut;
    errdefer environ = undefined;

    lazy_fn_registry = .{};
    registered_hashes = .{};

    // We need to make sure the leak checker is initialized, because
    // we create objects in this function.
    try leak_check.initThread();

    try regex.initGlobals();
    errdefer regex.deinitGlobals();
    try Capability.initGlobals(config.capability);
    errdefer Capability.deinitGlobals();

    // Shared across threads, so it ref counts atomically. Being cross-thread
    // also freezes it, which is what we want for a value every `[catch]` may
    // hand out: a caller that mutates it copies instead.
    const oom_dict = try objects.Dictionary.new(&.{
        InternedString.newValue("-code"),      Value.newInt(1),
        InternedString.newValue("-level"),     Value.newInt(0),
        InternedString.newValue("-errorcode"), InternedString.newValue("ZICL OOM"),
    });
    oom_dict.asHead().makeCrossthread();
    oom_error_options_dict = oom_dict.asHead().asValue();

    initialized = true;
}

/// Drop the preallocated fallback dict. Separate from `deinitGlobals` because the
/// leak check has to run after it, and `deinitGlobals` tears the leak check down.
/// Only safe once no script can run again: `[catch]` reaches for this dict with
/// `.?`, so a caller that frees it and keeps evaluating panics on the next OOM.
pub fn freeOomErrorOptionsDict() void {
    if (oom_error_options_dict) |dict| dict.dropReference();
    oom_error_options_dict = null;
}

/// Tear down global heap state. After this call, `initGlobals` may be called again.
pub fn deinitGlobals() void {
    init_mutex.lockUncancelable(global_io);
    defer init_mutex.unlock(global_io);

    if (!initialized) return;

    freeOomErrorOptionsDict();

    leak_check.deinit();
    Capability.deinitGlobals();
    regex.deinitGlobals();

    lazy_fn_registry.deinit(global_gpa);
    registered_hashes.entries.deinit(global_gpa);
    environ.deinit();

    initialized = false;
}

pub fn initThread() !void {
    local_arena_instance = memutil.ScopedArena.init(global_gpa);
    local_arena = local_arena_instance.allocator();
    try leak_check.initThread();
}

pub fn deinitThread() void {
    leak_check.deinitThread();
    local_arena_instance.deinit();
    local_arena = undefined;
}

/// Tests run on the vendored `Threaded`, the same `Io` that libzicl uses,
/// rather than the test runner's `std.Io.Threaded`.
var test_threaded: if (builtin.is_test) Threaded else void = undefined;

/// If `env` is provided, caller is responsible for cleanup.
pub fn testStart(gpa: Allocator, env: ?EnvironAndOwnership) !void {
    // Not `gpa`, since that fails on purpose during allocation-failure sweeps,
    // and `Threaded` only allocates for async tasks, which aren't under test.
    test_threaded = .init(std.testing.allocator, .{ .environ = std.testing.environ });
    errdefer test_threaded.deinit();
    _ = Threaded.initThread();
    errdefer Threaded.deinitThread();

    try initGlobals(gpa, test_threaded.io(), env orelse .{ .shared = getTestEnviron() }, .{});
    errdefer deinitGlobals();
    try initThread();
}

pub fn testFinish() void {
    // Ahead of the leak check, or the preallocated fallback is still live and
    // reports as a leak in every single test.
    freeOomErrorOptionsDict();
    if (options.trace_mem) leak_check.dumpLeaks() catch {};
    deinitThread();
    deinitGlobals();
    Threaded.deinitThread();
    test_threaded.deinit();
}

pub export fn dumpLastTouchedTrace(fd: i32) void {
    leak_check.dumpLastTouchedTrace(fd);
}

pub export fn isHeapInitialized() bool {
    return initialized;
}

/// Signature for a lazy native command initializer.
pub const LazyRegisterFn = *const fn (interp: *Interp) callconv(.c) void;

const LazyFnEntry = struct {
    init_fn: LazyRegisterFn,
    /// The lazy registry makes sure that if a second function is registered
    /// with a pre-existing name, that error.DuplicateLazyFn is returned.
    /// But, it's possible that a .so is loaded twice, each time loading
    /// a function with the same name. This would normally error, so we
    /// avoid that error be keeping track of what library a function came
    /// from. If a second function is registered with the same name _and_
    /// the same library, we just ignore it, since it's previously been
    /// loaded.
    library: []const u8,
};

/// Registry for lazily loaded functions. Will call `init_fn` when the function doesn't
/// exist as a nativefn.
pub const LazyFnRegistry = struct {
    mutex: std.Io.Mutex = .init,
    entries: std.StringHashMapUnmanaged(LazyFnEntry) = .empty,

    /// error.DuplicateLazyFn is returned if a function name is registered twice,
    /// but only if it's from a different library (this is so library loading
    /// is idempotent).
    pub fn register(self: *LazyFnRegistry, gpa: Allocator, name: []const u8, library: []const u8, init_fn: LazyRegisterFn) !void {
        self.mutex.lockUncancelable(global_io);
        defer self.mutex.unlock(global_io);
        if (self.entries.get(name)) |existing| {
            if (std.mem.eql(u8, existing.library, library)) return;
            return error.DuplicateLazyFn;
        }

        const name_owned = try global_gpa.dupe(u8, name);
        errdefer global_gpa.free(name_owned);
        const library_owned = try global_gpa.dupe(u8, library);
        errdefer global_gpa.free(library_owned);
        try self.entries.put(gpa, name_owned, .{ .init_fn = init_fn, .library = library_owned });
    }

    pub fn get(self: *LazyFnRegistry, name: []const u8) ?LazyRegisterFn {
        self.mutex.lockUncancelable(global_io);
        defer self.mutex.unlock(global_io);
        return if (self.entries.get(name)) |entry| entry.init_fn else null;
    }

    pub fn deinit(self: *LazyFnRegistry, gpa: Allocator) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            global_gpa.free(entry.key_ptr.*);
            global_gpa.free(entry.value_ptr.library);
        }
        self.entries.deinit(gpa);
    }
};

pub const InternedString = extern struct {
    ptr: [*:0]const u8,
    len: u16,

    /// `bytes` is never copied or freed, so it must live for the rest of the
    /// program, such as a string literal or `@errorName`.
    pub fn new(bytes: [:0]const u8) InternedString {
        assert(bytes.len <= std.math.maxInt(u16));
        return .{ .ptr = bytes.ptr, .len = @intCast(bytes.len) };
    }

    /// `bytes` is never copied or freed, so it must live for the rest of the
    /// program, such as a string literal or `@errorName`.
    pub fn newValue(bytes: [:0]const u8) Value {
        assert(bytes.len <= std.math.maxInt(u16));
        return .fromRep(.{
            .tag = .interned,
            .as = .{ .interned = bytes.ptr },
            .interned_string_len = @intCast(bytes.len),
        });
    }

    pub fn asSlice(interned: InternedString) [:0]const u8 {
        return interned.ptr[0..interned.len :0];
    }
};

const ValueRep = extern struct {
    comptime {
        assert(@sizeOf(ValueRep) <= 16);
    }

    pub const Tag = enum(u8) {
        none,
        pointer,
        boolean,
        integer,
        float,
        interned,
        external = 255,
    };

    as: extern union {
        pointer: *Object,
        float: f64,
        integer: i64,
        boolean: bool,
        interned: [*:0]const u8,
    },
    /// Used to store the interned string length, in the case that the
    /// `tag` type is .interned. I couldn't get the C ABI to keep
    /// `ValueRep`'s size inside two words otherwise.
    interned_string_len: u16 = 0,
    tag: Tag,

    pub fn asPtr(rep: ValueRep) ?*Object {
        if (rep.tag == .pointer) return rep.as.pointer;
        return null;
    }

    pub fn asInlineInt(rep: ValueRep) ?i64 {
        if (rep.tag == .integer) return rep.as.integer;
        return null;
    }

    pub fn asInlineFloat(rep: ValueRep) ?f64 {
        if (rep.tag == .float) return rep.as.float;
        return null;
    }

    pub fn asInlineBool(rep: ValueRep) ?bool {
        if (rep.tag == .boolean) return rep.as.boolean;
        return null;
    }

    pub fn asInterned(rep: ValueRep) ?InternedString {
        if (rep.tag == .interned) return rep.as.interned;
    }

    /// Must be a primitive.
    pub fn box(rep: ValueRep) !*Object {
        return switch (rep.tag) {
            .none => unreachable,
            .pointer => unreachable,
            .integer => (try objects.Integer.newBoxed(rep.as.integer)).asHead(),
            .boolean => try objects.String.newObject(if (rep.as.boolean) "true" else "false"),
            .interned => try objects.String.newObject(rep.as.interned[0..rep.interned_string_len]),
            .float => (try objects.Float.newBoxed(rep.as.float)).asHead(),
            .external => @panic("external value used"),
        };
    }

    /// This never falsely says that two values are equal if they're not,
    /// but it may say two values aren't the same when they are.
    pub fn quickEquals(a: ValueRep, b: ValueRep) bool {
        switch (a.tag) {
            .integer => {
                switch (b.tag) {
                    .integer => return a.as.integer == b.as.integer,
                    .float, .boolean => return false,
                    else => {
                        // Still need to fall through, because an interned string
                        // might contain a string value equal to a's value.
                    },
                }
            },
            .float => {
                switch (b.tag) {
                    .float => return a.as.float == b.as.float,
                    .integer, .boolean => return false,
                    else => {},
                }
            },
            .boolean => {
                switch (b.tag) {
                    .boolean => return a.as.boolean == b.as.boolean,
                    .integer, .float => return false,
                    else => {},
                }
            },
            .interned => {
                switch (b.tag) {
                    .interned => if (a.as.interned == b.as.interned) return true,
                    else => {},
                }
                // If the two value string pointers weren't identical, they may
                // be equal strings, if one pointer came from a different
                // source. Hence, we fall through.
            },
            .pointer => {
                switch (b.tag) {
                    .pointer => if (a.as.pointer == b.as.pointer) return true,
                    else => {},
                }
            },
            .none => return b.tag == .none,
            .external => return false,
        }
        return false;
    }
};

pub const interned_empty_string = InternedString.newValue("");
pub const OptionalValue = extern struct {
    pub const none: OptionalValue = .{ .raw = .{ .tag = .none, .as = undefined } };

    raw: ValueRep,

    pub fn isNone(optional: OptionalValue) bool {
        return optional.raw.tag == .none;
    }

    pub fn isSome(optional: OptionalValue) bool {
        return !optional.isNone();
    }

    pub fn asValue(optional: OptionalValue) ?Value {
        switch (optional.raw.tag) {
            .none => return null,
            else => return Value.fromRep(optional.raw),
        }
    }

    pub fn fromValue(value: ?Value) OptionalValue {
        if (value) |val| return val.asOptional();
        return .{ .raw = .{ .tag = .none, .as = undefined } };
    }

    pub fn takeReference(optional: OptionalValue) OptionalValue {
        if (optional.asValue()) |val| return val.takeReference().asOptional();
        return .none;
    }

    pub fn makeCrossthread(optional: OptionalValue) void {
        const val = optional.asValue() orelse return;
        const obj = val.asPtr() orelse return;
        obj.makeCrossthread();
    }

    pub fn dropReference(optional: OptionalValue) void {
        if (optional.asValue()) |val| val.dropReference();
    }

    pub fn orElse(optional: OptionalValue, otherwise: Value) Value {
        return optional.asValue() orelse otherwise;
    }

    pub fn orEmpty(optional: OptionalValue) Value {
        return optional.orElse(interned_empty_string);
    }

    pub fn swap(ref: *OptionalValue, new: Value) void {
        if (ref.asValue()) |obj| obj.dropReference();
        ref.* = new.asOptional();
    }

    pub fn swapWithNone(ref: *OptionalValue) void {
        if (ref.asValue()) |val| val.dropReference();
        ref.* = .none;
    }
};

pub const Value = extern struct {
    raw: ValueRep,

    pub fn asOptional(value: Value) OptionalValue {
        return .{ .raw = value.raw };
    }

    pub fn fromRep(rep: ValueRep) Value {
        assert(rep.tag != .none);
        return .{ .raw = rep };
    }

    pub fn asPtr(value: Value) ?*Object {
        return value.raw.asPtr();
    }

    pub fn asInlineInt(value: Value) ?i64 {
        return value.raw.asInlineInt();
    }

    pub fn asInlineFloat(value: Value) ?f64 {
        return value.raw.asInlineFloat();
    }

    pub fn asInlineBool(value: Value) ?bool {
        return value.raw.asInlineBool();
    }

    pub fn asType(value: Value, T: type) ?*T {
        if (value.asPtr()) |obj| return obj.asType(T);
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
    }

    pub fn asMutableInPlace(value: Value, T: type, det: ?*objects.ErrorDetails) !?*T {
        if (value.canMutate()) {
            if (value.asType(T)) |as_type| return as_type;

            var shim: objects.Shimmerable = .{ .original = value };
            _ = try T.shimmerFrom(det, &shim);

            if (shim.shimmered.isSome()) {
                // Something went wonky with the shimmer function not
                // shimmering in place, so we'll fall back to having
                // the user handle this.
                shim.discardChanges();
                return null;
            } else {
                assert(value.canMutate());
                return value.asType(T).?;
            }
        } else return null;
    }

    pub fn incrRefCount(value: Value) void {
        if (value.asPtr()) |obj| obj.incrRefCount();
    }

    pub fn takeReference(value: Value) Value {
        value.incrRefCount();
        return value;
    }

    pub fn dropReference(value: Value) void {
        if (value.asPtr()) |obj| obj.dropReference();
    }

    pub fn duplicate(value: Value) !Value {
        if (value.asPtr()) |obj| {
            return (try obj.duplicate()).asValue();
        } else {
            return value;
        }
    }

    pub fn duplicateAsBoxed(value: Value) !*Object {
        if (value.asPtr()) |obj| {
            return try obj.duplicate();
        } else {
            return try value.raw.box();
        }
    }

    /// Duplicate `value` and shimmer the copy to `T`, returning a `*T` the
    /// caller owns and may mutate. Use this for the copy-on-write half of a
    /// mutation, where `asMutableInPlace` returned null.
    pub fn duplicateAsType(value: Value, T: type, det: ?*objects.ErrorDetails) !*T {
        var shim: objects.Shimmerable = .{ .original = value };
        defer shim.discardChanges();
        return try shim.getMutable(T, det);
    }

    pub fn swap(ref: *Value, new: Value) void {
        const old = ref.*;
        ref.* = new;
        old.dropReference();
    }

    pub fn makeCrossthread(value: Value) void {
        if (value.asPtr()) |obj| {
            if (obj.metadata.cross_thread) return;
            obj.makeCrossthread();
        }
    }

    pub fn newInt(value: i64) Value {
        return .{ .raw = .{ .tag = .integer, .as = .{ .integer = value } } };
    }

    pub fn newFloat(value: f64) Value {
        return .{ .raw = .{ .tag = .float, .as = .{ .float = value } } };
    }

    pub fn newBool(value: bool) Value {
        return .{ .raw = .{ .tag = .boolean, .as = .{ .boolean = value } } };
    }

    pub fn getString(value: Value) ![:0]const u8 {
        switch (value.raw.tag) {
            .none => unreachable,
            .float => {
                var buf: [350]u8 = undefined;
                const rendered = objects.Float.renderFloat(value.raw.as.float, &buf);
                return try local_arena.dupeSentinel(u8, rendered, 0);
            },
            .pointer => return try value.raw.as.pointer.getString(),
            .integer => return try std.fmt.allocPrintSentinel(local_arena, "{}", .{value.raw.as.integer}, 0),
            .boolean => return if (value.raw.as.boolean) "true" else "false",
            .interned => return value.raw.as.interned[0..value.raw.interned_string_len :0],
            .external => @panic("external value used"),
        }
    }

    /// Guaranteed to return error.OutOfMemory if and only if the `Value` is
    /// an object pointer, and that Object OOM'd while generating its string.
    pub fn getStringWithBuffer(value: Value, buf: *[350]u8) ![:0]const u8 {
        comptime assert(std.fmt.count("{}", .{-std.math.floatMin(f64)}) + 1 <= 350); // + 1 for null.
        comptime assert(std.fmt.count("{}", .{-std.math.floatMax(f64)}) + 1 <= 350);

        switch (value.raw.tag) {
            .none => unreachable,
            .float => return objects.Float.renderFloat(value.raw.as.float, buf),
            .pointer => return try value.raw.as.pointer.getString(),
            .integer => return std.fmt.bufPrintSentinel(buf, "{}", .{value.raw.as.integer}, 0) catch unreachable,
            .boolean => return if (value.raw.as.boolean) "true" else "false",
            .interned => return value.raw.as.interned[0..value.raw.interned_string_len :0],
            .external => @panic("external value used"),
        }
    }

    /// Guaranteed to return error.OutOfMemory if and only if one of the value `Value`'s
    /// is an object pointer, and that Object OOM'd while generating its string.
    pub fn equals(a: Value, b: Value) error{OutOfMemory}!bool {
        if (a.raw.quickEquals(b.raw)) return true;

        if (a.asPtr()) |a_ptr| if (b.asPtr()) |b_ptr| {
            // If both strings are special strings, we can compare their hashes, to avoid
            // potentially expensive comparisons.
            const a_details = a_ptr.getStringDetails();
            const b_details = b_ptr.getStringDetails();
            if (a_details.asSpecial()) |a_special| if (b_details.asSpecial()) |b_special| {
                return try a_special.getHash() == try b_special.getHash();
            };
            // Else, fall through to the generic logic.
        };

        var buf_a: [350]u8 = undefined;
        // We use `getStringWithBuffer` instead of `getString`, because `equals` is called in
        // hash `eql` functions which must never fail.
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

/// The length of a string when it starts being considered large.
pub const considered_large_string: usize = 1024;

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
                // The allocation also holds the string's sentinel, but nothing
                // keeps a zero at the capacity, so this isn't a sentinel slice.
                global_gpa.free(info.string.ptr[0 .. info.original_capacity + 1]);
            },
        }
        for (self.tracked_hashes) |hash| if (hash.value) |val| val.dropReference();
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

    pub fn takeReference(self: *SpecialString) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    pub fn dropReference(self: *SpecialString) void {
        if (self.ref_count.fetchSub(1, .release) == 1) {
            // The release store above synchronizes with this acquire load to
            // ensure all prior operations on this string (from other threads)
            // are visible before we deinit and free it.
            _ = self.ref_count.load(.acquire);
            self.deinit();
        }
    }
};

/// OOM-safe in-place string patching.
///
/// A "patch" is a single `Edit`, which replaces a range of the string with
/// new, potentially empty bytes. It's guaranteed to either be atomically
/// applied, or to fail without changing anything.
pub const strpatch = struct {
    const HashAndInfo = SpecialString.HashAndInfo;

    /// Length of a full hash reference token.
    const token_len = hashutil.hash_token_len;

    // /// Attempts to atomically patch `obj`, by replacing `obj.string[edit_at..remove]` with `add`.
    // /// Corrects any changed hashes, and leaves `string` untouched if OOM occurs. `add`
    // /// must not alias the object's string.
    // pub fn patch2(obj: *Object, edit_at: usize, remove: usize, add: []const u8) error{OutOfMemory}!void {
    //     // Note: when we say "token" in the below code, we're referring specifically to a hash token,
    //     // e.g. `blake3.abc123~`.

    //     assert(obj.canMutate());
    //     _ = obj.getString();

    //     const old: struct {
    //         bytes: []const u8,
    //         hashes: []const HashAndInfo,
    //         special: ?*SpecialString,
    //     } = switch (obj.getStringDetails()) {
    //         .normal => |bytes| .{ .bytes = bytes, .hashes = &.{}, .special = null },
    //         .special => |special| .{ .bytes = special.getString(), .hashes = special.tracked_hashes, .special = special },
    //         .none => unreachable, // `String` objects always have a string rep.
    //     };

    //     assert(edit_at + remove <= old.bytes.len);

    //     // We will now allocate all needed structures for the patch, so we can
    //     // do all the fallible steps at once. We won't take any references until
    //     // this section successfully completes, so all that is needed for cleanup
    //     // is freeing the allocated structures.
    //     //
    //     // Some terminology we use below: There are "guaranteed" surviving
    //     // tokens, which are tokens in ranges where it's impossible for the edit
    //     // to damage them, and then we have "found" tokens, which are tokens
    //     // that were found either in the edit's bytes, or crossing the edit's
    //     // boundaries. This means that the tokens' start indices form a
    //     // partition: `guaranteed ∪ found = all tokens`, and
    //     // `guaranteed ∩ found = ∅`.

    //     // The edit is as follows:
    //     // old: text before|to be removed|text after edit section
    //     //                 ^ edit_at     ^ edit_at + remove
    //     // new: text before|newly added text|text after edit section
    //     //                 ^ edit_at        ^ edit_at + add.len
    //     const old_edit_end = edit_at + remove;
    //     const new_edit_end = edit_at + add.len;

    //     const guaranteed_ranges: [2]struct { old_start: usize, new_start: usize, len: usize } = .{
    //         .{
    //             .old_start = 0,
    //             .new_start = 0,
    //             .len = edit_at -| (token_len - 1),
    //         },
    //         .{
    //             .old_start = old_edit_end,
    //             .new_start = new_edit_end,
    //             .len = old.bytes.len - old_edit_end,
    //         },
    //     };

    //     // We have two (potentially overlapping) windows where we will find
    //     // new hashes. This diagram is in new string indices:
    //     //                                       v edit_at                                       v new_edit_end
    //     // |- guaranteed starts -|               |----------------- added text ------------------|- guaranteed starts -|
    //     //                       |`token_len - 1`|`token_len - 1`|               |`token_len - 1`|`token_len - 1`|
    //     //                       |-------- window before --------|               |-------- window after ---------|
    //     // We'll also scan "added text", since it can also have new hashes
    //     // (unless the windows overlap, as explained below).
    //     //
    //     // Some notes:
    //     // 1. You may notice that "guaranteed starts" doesn't overlap with
    //     //    "window before", but it does overlap with "window after." This is
    //     //    because "guaranteed starts" contains all the indices where the
    //     //    _start_ of the token is valid. We can have absolutely no overlap
    //     //    between "guaranteed starts" and "window before", or else we'll
    //     //    double count a token. Conversely, we need overlap between
    //     //    "guaranteed starts" and "window after", because only the first
    //     //    half of "window after" has the start indices of full tokens, while
    //     //    the second half only contains the end of tokens from the first
    //     //    half.
    //     // 2. When `add.len < 2 * (token_len - 1)`, the two windows will
    //     //    overlap. If we scanned both windows when they overlap, we could
    //     //    potentially scan a hash token twice. To prevent this, we merge the
    //     //    two windows into one that gets scanned in its entirety. We also
    //     //    don't scan `add`, since its contents will be scanned when
    //     //    scanning the merged window.

    //     var found_hashes: std.ArrayList(hashutil.HashInstance) = .empty;
    //     defer found_hashes.deinit(global_gpa);
    //     if (add.len < 2 * (token_len - 1)) {
    //         // Windows overlap, so we'll copy them into the same buffer.
    //         var buffer: [(token_len - 1) * 4]u8 = undefined;
    //         var writer: std.ArrayList(u8) = .initBuffer(&buffer);

    //         const window_start = edit_at -| (token_len - 1);
    //         // Part before `edit_at`.
    //         writer.appendSliceAssumeCapacity(old.bytes[window_start..edit_at]);
    //         writer.appendSliceAssumeCapacity(add);
    //         // Part after `old_edit_end`.
    //         writer.appendSliceAssumeCapacity(old.bytes[old_edit_end..@min(old_edit_end + (token_len - 1), old.bytes.len)]);
    //         try hashutil.scanStringForHashRefs(global_gpa, writer.items, window_start, &found_hashes);
    //     } else {
    //         // No overlap, so we'll scan each one separately.
    //         var buffer: [(token_len - 1) * 2]u8 = undefined;
    //         var writer: std.ArrayList(u8) = .initBuffer(&buffer);

    //         // Scan "before window."
    //         const window_start = edit_at -| (token_len - 1);
    //         writer.appendSliceAssumeCapacity(old.bytes[window_start..edit_at]);
    //         writer.appendSliceAssumeCapacity(add[0..(token_len - 1)]);
    //         try hashutil.scanStringForHashRefs(global_gpa, writer.items, window_start, &found_hashes);

    //         // Scan "added text."
    //         try hashutil.scanStringForHashRefs(global_gpa, add, edit_at, &found_hashes);

    //         // Scan "after window."
    //         writer = .initBuffer(&buffer);
    //         writer.appendSliceAssumeCapacity(add[(add.len - (token_len - 1))..]);
    //         writer.appendSliceAssumeCapacity(old.bytes[old_edit_end..@min(old_edit_end + (token_len - 1), old.bytes.len)]);
    //         try hashutil.scanStringForHashRefs(global_gpa, writer.items, new_edit_end - (token_len - 1), &found_hashes);
    //     }

    //     // Do after successfully changing the string.
    //     obj.invalidateInternalRep();
    // }

    /// Replaces `[start, end)` of the original string with `bytes`.
    /// A pure insert uses `start == end`, while a pure delete has
    /// empty `bytes`.
    ///
    /// `bytes` is borrowed for the duration of `patch`, and must not alias the
    /// string being patched.
    pub const Edit = struct {
        start: usize,
        end: usize,
        bytes: []const u8,
    };

    /// Attempts to atomically apply `edit` to `string`, leaving `string`
    /// untouched in the case of OOM. Asserts that `string` can be mutated.
    pub fn patch(string: *objects.String, edit: Edit) error{OutOfMemory}!void {
        const obj = string.asHead();
        assert(obj.canMutate());

        const old: struct {
            bytes: []const u8,
            hashes: []const HashAndInfo,
            special: ?*SpecialString,
        } = switch (obj.getStringDetails()) {
            .normal => |bytes| .{ .bytes = bytes, .hashes = &.{}, .special = null },
            .special => |special| .{ .bytes = special.getString(), .hashes = special.tracked_hashes, .special = special },
            .none => unreachable, // `String` objects always have a string rep.
        };

        {
            assert(edit.start <= edit.end); // Make sure the edit bounds are correct.
            assert(edit.end <= old.bytes.len);
            const old_start = @intFromPtr(old.bytes.ptr); // Used for checking aliasing.
            const edit_start = @intFromPtr(edit.bytes.ptr);
            assert(edit.bytes.len == 0 or
                edit_start + edit.bytes.len <= old_start or
                old_start + old.bytes.len <= edit_start); // Make sure the edit doesn't alias the string.
        }

        const old_tail = old.bytes[edit.end..];
        const new_tail_start = edit.start + edit.bytes.len;
        const new_len = new_tail_start + old_tail.len;

        // We will now allocate all needed structures for the patch. We won't
        // take any references until this section successfully completes, to
        // simplify error handling.
        //
        // Some terminology we use below: There are "guaranteed" surviving
        // tokens, which are tokens in ranges where it's impossible for the
        // edit to damage them, and then we have "found" tokens, which are
        // tokens that were found either in the edit's bytes, or crossing one
        // of the edit's boundaries. This means that the tokens' start indices
        // form a partition: `guaranteed ∪ found = all tokens`, and
        // `guaranteed ∩ found = ∅`.

        // We first locate the "guaranteed" tokens. We don't need to scan for
        // them, since we can take them from the old hashes. Those are sorted,
        // so removing the damaged ones from the middle leaves the guaranteed
        // ones on either side.
        //
        // The edit damages a token iff it's a deletion overlapping the token,
        // or an insertion strictly inside it. An edit ending at or before a
        // token's start (an insert exactly at its start included) moves the
        // token but cannot damage it.
        var damaged_start: usize = 0;
        while (damaged_start < old.hashes.len and old.hashes[damaged_start].str_index + token_len <= edit.start) damaged_start += 1;
        var damaged_end = damaged_start;
        while (damaged_end < old.hashes.len and old.hashes[damaged_end].str_index < edit.end) damaged_end += 1;
        const guaranteed_before = old.hashes[0..damaged_start];
        const guaranteed_after = old.hashes[damaged_end..];

        // We next look for our "found" tokens. Every one of them crosses a
        // boundary of the edit or lies inside its bytes, so only the
        // `token_len - 1` bytes on each side need scanning, plus the edit's
        // bytes. Neither side holds enough old bytes to contain a guaranteed
        // token, so nothing here is reported twice.
        //
        // `window` may begin partway through a surviving token. The token
        // format is overlap-free, so no valid token can start inside those
        // bytes and the scanner can't be thrown off by them.
        const window_start = edit.start -| (token_len - 1);
        var found: std.ArrayList(hashutil.HashInstance) = .empty;
        defer found.deinit(global_gpa);
        {
            const window = try mem.concat(global_gpa, u8, &.{
                old.bytes[window_start..edit.start],
                edit.bytes,
                old_tail[0..@min(old_tail.len, token_len - 1)],
            });
            defer global_gpa.free(window);
            try hashutil.scanStringForHashRefs(global_gpa, window, 0, &found);
        }

        const new_tracked = try global_gpa.alloc(HashAndInfo, guaranteed_before.len + found.items.len + guaranteed_after.len);
        errdefer global_gpa.free(new_tracked);

        // The special string itself may be shared with other objects
        // (`duplicateHeadOnto` shares rather than copies), even when `obj` is
        // exclusively ours. Unlike everything else a patch touches, its count
        // is atomic, since a sharer can be cross-thread.
        const exclusive_special: ?*SpecialString = if (old.special) |special|
            (if (special.ref_count.load(.monotonic) == 1) special else null)
        else
            null;

        if (exclusive_special) |special| {
            // The object exclusively owns a special string: patch its buffer
            // in place, growing it if needed.
            const string_bytes: [:0]u8, const old_capacity: usize = switch (special.value) {
                .normal => |bytes| .{ bytes, bytes.len },
                .different_capacity => |info| .{ info.string, info.original_capacity },
            };
            // The `+ 1` is for the sentinel.
            var buf = string_bytes.ptr[0 .. old_capacity + 1];
            if (new_len > old_capacity) {
                const new_capacity = @max(new_len, old_capacity +| old_capacity / 2);
                // Last fallible step. A failed `realloc` leaves the buffer as
                // it was, and nothing after a successful one can fail, which
                // matters since `special` still points to the old buffer.
                buf = try global_gpa.realloc(buf, new_capacity + 1);
            }
            const capacity = buf.len - 1;

            errdefer comptime unreachable; // We now take references, and know nothing will go wrong.

            fillTrackedHashes(new_tracked, edit, guaranteed_before, window_start, found.items, guaranteed_after);

            // Move the untouched tail of old bytes. Inserted bytes go in last,
            // since they can overlap the tail's old position.
            @memmove(buf[new_tail_start..][0..old_tail.len], buf[edit.end..][0..old_tail.len]);
            @memcpy(buf[edit.start..][0..edit.bytes.len], edit.bytes);
            buf[new_len] = 0;

            special.value = if (capacity == new_len)
                .{ .normal = buf[0..new_len :0] }
            else
                .{ .different_capacity = .{
                    .string = buf[0..new_len :0],
                    .original_capacity = capacity,
                } };

            for (special.tracked_hashes) |tracked| if (tracked.value) |value| value.dropReference();
            global_gpa.free(special.tracked_hashes);
            special.tracked_hashes = new_tracked;

            // Invalidate what was derived from the old bytes.
            if (special.hash.raw) |hash| {
                global_gpa.destroy(hash);
                special.hash.raw = null;
            }
            special.utf8_length.raw = math.maxInt(u64);
        } else {
            // Gather-copy into a new buffer. Used for normal strings (small,
            // with no spare capacity to work in) and for special strings
            // shared with other objects.
            const buf = try global_gpa.allocSentinel(u8, new_len, 0);
            errdefer global_gpa.free(buf);
            const needs_special = new_tracked.len > 0 or new_len > considered_large_string;
            // Null when the result fits the normal-string rules.
            const new_special = if (needs_special) try global_gpa.create(SpecialString) else null;

            errdefer comptime unreachable; // We now take references, and know nothing will go wrong.

            fillTrackedHashes(new_tracked, edit, guaranteed_before, window_start, found.items, guaranteed_after);

            @memcpy(buf[0..edit.start], old.bytes[0..edit.start]);
            @memcpy(buf[edit.start..new_tail_start], edit.bytes);
            @memcpy(buf[new_tail_start..], old_tail);

            // Frees a normal string, or drops our reference to a shared
            // special one (which keeps its own tracked references; ours were
            // taken separately).
            obj.freeStringInner();

            if (new_special) |special| {
                special.* = .{
                    .value = .{ .normal = buf },
                    .tracked_hashes = new_tracked,
                    .hash = .init(null),
                };
                obj.string.raw = special;
                obj.string_metadata.raw = .{
                    .has_value = true,
                    .is_special = true,
                    .len = math.maxInt(u16),
                };
            } else {
                assert(new_tracked.len == 0);
                global_gpa.free(new_tracked);
                obj.string.raw = buf.ptr;
                obj.string_metadata.raw = .{
                    .has_value = true,
                    .is_special = false,
                    .len = @intCast(new_len),
                };
            }
        }

        // The body caches the codepoint length of normal strings.
        string.* = .{};
        if (options.trace_mem) {
            const final_bytes: []const u8 = switch (obj.getStringDetails()) {
                .normal => |bytes| bytes,
                .special => |special| special.getString(),
                .none => unreachable,
            };
            leak_check.globalTrace(obj, .{ .set_string = .{ .set_to = leak_check.dupeForTrace(final_bytes) } });
        }
    }

    /// Fills `out` with the new string's tokens in increasing order, taking a
    /// reference to each resolved value. Indices are unique, since tokens
    /// can't overlap. The indices in `found` are relative to `window_start`.
    fn fillTrackedHashes(
        out: []HashAndInfo,
        edit: Edit,
        guaranteed_before: []const HashAndInfo,
        window_start: usize,
        found: []const hashutil.HashInstance,
        guaranteed_after: []const HashAndInfo,
    ) void {
        var filled: std.ArrayList(HashAndInfo) = .initBuffer(out);

        for (guaranteed_before) |hash| filled.appendAssumeCapacity(.{
            .str_index = hash.str_index,
            .value = if (hash.value) |value| value.takeReference() else null,
        });

        if (found.len > 0) {
            registered_hashes.rw_lock.lockSharedUncancelable(global_io);
            defer registered_hashes.rw_lock.unlockShared(global_io);

            for (found) |token| filled.appendAssumeCapacity(.{
                .str_index = window_start + token.index,
                .value = if (registered_hashes.entries.get(token.hash)) |resolved|
                    resolved.representative.takeReference()
                else
                    null,
            });
        }

        // These tokens move with the old bytes just after the edit. This won't
        // underflow, as they all start at or after `edit.end`.
        for (guaranteed_after) |hash| filled.appendAssumeCapacity(.{
            .str_index = hash.str_index - edit.end + edit.start + edit.bytes.len,
            .value = if (hash.value) |value| value.takeReference() else null,
        });

        assert(filled.items.len == out.len);
    }
};

pub const Object = extern struct {
    pub const body_max_size = 48;
    pub const body_align = 8;

    pub var next_sequence_number: std.atomic.Value(u64) = .init(0);

    pub const VTable = extern struct {
        is_c_vtable: bool = false,
        name: [*:0]const u8,
        as: extern union {
            c: extern struct {
                duplicate: ?*const fn (src: *const Object) callconv(.c) ?*Object,
                free_internal_rep: ?*const fn (obj: *Object) callconv(.c) void,
                update_string: ?*const fn (obj: *Object) callconv(.c) ReturnCode,
                make_crossthread: ?*const fn (obj: *Object) callconv(.c) void,
                enumerate_struct: ?memutil.StructIterator.EnumerateStructCFn,
            },
            zig: extern struct {
                duplicate: ?*const fn (src: *const Object) error{OutOfMemory}!*Object,
                free_internal_rep: ?*const fn (obj: *Object) void,
                update_string: ?*const fn (obj: *Object) error{ OutOfMemory, OtherThreadSet }!void,
                make_crossthread: ?*const fn (obj: *Object) void,
                enumerate_struct: ?*const fn (
                    obj: *const Object,
                    ctx: StructIterator,
                    node_info: *const StructIterator.NodeInfo,
                ) StructIterator.Error!void,
            },
        },

        pub fn zig(name: [*:0]const u8, as_zig: @FieldType(@FieldType(VTable, "as"), "zig")) VTable {
            return .{ .name = name, .as = .{ .zig = as_zig } };
        }
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

    vtable: *const VTable,

    ref_count: u32,
    metadata: Metadata,
    /// Located here for layout reasons, but consider it grouped with `string`.
    string_metadata: std.atomic.Value(StringMetadata),
    hash_metadata: std.atomic.Value(HashMetadata),

    body_backing: [body_max_size]u8 align(body_align),

    sequence_number: if (options.trace_mem) u64 else u0,

    pub fn assertValidType(T: type) void {
        comptime {
            if (@sizeOf(T) > body_max_size) @compileError("Object is too large");
            if (@alignOf(T) > body_align) @compileError(std.fmt.comptimePrint(
                "Object has too high alignment requirements ({s} has align {}, while max align is {})",
                .{ @typeName(T), @alignOf(T), body_align },
            ));
            if (!@hasDecl(T, "vtable")) @compileError("Type is missing vtable");
            if (@TypeOf(@field(T, "vtable")) != VTable) @compileError("Wrong vtable type");
        }
    }

    pub fn from(T: type, ptr: *T) *Object {
        assertValidType(T);
        const bytes_ptr: *align(body_align) [body_max_size]u8 = @ptrCast(@alignCast(ptr));
        return @fieldParentPtr("body_backing", bytes_ptr);
    }

    pub fn fromConst(T: type, ptr: *const T) *const Object {
        assertValidType(T);
        const bytes_ptr: *align(body_align) const [body_max_size]u8 = @ptrCast(@alignCast(ptr));
        return @fieldParentPtr("body_backing", bytes_ptr);
    }

    /// Asserts that `obj` has type `T.vtable`.
    pub fn asType(obj: *Object, T: type) ?*T {
        assertValidType(T);
        if (obj.vtable == &T.vtable) return @ptrCast(@alignCast(&obj.body_backing));
        return null;
    }

    pub fn asTypeConst(obj: *const Object, T: type) ?*const T {
        assertValidType(T);
        if (obj.vtable == &T.vtable) return @ptrCast(@alignCast(&obj.body_backing));
        return null;
    }

    pub fn asValue(obj: *Object) Value {
        return Value.fromRep(.{ .tag = .pointer, .as = .{ .pointer = obj } });
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
        if (obj.hash_metadata.raw.hash_registered) return false;
        return true;
    }

    pub fn canShimmer(obj: *const Object) bool {
        return !obj.metadata.cross_thread;
    }

    /// If `obj` is exclusively owned (`canMutate()`), ensures its string rep is
    /// an exclusively owned `*SpecialString`, invalidates any internal rep, and
    /// returns the mutable `*SpecialString`. Returns `null` if `obj` cannot be
    /// mutated in place.
    pub fn newObjectWithVTable(vtable: *const VTable) !*Object {
        const obj = try global_gpa.create(Object);
        obj.* = .{
            .vtable = vtable,
            .ref_count = 1,
            .metadata = .{},
            .hash_metadata = .init(.{}),
            .string = undefined,
            .string_metadata = undefined,
            .body_backing = undefined,
            .sequence_number = if (options.trace_mem) next_sequence_number.fetchAdd(1, .monotonic) else 0,
        };

        leak_check.globalTrace(obj, .alloc);

        return obj;
    }

    pub fn newObjectUninitialized(T: type) !struct { head: *Object, body: *T } {
        assertValidType(T);

        const obj = try newObjectWithVTable(&T.vtable);
        return .{ .head = obj, .body = obj.asType(T).? };
    }

    pub fn newObject(T: type) !struct { head: *Object, body: *T } {
        const new_obj = try newObjectUninitialized(T);
        new_obj.head.string = .init(null);
        new_obj.head.string_metadata = .init(.{});
        return .{ .head = new_obj.head, .body = new_obj.body };
    }

    pub fn duplicate(obj: *const Object) !*Object {
        if (obj.vtable.is_c_vtable) {
            if (obj.vtable.as.c.duplicate) |dup| return dup(obj) orelse error.OutOfMemory;
        } else {
            if (obj.vtable.as.zig.duplicate) |dup| return try dup(obj);
        }
        debug.panic("Could not duplicate {s}", .{obj.vtable.name});
    }

    /// For a type whose body reaches no other object, so sharing it needs
    /// nothing done. Deliberately explicit rather than leaving the vtable entry
    /// null: null means the type cannot cross threads at all, and a type that
    /// simply has no children would otherwise be indistinguishable from one that
    /// must never be shared.
    pub fn noopMakeCrossthread(_: *Object) void {}

    pub fn makeCrossthread(obj: *Object) void {
        // Marking is one-way and always covers the whole subgraph, so an object
        // that is already marked has already had its children marked too. Bail
        // out rather than walking them again: scope dictionaries chain through
        // `~parent` to every enclosing scope, so re-walking on each capture
        // turns marking a closure's scope into a walk of the entire chain.
        if (obj.metadata.cross_thread) return;

        // Marked before recursing, so a graph that reaches back into itself
        // terminates on the check above rather than recursing forever.
        obj.metadata.cross_thread = true;

        // A null entry means the type cannot cross threads, so the unwrap
        // intentionally panics when it doesn't have an impl.
        if (obj.vtable.is_c_vtable) {
            obj.vtable.as.c.make_crossthread.?(obj);
        } else {
            obj.vtable.as.zig.make_crossthread.?(obj);
        }
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
        try ctx.addField(Metadata, info, "metadata", "{any}", .{obj.metadata});
        if (obj.vtable.is_c_vtable) {
            if (obj.vtable.as.c.enumerate_struct) |c_fn| {
                var walker: memutil.StructIterator.CEnumerateContext = .{ .ctx = ctx, .info = info };
                if (c_fn(&walker, info.node) != 0) return error.OutOfMemory;
            }
        } else {
            if (obj.vtable.as.zig.enumerate_struct) |walk_fn| try walk_fn(obj, ctx, info);
        }
    }

    pub fn freeBacking(obj: *Object) void {
        leak_check.globalTrace(obj, .free);
        global_gpa.destroy(obj);
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

        pub fn asSpecial(details: StringDetails) ?*SpecialString {
            switch (details) {
                .special => |special| return special,
                else => return null,
            }
        }
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
                if (obj.vtable.is_c_vtable) {
                    const update_str_fn = obj.vtable.as.c.update_string orelse {
                        debug.panic("Can't generate string for {s} (should always have a string rep)", .{obj.vtable.name});
                    };
                    switch (update_str_fn(obj)) {
                        .ok => {},
                        .oom => return error.OutOfMemory,
                        else => unreachable,
                    }
                } else {
                    const update_str_fn = obj.vtable.as.zig.update_string orelse {
                        debug.panic("Can't generate string for {s} (should always have a string rep)", .{obj.vtable.name});
                    };
                    update_str_fn(obj) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.OtherThreadSet => {},
                    };
                }

                var details = obj.getStringDetails();
                switch (details) {
                    .special => |special| return special.getString(),
                    .normal => |normal| return normal,
                    .none => {
                        // May not have released the details of the string yet,
                        // so spin until we get all the details.
                        while (std.meta.activeTag(details) == .none) {
                            details = obj.getStringDetails();
                        }

                        switch (details) {
                            .special => |special| return special.getString(),
                            .normal => |normal| return normal,
                            .none => unreachable,
                        }
                    },
                }
            },
        }
    }

    pub fn maybeGetString(obj: *const Object) ?[:0]const u8 {
        switch (obj.getStringDetails()) {
            .special => |special| return special.getString(),
            .normal => |bytes| return bytes,
            .none => return null,
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
        errdefer for (hashes) |hash| if (hash.value) |val| val.dropReference();

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
            leak_check.globalTrace(obj, .{ .set_string = .{ .set_to = leak_check.dupeForTrace(bytes) } });
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
            leak_check.globalTrace(obj, .{ .set_string = .{ .set_to = leak_check.dupeForTrace(bytes) } });
        }
    }

    /// Takes ownership of `bytes`.
    pub fn setStringLocalObject(obj: *Object, bytes: [:0]u8) error{OutOfMemory}!void {
        assert(obj.metadata.cross_thread == false);

        const hashes = try hashutil.scanAndResolveHashRefs(global_gpa, bytes);
        errdefer global_gpa.free(hashes);
        errdefer for (hashes) |hash| if (hash.value) |val| val.dropReference();

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
    }

    pub fn getRefCount(obj: *const Object) u32 {
        if (obj.metadata.cross_thread) {
            return @atomicLoad(u32, &obj.ref_count, .monotonic);
        } else {
            return obj.ref_count;
        }
    }

    pub fn incrRefCount(obj: *Object) void {
        const new_ref_count = incrRefCountOf(u32, &obj.ref_count, obj.metadata.cross_thread);
        leak_check.globalTrace(obj, .{ .incr_ref_count = .{ .new_ref_count = new_ref_count } });
    }

    pub fn takeReference(obj: *Object) *Object {
        obj.incrRefCount();
        return obj;
    }

    pub fn dropReference(obj: *Object) void {
        if (!obj.metadata.cross_thread) {
            // We don't deal with hash unregistering here, since an object
            // is always marked as crossthread when it's registered.
            obj.ref_count -= 1;
            leak_check.globalTrace(obj, .{ .decr_ref_count = .{ .new_ref_count = obj.ref_count } });
            if (obj.ref_count == 0) obj.deinit();
            return;
        }

        // We need to load `metadata` before decrementing, because decrementing means
        // we've dropped our ownership of the object, and so another thread could
        // swoop in and free the object before we read the metadata (ask me how I know).
        const metadata = obj.hash_metadata.load(.monotonic);
        const new_ref_count = decrRefCountOf(u32, &obj.ref_count, true);
        leak_check.globalTrace(obj, .{ .decr_ref_count = .{ .new_ref_count = new_ref_count } });

        if (new_ref_count == 1) {
            if (metadata.is_representative) {
                // It's impossible for this to not have a registered hash,
                // since we just checked that `is_representative` is true,
                // which means that the hash was registered and owned
                // by the registry.
                const hash = obj.getHashNoRegister() catch unreachable;
                registered_hashes.unregister(hash, obj, metadata.is_representative);
            }
        } else if (new_ref_count == 0) {
            if (metadata.hash_registered) {
                // Now you might say, "hey, didn't you previously have to
                // load `metadata` beforehand to prevent the object from
                // being freed from underneath you?" And yes, I did say that.
                // However, if we were the ones _who brought it to zero_,
                // we are the true last owners. When we brought it to one,
                // there was still someone else who could bring it to zero.
                const hash = obj.getHashNoRegister() catch unreachable;
                registered_hashes.unregister(hash, obj, metadata.is_representative);
            }
            obj.deinit();
        }
    }

    pub fn swap(ref: **Object, new: *Object) void {
        const old = ref.*;
        ref.* = new;
        old.dropReference();
    }

    fn freeStringInner(obj: *Object) void {
        switch (obj.getStringDetails()) {
            .none => {},
            .normal => |normal| global_gpa.free(normal),
            .special => |special| special.dropReference(),
        }
        obj.string.raw = null;
        obj.string_metadata.raw = .{};
    }

    pub fn invalidateString(obj: *Object) void {
        assert(obj.canShimmer());
        if (options.trace_mem) {
            const was: []u8 = switch (obj.getStringDetails()) {
                .none => &.{},
                .normal => |normal| leak_check.dupeForTrace(normal),
                .special => |special| leak_check.dupeForTrace(special.getString()),
            };
            leak_check.globalTrace(obj, .{ .invalidate_string = .{ .was = was } });
        }
        obj.freeStringInner();
    }

    /// This is separate from `invalidateString`, as I plan to have richer
    /// in-place mutation semantics in the future.
    pub fn commitMutation(obj: *Object) void {
        obj.invalidateString();
    }

    pub fn invalidateInternalRep(obj: *Object) void {
        leak_check.globalTrace(obj, .invalidate_rep);
        if (obj.vtable.is_c_vtable) {
            if (obj.vtable.as.c.free_internal_rep) |free_fn| free_fn(obj);
        } else {
            if (obj.vtable.as.zig.free_internal_rep) |free_fn| free_fn(obj);
        }
    }

    pub fn getHashNoRegister(obj: *Object) !u256 {
        // We need to generate the string before checking its details, since it
        // may generate as a `SpecialString` instead of as a normal string. If
        // it generates as a `SpecialString`, we need to have the
        // `SpecialString` store its hash.
        const bytes = try obj.getString();

        switch (obj.getStringDetails()) {
            .special => |special| {
                const hash = try special.getHash();
                if (obj.asType(objects.Source) == null) return hash;
                // It was a Source object, so we need to fall through to the
                // later code which sets the hash on Source as well.
            },
            .none => unreachable, // `getString` above just produced one.
            .normal => {
                // Fall through.
            },
        }

        if (obj.asType(objects.Source)) |source| {
            if (source.hash.load(.monotonic)) |hash| {
                return hash.*;
            } else {
                const hash = hashutil.hashBytes(bytes);
                const hash_ptr = try global_gpa.create(u256);
                hash_ptr.* = hash;
                if (source.hash.cmpxchgStrong(null, hash_ptr, .release, .acquire)) |other_set| {
                    global_gpa.destroy(hash_ptr);
                    return other_set.?.*;
                }
                return hash;
            }
        }

        return hashutil.hashBytes(bytes);
    }

    pub fn getHashRegistering(obj: *Object) !u256 {
        const hash = try obj.getHashNoRegister();
        try registered_hashes.register(hash, obj); // Idempotent.
        return hash;
    }

    /// Whether `getHashNoRegister` can return the object's hash without
    /// allocating (e.g. potentially returning OOM).
    pub fn hashIsCached(obj: *const Object) bool {
        if (obj.asTypeConst(objects.Source)) |source| {
            if (source.hash.load(.monotonic) == null) return false;
            // Note that if the source has a hash, we also need to make sure
            // that if it is a `SpecialString`, it also has a cached hash.
        }

        switch (obj.getStringDetails()) {
            .none => return false,
            .special => |special| return special.hash.load(.monotonic) != null,
            .normal => return true,
        }
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
                special.takeReference();
                dest.string = .init(special);
                dest.string_metadata = .init(.{
                    .has_value = true,
                    .is_special = true,
                    .len = math.maxInt(u16),
                });
            },
            .none => {
                dest.string = .init(null);
                dest.string_metadata = .init(.{
                    .has_value = false,
                    .is_special = false,
                    .len = 0,
                });
            },
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
    try testStart(ta, null);
    defer testFinish();

    const obj = try Value.newInt(42).raw.box();
    defer obj.dropReference();
    try testing.expectEqualStrings("42", try obj.getString());
}

test "value box int" {
    try testing.checkAllAllocationFailures(testing.allocator, testBoxInteger, .{});
}

fn testBoxFloat(ta: std.mem.Allocator) !void {
    try testStart(ta, null);
    defer testFinish();

    const obj = try Value.newFloat(3.14).raw.box();
    defer obj.dropReference();
    try testing.expectEqualStrings("3.14", try obj.getString());
}

test "value box float" {
    try testing.checkAllAllocationFailures(testing.allocator, testBoxFloat, .{});
}

fn testBoxBool(ta: std.mem.Allocator) !void {
    try testStart(ta, null);
    defer testFinish();

    const true_obj = try Value.newBool(true).raw.box();
    defer true_obj.dropReference();
    try testing.expectEqualStrings("true", try true_obj.getString());

    const false_obj = try Value.newBool(false).raw.box();
    defer false_obj.dropReference();
    try testing.expectEqualStrings("false", try false_obj.getString());
}

test "value box bool" {
    try testing.checkAllAllocationFailures(testing.allocator, testBoxBool, .{});
}

fn testReferenceCounting(ta: std.mem.Allocator) !void {
    try testStart(ta, null);
    defer testFinish();

    const obj = (try objects.String.new("foo")).asHead();
    try testing.expectEqual(@as(u32, 1), obj.getRefCount());
    _ = obj.takeReference();
    try testing.expectEqual(@as(u32, 2), obj.getRefCount());
    obj.dropReference();
    try testing.expectEqual(@as(u32, 1), obj.getRefCount());
    obj.dropReference();
}

test "object ref count" {
    try testing.checkAllAllocationFailures(testing.allocator, testReferenceCounting, .{});
}

fn testDuplicateObject(ta: std.mem.Allocator) !void {
    try testStart(ta, null);
    defer testFinish();

    const original = (try objects.String.new("to duplicate")).asHead();
    defer original.dropReference();
    const dup_obj = try original.duplicate();
    defer dup_obj.dropReference();
    try testing.expectEqualStrings("to duplicate", try dup_obj.getString());
}

test "object duplicate" {
    try testing.checkAllAllocationFailures(testing.allocator, testDuplicateObject, .{});
}

fn testSpecialSourceHash(ta: std.mem.Allocator) !void {
    try testStart(ta, null);
    defer testFinish();

    // Over `considered_large_string` bytes, so the string rep is stored as a
    // `SpecialString` and both it and `Source.hash` have a slot to fill. A
    // `Source` is the only type where the two coexist, so it is the only place
    // they can disagree.
    const script = memutil.repeat("set x 1\n", considered_large_string);
    const source = try objects.Source.new(&script, .none, 1);
    defer source.asHead().dropReference();

    const hash = try source.asHead().getHashRegistering();

    // Both slots filled, and filled with the same hash. Registering leaves the
    // object frozen, so `release` below can only unregister without allocating
    // if this holds.
    try testing.expect(source.asHead().hashIsCached());
    try testing.expectEqual(hash, source.hash.load(.monotonic).?.*);
    try testing.expectEqual(hash, try source.asHead().getStringDetails().asSpecial().?.getHash());
}

test "source with a special string hashes both slots" {
    try testing.checkAllAllocationFailures(testing.allocator, testSpecialSourceHash, .{});
}

fn testScanStringForHashRefs(ta: std.mem.Allocator) !void {
    try testStart(ta, null);
    defer testFinish();

    const target = try objects.String.new("referenced payload");
    defer target.asHead().dropReference();
    const hash_ref = try objects.HashReference.new(target.asHead());
    defer hash_ref.asHead().dropReference();
    const ref_str = try hash_ref.asHead().getString();
    const expected_hash = try target.asHead().getHashNoRegister();

    // Prepend a prefix AND a malformed `blake3.` (less than a token length before the real one)
    // to verify both that `.index` is the exact start of the match (`next`, not `current_index`)
    // and that a failed base64 decode only advances past `blake3.` rather than skipping a whole token.
    const prefix = "hello blake3.invalid! ";
    const combined = try std.fmt.allocPrint(ta, "{s}{s} trailing", .{ prefix, ref_str });
    defer ta.free(combined);

    var found: std.ArrayList(hashutil.HashInstance) = .empty;
    defer found.deinit(ta);
    try hashutil.scanStringForHashRefs(ta, combined, 0, &found);

    try expectEqual(@as(usize, 1), found.items.len);
    try expectEqual(prefix.len, found.items[0].index);
    try expectEqual(expected_hash, found.items[0].hash);
}

test "scanStringForHashRefs records exact index and recovers after invalid prefix" {
    try testing.checkAllAllocationFailures(testing.allocator, testScanStringForHashRefs, .{});
}

fn testCurrentBytes(obj: *Object) []const u8 {
    return switch (obj.getStringDetails()) {
        .normal => |bytes| bytes,
        .special => |special| special.getString(),
        .none => unreachable,
    };
}

fn testTrackedHashes(obj: *Object) []const SpecialString.HashAndInfo {
    return switch (obj.getStringDetails()) {
        .normal => &.{},
        .special => |special| special.tracked_hashes,
        .none => unreachable,
    };
}

/// Fails unless `obj` tracks exactly the hash references a full rescan finds.
fn expectTrackedMatchesRescan(obj: *Object) !void {
    const expected = try hashutil.scanAndResolveHashRefs(global_gpa, testCurrentBytes(obj));
    defer {
        for (expected) |entry| if (entry.value) |value| value.dropReference();
        global_gpa.free(expected);
    }

    const actual = testTrackedHashes(obj);
    try expectEqual(expected.len, actual.len);
    for (expected, actual) |exp, act| {
        try expectEqual(exp.str_index, act.str_index);
        try expectEqual(exp.value, act.value);
    }
}

fn testAppend(obj: *Object, bytes: []const u8) !void {
    const len = testCurrentBytes(obj).len;
    try strpatch.patch(obj.asType(objects.String).?, .{ .start = len, .end = len, .bytes = bytes });
}

/// Overwrites `data` at `offset`, zero-filling any gap past the old end.
fn testOverwrite(obj: *Object, offset: usize, data: []const u8) !void {
    const old_len = testCurrentBytes(obj).len;
    const start = @min(offset, old_len);
    const bytes = try global_gpa.alloc(u8, offset - start + data.len);
    defer global_gpa.free(bytes);
    @memset(bytes[0 .. offset - start], 0);
    @memcpy(bytes[offset - start ..], data);

    try strpatch.patch(obj.asType(objects.String).?, .{ .start = start, .end = @min(offset + data.len, old_len), .bytes = bytes });
}

fn expectSingleTrackedHashAt(obj: *Object, expected_index: usize) !void {
    const tracked = testTrackedHashes(obj);
    try expectEqual(@as(usize, 1), tracked.len);
    try expectEqual(expected_index, tracked[0].str_index);
    try testing.expect(tracked[0].value != null);
    try testing.expectEqualStrings("sliding payload", try tracked[0].value.?.getString());
}

fn testStrpatchSlidingWindow(ta: std.mem.Allocator) !void {
    try testStart(ta, null);
    defer testFinish();

    // 1. Every split point of a hash reference across two appends, with decoy
    //    prepends and postpends immediately before and after the real reference.
    {
        const target = try objects.String.new("sliding payload");
        defer target.asHead().dropReference();
        const hash = try target.asHead().getHashRegistering();
        const ref_bytes = objects.HashReference.render(hash);

        const prefixes = [_][]const u8{
            "",
            "a",
            hashutil.hash_prepend,
            hashutil.hash_postpend,
            hashutil.hash_prepend ++ "not_a_valid_hash_because_of_bang!_padding____" ++ hashutil.hash_postpend,
            &memutil.repeat("x", hashutil.hash_token_len - 1),
            &memutil.repeat("x", hashutil.hash_token_len),
            &memutil.repeat("x", hashutil.hash_token_len + 1),
        };
        const suffixes = [_][]const u8{
            "",
            "z",
            hashutil.hash_prepend,
            hashutil.hash_postpend,
            hashutil.hash_prepend ++ "short",
        };

        for (prefixes) |prefix| {
            for (suffixes) |suffix| {
                for (0..ref_bytes.len + 1) |split| {
                    const string = try objects.String.new(prefix);
                    defer string.asHead().dropReference();
                    const obj = string.asHead();

                    try testAppend(obj, ref_bytes[0..split]);
                    if (split < ref_bytes.len) try expectEqual(@as(usize, 0), testTrackedHashes(obj).len);
                    try testAppend(obj, ref_bytes[split..]);
                    try expectSingleTrackedHashAt(obj, prefix.len);

                    try testAppend(obj, suffix);
                    try expectSingleTrackedHashAt(obj, prefix.len);
                }
            }
        }
    }

    // 2. Slide a hash reference while the patched string holds the only
    //    reference to its target outside `registered_hashes`. Dropping the old
    //    reference before taking the new one, or misjudging a window boundary
    //    by a byte, unregisters and frees the target.
    {
        const target = try objects.String.new("sliding payload");
        const hash = try target.asHead().getHashRegistering();
        const ref_bytes = objects.HashReference.render(hash);

        var initial_buf: [220]u8 = @splat('_');
        @memcpy(initial_buf[0..ref_bytes.len], &ref_bytes);
        const string = try objects.String.new(&initial_buf);
        defer string.asHead().dropReference();
        const obj = string.asHead();

        target.asHead().dropReference();
        try expectSingleTrackedHashAt(obj, 0);

        // Forward one byte at a time.
        var step_forward: [hashutil.hash_token_len + 1]u8 = undefined;
        step_forward[0] = '_';
        @memcpy(step_forward[1..], &ref_bytes);
        var pos: usize = 0;
        while (pos < 120) : (pos += 1) {
            try testOverwrite(obj, pos, &step_forward);
            try expectSingleTrackedHashAt(obj, pos + 1);
        }

        // Backward one byte at a time.
        var step_backward: [hashutil.hash_token_len + 1]u8 = undefined;
        @memcpy(step_backward[0..ref_bytes.len], &ref_bytes);
        step_backward[ref_bytes.len] = '_';
        while (pos > 0) {
            pos -= 1;
            try testOverwrite(obj, pos, &step_backward);
            try expectSingleTrackedHashAt(obj, pos);
        }

        // Jumps across the boundary distances, each in a single patch.
        const token_len = hashutil.hash_token_len;
        const jumps = [_]usize{ 7, 43, token_len - 1, token_len, token_len + 1, 60, 0, token_len, 1, token_len, token_len - 1, 0, 60 };
        var cur_pos: usize = 0;
        for (jumps) |next_pos| {
            const patch_start = @min(cur_pos, next_pos);
            const patch_end = @max(cur_pos, next_pos) + ref_bytes.len;
            var patch_buf: [220]u8 = @splat('_');
            @memcpy(patch_buf[next_pos - patch_start ..][0..ref_bytes.len], &ref_bytes);

            try testOverwrite(obj, patch_start, patch_buf[0 .. patch_end - patch_start]);
            cur_pos = next_pos;
            try expectSingleTrackedHashAt(obj, cur_pos);
        }

        // Decoy prefixes ending exactly where the reference starts, and
        // starting exactly where it ends.
        try testOverwrite(obj, cur_pos - hashutil.hash_prepend.len, hashutil.hash_prepend);
        try expectSingleTrackedHashAt(obj, cur_pos);
        try testOverwrite(obj, cur_pos + ref_bytes.len, hashutil.hash_prepend);
        try expectSingleTrackedHashAt(obj, cur_pos);
    }
}

test "strpatch sliding window and boundary hash tracking" {
    try testStrpatchSlidingWindow(testing.allocator);
}

/// Patches `obj`, and if that fails, checks that neither its bytes nor its
/// tracked hashes changed.
fn testPatchOrUnchanged(obj: *Object, edit: strpatch.Edit) !void {
    const before = try global_gpa.dupe(u8, testCurrentBytes(obj));
    defer global_gpa.free(before);

    strpatch.patch(obj.asType(objects.String).?, edit) catch |err| {
        try testing.expectEqualStrings(before, testCurrentBytes(obj));
        try expectTrackedMatchesRescan(obj);
        return err;
    };
}

fn testStrpatchOom(ta: std.mem.Allocator) !void {
    try testStart(ta, null);
    defer testFinish();

    const target = try objects.String.new("oom payload");
    defer target.asHead().dropReference();
    const hash = try target.asHead().getHashRegistering();
    const ref_bytes = objects.HashReference.render(hash);

    const string = try objects.String.new("prefix:");
    defer string.asHead().dropReference();
    const obj = string.asHead();

    // Normal to special, then in place.
    try testPatchOrUnchanged(obj, .{ .start = 7, .end = 7, .bytes = ref_bytes[0..20] });
    try testPatchOrUnchanged(obj, .{ .start = 27, .end = 27, .bytes = ref_bytes[20..] });
    try expectEqual(@as(usize, 1), testTrackedHashes(obj).len);
    try expectEqual(@as(usize, 7), testTrackedHashes(obj)[0].str_index);

    // Shift the reference right by two, growing past the capacity.
    try testPatchOrUnchanged(obj, .{ .start = 0, .end = 0, .bytes = "__" });
    try expectEqual(@as(usize, 1), testTrackedHashes(obj).len);
    try expectEqual(@as(usize, 9), testTrackedHashes(obj)[0].str_index);
    try expectTrackedMatchesRescan(obj);
}

test "strpatch leaves the string unchanged on OOM" {
    try testing.checkAllAllocationFailures(testing.allocator, testStrpatchOom, .{});
}

fn testStrpatchSharedSpecial(ta: std.mem.Allocator) !void {
    try testStart(ta, null);
    defer testFinish();

    const target = try objects.String.new("shared payload");
    defer target.asHead().dropReference();
    const ref_bytes = objects.HashReference.render(try target.asHead().getHashRegistering());

    const original = try objects.String.new(&ref_bytes);
    defer original.asHead().dropReference();
    // Duplicating shares the special string rather than copying it, so the
    // patch has to copy instead of editing in place.
    const copy = try original.asHead().duplicate();
    defer copy.dropReference();

    try strpatch.patch(copy.asType(objects.String).?, .{ .start = 0, .end = 0, .bytes = "head:" });

    try testing.expectEqualStrings(&ref_bytes, testCurrentBytes(original.asHead()));
    try testing.expectEqualStrings("head:" ++ ref_bytes, testCurrentBytes(copy));
    try expectSingleTrackedHashAtIn(original.asHead(), 0);
    try expectSingleTrackedHashAtIn(copy, 5);
}

fn expectSingleTrackedHashAtIn(obj: *Object, expected_index: usize) !void {
    const tracked = testTrackedHashes(obj);
    try expectEqual(@as(usize, 1), tracked.len);
    try expectEqual(expected_index, tracked[0].str_index);
    try testing.expect(tracked[0].value != null);
}

test "strpatch copies a shared special string" {
    try testing.checkAllAllocationFailures(testing.allocator, testStrpatchSharedSpecial, .{});
}

/// Patches `obj` with `edit`, then checks its bytes against `expected`, its
/// tracked hashes against a full rescan, and that its cached hash was
/// invalidated.
fn expectPatch(obj: *Object, edit: strpatch.Edit, expected: []const u8) !void {
    _ = try obj.getHashNoRegister();
    try strpatch.patch(obj.asType(objects.String).?, edit);
    try testing.expectEqualStrings(expected, testCurrentBytes(obj));
    try expectTrackedMatchesRescan(obj);
    try expectEqual(hashutil.hashBytes(expected), try obj.getHashNoRegister());
}

fn testStrpatchEdgeCases(ta: std.mem.Allocator) !void {
    try testStart(ta, null);
    defer testFinish();

    const target = try objects.String.new("edge payload");
    defer target.asHead().dropReference();
    const ref = objects.HashReference.render(try target.asHead().getHashRegistering());
    const no_postpend = ref[0 .. ref.len - hashutil.hash_postpend.len];

    // Deleting the bytes between two halves joins them into a reference.
    {
        const string = try objects.String.new(ref[0..20] ++ "xx" ++ ref[20..]);
        defer string.asHead().dropReference();
        try expectEqual(@as(usize, 0), testTrackedHashes(string.asHead()).len);
        try expectPatch(string.asHead(), .{ .start = 20, .end = 22, .bytes = "" }, &ref);
        try expectEqual(@as(usize, 1), testTrackedHashes(string.asHead()).len);
    }

    // Deleting one byte of a reference, or inserting one inside it, breaks it.
    {
        const string = try objects.String.new(&ref);
        defer string.asHead().dropReference();
        try expectPatch(string.asHead(), .{ .start = 10, .end = 11, .bytes = "" }, ref[0..10] ++ ref[11..]);
    }
    {
        const string = try objects.String.new(&ref);
        defer string.asHead().dropReference();
        try expectPatch(string.asHead(), .{ .start = 25, .end = 25, .bytes = "_" }, ref[0..25] ++ "_" ++ ref[25..]);
    }

    // A reference is only recognized with its postpend. Without the check,
    // `no_postpend` followed by any byte would be tracked.
    {
        const string = try objects.String.new(no_postpend ++ "x");
        defer string.asHead().dropReference();
        try expectEqual(@as(usize, 0), testTrackedHashes(string.asHead()).len);
        try expectPatch(string.asHead(), .{ .start = no_postpend.len, .end = no_postpend.len + 1, .bytes = hashutil.hash_postpend }, &ref);
        try expectEqual(@as(usize, 1), testTrackedHashes(string.asHead()).len);

        try expectPatch(string.asHead(), .{ .start = no_postpend.len, .end = ref.len, .bytes = "x" }, no_postpend ++ "x");
        try expectEqual(@as(usize, 0), testTrackedHashes(string.asHead()).len);
    }

    // A reference inserted between two survivors lands between them in the
    // tracked hashes.
    {
        const string = try objects.String.new(ref ++ "||" ++ ref);
        defer string.asHead().dropReference();
        try expectPatch(string.asHead(), .{ .start = ref.len + 1, .end = ref.len + 1, .bytes = &ref }, ref ++ "|" ++ ref ++ "|" ++ ref);
        const tracked = testTrackedHashes(string.asHead());
        try expectEqual(@as(usize, 3), tracked.len);
        try expectEqual(ref.len + 1, tracked[1].str_index);
    }

    // Growing an exclusively owned special string past its capacity
    // reallocates it with spare capacity, which then has to free cleanly.
    {
        const long: [considered_large_string + 1]u8 = @splat('_');
        const string = try objects.String.new(&long);
        defer string.asHead().dropReference();
        try expectPatch(string.asHead(), .{ .start = long.len, .end = long.len, .bytes = "grown" }, &long ++ "grown");
        try expectPatch(string.asHead(), .{ .start = 0, .end = long.len + "grown".len, .bytes = &ref }, &ref);
    }

    // A copied special string that ends up small without references becomes
    // a normal string again.
    {
        const long: [considered_large_string + 1]u8 = @splat('_');
        const original = try objects.String.new(&long);
        defer original.asHead().dropReference();
        const copy = try original.asHead().duplicate();
        defer copy.dropReference();
        try expectPatch(copy, .{ .start = 1, .end = long.len, .bytes = "" }, "_");
        try testing.expect(copy.getStringDetails() == .normal);
        try testing.expectEqualStrings(&long, testCurrentBytes(original.asHead()));
    }
}

test "strpatch edge cases" {
    try testing.checkAllAllocationFailures(testing.allocator, testStrpatchEdgeCases, .{});
}

const StrpatchFuzzContext = struct {
    refs: [3][hashutil.hash_token_len]u8,
};

/// Edit bytes biased toward forming and breaking hash references.
fn fuzzEditBytes(ctx: *const StrpatchFuzzContext, smith: *std.testing.Smith, out: []u8) []const u8 {
    const ref = &ctx.refs[smith.index(ctx.refs.len)];
    switch (smith.index(7)) {
        0 => return ref,
        1 => return ref[0 .. smith.index(ref.len) + 1],
        2 => return ref[smith.index(ref.len)..],
        3 => return hashutil.hash_prepend,
        4 => return hashutil.hash_postpend,
        5 => return "",
        else => {
            const len = smith.index(out.len) + 1;
            smith.bytes(out[0..len]);
            return out[0..len];
        },
    }
}

/// Applies an edit chosen by the fuzzer, then checks the result the same way
/// `expectPatch` does, against a straightforward model.
fn fuzzOnePatch(ctx: *const StrpatchFuzzContext, smith: *std.testing.Smith, obj: *Object) !void {
    const old = try global_gpa.dupe(u8, testCurrentBytes(obj));
    defer global_gpa.free(old);

    const a = smith.index(old.len + 1);
    const b = smith.index(old.len + 1);
    var buf: [24]u8 = undefined;
    const edit: strpatch.Edit = .{
        .start = @min(a, b),
        .end = @max(a, b),
        .bytes = fuzzEditBytes(ctx, smith, &buf),
    };

    const expected = try mem.concat(global_gpa, u8, &.{ old[0..edit.start], edit.bytes, old[edit.end..] });
    defer global_gpa.free(expected);

    try expectPatch(obj, edit, expected);
}

fn testStrpatchFuzzOne(ctx: *StrpatchFuzzContext, smith: *std.testing.Smith) !void {
    // Starting long makes the first patches go in place rather than copy.
    const long: [considered_large_string + 1]u8 = @splat('_');
    const string = try objects.String.new(if (smith.value(bool)) &long else "");
    defer string.asHead().dropReference();

    const op_count = smith.valueRangeAtMost(u8, 1, 8);
    for (0..op_count) |_| try fuzzOnePatch(ctx, smith, string.asHead());
}

test "strpatch fuzz" {
    const backing_gpa = if (@import("builtin").fuzz) std.heap.c_allocator else testing.allocator;
    try testStart(backing_gpa, null);
    defer testFinish();

    var ctx: StrpatchFuzzContext = undefined;
    var targets: [3]*objects.String = undefined;
    for (&targets, &ctx.refs, 0..) |*target, *ref, i| {
        var name_buf: [24]u8 = undefined;
        target.* = try objects.String.new(try std.fmt.bufPrint(&name_buf, "fuzz payload {d}", .{i}));
        ref.* = objects.HashReference.render(try target.*.asHead().getHashRegistering());
    }
    defer for (targets) |target| target.asHead().dropReference();

    try std.testing.fuzz(&ctx, testStrpatchFuzzOne, .{});
}

//! This struct is responsible for housing Zicl's capability system. Capabilities are
//! URLs such as <zicl://folk-peridot.local/file-handle/sVye-a_2s3tvQm8xR4pLnW>,
//! with three notable parts: hostname (folk-peridot.local), capability type
//! (file-handle), and capability id (sVye-a_2s3tvQm8xR4pLnW).
//!
//! Lifetime management is manual, as in all capabilities are manually created
//! and closed. Closing is manual because everything is a string, so there's
//! no concept of reference. We were able to get away with this in the hash
//! registry because the hash registry addresses content only, but capabilities
//! are a unique identifier to, well, anything.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const builtin = @import("builtin");

const heap = @import("heap.zig");
const Object = heap.Object;
const Value = heap.Value;
const memutil = @import("memutil.zig");
const StructIterator = memutil.StructIterator;
const objects = @import("objects.zig");
const ErrorDetails = objects.ErrorDetails;

const Capability = @This();
pub const scheme_name = "zicl";
pub const scheme = scheme_name ++ "://";

/// Capability identifier. We use 128 bits since that is enough to be effectively unforgable.
pub const Id = i128;
const encoded_id_len = std.base64.url_safe_no_pad.Encoder.calcSize(@sizeOf(Id));

head: *Head,

pub fn asHead(self: *Capability) *Object {
    return Object.from(Capability, self);
}

pub fn new(head: *Head) !*Capability {
    try registry.register(head);
    errdefer registry.deregister(head);

    const new_obj = try Object.newObject(Capability);
    new_obj.body.* = .{ .head = head };
    return new_obj.body;
}

pub fn getBacking(self: *const Capability, Backing: type, det: ?*ErrorDetails) !*Backing {
    if (self.head.vtable != &Backing.vtable) {
        if (det) |details| details.* = .{
            .message = try objects.allocPrintZ(
                "expected a {s} but got a {s}",
                .{ Backing.vtable.name, self.head.vtable.name },
            ),
        };
        return error.BadCapability;
    }

    if (self.head.isClosed()) return staleError(det, try @constCast(self).asHead().getString());

    const backing: *Backing = @fieldParentPtr("head", self.head);
    return backing;
}

pub fn close(self: *Capability) void {
    self.head.close();
}

pub fn shimmerFrom(det: ?*ErrorDetails, shim: *objects.Shimmerable) !*const Capability {
    if (shim.current().asType(Capability)) |cap| return cap;

    const bytes = try shim.getString();
    const parsed = try parseName(det, bytes);

    if (!std.mem.eql(u8, parsed.host, host_name)) {
        if (det) |details| details.* = .{ .message = try objects.allocPrintZ(
            "capability \"{s}\" belongs to {s}, and capabilities cannot be used across machines",
            .{ bytes, parsed.host },
        ) };
        return error.BadCapability;
    }

    const head = registry.resolve(parsed.id) orelse return staleError(det, bytes);
    errdefer head.release();

    if (!std.mem.eql(u8, parsed.type_name, std.mem.span(head.vtable.name))) {
        // Capability type name and parsed type name aren't the same. We consider
        // this to be a stale error, so the details on whether it's registered or
        // not are not visible.
        return staleError(det, bytes);
    }

    const as_cap = try shim.prepareToShimmer(Capability);
    as_cap.* = .{ .head = head };
    return as_cap;
}

fn updateString(obj: *Object) !void {
    const self = obj.asType(Capability).?;

    var id_bytes: [@sizeOf(Id)]u8 = undefined;
    std.mem.writeInt(Id, &id_bytes, self.head.id, .big);
    var encoded: [encoded_id_len]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &id_bytes);

    const bytes = try objects.allocPrintZ("<{s}{s}/{s}/{s}>", .{
        scheme,
        host_name,
        self.head.vtable.name,
        encoded,
    });
    try obj.setStringIgnoreRace(bytes);
}

fn duplicate(src: *const Object) !*Object {
    const new_obj = try Object.newObjectUninitialized(Capability);
    errdefer new_obj.head.freeBacking();
    try src.duplicateHeadOnto(new_obj.head);
    new_obj.body.* = .{ .head = src.asTypeConst(Capability).?.head.borrow() };
    return new_obj.head;
}

fn freeInternalRep(obj: *Object) void {
    obj.asType(Capability).?.head.release();
}

fn enumerateStruct(obj: *const Object, ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
    const self = obj.asTypeConst(Capability).?;
    try ctx.followNode(Head, info, "head", self.head);
}

pub const vtable: Object.VTable = .zig(@typeName(Capability), .{
    .duplicate = duplicate,
    .free_internal_rep = freeInternalRep,
    .update_string = updateString,
    // The head is atomically reference counted and holds no Values.
    .make_crossthread = Object.noopMakeCrossthread,
    .enumerate_struct = enumerateStruct,
});

/// Heads are the generic part of a capability. Capabilities are the combination
/// of a Head and a Body, where Body is a custom type. This is currently
/// implemented as `const Backing = struct { head: Head, body: Body }`, and
/// `body` is recovered using @parentFieldPtr on the `head` pointer.
///
/// `extern` so a C program can embed a `Zicl_Head` as the first field of its own
/// backing struct and register it through the C API; the vtable-identity check
/// in `getBacking` then works uniformly for Zig- and C-created capabilities.
pub const Head = extern struct {
    vtable: *const VTable,
    id: Id,
    /// Whether the capability is dead. Needed because a capability can be
    /// closed while there are still active references to the Head.
    closed: std.atomic.Value(bool) = .init(false),
    ref_count: std.atomic.Value(u32) = .init(1),

    pub fn borrow(head: *Head) *Head {
        _ = head.ref_count.fetchAdd(1, .monotonic);
        return head;
    }

    pub fn release(head: *Head) void {
        if (head.ref_count.fetchSub(1, .release) != 1) return;
        _ = head.ref_count.load(.acquire);

        // Reaching zero implies the capability was closed, since the registry
        // holds a reference until the capability is closed.
        assert(head.closed.load(.monotonic));
        head.vtable.destroyBacking(head);
    }

    /// Deinits the body and takes the capability out of the registry, so that
    /// its string rep stops resolving from here on. Idempotent.
    pub fn close(head: *Head) void {
        if (head.closed.swap(true, .acq_rel) == true) return;
        head.vtable.deinitBody(head); // This is the implementation of closing the capability.

        // We won the swap, so we get to deregister.
        registry.deregister(head);
    }

    pub fn isClosed(head: *const Head) bool {
        return head.closed.load(.monotonic);
    }

    pub fn enumerateStruct(ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const head: *const Head = @ptrCast(@alignCast(info.node));
        const helper: objects.IterHelper = .{ .ctx = ctx, .info = info };
        try helper.addField([]const u8, "type", "{s}", .{std.mem.span(head.vtable.name)});
        try helper.addField(bool, "closed", "{}", .{head.isClosed()});
        try helper.addField(u32, "ref_count", "{}", .{head.ref_count.load(.monotonic)});
    }

    pub const VTable = extern struct {
        /// Path segment a string rep uses, such as "file-handle". NUL-terminated
        /// so the vtable is layout-compatible with C (see `Zicl_HeadVTable`).
        name: [*:0]const u8,
        /// Deinits the underlying body. Runs exactly once, from `close`.
        deinitBody: *const fn (head: *Head) callconv(.c) void,
        /// This may be called much later than `deinitBody`, as closing the capability
        /// is not the same thing as freeing the entry and body.
        destroyBacking: *const fn (head: *Head) callconv(.c) void,
    };
};

/// Maps identifiers to heads. A capability is registered at creation and is
/// deregistered when the capability is closed.
pub const Registry = struct {
    mutex: std.Io.Mutex = .init,
    /// Has strong ownership of every head in the map.
    heads: std.AutoHashMapUnmanaged(Id, *Head) = .empty,
    csprng: std.Random.DefaultCsprng = undefined,

    /// Adds `head` to the registry and assigns it an identifier. Note that
    /// `id` is not synchronized by itself, so only call `register` with
    /// a newly created, non-crossthread Head.
    pub fn register(self: *Registry, head: *Head) !void {
        self.mutex.lockUncancelable(heap.global_io);
        defer self.mutex.unlock(heap.global_io);

        try self.heads.ensureUnusedCapacity(heap.global_gpa, 1);
        errdefer comptime unreachable;

        // Generated while the mutex is locked because the generator is shared state.
        head.id = self.csprng.random().int(Id);
        self.heads.putAssumeCapacity(head.id, head.borrow());
    }

    pub fn deregister(self: *Registry, head: *Head) void {
        self.mutex.lockUncancelable(heap.global_io);
        const removed = self.heads.fetchRemove(head.id);
        self.mutex.unlock(heap.global_io);

        // Note that we assert that there was a value with `.?`,
        // since you can't deregister something that was never
        // registered.
        removed.?.value.release();
    }

    /// Resolves a registered identifier, borrowing the head for the caller.
    pub fn resolve(self: *Registry, id: Id) ?*Head {
        self.mutex.lockUncancelable(heap.global_io);
        defer self.mutex.unlock(heap.global_io);
        return (self.heads.get(id) orelse return null).borrow();
    }
};

pub var registry: Registry = .{};

/// Since all capabilities are rendered as URLs, we need a hostname to
/// associate with the URL. This also is used for cross-machine errors,
/// so we can tell the difference between a stale capability and a
/// capability that came from somewhere else.
var host_name: []const u8 = undefined;
var host_name_owned: ?[]u8 = null;

pub const Options = struct {
    /// If null, `std.posix.gethostname` will be used to select the hostname.
    host_name: ?[]const u8 = null,
};

pub fn initGlobals(options: Options) !void {
    registry = .{};

    // Seeded from the platform's secure entropy, to avoid predictable identifiers.
    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    try heap.global_io.randomSecure(&seed);
    registry.csprng = .init(seed);

    var buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const chosen = options.host_name orelse try std.posix.gethostname(&buffer);

    const owned = try heap.global_gpa.dupe(u8, chosen);
    host_name_owned = owned;
    host_name = owned;
}

pub fn deinitGlobals() void {
    // Steal the map so we can deinit atomically.
    registry.mutex.lockUncancelable(heap.global_io);
    const heads = registry.heads;
    registry.heads = .empty;
    registry.mutex.unlock(heap.global_io);
    registry = .{};

    var stolen_registry: Registry = .{
        .mutex = .init,
        .heads = heads,
        .csprng = undefined,
    };

    var iter = stolen_registry.heads.valueIterator();
    while (iter.next()) |head| head.*.close();
    stolen_registry.heads.deinit(heap.global_gpa);

    if (host_name_owned) |owned| heap.global_gpa.free(owned);
    host_name_owned = null;
    host_name = undefined;
}

/// Parsed form of a capability string rep.
pub const ParsedName = struct {
    host: []const u8,
    type_name: []const u8,
    id: Id,
};

fn parseError(det: ?*ErrorDetails, name: []const u8) error{ OutOfMemory, BadCapability } {
    if (det) |value| value.* = .{
        .message = try objects.allocPrintZ("expected a capability but got \"{s}\"", .{name}),
    };
    return error.BadCapability;
}

fn staleError(det: ?*ErrorDetails, name: []const u8) error{ OutOfMemory, StaleCapability } {
    if (det) |value| value.* = .{
        .message = try objects.allocPrintZ("capability \"{s}\" is stale", .{name}),
    };
    return error.StaleCapability;
}

pub fn parseName(det: ?*ErrorDetails, bytes: []const u8) !ParsedName {
    // Angle brackets enclose the URI, as RFC 3986 recommends.
    if (bytes.len < 2 or bytes[0] != '<' or bytes[bytes.len - 1] != '>') {
        return parseError(det, bytes);
    }
    const uri_text = bytes[1 .. bytes.len - 1];

    const uri = std.Uri.parse(uri_text) catch return parseError(det, bytes);
    if (!std.mem.eql(u8, uri.scheme, scheme_name)) return parseError(det, bytes);

    const host_component = uri.host orelse return parseError(det, bytes);
    // A bit confusing, but .percent_encoded in this context means "already in
    // a form that is percent encoded, such that no escaping is needed."
    // Since it's coming in from a well-formed URL, of course no additional
    // escaping is needed.
    const host = switch (host_component) {
        .raw, .percent_encoded => |written| written,
    };
    const path = switch (uri.path) {
        .raw, .percent_encoded => |written| written,
    };

    // Leading slash, then "<type>/<id>".
    if (path.len == 0 or path[0] != '/') return parseError(det, bytes);
    const after_slash = path[1..];

    const type_end = std.mem.indexOfScalar(u8, after_slash, '/') orelse return parseError(det, bytes);
    const encoded = after_slash[(type_end + 1)..];
    if (encoded.len != encoded_id_len) return parseError(det, bytes);

    var id_bytes: [@sizeOf(Id)]u8 = undefined;
    std.base64.url_safe_no_pad.Decoder.decode(&id_bytes, encoded) catch return parseError(det, bytes);

    return .{
        .host = host,
        .type_name = after_slash[0..type_end],
        .id = std.mem.readInt(Id, &id_bytes, .big),
    };
}

const TestCapability = struct {
    deinited_ptr: *bool,
    payload: [3]u64,

    pub fn new(deinited_ptr: *bool, payload: [3]u64) !*Capability {
        const cap_backing = try heap.global_gpa.create(Backing);
        errdefer heap.global_gpa.destroy(cap_backing);
        cap_backing.* = .{
            .head = .{ .vtable = &Backing.vtable, .id = undefined },
            .body = .{ .deinited_ptr = deinited_ptr, .payload = payload },
        };

        return try Capability.new(&cap_backing.head);
    }

    pub const Backing = struct {
        head: Head,
        body: TestCapability,

        fn deinitBody(head: *Head) callconv(.c) void {
            const backing: *Backing = @fieldParentPtr("head", head);
            backing.body.deinited_ptr.* = true;
        }

        fn destroyBacking(head: *Head) callconv(.c) void {
            const backing: *Backing = @fieldParentPtr("head", head);
            heap.global_gpa.destroy(backing);
        }

        pub const vtable: Head.VTable = .{
            .deinitBody = deinitBody,
            .destroyBacking = destroyBacking,
            .name = "test-handle",
        };
    };
};

fn testCapabilityRoundTrip(ta: std.mem.Allocator) !void {
    try heap.testStart(ta, testing.io);
    defer heap.testFinish();

    var deinited = false;
    const cap = try TestCapability.new(&deinited, .{ 1, 2, 3 });
    defer cap.asHead().release();
    // Nothing reclaims a capability on its own, so every exit from here has to
    // close, including the ones an injected allocation failure takes.
    defer cap.close();

    // The body survives the trip through the type-erased head.
    const backing = try cap.getBacking(TestCapability.Backing, null);
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, &backing.body.payload);

    const string_rep = try cap.asHead().getString();
    try testing.expect(std.mem.startsWith(u8, string_rep, "<" ++ scheme));
    try testing.expect(std.mem.endsWith(u8, string_rep, ">"));
    try testing.expect(std.mem.indexOf(u8, string_rep, "/test-handle/") != null);

    // Check that we can get the capability back from its string.
    var shim: objects.Shimmerable = .{ .original = try objects.String.newValue(string_rep) };
    defer shim.deinit();
    const resolved = try Capability.shimmerFrom(null, &shim);
    try testing.expectEqual(backing, try resolved.getBacking(TestCapability.Backing, null));

    // Trailing '>' trimmed along with the leading segments.
    const encoded_id = string_rep[std.mem.lastIndexOfScalar(u8, string_rep, '/').? + 1 .. string_rep.len - 1];

    // A name asserting another machine does not resolve here, even when the
    // identifier is one this machine would recognise. There is no remote
    // dereference, so honouring the assertion is the only correct answer.
    const elsewhere = try std.fmt.allocPrint(ta, "<{s}other-host/test-handle/{s}>", .{
        scheme, encoded_id,
    });
    defer ta.free(elsewhere);
    var elsewhere_shim: objects.Shimmerable = .{ .original = try objects.String.newValue(elsewhere) };
    defer elsewhere_shim.deinit();
    try memutil.expectErrorOrOom(error.BadCapability, Capability.shimmerFrom(null, &elsewhere_shim));

    // We create a malicious capability with an existing id, but wrong type.
    const wrong_type = try std.fmt.allocPrint(ta, "<{s}{s}/other-handle/{s}>", .{
        scheme, host_name, encoded_id,
    });
    defer ta.free(wrong_type);
    var wrong_type_shim: objects.Shimmerable = .{ .original = try objects.String.newValue(wrong_type) };
    defer wrong_type_shim.deinit();
    try memutil.expectErrorOrOom(error.StaleCapability, Capability.shimmerFrom(null, &wrong_type_shim));

    try testing.expect(!deinited);
    cap.close();
    try testing.expect(deinited);

    // Closing frees the body but not the name: it still reports staleness
    // rather than resolving to something else.
    try testing.expectError(error.StaleCapability, cap.getBacking(TestCapability.Backing, null));
}

test "capability round trip" {
    try testing.checkAllAllocationFailures(testing.allocator, testCapabilityRoundTrip, .{});
}

fn testRegistryWorksWithoutOriginalObject(ta: std.mem.Allocator) !void {
    try heap.testStart(ta, testing.io);
    defer heap.testFinish();

    var deinited = false;

    var string_rep: ?[]u8 = null;
    defer if (string_rep) |rep| heap.global_gpa.free(rep);

    var head_ref: *Head = undefined;

    // The object containing the capability is freed at the end of this block,
    // which means we can test if the capability truly outlives the original
    // object.
    {
        const cap = try TestCapability.new(&deinited, .{ 4, 5, 6 });
        defer cap.asHead().release();
        errdefer cap.close();

        head_ref = cap.head;

        string_rep = try heap.global_gpa.dupe(u8, try cap.asHead().getString());
    }

    // Capability should still be alive.
    try testing.expect(!deinited);
    defer head_ref.close();

    // And we should be able to recover it here.
    var shim: objects.Shimmerable = .{ .original = try objects.String.newValue(string_rep.?) };
    defer shim.deinit();
    const resolved = try Capability.shimmerFrom(null, &shim);
    const backing = try resolved.getBacking(TestCapability.Backing, null);
    try testing.expectEqualSlices(u64, &.{ 4, 5, 6 }, &backing.body.payload);
}

test "registry works without original object" {
    try testing.checkAllAllocationFailures(testing.allocator, testRegistryWorksWithoutOriginalObject, .{});
}

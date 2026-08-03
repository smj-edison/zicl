//! Capabilities: resources named by an unforgeable, globally meaningful string.
//!
//! A resource, here, is something the runtime holds that is not itself a value:
//! an open file, a socket, a compiled shader. It has an identity and a lifetime
//! of its own, so it cannot be copied around the way a string or a list can.
//!
//! A capability is a value that names such a resource, where holding the value
//! is what confers the right to use it. For that to work across machines the
//! name has to carry three things: which machine the resource lives on, which
//! kind of resource it is, and enough randomness that a name cannot be guessed
//! or accidentally collided with. A capability here renders as
//!
//! ```
//! zicl://folk-peridot.local/file-handles/sVye-a_2s3tvQm8xR4pLnW
//! ```
//!
//! Since every object is transparently a string, that string _is_ the
//! authority: anyone holding it holds the capability, which is why the
//! identifier is unguessable rather than merely unique.
//!
//! The usual alternative is a process-local table index. Tcl names open files
//! `file3`, for example, which reads like a value but is really an offset into
//! a per-process array. It says nothing about which machine it came from, and
//! the same text names a different file on another machine, or on the same
//! machine after a restart. Both failures are silent, which is what makes them
//! worth designing away.
//!
//! Lifetime is manual, as with any imperative resource. `[close]` releases the
//! resource, and a name whose resource is gone reports that it is stale rather
//! than resolving to something else. Identifiers are never reissued, so "stale"
//! can never be mistaken for "valid".
//!
//! Resolution is cached by shimmering rather than by an epoch. A name resolves
//! to exactly one entry forever, so a resolved pointer never goes stale; only
//! the resource behind it does, and the entry reports that about itself. That
//! is why closing a capability costs nothing for unrelated ones: there is no
//! bulk invalidation to do.

const std = @import("std");
const builtin = @import("builtin");

const assert = std.debug.assert;

const heap = @import("heap.zig");
const Object = heap.Object;
const Value = heap.Value;
const memutil = @import("memutil.zig");
const StructIterator = memutil.StructIterator;
const objects = @import("objects.zig");
const ErrorDetails = objects.ErrorDetails;

pub const scheme_name = "zicl";
pub const scheme = scheme_name ++ "://";

/// Width of a capability's identifier. Wide enough that independently generated
/// identifiers never collide without coordination, and that possessing one
/// cannot be arrived at by guessing.
pub const id_bits = 128;
const Id = std.meta.Int(.unsigned, id_bits);
const encoded_id_len = std.base64.url_safe_no_pad.Encoder.calcSize(@sizeOf(Id));

/// Describes one flavour of resource: what to call it in a name, and how to let
/// it go. Built at comptime by `Capability`, so pointer identity distinguishes
/// one flavour from another.
pub const Type = struct {
    /// Path segment a name uses, such as "file-handles".
    name: []const u8,
    /// Finalizes the underlying resource. Runs exactly once, from `Entry.close`.
    deinit: *const fn (entry: *Entry) void,
    /// Frees the entry itself, once nothing names it any more. Separate from
    /// `deinit` because the two happen at different times: a closed capability
    /// still has to exist to report that it is closed.
    destroy: *const fn (entry: *Entry) void,
};

/// The type-erased part of a live capability, which is all the registry needs
/// to see. The resource itself follows in memory, reached through the owning
/// `Capability` type that knows its shape.
///
/// Reference counted by the objects naming it, which is what lets an object
/// outlive the `[close]` that released its resource without dangling.
pub const Entry = struct {
    type: *const Type,
    /// Assigned the first time the capability is rendered as a string. Until
    /// then it has no public name and is absent from the registry, so a
    /// capability that is never printed pays for neither. Written and read
    /// under the registry lock.
    id: ?Id,
    closed: std.atomic.Value(bool),
    ref_count: std.atomic.Value(u32),

    pub fn borrow(entry: *Entry) *Entry {
        _ = entry.ref_count.fetchAdd(1, .monotonic);
        return entry;
    }

    pub fn release(entry: *Entry) void {
        // Dropping the last reference has to be serialized against `resolve`,
        // which can otherwise find this entry in the registry and borrow it
        // back to life in between the decrement and the free.
        registry.mutex.lockUncancelable(heap.global_io);

        if (entry.ref_count.fetchSub(1, .release) != 1) {
            // Someone else still names it. Not freed here.
            registry.mutex.unlock(heap.global_io);
            return;
        }
        _ = entry.ref_count.load(.acquire);

        // That was the last reference, so everything below tears the entry down.

        if (entry.id) |id| _ = registry.entries.remove(id);
        registry.mutex.unlock(heap.global_io);

        // An entry nobody names any more may never have been closed, in which
        // case it still owns its resource. Release it rather than leaking the
        // descriptor, even though reaching here means a missing [close].
        entry.close();
        entry.type.destroy(entry);
    }

    /// Finalizes the resource. Idempotent, so an explicit `[close]` followed by
    /// the last name going away does not finalize twice.
    pub fn close(entry: *Entry) void {
        if (entry.closed.swap(true, .acq_rel)) return;
        entry.type.deinit(entry);
    }

    /// Read on every use of a capability, and nothing is published alongside
    /// it, so the cheapest ordering is the right one. A close racing a use is
    /// unsynchronized either way: lifetime here is the caller's to manage.
    pub fn isClosed(entry: *const Entry) bool {
        return entry.closed.load(.monotonic);
    }
};

/// Maps public identifiers onto entries. Only holds entries that have been
/// rendered as a string, since that is when an identifier is minted.
///
/// A plain mutex rather than a read-write lock: because resolution is cached by
/// shimmering, a name is looked up once when it first arrives as a string and
/// never again, so reads are not the asymmetric case they are for the hash
/// registry. Dropping an entry needs exclusive access regardless.
pub const Registry = struct {
    mutex: std.Io.Mutex = .init,
    entries: std.AutoHashMapUnmanaged(Id, *Entry) = .empty,
    /// Identifiers must be unguessable, so this is a CSPRNG rather than the
    /// usual default-seeded generator.
    csprng: std.Random.DefaultCsprng = undefined,

    /// Mints an identifier for `entry` and publishes it. Idempotent: an entry
    /// that already has one keeps it, so a capability's string never changes.
    pub fn publish(self: *Registry, entry: *Entry) !Id {
        self.mutex.lockUncancelable(heap.global_io);
        defer self.mutex.unlock(heap.global_io);

        if (entry.id) |id| return id;

        const id = self.csprng.random().int(Id);
        try self.entries.put(heap.global_gpa, id, entry);
        entry.id = id;
        return id;
    }

    /// Resolves a published identifier, borrowing the entry for the caller.
    pub fn resolve(self: *Registry, id: Id) ?*Entry {
        self.mutex.lockUncancelable(heap.global_io);
        defer self.mutex.unlock(heap.global_io);
        const entry = self.entries.get(id) orelse return null;
        return entry.borrow();
    }
};

pub var registry: Registry = .{};

/// The authority part of a name. Only an identity hint, since a hostname is
/// neither stable nor authenticated, but it tells a reader which machine a
/// capability came from when it fails to resolve here.
/// Poisoned until `initGlobals` runs. A plausible-looking default would let a
/// missing init produce capability names that are wrong rather than absent, and
/// a name identifying the wrong machine is exactly the failure this whole design
/// exists to remove.
var host_name: []const u8 = undefined;
var host_name_owned: ?[]u8 = null;

pub const Options = struct {
    /// The name this machine goes by in the capabilities it hands out. Null
    /// asks the system, which is usually right; an embedder that already knows
    /// its own identity should say so rather than have it guessed.
    host_name: ?[]const u8 = null,
};

pub fn initGlobals(options: Options) !void {
    registry = .{};

    // Seeded from the platform's secure entropy rather than the usual
    // default-seeded generator: an identifier that can be predicted is an
    // authority that can be forged.
    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    try heap.global_io.randomSecure(&seed);
    registry.csprng = .init(seed);

    var buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const chosen = options.host_name orelse try std.posix.gethostname(&buffer);

    // Owned rather than borrowed, since the caller's string need not outlive
    // this call and `gethostname` writes into a buffer that certainly does not.
    const owned = try heap.global_gpa.dupe(u8, chosen);
    host_name_owned = owned;
    host_name = owned;
}

pub fn deinitGlobals() void {
    // Entries are owned by the objects naming them, so anything still here
    // outlived the interpreter. Release the resources; the entries themselves
    // go when their objects do.
    var iter = registry.entries.valueIterator();
    while (iter.next()) |entry| entry.*.close();
    registry.entries.deinit(heap.global_gpa);
    registry = .{};

    if (host_name_owned) |owned| heap.global_gpa.free(owned);
    host_name_owned = null;
    host_name = undefined;
}

/// Parsed form of a capability name. `host` is carried for diagnostics only:
/// there is no remote dereference, so a name from elsewhere fails rather than
/// reaching across the network.
pub const ParsedName = struct {
    host: []const u8,
    type_name: []const u8,
    id: Id,
};

pub fn parseName(det: ?*ErrorDetails, bytes: []const u8) !ParsedName {
    const bad = struct {
        fn err(details: ?*ErrorDetails, name: []const u8) error{ OutOfMemory, BadCapability } {
            if (details) |value| value.* = .{
                .message = objects.allocPrintZ(
                    "expected a capability but got \"{s}\"",
                    .{name},
                ) catch return error.OutOfMemory,
            };
            return error.BadCapability;
        }
    }.err;

    const uri = std.Uri.parse(bytes) catch return bad(det, bytes);
    if (!std.mem.eql(u8, uri.scheme, scheme_name)) return bad(det, bytes);

    // Compared as written, without percent-decoding, so that parsing a name
    // never allocates. Names are only ever produced by `updateString`, which
    // emits none of the characters that would need escaping: `capability_name`
    // is checked against the URI-unreserved set at comptime and the identifier
    // is base64url. So a name carrying escapes did not come from here, and
    // rejecting it is right. Note the failure direction: an escaped spelling
    // fails to parse rather than resolving to a different capability, which is
    // the only property that would matter for something that confers authority.
    const host_component = uri.host orelse return bad(det, bytes);
    const host = switch (host_component) {
        .raw, .percent_encoded => |written| written,
    };
    const path = switch (uri.path) {
        .raw, .percent_encoded => |written| written,
    };

    // Rejected outright rather than left to fail further along. An escape can
    // only appear in a name that did not come from `updateString`, so saying so
    // is more use than the base64 decoder happening to choke on the '%'.
    if (std.mem.indexOfScalar(u8, host, '%') != null or
        std.mem.indexOfScalar(u8, path, '%') != null)
    {
        if (det) |details| details.* = .{
            .message = try objects.allocPrintZ(
                "capability \"{s}\" is percent-encoded, which a capability name never is",
                .{bytes},
            ),
        };
        return error.BadCapability;
    }

    // Leading slash, then "<type>/<id>".
    if (path.len == 0 or path[0] != '/') return bad(det, bytes);
    const after_slash = path[1..];

    const type_end = std.mem.indexOfScalar(u8, after_slash, '/') orelse return bad(det, bytes);
    const encoded = after_slash[type_end + 1 ..];
    if (encoded.len != encoded_id_len) return bad(det, bytes);

    var id_bytes: [@sizeOf(Id)]u8 = undefined;
    std.base64.url_safe_no_pad.Decoder.decode(&id_bytes, encoded) catch return bad(det, bytes);

    return .{
        .host = host,
        .type_name = after_slash[0..type_end],
        .id = std.mem.readInt(Id, &id_bytes, .big),
    };
}

/// Builds the object type for capabilities over `Resource`, which must declare
/// the path segment its names use and how to let go of itself:
///
/// ```zig
/// const FileHandle = struct {
///     pub const capability_name = "file-handles";
///     file: std.Io.File,
///     pub fn deinit(self: *FileHandle) void { self.file.close(); }
/// };
/// const FileCapability = capability.Capability(FileHandle);
/// ```
///
/// One object type per resource rather than a single erased one, so a resource
/// keeps its real shape instead of being flattened into a word, and so holding
/// the wrong kind of capability is a type error rather than a runtime check.
pub fn Capability(comptime Resource: type) type {
    comptime {
        // The name goes into a URL unescaped, so anything needing escaping
        // would produce a name that does not round-trip through `parseName`.
        for (Resource.capability_name) |char| {
            const is_unreserved = std.ascii.isAlphanumeric(char) or
                char == '-' or char == '.' or char == '_' or char == '~';
            if (!is_unreserved) @compileError(
                "capability_name must be URI-unreserved, but \"" ++
                    Resource.capability_name ++ "\" is not",
            );
        }
    }

    return struct {
        const Self = @This();

        /// The entry and its resource share one allocation, so the registry can
        /// hold every flavour uniformly as a `*Entry` while each capability type
        /// recovers its own resource from that pointer. Field order is left to
        /// the compiler: `@fieldParentPtr` works from whatever offset it picks.
        const Backing = struct {
            entry: Entry,
            resource: Resource,
        };

        const capability_type: Type = .{
            .name = Resource.capability_name,
            .deinit = deinitResource,
            .destroy = destroyEntry,
        };

        entry: *Entry,

        fn deinitResource(entry: *Entry) void {
            const backing: *Backing = @fieldParentPtr("entry", entry);
            backing.resource.deinit();
        }

        fn destroyEntry(entry: *Entry) void {
            const backing: *Backing = @fieldParentPtr("entry", entry);
            heap.global_gpa.destroy(backing);
        }

        pub fn asHead(self: *Self) *Object {
            return Object.from(Self, self);
        }

        /// Creates a capability owning `resource`. The object is the caller's.
        pub fn create(resource: Resource) !*Self {
            const backing = try heap.global_gpa.create(Backing);
            errdefer heap.global_gpa.destroy(backing);
            backing.* = .{
                .entry = .{
                    .type = &capability_type,
                    .id = null,
                    .closed = .init(false),
                    .ref_count = .init(1),
                },
                .resource = resource,
            };

            const new_obj = try Object.newObject(Self);
            new_obj.body.* = .{ .entry = &backing.entry };
            return new_obj.body;
        }

        /// Returns the resource, or reports that this capability no longer names
        /// a live one. The pointer is valid for as long as the caller holds the
        /// object, which owns a reference to the entry for its whole life, so
        /// there is nothing further to synchronize or release.
        pub fn getResource(self: *const Self, det: ?*ErrorDetails) !*Resource {
            if (self.entry.isClosed()) {
                if (det) |details| details.* = .{
                    .message = try objects.allocPrintZ(
                        "capability has already been closed",
                        .{},
                    ),
                };
                return error.StaleCapability;
            }
            const backing: *Backing = @fieldParentPtr("entry", self.entry);
            return &backing.resource;
        }

        pub fn close(self: *Self) void {
            self.entry.close();
        }

        /// Resolves a name into the capability it refers to. Only capabilities
        /// of this type on this machine resolve; anything else is reported
        /// rather than being silently treated as local.
        pub fn shimmerFrom(det: ?*ErrorDetails, shim: *objects.Shimmerable) !*const Self {
            if (shim.current().asType(Self)) |existing| return existing;

            const bytes = try shim.getString();
            const parsed = try parseName(det, bytes);

            // Checked before resolving, not just reported when resolution
            // fails. A name asserts which machine its resource lives on, and
            // ignoring that assertion would let a name that says it belongs
            // elsewhere quietly resolve to a local resource instead.
            if (!std.mem.eql(u8, parsed.host, host_name)) {
                if (det) |details| details.* = .{
                    .message = try objects.allocPrintZ(
                        "capability \"{s}\" belongs to {s}, and capabilities cannot be used across machines",
                        .{ bytes, parsed.host },
                    ),
                };
                return error.StaleCapability;
            }

            const entry = registry.resolve(parsed.id) orelse {
                if (det) |details| details.* = .{
                    .message = try objects.allocPrintZ("capability \"{s}\" is stale", .{bytes}),
                };
                return error.StaleCapability;
            };
            errdefer entry.release();

            // A name carries its type, and identifiers are never reissued, so a
            // mismatch means the name was built by hand or truncated rather
            // than that the resource changed shape.
            if (entry.type != &capability_type) {
                if (det) |details| details.* = .{
                    .message = try objects.allocPrintZ(
                        "capability \"{s}\" is a {s}, not a {s}",
                        .{ bytes, entry.type.name, Resource.capability_name },
                    ),
                };
                return error.BadCapability;
            }

            const body = try shim.prepareToShimmer(Self);
            body.* = .{ .entry = entry };
            return body;
        }

        /// Minting the identifier here rather than at creation is what makes the
        /// public name lazy: a capability that is never rendered never gets one.
        fn updateString(obj: *Object) !void {
            const self = obj.asType(Self).?;
            const id = try registry.publish(self.entry);

            var id_bytes: [@sizeOf(Id)]u8 = undefined;
            std.mem.writeInt(Id, &id_bytes, id, .big);
            var encoded: [encoded_id_len]u8 = undefined;
            _ = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &id_bytes);

            const bytes = try objects.allocPrintZ("{s}{s}/{s}/{s}", .{
                scheme,
                host_name,
                Resource.capability_name,
                encoded,
            });
            try obj.setStringIgnoreRace(bytes);
        }

        /// A duplicate aliases the same resource rather than copying it, which
        /// is the opposite of every other type here. Copying would have to mean
        /// duplicating the resource itself, and two handles onto one file with
        /// independent positions is not what duplicating a value should mean.
        fn duplicate(src: *const Object) !*Object {
            const new_obj = try Object.newObjectUninitialized(Self);
            errdefer new_obj.head.freeBacking();
            try src.duplicateHeadOnto(new_obj.head);
            new_obj.body.* = .{ .entry = src.asTypeConst(Self).?.entry.borrow() };
            return new_obj.head;
        }

        fn freeInternalRep(obj: *Object) void {
            obj.asType(Self).?.entry.release();
        }

        fn enumerateStruct(obj: *const Object, ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
            const self = obj.asTypeConst(Self).?;
            try ctx.addField(bool, info, "closed", "{}", .{self.entry.isClosed()});
        }

        pub const vtable: Object.VTable = .{
            .duplicate = duplicate,
            .free_internal_rep = freeInternalRep,
            .update_string = updateString,
            // The entry is atomically reference counted and holds no Values, so
            // there is nothing below this to mark.
            .make_crossthread = Object.noopMakeCrossthread,
            .enumerate_struct = enumerateStruct,
            .name = @typeName(Self),
        };
    };
}

const testing = std.testing;

/// Deliberately larger than a word and with a field after the flag, so that
/// recovering it from a `*Entry` exercises a real offset rather than one that
/// would work by accident.
const TestResource = struct {
    pub const capability_name = "test-handles";

    deinited: *bool,
    payload: [3]u64,

    pub fn deinit(self: *TestResource) void {
        self.deinited.* = true;
    }
};

fn testCapabilityRoundTrip(ta: std.mem.Allocator) !void {
    try heap.testStart(ta, testing.io);
    defer heap.testFinish();

    const TestCapability = Capability(TestResource);

    var deinited = false;
    const cap = try TestCapability.create(.{ .deinited = &deinited, .payload = .{ 1, 2, 3 } });
    defer cap.asHead().release();

    // The resource survives the trip through the type-erased entry.
    const resource = try cap.getResource(null);
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, &resource.payload);

    const name = try cap.asHead().getString();
    try testing.expect(std.mem.startsWith(u8, name, scheme));
    try testing.expect(std.mem.indexOf(u8, name, "/test-handles/") != null);

    // The name resolves back to the same resource, which is the whole point.
    var shim: objects.Shimmerable = .{ .original = try objects.String.newValue(name) };
    defer shim.deinit();
    const resolved = try TestCapability.shimmerFrom(null, &shim);
    try testing.expectEqual(resource, try resolved.getResource(null));

    // A name keeps the same string once minted, so it stays resolvable.
    try testing.expectEqualStrings(name, try cap.asHead().getString());

    const encoded_id = name[std.mem.lastIndexOfScalar(u8, name, '/').? + 1 ..];

    // Names are matched as written rather than percent-decoded, so an escaped
    // spelling of a real identifier is rejected. What matters is the direction
    // of the failure: it must not resolve to some other capability.
    const escaped = try std.fmt.allocPrint(ta, "{s}{s}/test-handles/%2D{s}", .{
        scheme, host_name, encoded_id[1..],
    });
    defer ta.free(escaped);
    var escaped_shim: objects.Shimmerable = .{ .original = try objects.String.newValue(escaped) };
    defer escaped_shim.deinit();
    try memutil.expectErrorOrOom(error.BadCapability, TestCapability.shimmerFrom(null, &escaped_shim));

    // A name asserting another machine does not resolve here, even when the
    // identifier is one this machine would recognise. There is no remote
    // dereference, so honouring the assertion is the only correct answer.
    const elsewhere = try std.fmt.allocPrint(ta, "{s}other-host/test-handles/{s}", .{
        scheme, encoded_id,
    });
    defer ta.free(elsewhere);
    var elsewhere_shim: objects.Shimmerable = .{ .original = try objects.String.newValue(elsewhere) };
    defer elsewhere_shim.deinit();
    try memutil.expectErrorOrOom(error.StaleCapability, TestCapability.shimmerFrom(null, &elsewhere_shim));

    try testing.expect(!deinited);
    cap.close();
    try testing.expect(deinited);

    // Closing frees the resource but not the name: it still reports staleness
    // rather than resolving to something else.
    try testing.expectError(error.StaleCapability, cap.getResource(null));
}

test "capability round trip" {
    try testing.checkAllAllocationFailures(testing.allocator, testCapabilityRoundTrip, .{});
}

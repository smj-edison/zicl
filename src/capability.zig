//! This struct is responsible for housing Zicl's capability system. Capabilities are
//! URLs such as <zicl://folk-peridot.local/file-handle/sVye-a_2s3tvQm8xR4pLnW>,
//! with three notable parts: hostname (folk-peridot.local), capability type
//! (file-handle), and capability id (sVye-a_2s3tvQm8xR4pLnW).
//!
//! Lifetime management is manual, as in all capabilities are manually created
//! and closed.
//!
//! Capabilities lazily generate their id, so most of the time a capability will
//! only be an object allocation + the capability allocation.

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

/// Capability identifier. We use 128 bits since that is enough to be effectively unforgable.
const Id = i128;
const encoded_id_len = std.base64.url_safe_no_pad.Encoder.calcSize(@sizeOf(Id));

/// Heads are the generic part of a capability. Capabilities are the combination
/// of a Head and a Body, where Body is custom to each type. This is currently
/// implemented as `const Backing = struct { head: Head, body: Body }`, and
/// `body` is recovered using @parentFieldPtr on the `head` pointer.
pub const Head = struct {
    vtable: *const VTable,
    id: struct {
        /// Set to maxInt by default to be poisoned.
        raw: Id = std.math.maxInt(Id),
        /// Must always monotonically increase through the states.
        state: std.atomic.Value(enum(u8) {
            not_set,
            registering,
            registered,
        }) = .init(.not_set),

        pub fn get(self: *const @This()) ?Id {
            // We always synchronize on `state`.
            var register_state = self.state.load(.acquire);
            if (register_state == .not_set) return null;

            while (register_state == .registering) {
                // Spin until the registering finishes. Registering is just setting a value, so
                // it shouldn't take long at all.
                register_state = self.state.load(.acquire);
            }
            assert(register_state == .registered);
            return self.raw; // Happens-after the .release on `self.state`.
        }

        pub fn set(self: *@This(), value: Id) !void {
            if (self.state.cmpxchgStrong(.not_set, .registering, .monotonic, .monotonic)) |_| return error.OtherThreadSet;
            // We successfully set state to registering, so now we'll do the actual registration.
            self.raw = value;
            self.state.store(.registered, .release);
        }
    },
    /// When closed, it means the capability is dead. We need this because there may still be
    /// references to the Head, even though it's been closed.
    closed: std.atomic.Value(bool),
    ref_count: std.atomic.Value(u32),

    pub fn borrow(head: *Head) *Head {
        _ = head.ref_count.fetchAdd(1, .monotonic);
        return head;
    }

    /// Takes a reference only if the object is still alive, returning null if the
    /// reference count is zero.
    ///
    /// The registry stores heads without owning them, so presence in the map
    /// does not imply the head is alive. A head whose count has reached zero is
    /// on its way to being destroyed but stays findable until it deregisters,
    /// and handing it out would revive an object mid-teardown. Declining to
    /// count up from zero closes that window without `release` having to hold
    /// the registry lock.
    fn tryBorrow(head: *Head) ?*Head {
        var current = head.ref_count.load(.monotonic);
        while (current != 0) {
            current = head.ref_count.cmpxchgWeak(current, current + 1, .acquire, .monotonic) orelse return head;
        }
        return null;
    }

    pub fn release(head: *Head) void {
        if (head.ref_count.fetchSub(1, .release) != 1) return;
        _ = head.ref_count.load(.acquire);

        // Nothing names this any more. A caller may never have closed it, so
        // close now; the body would otherwise be leaked.
        head.close();
        head.vtable.destroyBacking(head);
    }

    /// Deinits the body and removes the capability from the registry, so
    /// that its name stops resolving from here on. Idempotent.
    pub fn close(head: *Head) void {
        if (head.closed.swap(true, .acq_rel) == true) return;

        // An identifier exists only once the capability has been rendered as a
        // string, and most never are, so most closes take no lock.
        if (head.id.get()) |id| {
            registry.mutex.lockUncancelable(heap.global_io);
            _ = registry.heads.remove(id);
            registry.mutex.unlock(heap.global_io);
        }

        head.vtable.deinitBody(head);
    }

    pub fn isClosed(head: *const Head) bool {
        // Monotonic load because the flag carries nothing with it: seeing false says
        // only that the capability was open at some point during the call. A close
        // running concurrently with a use is a caller error under any ordering,
        // since lifetimes here are managed by hand.
        return head.closed.load(.monotonic);
    }

    pub const VTable = struct {
        /// Path segment a name uses, such as "file-handle".
        name: []const u8,
        /// Deinits the underlying body. Runs exactly once, from `close`.
        deinitBody: *const fn (head: *Head) void,
        /// Frees the backing itself, once nothing names it any more. Separate from
        /// `deinit` because the two happen at different times: a closed
        /// capability still has to exist in order to report that it is closed.
        destroyBacking: *const fn (head: *Head) void,
    };
};

/// Maps identifiers onto heads. A head appears here only once its capability
/// has been rendered as a string, which is when an identifier is minted, and
/// leaves when the capability is closed.
///
/// A plain mutex is enough because lookups are rare: resolving a name converts
/// the object holding it into a `Capability` in place, so a given name is
/// looked up once when it first arrives as text and never again.
pub const Registry = struct {
    mutex: std.Io.Mutex = .init,
    /// Holds its heads without owning them; see `Head.tryBorrow`.
    heads: std.AutoHashMapUnmanaged(Id, *Head) = .empty,
    /// Identifiers must be unguessable, so this is a CSPRNG rather than the
    /// usual default-seeded generator.
    csprng: std.Random.DefaultCsprng = undefined,

    /// Creates an identifier for `head` and registers it. Idempotent: a head that
    /// already has one keeps it, so a capability's string never changes.
    pub fn register(self: *Registry, head: *Head) !Id {
        self.mutex.lockUncancelable(heap.global_io);
        defer self.mutex.unlock(heap.global_io);

        if (head.id.get()) |id| return id; // ID already set.

        const id = self.csprng.random().int(Id);
        head.id.set(id) catch |err| switch (err) {
            error.OtherThreadSet => return head.id.get().?, // Reload the new ID.
        };
        // Only register if we were the ones to successfully set the ID.
        try self.heads.put(heap.global_gpa, id, head);
        return id;
    }

    /// Resolves a published identifier, borrowing the head for the caller.
    pub fn resolve(self: *Registry, id: Id) ?*Head {
        self.mutex.lockUncancelable(heap.global_io);
        defer self.mutex.unlock(heap.global_io);
        const head = self.heads.get(id) orelse return null;
        // Presence in the map does not mean the head is still alive, as it
        // may be in the process of deiniting.
        return head.tryBorrow();
    }
};

pub var registry: Registry = .{};

/// The authority part of a name. A hostname is neither stable nor
/// authenticated, so it serves only to tell a reader which machine a capability
/// came from; nothing trusts it.
///
/// Left poisoned until `initGlobals` runs, since a default would let a missing
/// init create names identifying the wrong machine, which is worse than creating
/// none at all.
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

    // Seeded from the platform's secure entropy, to avoid predictable IDs.
    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    try heap.global_io.randomSecure(&seed);
    registry.csprng = .init(seed);

    var buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const chosen = options.host_name orelse try std.posix.gethostname(&buffer);

    // Copied, since the caller's string need not outlive this call and
    // `gethostname` writes into a stack buffer that certainly does not.
    const owned = try heap.global_gpa.dupe(u8, chosen);
    host_name_owned = owned;
    host_name = owned;
}

/// Requires that no other thread is still using capabilities: every live
/// capability is deinitialized here, so a thread holding one would have it
/// closed underneath it.
pub fn deinitGlobals() void {
    // We move it out under the lock, so that `close` below is free to take the
    // lock for itself without deadlocking, and so that removing entries cannot
    // invalidate the iterator walking them.
    registry.mutex.lockUncancelable(heap.global_io);
    var heads = registry.heads;
    registry.heads = .empty;
    registry.mutex.unlock(heap.global_io);

    // Anything still registered was never closed, so close it now to deinit its
    // body. Each one tries to deregister itself and harmlessly finds nothing,
    // the map having already been emptied. The heads themselves belong to the
    // objects naming them and go when those do.
    var iter = heads.valueIterator();
    while (iter.next()) |head| head.*.close();
    heads.deinit(heap.global_gpa);

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

/// Errors come in exactly two kinds, and the split is deliberate.
///
/// `BadCapability` means the string cannot name a capability of this type on
/// this machine. Everything it covers is decidable from the string alone, so
/// its messages can be specific without telling the caller anything they could
/// not already work out for themselves.
///
/// `StaleCapability` means the string is a well-formed local name, but nothing
/// live answers to it. Deciding that requires the registry, so every way of
/// reaching it reports the same thing. Whether an identifier is unknown, closed,
/// or in use by a capability of another type is state belonging to whoever holds
/// that capability, and a caller presenting a name they were not given does not
/// get to learn which it is.
fn parseError(details: ?*ErrorDetails, name: []const u8) error{ OutOfMemory, BadCapability } {
    if (details) |value| value.* = .{
        .message = try objects.allocPrintZ("expected a capability but got \"{s}\"", .{name}),
    };
    return error.BadCapability;
}

fn staleError(details: ?*ErrorDetails, name: []const u8) error{ OutOfMemory, StaleCapability } {
    if (details) |value| value.* = .{
        .message = try objects.allocPrintZ("capability \"{s}\" is stale", .{name}),
    };
    return error.StaleCapability;
}

pub fn parseName(det: ?*ErrorDetails, bytes: []const u8) !ParsedName {
    // Angle brackets delimit the URI, as RFC 3986 recommends for one embedded
    // in running text. Every value here is transparently a string, so a
    // capability regularly ends up inside a larger one, and the brackets are
    // what mark where it starts and stops.
    if (bytes.len < 2 or bytes[0] != '<' or bytes[bytes.len - 1] != '>') {
        return parseError(det, bytes);
    }
    const uri_text = bytes[1 .. bytes.len - 1];

    const uri = std.Uri.parse(uri_text) catch return parseError(det, bytes);
    if (!std.mem.eql(u8, uri.scheme, scheme_name)) return parseError(det, bytes);

    // Taken as written, never percent-decoded, so that parsing allocates
    // nothing. A name minted by `updateString` contains nothing that needs
    // escaping: `capability_name` is checked against the URI-unreserved set at
    // comptime, and the identifier is base64url.
    //
    // An escaped name therefore did not come from here, and falls out below
    // when its identifier fails to decode. That direction matters: an escaped
    // spelling of a real identifier is refused rather than decoded into some
    // other capability, which is the only property worth having in a string
    // that confers authority.
    const host_component = uri.host orelse return parseError(det, bytes);
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
    const encoded = after_slash[type_end + 1 ..];
    if (encoded.len != encoded_id_len) return parseError(det, bytes);

    var id_bytes: [@sizeOf(Id)]u8 = undefined;
    std.base64.url_safe_no_pad.Decoder.decode(&id_bytes, encoded) catch return parseError(det, bytes);

    return .{
        .host = host,
        .type_name = after_slash[0..type_end],
        .id = std.mem.readInt(Id, &id_bytes, .big),
    };
}

/// Builds the object type for capabilities using `Body`, which must declare
/// the path segment its names use and how to let go of itself:
/// ```zig
/// const FileHandle = struct {
///     pub const capability_name = "file-handle";
///     file: std.Io.File,
///     pub fn deinit(self: *FileHandle) void { self.file.close(); }
/// };
/// const FileCapability = capability.Capability(FileHandle);
/// ```
/// Each body gets its own object type, so it keeps its real shape rather
/// than being flattened into a word, and so holding the wrong kind of
/// capability is caught at compile time.
pub fn Capability(Body: type) type {
    comptime {
        // The name goes into a URL unescaped, so anything needing escaping
        // would produce a name that does not round-trip through `parseName`.
        for (Body.capability_name) |char| {
            const is_unreserved = std.ascii.isAlphanumeric(char) or
                char == '-' or char == '.' or char == '_' or char == '~';
            if (!is_unreserved) @compileError(
                "capability_name must be URI-unreserved, but \"" ++
                    Body.capability_name ++ "\" is not",
            );
        }
    }

    return struct {
        const Self = @This();

        /// The head and its body share one allocation, so the registry can hold
        /// every kind of capability uniformly as a `*Head` while each capability
        /// type recovers its own body from that pointer. Field order is left to
        /// the compiler: `@fieldParentPtr` works from whatever offset it picks.
        const Backing = struct {
            header: Head,
            body: Body,
        };

        const capability_vtable: Head.VTable = .{
            .name = Body.capability_name,
            .deinitBody = deinitBody,
            .destroyBacking = destroyBacking,
        };

        head: *Head,

        fn deinitBody(head: *Head) void {
            const backing: *Backing = @fieldParentPtr("header", head);
            backing.body.deinit();
        }

        fn destroyBacking(head: *Head) void {
            const backing: *Backing = @fieldParentPtr("header", head);
            heap.global_gpa.destroy(backing);
        }

        pub fn asHead(self: *Self) *Object {
            return Object.from(Self, self);
        }

        /// Creates a capability owning `body`. The object is the caller's.
        pub fn create(body: Body) !*Self {
            const backing = try heap.global_gpa.create(Backing);
            errdefer heap.global_gpa.destroy(backing);
            backing.* = .{
                .header = .{
                    .vtable = &capability_vtable,
                    .id = .{},
                    .closed = .init(false),
                    .ref_count = .init(1),
                },
                .body = body,
            };

            const new_obj = try Object.newObject(Self);
            new_obj.body.* = .{ .head = &backing.header };
            return new_obj.body;
        }

        /// Returns the body, or reports that this capability no longer names a
        /// live body. The pointer stays valid for as long as the caller
        /// holds the object, which owns a reference to the head for its whole
        /// life, so there is nothing further to synchronize or release.
        pub fn getBody(self: *const Self, det: ?*ErrorDetails) !*Body {
            if (self.head.isClosed()) {
                // The same wording a name that fails to resolve gets. Holding a
                // closed capability and holding a name for one that was never
                // yours are different situations, but they are the same answer:
                // this does not name anything usable.
                const obj = Object.fromConst(Self, self);
                return staleError(det, obj.maybeGetString() orelse "");
            }
            const backing: *Backing = @fieldParentPtr("header", self.head);
            return &backing.body;
        }

        pub fn close(self: *Self) void {
            self.head.close();
        }

        /// Resolves a name into the capability it refers to. Only capabilities
        /// of this type on this machine resolve; anything else is reported
        /// rather than being silently treated as local.
        pub fn shimmerFrom(det: ?*ErrorDetails, shim: *objects.Shimmerable) !*const Self {
            if (shim.current().asType(Self)) |existing| return existing;

            const bytes = try shim.getString();
            const parsed = try parseName(det, bytes);

            // A name states which machine its body lives on, and that
            // statement is binding: without this, a name belonging to another
            // machine would resolve to whichever local capability happened to
            // share its identifier.
            if (!std.mem.eql(u8, parsed.host, host_name)) {
                if (det) |details| details.* = .{
                    .message = try objects.allocPrintZ(
                        "capability \"{s}\" belongs to {s}, and capabilities cannot be used across machines",
                        .{ bytes, parsed.host },
                    ),
                };
                return error.BadCapability;
            }

            // Checked against the name as written, which keeps names canonical:
            // exactly one spelling refers to any given capability, and a typo in
            // the type segment is reported as such instead of surviving to the
            // identifier.
            if (!std.mem.eql(u8, parsed.type_name, Body.capability_name)) {
                if (det) |details| details.* = .{
                    .message = try objects.allocPrintZ(
                        "capability \"{s}\" names a {s}, not a {s}",
                        .{ bytes, parsed.type_name, Body.capability_name },
                    ),
                };
                return error.BadCapability;
            }

            const head = registry.resolve(parsed.id) orelse return staleError(det, bytes);
            errdefer head.release();

            // The name spells this type but its identifier belongs to another,
            // so the name was assembled rather than minted. Reported exactly as
            // an unknown identifier is: the caller does not hold whatever this
            // identifier names, so what it is, or that it is anything, is not
            // theirs to find out by asking.
            if (head.vtable != &capability_vtable) return staleError(det, bytes);

            const body = try shim.prepareToShimmer(Self);
            body.* = .{ .head = head };
            return body;
        }

        /// Minting the identifier here rather than at creation is what makes the
        /// public name lazy: a capability that is never rendered never gets one.
        fn updateString(obj: *Object) !void {
            const self = obj.asType(Self).?;
            const id = try registry.register(self.head);

            var id_bytes: [@sizeOf(Id)]u8 = undefined;
            std.mem.writeInt(Id, &id_bytes, id, .big);
            var encoded: [encoded_id_len]u8 = undefined;
            _ = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &id_bytes);

            const bytes = try objects.allocPrintZ("<{s}{s}/{s}/{s}>", .{
                scheme,
                host_name,
                Body.capability_name,
                encoded,
            });
            try obj.setStringIgnoreRace(bytes);
        }

        /// A duplicate aliases the same body rather than copying it, which
        /// is the opposite of every other type here. Copying would have to mean
        /// duplicating the body itself, and two handles onto one file with
        /// independent positions is not what duplicating a value should mean.
        fn duplicate(src: *const Object) !*Object {
            const new_obj = try Object.newObjectUninitialized(Self);
            errdefer new_obj.head.freeBacking();
            try src.duplicateHeadOnto(new_obj.head);
            new_obj.body.* = .{ .head = src.asTypeConst(Self).?.head.borrow() };
            return new_obj.head;
        }

        fn freeInternalRep(obj: *Object) void {
            obj.asType(Self).?.head.release();
        }

        fn enumerateStruct(obj: *const Object, ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
            const self = obj.asTypeConst(Self).?;
            try ctx.addField(bool, info, "closed", "{}", .{self.head.isClosed()});
        }

        pub const vtable: Object.VTable = .{
            .duplicate = duplicate,
            .free_internal_rep = freeInternalRep,
            .update_string = updateString,
            // The head is atomically reference counted and holds no Values, so
            // there is nothing below this to mark.
            .make_crossthread = Object.noopMakeCrossthread,
            .enumerate_struct = enumerateStruct,
            .name = @typeName(Self),
        };
    };
}

const testing = std.testing;

/// Deliberately wider than a word, with a field after the flag, so that
/// recovering the body from a `*Head` exercises a real offset rather than one
/// that would work by accident.
const TestBody = struct {
    pub const capability_name = "test-handle";

    deinited: *bool,
    payload: [3]u64,

    pub fn deinit(self: *TestBody) void {
        self.deinited.* = true;
    }
};

/// A second kind of capability, so that a name can be forged carrying an
/// identifier that really exists but belongs to something else.
const OtherBody = struct {
    pub const capability_name = "other-handle";

    pub fn deinit(self: *OtherBody) void {
        _ = self;
    }
};

fn testCapabilityRoundTrip(ta: std.mem.Allocator) !void {
    try heap.testStart(ta, testing.io);
    defer heap.testFinish();

    const TestCapability = Capability(TestBody);

    var deinited = false;
    const cap = try TestCapability.create(.{ .deinited = &deinited, .payload = .{ 1, 2, 3 } });
    defer cap.asHead().release();

    // The body survives the trip through the type-erased head.
    const body = try cap.getBody(null);
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, &body.payload);

    const name = try cap.asHead().getString();
    try testing.expect(std.mem.startsWith(u8, name, "<" ++ scheme));
    try testing.expect(std.mem.endsWith(u8, name, ">"));
    try testing.expect(std.mem.indexOf(u8, name, "/test-handle/") != null);

    // The name resolves back to the same body, which is the whole point.
    var shim: objects.Shimmerable = .{ .original = try objects.String.newValue(name) };
    defer shim.deinit();
    const resolved = try TestCapability.shimmerFrom(null, &shim);
    try testing.expectEqual(body, try resolved.getBody(null));

    // A name keeps the same string once minted, so it stays resolvable.
    try testing.expectEqualStrings(name, try cap.asHead().getString());

    // Trailing '>' trimmed along with the leading segments.
    const encoded_id = name[std.mem.lastIndexOfScalar(u8, name, '/').? + 1 .. name.len - 1];

    // Names are matched as written rather than percent-decoded, so an escaped
    // spelling of a real identifier is rejected. What matters is the direction
    // of the failure: it must not resolve to some other capability.
    const escaped = try std.fmt.allocPrint(ta, "<{s}{s}/test-handle/%2D{s}>", .{
        scheme, host_name, encoded_id[1..],
    });
    defer ta.free(escaped);
    var escaped_shim: objects.Shimmerable = .{ .original = try objects.String.newValue(escaped) };
    defer escaped_shim.deinit();
    try memutil.expectErrorOrOom(error.BadCapability, TestCapability.shimmerFrom(null, &escaped_shim));

    // A name asserting another machine does not resolve here, even when the
    // identifier is one this machine would recognise. There is no remote
    // dereference, so honouring the assertion is the only correct answer.
    const elsewhere = try std.fmt.allocPrint(ta, "<{s}other-host/test-handle/{s}>", .{
        scheme, encoded_id,
    });
    defer ta.free(elsewhere);
    var elsewhere_shim: objects.Shimmerable = .{ .original = try objects.String.newValue(elsewhere) };
    defer elsewhere_shim.deinit();
    try memutil.expectErrorOrOom(error.BadCapability, TestCapability.shimmerFrom(null, &elsewhere_shim));

    // The type segment is part of the name, not decoration, so a live
    // identifier under the wrong one does not resolve. Without this exactly one
    // spelling would refer to a capability, and every other would too.
    const wrong_type = try std.fmt.allocPrint(ta, "<{s}{s}/other-handle/{s}>", .{
        scheme, host_name, encoded_id,
    });
    defer ta.free(wrong_type);
    var wrong_type_shim: objects.Shimmerable = .{ .original = try objects.String.newValue(wrong_type) };
    defer wrong_type_shim.deinit();
    try memutil.expectErrorOrOom(error.BadCapability, TestCapability.shimmerFrom(null, &wrong_type_shim));

    // A forged name: correct in every part a reader could check, but carrying
    // an identifier that belongs to a capability of another type. It must be
    // refused exactly as an unknown identifier is, and the message must not
    // reveal what the identifier really names, since the caller does not hold
    // it and could not otherwise find out.
    const OtherCapability = Capability(OtherBody);
    const other = try OtherCapability.create(.{});
    defer other.asHead().release();
    defer other.close();

    const other_name = try other.asHead().getString();
    const other_id = other_name[std.mem.lastIndexOfScalar(u8, other_name, '/').? + 1 .. other_name.len - 1];
    const forged = try std.fmt.allocPrint(ta, "<{s}{s}/test-handle/{s}>", .{
        scheme, host_name, other_id,
    });
    defer ta.free(forged);
    var forged_shim: objects.Shimmerable = .{ .original = try objects.String.newValue(forged) };
    defer forged_shim.deinit();

    var det: ErrorDetails = undefined;
    try memutil.expectErrorOrOom(error.StaleCapability, TestCapability.shimmerFrom(&det, &forged_shim));
    defer heap.global_gpa.free(det.message);
    try testing.expect(std.mem.indexOf(u8, det.message, OtherBody.capability_name) == null);

    try testing.expect(!deinited);
    cap.close();
    try testing.expect(deinited);

    // Closing frees the body but not the name: it still reports staleness
    // rather than resolving to something else.
    try testing.expectError(error.StaleCapability, cap.getBody(null));
}

test "capability round trip" {
    try testing.checkAllAllocationFailures(testing.allocator, testCapabilityRoundTrip, .{});
}

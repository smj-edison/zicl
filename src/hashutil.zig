const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const ioutil = @import("ioutil.zig");
const heap = @import("heap.zig");
const Object = heap.Object;
const Value = heap.Value;
const SpecialString = heap.SpecialString;

// It is _very important_ that we have both a hash prepend and a hash
// postpend that are unique from the body of the hash, and from each other.
// That's what makes it mathematically impossible for hashes to overlap. Or
// else this terrible thing could happen with no postpend:
//                        V   Start of another hash, that was _embedded_
// blake3.hash-here-blake3.   inside the first hash. That means that two
// ^^     valid hash    ^^    hash references can exist _overlapping_. Not
//                            exactly the best idea.
// So we have the "." prepend and "~" postpend to make sure that hashes can
// never overlap.

pub const HashBacking = u256;
pub const hash_prepend = "blake3.";
pub const hash_postpend = "~";
pub const hash_chars = std.base64.url_safe_alphabet_chars;
pub const hash_encoder = std.base64.Base64Encoder.init(hash_chars, null);
/// The decoder will ensure that the padding bytes are 0.
pub const hash_decoder = std.base64.Base64Decoder.init(hash_chars, null);
pub const hash_body_len = hash_encoder.calcSize(@sizeOf(HashBacking));
pub const hash_token_len = hash_prepend.len + hash_body_len + hash_postpend.len;
pub const HashInstance = struct { index: usize, hash: HashBacking };

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
///    alive, even when everyone else has dropped the representative, since a second object
///    could resolve to the representative's hash and then cause a UAF. Hence, the registry
///    references the representative until every instance of the hash reference has disappeared.
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
        /// Registry owns a reference of the representative.
        representative: *Object,
        /// It's possible for another `Object` to have the same content, and thus,
        /// resolve to the same hash. When we register a second object, we have
        /// to keep the representative alive until both the respresentative and
        /// second object are dropped. This is a total count of instances of this
        /// hash (both our representative and duplicate instances).
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

    pub fn getAndTakeReference(registry: *HashRegistry, hash: u256) ?*Object {
        registry.rw_lock.lockSharedUncancelable(heap.global_io);
        defer registry.rw_lock.unlockShared(heap.global_io);

        if (registry.entries.getPtr(hash)) |entry| {
            assert(entry.instances.load(.monotonic) > 0);
            return entry.representative.takeReference(); // Take while still locked.
        } else return null;
    }

    /// Reallocates the table at the smallest capacity that holds its current
    /// entries.
    pub fn shrinkToFit(registry: *HashRegistry) error{OutOfMemory}!void {
        registry.rw_lock.lockUncancelable(heap.global_io);
        defer registry.rw_lock.unlock(heap.global_io);

        var shrunk: @TypeOf(registry.entries) = .empty;
        try shrunk.ensureTotalCapacity(heap.global_gpa, registry.entries.count());
        if (shrunk.capacity() >= registry.entries.capacity()) {
            shrunk.deinit(heap.global_gpa);
            return;
        }

        var iter = registry.entries.iterator();
        while (iter.next()) |entry| shrunk.putAssumeCapacityNoClobber(entry.key_ptr.*, entry.value_ptr.*);
        registry.entries.deinit(heap.global_gpa);
        registry.entries = shrunk;
    }

    pub fn register(registry: *HashRegistry, key: u256, obj: *Object) !void {
        registry.rw_lock.lockSharedUncancelable(heap.global_io);
        obj.makeCrossthread();

        if (registry.entries.getPtr(key)) |entry| {
            if (obj.hash_metadata.fetchOr(.{ .hash_registered = true }, .acq_rel).hash_registered == true) {
                // Someone else registered this already, so no need to do anything.
            } else {
                // We were the ones to successfully set `value` as registered.
                _ = entry.instances.fetchAdd(1, .monotonic);
            }

            registry.rw_lock.unlockShared(heap.global_io);
            return;
        }

        // Entry doesn't exist yet, so we'll upgrade to exclusive lock to insert.
        registry.rw_lock.unlockShared(heap.global_io);
        registry.rw_lock.lockUncancelable(heap.global_io);
        defer registry.rw_lock.unlock(heap.global_io);

        const new_entry = try registry.entries.getOrPut(heap.global_gpa, key);
        if (new_entry.found_existing) {
            const before_marking = obj.hash_metadata.fetchOr(.{ .hash_registered = true }, .acq_rel);
            if (before_marking.hash_registered == true) {
                // Someone registered it in-between upgrading the shared lock to an exclusive lock.
            } else {
                // We successfully marked it as registered, so we can increment the instances count.
                _ = new_entry.value_ptr.instances.fetchAdd(1, .monotonic);
            }
        } else {
            new_entry.key_ptr.* = key;
            new_entry.value_ptr.* = .{
                .representative = obj.takeReference(),
                .instances = .init(1),
            };

            // We have an exclusive lock on rw_lock, so nobody else could have registered this value.
            const expected: Object.HashMetadata = .{ .hash_registered = false, .is_representative = false };
            assert(obj.hash_metadata.fetchOr(.{ .hash_registered = true, .is_representative = true }, .acq_rel) == expected);
        }
    }

    /// Called when either:
    /// - `obj` is the representative and its ref_count just dropped to 1, or
    /// - `obj` is a non-representative registered object and its ref_count just dropped to 0.
    pub fn unregister(registry: *HashRegistry, key: u256, obj: *Object, is_rep: bool) void {
        var lock_helper: ioutil.RwLockHelper = .init(&registry.rw_lock);
        if (is_rep) {
            // We actually need to clear `.hash_registered` of the rep under an
            // exclusive lock, since otherwise we might atomically clear `.hash_registered`
            // while another thread returned it from `register`, causing the other thread
            // to return a broken object.
            lock_helper.lockExclusiveAsserting(heap.global_io);
        } else {
            lock_helper.lockSharedAsserting(heap.global_io);
        }

        if (registry.entries.getPtr(key)) |entry_first_load| {
            // Clear `.hash_registered`.
            const before_clearing = obj.hash_metadata.fetchAnd(.{ .is_representative = true }, .acq_rel);
            if (before_clearing.hash_registered == false) {
                // Someone else unregistered this already, so no need to do anything.
                lock_helper.unlock(heap.global_io);
                return;
            } else {
                // We were the ones to successfully set `value` as not registered.
                const instance_count = entry_first_load.instances.fetchSub(1, .monotonic) - 1;
                if (instance_count == 0) {
                    // This was the last instance of this hash, so we can now clean it up.

                    lock_helper.lockExclusiveMaybeUpgrade(heap.global_io);

                    // The entry should still exist here, as we were the ones who set instances
                    // to 0. It could have moved locations though, when upgrading to an exclusive
                    // lock.
                    const entry_second_load = registry.entries.getPtr(key) orelse {
                        // Our thread could drop instances to 0, but then a second
                        // thread could come in, resurrect the object, drop instances
                        // to 0 a second time, and then remove it from the registry.
                        // Hence we return early if it's no longer in the registry.
                        lock_helper.unlock(heap.global_io);
                        return;
                    };
                    const entry_derefed = entry_second_load.*;
                    if (entry_second_load.instances.load(.monotonic) != 0) {
                        // Someone was able to re-register this value when upgrading
                        // to an exclusive lock.
                        lock_helper.unlock(heap.global_io);
                        return;
                    }

                    _ = entry_derefed.representative.hash_metadata.fetchAnd(.{}, .acq_rel);
                    assert(registry.entries.remove(key));
                    lock_helper.unlock(heap.global_io);

                    // Make sure to `decrRefCount` only after unlocking the mutex, to avoid
                    // recursive locking.
                    entry_derefed.representative.dropReference();
                    return;
                } else {
                    lock_helper.unlock(heap.global_io);
                    return;
                }
            }
        } else {
            // Was already unregistered by the time we checked, so nothing to do.
            lock_helper.unlock(heap.global_io);
            return;
        }
    }
};

/// Uses blake3 to calculate a unique hash.
pub fn hashBytes(bytes: []const u8) HashBacking {
    var out: [32]u8 = @splat(0);
    std.crypto.hash.Blake3.hash(bytes, &out, .{});
    return @bitCast(out);
}

/// Appends every hash reference in `bytes` to `found_hashes`, with
/// indices in `bytes`, plus `offset`.
pub fn scanStringForHashRefs(gpa: Allocator, bytes: []const u8, offset: usize, found_hashes: *std.ArrayList(HashInstance)) !void {
    if (bytes.len < hash_token_len) return;

    var current_index: usize = 0;
    while (std.mem.findPos(u8, bytes, current_index, hash_prepend)) |next| {
        if (bytes.len - next < hash_token_len) return; // Not enough remaining to contain a token.
        // The next possible hash reference will be at least after the current "blake3.".
        current_index = next + hash_prepend.len;

        const potential_token = bytes[next..][0..hash_token_len];
        if (!std.mem.endsWith(u8, potential_token, hash_postpend)) continue;

        var output: [32]u8 = undefined;
        hash_decoder.decode(&output, bytes[(next + hash_prepend.len)..][0..hash_body_len]) catch continue;
        try found_hashes.append(gpa, .{ .index = next + offset, .hash = @bitCast(output) });
        current_index = next + hash_token_len;
    }
}

/// Parse a string that is exactly a single hash reference.
/// The string must start with "blake3." at position 0, followed by a valid
/// base64-encoded 32-byte hash, and end with "~". It must also have length
/// `hash_token_len`.
pub fn parseHashReference(bytes: []const u8) ?u256 {
    if (bytes.len != hash_token_len) return null;
    if (!std.mem.startsWith(u8, bytes, hash_prepend)) return null;
    if (!std.mem.endsWith(u8, bytes, hash_postpend)) return null;

    var output: [32]u8 = undefined;
    hash_decoder.decode(&output, bytes[hash_prepend.len..][0..hash_body_len]) catch return null;
    return @bitCast(output);
}

pub fn scanAndResolveHashRefs(gpa: Allocator, bytes: []const u8) error{OutOfMemory}![]SpecialString.HashAndInfo {
    var found_hashes: std.ArrayList(HashInstance) = .empty;
    defer found_hashes.deinit(gpa);
    try scanStringForHashRefs(gpa, bytes, 0, &found_hashes);

    // Look up all the found hashes.
    const resolved_hashes = try gpa.alloc(SpecialString.HashAndInfo, found_hashes.items.len);
    errdefer comptime unreachable;

    heap.registered_hashes.rw_lock.lockSharedUncancelable(heap.global_io);
    defer heap.registered_hashes.rw_lock.unlockShared(heap.global_io);
    resolveHashRefsInner(found_hashes.items, resolved_hashes);

    return resolved_hashes;
}

/// Resolves each of `found` into the matching slot of `out`, taking a
/// reference to every registered value. The caller must hold
/// `heap.registered_hashes`'s shared lock.
pub fn resolveHashRefsInner(found: []const HashInstance, out: []SpecialString.HashAndInfo) void {
    assert(found.len == out.len);
    for (found, out) |found_hash, *resolved_hash| {
        resolved_hash.* = .{
            .str_index = found_hash.index,
            .value = if (heap.registered_hashes.entries.get(found_hash.hash)) |resolved|
                resolved.representative.takeReference()
            else
                null,
        };
    }
}

/// Use only for hash tables and similar data structures that also use equality,
/// as this is not cryptographically secure.
pub fn quickHash(value: Value) !u64 {
    var buf: [350]u8 = undefined;
    const bytes = try value.getStringWithBuffer(&buf);
    if (bytes.len < heap.considered_large_string) return std.hash.Wyhash.hash(0, bytes);
    return @truncate(try value.getHashNoRegister());
}

/// This ensures that `quickHash` is guaranteed not to OOM when hashed in the
/// future.
pub fn cacheQuickHash(value: Value) error{OutOfMemory}!void {
    const obj = value.asPtr() orelse return;
    const bytes = try obj.getString();
    if (bytes.len >= heap.considered_large_string) {
        if (!obj.hashIsCached()) _ = try obj.getHashNoRegister();
    }
}

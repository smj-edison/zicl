//! Computes the hash references a string made by joining pieces would track,
//! without building the string itself.
//!
//! Glossary:
//! - _Token_: a hash reference, `blake3.<hash>~`.
//! - _Piece_: a byte slice, which is joined in order with the other pieces to
//!   form the _joined string_. A piece is often a slice of an existing
//!   string, its _source_.
//! - _Tracked_ piece: one with a `PieceMetadata`, which passes along its
//!   source's tracked hashes so the tokens inside it don't need rescanning. A
//!   _raw_ piece has no metadata, and is scanned.
//! - _Boundary_: the point in the joined string where one piece ends and the
//!   next begins. A token can cross one or more boundaries.
//! - _Window_: a range of bytes around one or more boundaries, which is
//!   scanned for tokens crossing them.
//! - _Overlap_: the `max_overlap` bytes that consecutive scans share, so a
//!   token cut by where one scan ends is still found whole by the next.
//! - _Run_: the tracked hashes of the tokens fully inside one piece, which are
//!   merged into the result without being rescanned.
//!
//! This module only computes the tracked hashes. Callers assemble the joined
//! bytes however suits them, whether by patching in place, growing a buffer,
//! or gathering into a fresh one. Since the pieces are only read, they may
//! alias each other or the string being written, as long as the caller
//! doesn't write until `trackedHashes` returns.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;

const heap = @import("heap.zig");
const hashutil = @import("hashutil.zig");
const objects = @import("objects.zig");
const Object = heap.Object;
const ResolvedHash = heap.SpecialString.ResolvedHash;

const token_len = hashutil.hash_token_len;

/// The most bytes a token can have on one side of a boundary it crosses.
/// Scans split at a boundary overlap by this much, so no token is missed.
const max_overlap = token_len - 1;

/// What a tracked piece carries: the tracked hashes of the tokens inside it,
/// and where in its source it starts.
pub const PieceMetadata = struct {
    /// The source's tracked hashes for exactly the tokens fully inside the
    /// piece, sorted by `str_index`. `Piece.fromSource` picks these out.
    hashes: []const ResolvedHash,
    /// Where the piece starts in its source. The source indexes its tracked
    /// hashes from its own start, not the piece's, so this offset tells where
    /// `hashes` land in the joined string. For example, the tail of a patch,
    /// `old[old_edit_end..]`, has a `source_start` of `old_edit_end`.
    source_start: usize,
};

pub const Piece = struct {
    bytes: []const u8,
    /// Null for a raw piece.
    metadata: ?PieceMetadata = null,

    /// Returns `source[start..end]` as a tracked piece. `source_hashes` must
    /// be every token in `source`, sorted by `str_index`, as a string's
    /// tracked hashes are. The piece borrows from both.
    pub fn fromSource(source: []const u8, source_hashes: []const ResolvedHash, start: usize, end: usize) Piece {
        // Tokens cut by either end of the piece are left out. If the joined
        // string recreates one, the window around that boundary finds it.
        const Search = struct {
            fn startsBefore(limit: usize, hash: ResolvedHash) bool {
                return hash.str_index < limit;
            }
            fn endsBy(limit: usize, hash: ResolvedHash) bool {
                return hash.str_index + token_len <= limit;
            }
        };
        const first = std.sort.partitionPoint(ResolvedHash, source_hashes, start, Search.startsBefore);
        const count = std.sort.partitionPoint(ResolvedHash, source_hashes[first..], end, Search.endsBy);
        return .{
            .bytes = source[start..end],
            .metadata = .{ .hashes = source_hashes[first..][0..count], .source_start = start },
        };
    }

    /// Returns `obj`'s string `[start, end)` as a tracked piece. It borrows
    /// from `obj`, which must have a string rep.
    pub fn fromObject(obj: *const Object, start: usize, end: usize) Piece {
        // A normal string never contains a token, so it tracks nothing.
        const bytes: []const u8, const hashes: []const ResolvedHash = switch (obj.getStringDetails()) {
            .normal => |bytes| .{ bytes, &.{} },
            .special => |special| .{ special.getString(), special.tracked_hashes },
            .none => unreachable,
        };
        return .fromSource(bytes, hashes, start, end);
    }
};

/// Returns the hash references that `pieces`, joined in order, would track,
/// sorted by their index in the joined string. Each returned entry whose
/// `value` is non-null carries a reference owned by the caller, so free the
/// result with `release`.
///
/// `scan_buffer` is scratch space for scanning windows, and must hold at
/// least `hashutil.hash_token_len` bytes. A larger buffer means fewer scans,
/// and 256 bytes is plenty.
pub fn trackedHashes(gpa: Allocator, scan_buffer: []u8, pieces: []const Piece) error{OutOfMemory}![]ResolvedHash {
    // Every token in the joined string either lies fully inside one piece, or
    // crosses at least one boundary. Crossing tokens are found by streaming
    // the windows around each boundary through `scanner`.
    //
    // A short piece, of at most `2 * max_overlap` bytes, is streamed whole,
    // which merges the windows on either side of it into one. That merged
    // window also finds the tokens inside the short piece.
    //
    // A long piece only streams its first and last `max_overlap` bytes, with
    // the window ended between them, so its two windows can only find
    // tokens crossing a boundary. The tokens inside a long piece come from
    // its run instead. A raw long piece has no run, so it's scanned in place.
    //
    // This first pass is the fallible one, and takes no references. Scanned
    // tokens collect in `found` as bare hashes, and are only resolved once
    // nothing else can fail. Meanwhile, a run's values stay alive through its
    // piece's source.
    var found: std.ArrayList(hashutil.HashInstance) = .empty;
    defer found.deinit(gpa);
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(gpa);
    var runs_len: usize = 0;

    var scanner: BoundaryScanner = .init(scan_buffer);
    var joined_start: usize = 0;
    for (pieces) |piece| {
        const bytes = piece.bytes;
        defer joined_start += bytes.len;
        if (bytes.len <= 2 * max_overlap) {
            try scanner.feed(gpa, &found, bytes, joined_start);
            continue;
        }
        try scanner.feed(gpa, &found, bytes[0..max_overlap], joined_start);
        try scanner.endWindow(gpa, &found);
        if (piece.metadata) |metadata| {
            if (metadata.hashes.len > 0) {
                // Catches metadata built by hand rather than by `fromSource`.
                assert(metadata.hashes[0].str_index >= metadata.source_start);
                assert(metadata.hashes[metadata.hashes.len - 1].str_index + token_len <= metadata.source_start + bytes.len);
                try runs.append(gpa, .{ .metadata = metadata, .joined_start = joined_start });
                runs_len += metadata.hashes.len;
            }
        } else {
            try hashutil.scanStringForHashRefs(gpa, bytes, joined_start, &found);
        }
        try scanner.feed(gpa, &found, bytes[bytes.len - max_overlap ..], joined_start + bytes.len - max_overlap);
    }
    try scanner.endWindow(gpa, &found);

    const out = try gpa.alloc(ResolvedHash, runs_len + found.items.len);
    errdefer comptime unreachable;

    // `found` is sorted, and so is each run. A run belongs between the found
    // tokens starting before its piece and the ones starting after, so
    // merging only needs to know where each run splits `found`.
    heap.registered_hashes.rw_lock.lockSharedUncancelable(heap.global_io);
    defer heap.registered_hashes.rw_lock.unlockShared(heap.global_io);

    var filled: std.ArrayList(ResolvedHash) = .initBuffer(out);
    var remaining = found.items;
    for (runs.items) |run| {
        var before: usize = 0;
        while (before < remaining.len and remaining[before].index < run.joined_start) before += 1;
        hashutil.resolveHashRefsInner(remaining[0..before], filled.addManyAsSliceAssumeCapacity(before));
        remaining = remaining[before..];

        for (run.metadata.hashes) |hash| filled.appendAssumeCapacity(.{
            .str_index = hash.str_index - run.metadata.source_start + run.joined_start,
            .value = if (hash.value) |value| value.takeReference() else null,
        });
    }
    hashutil.resolveHashRefsInner(remaining, filled.addManyAsSliceAssumeCapacity(remaining.len));
    assert(filled.items.len == out.len);

    return out;
}

/// Drops every reference in `hashes`, and frees it.
pub fn release(gpa: Allocator, hashes: []const ResolvedHash) void {
    for (hashes) |hash| if (hash.value) |value| value.dropReference();
    gpa.free(hashes);
}

/// The tokens fully inside one tracked piece.
const Run = struct {
    metadata: PieceMetadata,
    /// Where the piece starts in the joined string.
    joined_start: usize,
};

/// Scans windows of the joined string through a fixed buffer. A window is fed
/// in contiguous parts, and `endWindow` ends it.
const BoundaryScanner = struct {
    buffer: []u8,
    len: usize = 0,
    /// Where `buffer[0]` is in the joined string.
    start: usize = 0,

    fn init(buffer: []u8) BoundaryScanner {
        assert(buffer.len > max_overlap);
        return .{ .buffer = buffer };
    }

    fn feed(scanner: *BoundaryScanner, gpa: Allocator, found: *std.ArrayList(hashutil.HashInstance), bytes: []const u8, joined_start: usize) error{OutOfMemory}!void {
        if (scanner.len == 0) scanner.start = joined_start else assert(scanner.start + scanner.len == joined_start);

        var rest = bytes;
        while (rest.len > 0) {
            const copied = @min(rest.len, scanner.buffer.len - scanner.len);
            @memcpy(scanner.buffer[scanner.len..][0..copied], rest[0..copied]);
            scanner.len += copied;
            rest = rest[copied..];

            if (scanner.len == scanner.buffer.len) {
                try hashutil.scanStringForHashRefs(gpa, scanner.buffer, scanner.start, found);
                // A token that runs past the end of the buffer starts in its
                // last `max_overlap` bytes, so those overlap with the next
                // scan. They're too short to hold a whole token, so nothing
                // already found is found twice.
                @memmove(scanner.buffer[0..max_overlap], scanner.buffer[scanner.buffer.len - max_overlap ..]);
                scanner.start += scanner.buffer.len - max_overlap;
                scanner.len = max_overlap;
            }
        }
    }

    fn endWindow(scanner: *BoundaryScanner, gpa: Allocator, found: *std.ArrayList(hashutil.HashInstance)) error{OutOfMemory}!void {
        try hashutil.scanStringForHashRefs(gpa, scanner.buffer[0..scanner.len], scanner.start, found);
        scanner.len = 0;
    }
};

/// Fails unless `trackedHashes` gives exactly what a full rescan of the joined
/// bytes finds. It's checked with a full-size scan buffer, and again with the
/// smallest allowed one, which overlaps on nearly every byte.
fn expectMatchesRescan(pieces: []const Piece) !void {
    const gpa = heap.global_gpa;

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    for (pieces) |piece| try joined.appendSlice(gpa, piece.bytes);

    const expected = try hashutil.scanAndResolveHashRefs(gpa, joined.items);
    defer release(gpa, expected);

    var scan_buffer: [256]u8 = undefined;
    for ([_]usize{ scan_buffer.len, token_len }) |buffer_len| {
        const actual = try trackedHashes(gpa, scan_buffer[0..buffer_len], pieces);
        defer release(gpa, actual);

        try testing.expectEqual(expected.len, actual.len);
        for (expected, actual) |exp, act| {
            try testing.expectEqual(exp.str_index, act.str_index);
            try testing.expectEqual(exp.value, act.value);
        }
    }
}

const TestRefs = struct {
    targets: [2]*objects.String,
    registered: [2][token_len]u8,
    unregistered: [token_len]u8,

    fn init() !TestRefs {
        var refs: TestRefs = undefined;
        var created: usize = 0;
        errdefer for (refs.targets[0..created]) |target| target.asHead().dropReference();
        for (&refs.targets, &refs.registered, 0..) |*target, *ref, i| {
            var name_buf: [24]u8 = undefined;
            target.* = try objects.String.new(try std.fmt.bufPrint(&name_buf, "join payload {d}", .{i}));
            created += 1;
            ref.* = objects.HashReference.render(try target.*.asHead().getHashRegistering());
        }
        refs.unregistered = objects.HashReference.render(hashutil.hashBytes("never registered"));
        return refs;
    }

    fn deinit(refs: TestRefs) void {
        for (refs.targets) |target| target.asHead().dropReference();
    }
};

/// Checks every way of cutting a string into three pieces whose first cut is
/// at `first_cut`, with each piece either tracked or raw. Cutting through a
/// token leaves it to the boundary scan to find.
fn testSplitsFrom(ta: Allocator, first_cut: usize) !void {
    try heap.testStart(ta, null);
    defer heap.testFinish();
    const refs = try TestRefs.init();
    defer refs.deinit();

    const source_bytes = testSplitsSource(refs);
    const source = try objects.String.new(&source_bytes);
    defer source.asHead().dropReference();
    const obj = source.asHead();
    const len = (try obj.getString()).len;
    // Runs only come from a source that tracks its tokens.
    try testing.expect(obj.getStringDetails() == .special);

    for (first_cut..len + 1) |second_cut| for (0..8) |raw_mask| {
        const bounds = [_]usize{ 0, first_cut, second_cut, len };
        var pieces: [3]Piece = undefined;
        for (&pieces, 0..) |*piece, i| {
            piece.* = .fromObject(obj, bounds[i], bounds[i + 1]);
            if (raw_mask & (@as(usize, 1) << @intCast(i)) != 0) piece.metadata = null;
        }
        try expectMatchesRescan(&pieces);
    };
}

const splits_source_len = 2 + token_len + 1 + 2 * token_len + 4;

fn testSplitsSource(refs: TestRefs) [splits_source_len]u8 {
    return ("ab" ++ refs.registered[0] ++ "x" ++ refs.registered[1] ++ refs.unregistered ++ "tail").*;
}

test "hashjoin matches a rescan for every three-way split" {
    // Each first cut gets its own heap cycle, since the whole sweep traces
    // more operations than one cycle's trace log holds.
    for (0..splits_source_len + 1) |first_cut| {
        try testSplitsFrom(testing.allocator, first_cut);
    }
}

fn testBoundaries(ta: Allocator) !void {
    try heap.testStart(ta, null);
    defer heap.testFinish();
    const refs = try TestRefs.init();
    defer refs.deinit();
    const ref = &refs.registered[0];

    // A token made from bytes of two different strings, neither of which
    // tracks it.
    {
        const head = try objects.String.new("left " ++ ref[0..10]);
        defer head.asHead().dropReference();
        const tail = try objects.String.new(ref[10..] ++ " right");
        defer tail.asHead().dropReference();
        try expectMatchesRescan(&.{
            Piece.fromObject(head.asHead(), 0, 15),
            Piece.fromObject(tail.asHead(), 0, token_len - 10 + 6),
        });
    }

    // One token crossing many boundaries, with empty pieces between some of them.
    {
        var pieces: [2 * token_len]Piece = undefined;
        for (0..token_len) |i| {
            pieces[2 * i] = .{ .bytes = ref[i..][0..1] };
            pieces[2 * i + 1] = .{ .bytes = "" };
        }
        try expectMatchesRescan(&pieces);
    }

    // The same string joined to itself, around an inserted token. This is
    // the shape of a patch: `old[0..at] ++ add ++ old[at..]`.
    {
        const doubled = try objects.String.new(refs.registered[1] ++ "mid" ++ refs.unregistered);
        defer doubled.asHead().dropReference();
        const obj = doubled.asHead();
        const len = (try obj.getString()).len;
        try testing.expect(obj.getStringDetails() == .special);
        for (0..len + 1) |at| try expectMatchesRescan(&.{
            Piece.fromObject(obj, 0, at),
            .{ .bytes = ref },
            Piece.fromObject(obj, at, len),
            Piece.fromObject(obj, 0, len),
        });
    }

    // Long raw pieces, scanned in place.
    try expectMatchesRescan(&.{
        .{ .bytes = "a fairly long raw prefix " ++ ref.* ++ " and " ++ refs.unregistered },
        .{ .bytes = &(ref.* ++ ref.*) },
    });
}

test "hashjoin boundaries" {
    try testing.checkAllAllocationFailures(testing.allocator, testBoundaries, .{});
}

/// Fails unless `trackedHashes` gives exactly `expected`, with both a
/// full-size and the smallest allowed scan buffer.
fn expectTrackedHashes(pieces: []const Piece, expected: []const ResolvedHash) !void {
    const gpa = heap.global_gpa;
    var scan_buffer: [256]u8 = undefined;
    for ([_]usize{ scan_buffer.len, token_len }) |buffer_len| {
        const actual = try trackedHashes(gpa, scan_buffer[0..buffer_len], pieces);
        defer release(gpa, actual);

        try testing.expectEqual(expected.len, actual.len);
        for (expected, actual) |exp, act| {
            try testing.expectEqual(exp.str_index, act.str_index);
            try testing.expectEqual(exp.value, act.value);
        }
    }
}

fn testRunsSkipRescan(ta: Allocator) !void {
    try heap.testStart(ta, null);
    defer heap.testFinish();
    const refs = try TestRefs.init();
    defer refs.deinit();

    // A rescan can't tell a run from a scan of the same bytes, so these
    // pieces carry metadata that disagrees with their bytes. `bytes` holds
    // a real token for `targets[0]`, padded so that neither window around
    // the piece holds all of it.
    const padding: [token_len]u8 = @splat(' ');
    const bytes = padding ++ refs.registered[0] ++ padding;
    const claimed = [_]ResolvedHash{
        .{ .str_index = token_len, .value = refs.targets[1].asHead() },
        .{ .str_index = 2 * token_len, .value = null },
    };

    // A tracked piece that tracks nothing is never scanned inside.
    try expectTrackedHashes(&.{.fromSource(&bytes, &.{}, 0, bytes.len)}, &.{});

    // A run's values come from its metadata, not the registry.
    try expectTrackedHashes(&.{.fromSource(&bytes, &claimed, 0, bytes.len)}, &claimed);

    // A run starting partway into its source, between scanned tokens.
    const head = "<" ++ refs.registered[0];
    const source_start = 10;
    const tail_start = head.len + bytes.len - source_start;
    try expectTrackedHashes(&.{
        .{ .bytes = head },
        .fromSource(&bytes, &claimed, source_start, bytes.len),
        .{ .bytes = refs.unregistered ++ ">" },
    }, &.{
        .{ .str_index = 1, .value = refs.targets[0].asHead() },
        .{ .str_index = head.len + token_len - source_start, .value = refs.targets[1].asHead() },
        .{ .str_index = head.len + 2 * token_len - source_start, .value = null },
        .{ .str_index = tail_start, .value = null },
    });
}

test "hashjoin passes runs through without rescanning" {
    try testing.checkAllAllocationFailures(testing.allocator, testRunsSkipRescan, .{});
}

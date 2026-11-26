//! Computes the hash references a string made by joining pieces would track,
//! without building the string itself.
//!
//! Callers assemble the bytes however suits them (patching in place, growing
//! a buffer, gathering into a fresh one), and use this for the tracked hashes.
//! Since it only reads the pieces, they may alias each other or the string
//! being written, as long as the caller doesn't write until this returns.
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

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;

const heap = @import("heap.zig");
const hashutil = @import("hashutil.zig");
const objects = @import("objects.zig");
const Object = heap.Object;
const HashAndInfo = heap.SpecialString.HashAndInfo;

const token_len = hashutil.hash_token_len;

/// The most bytes a token can have on one side of a boundary it crosses.
/// Scans split at a boundary overlap by this much, so no token is missed.
const max_overlap = token_len - 1;

/// What a tracked piece carries: its source's tracked hashes, and where in
/// the source it starts.
pub const PieceMetadata = struct {
    /// Every token in the source string, sorted by `str_index`. Tokens not
    /// fully inside the piece are ignored.
    hashes: []const HashAndInfo,
    /// Where the piece starts in its source. `hashes` index into the source,
    /// not the piece, so this is needed to tell which tokens are inside the
    /// piece, and where they land in the joined string. For example, the
    /// tail of a patch, `old[old_edit_end..]`, has a `source_start` of
    /// `old_edit_end`.
    source_start: usize,

    /// Borrows `obj`'s string `[start, end)` along with its tracked hashes.
    /// `obj` must have a string rep.
    pub fn fromObject(obj: *const Object, start: usize, end: usize) struct { []const u8, ?PieceMetadata } {
        // A normal string never contains a token, so it tracks nothing.
        const bytes: []const u8, const hashes: []const HashAndInfo = switch (obj.getStringDetails()) {
            .normal => |bytes| .{ bytes, &.{} },
            .special => |special| .{ special.getString(), special.tracked_hashes },
            .none => unreachable,
        };
        return .{ bytes[start..end], .{ .hashes = hashes, .source_start = start } };
    }
};

/// Returns the hash references that the pieces `bytes`, joined in order,
/// would track, sorted by their index in the joined string. `metadata` is
/// parallel to `bytes`, and is null for bytes that were never scanned. Each
/// non-null `value` carries a reference owned by the caller. Free the result
/// with `release`.
///
/// `scan_buffer` is scratch space for scanning the bytes around each boundary, and
/// must hold at least `hashutil.hash_token_len` bytes. A larger buffer means
/// fewer scans, and 256 bytes is plenty.
pub fn trackedHashes(
    gpa: Allocator,
    scan_buffer: []u8,
    bytes: []const []const u8,
    metadata: []const ?PieceMetadata,
) error{OutOfMemory}![]HashAndInfo {
    assert(bytes.len == metadata.len);

    // Every token in the joined string is either fully inside one piece, or
    // crosses at least one boundary between pieces. Tokens inside a long
    // piece come from its tracked hashes (or an in-place scan, for raw
    // bytes). Crossing tokens are found by streaming the `max_overlap` bytes
    // on each side of every boundary through `scanner`.
    //
    // A piece of at most `2 * max_overlap` bytes is streamed whole, which
    // merges the windows on either side of it. That window also finds the
    // tokens inside the piece, so they aren't taken from the piece itself.
    // A longer piece has a gap between its two windows, so the window is
    // flushed there, and only finds tokens crossing a boundary.
    //
    // This first pass is the fallible one, and takes no references. A run's
    // values stay alive through the source strings, and found tokens are
    // only resolved once nothing else can fail.
    var found: std.ArrayList(hashutil.HashInstance) = .empty;
    defer found.deinit(gpa);
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(gpa);
    var runs_len: usize = 0;

    var scanner: BoundaryScanner = .init(scan_buffer);
    var joined_start: usize = 0;
    for (bytes, metadata) |piece, piece_metadata| {
        defer joined_start += piece.len;
        if (piece.len <= 2 * max_overlap) {
            try scanner.feed(gpa, &found, piece, joined_start);
            continue;
        }
        try scanner.feed(gpa, &found, piece[0..max_overlap], joined_start);
        try scanner.flush(gpa, &found);
        if (piece_metadata) |source| {
            const contained = containedHashes(source, piece.len);
            if (contained.len > 0) {
                try runs.append(gpa, .{ .hashes = contained, .source_start = source.source_start, .joined_start = joined_start });
                runs_len += contained.len;
            }
        } else {
            try hashutil.scanStringForHashRefs(gpa, piece, joined_start, &found);
        }
        try scanner.feed(gpa, &found, piece[piece.len - max_overlap ..], joined_start + piece.len - max_overlap);
    }
    try scanner.flush(gpa, &found);

    const out = try gpa.alloc(HashAndInfo, runs_len + found.items.len);
    errdefer comptime unreachable;

    // `found` is sorted, and so is each run. A run's tokens all come after
    // every found token that starts before its piece, and before every other
    // found token, so merging is a matter of where each run splits `found`.
    heap.registered_hashes.rw_lock.lockSharedUncancelable(heap.global_io);
    defer heap.registered_hashes.rw_lock.unlockShared(heap.global_io);

    var filled: std.ArrayList(HashAndInfo) = .initBuffer(out);
    var remaining = found.items;
    for (runs.items) |run| {
        var before: usize = 0;
        while (before < remaining.len and remaining[before].index < run.joined_start) before += 1;
        hashutil.resolveHashRefsInner(remaining[0..before], filled.addManyAsSliceAssumeCapacity(before));
        remaining = remaining[before..];

        for (run.hashes) |hash| filled.appendAssumeCapacity(.{
            .str_index = hash.str_index - run.source_start + run.joined_start,
            .value = if (hash.value) |value| value.takeReference() else null,
        });
    }
    hashutil.resolveHashRefsInner(remaining, filled.addManyAsSliceAssumeCapacity(remaining.len));
    assert(filled.items.len == out.len);

    return out;
}

/// Drops every reference in `hashes`, and frees it.
pub fn release(gpa: Allocator, hashes: []const HashAndInfo) void {
    for (hashes) |hash| if (hash.value) |value| value.dropReference();
    gpa.free(hashes);
}

/// The tokens fully inside one tracked piece.
const Run = struct {
    hashes: []const HashAndInfo,
    source_start: usize,
    /// Where the piece starts in the joined string.
    joined_start: usize,
};

/// The hashes in `source` for tokens fully inside its piece of `piece_len` bytes.
fn containedHashes(source: PieceMetadata, piece_len: usize) []const HashAndInfo {
    const Search = struct {
        fn startsBefore(limit: usize, hash: HashAndInfo) bool {
            return hash.str_index < limit;
        }
        fn endsBy(limit: usize, hash: HashAndInfo) bool {
            return hash.str_index + token_len <= limit;
        }
    };
    const source_end = source.source_start + piece_len;
    const first = std.sort.partitionPoint(HashAndInfo, source.hashes, source.source_start, Search.startsBefore);
    const count = std.sort.partitionPoint(HashAndInfo, source.hashes[first..], source_end, Search.endsBy);
    return source.hashes[first..][0..count];
}

/// Scans a window of the joined string that arrives in pieces, through a
/// fixed buffer. Each window must be contiguous, and `flush` ends it.
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
                std.mem.copyForwards(u8, scanner.buffer[0..max_overlap], scanner.buffer[scanner.buffer.len - max_overlap ..]);
                scanner.start += scanner.buffer.len - max_overlap;
                scanner.len = max_overlap;
            }
        }
    }

    fn flush(scanner: *BoundaryScanner, gpa: Allocator, found: *std.ArrayList(hashutil.HashInstance)) error{OutOfMemory}!void {
        try hashutil.scanStringForHashRefs(gpa, scanner.buffer[0..scanner.len], scanner.start, found);
        scanner.len = 0;
    }
};

const TestPiece = struct { []const u8, ?PieceMetadata };

/// Fails unless both buffer sizes give exactly what a full rescan of the
/// joined bytes finds.
fn expectMatchesRescan(pieces: []const TestPiece) !void {
    const gpa = heap.global_gpa;

    const bytes = try gpa.alloc([]const u8, pieces.len);
    defer gpa.free(bytes);
    const metadata = try gpa.alloc(?PieceMetadata, pieces.len);
    defer gpa.free(metadata);
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    for (pieces, bytes, metadata) |piece, *piece_bytes, *piece_metadata| {
        piece_bytes.*, piece_metadata.* = piece;
        try joined.appendSlice(gpa, piece_bytes.*);
    }

    const expected = try hashutil.scanAndResolveHashRefs(gpa, joined.items);
    defer release(gpa, expected);

    var scan_buffer: [256]u8 = undefined;
    for ([_]usize{ scan_buffer.len, token_len }) |buffer_len| {
        const actual = try trackedHashes(gpa, scan_buffer[0..buffer_len], bytes, metadata);
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

    for (first_cut..len + 1) |second_cut| for (0..8) |raw_mask| {
        const bounds = [_]usize{ 0, first_cut, second_cut, len };
        var pieces: [3]TestPiece = undefined;
        for (&pieces, 0..) |*piece, i| {
            piece.* = PieceMetadata.fromObject(obj, bounds[i], bounds[i + 1]);
            if (raw_mask & (@as(usize, 1) << @intCast(i)) != 0) piece[1] = null;
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
            PieceMetadata.fromObject(head.asHead(), 0, 15),
            PieceMetadata.fromObject(tail.asHead(), 0, token_len - 10 + 6),
        });
    }

    // One token crossing many boundaries, with empty pieces between some of them.
    {
        var pieces: [2 * token_len]TestPiece = undefined;
        for (0..token_len) |i| {
            pieces[2 * i] = .{ ref[i..][0..1], null };
            pieces[2 * i + 1] = .{ "", null };
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
        for (0..len + 1) |at| try expectMatchesRescan(&.{
            PieceMetadata.fromObject(obj, 0, at),
            .{ ref, null },
            PieceMetadata.fromObject(obj, at, len),
            PieceMetadata.fromObject(obj, 0, len),
        });
    }

    // Long raw pieces, scanned in place.
    try expectMatchesRescan(&.{
        .{ "a fairly long raw prefix " ++ ref.* ++ " and " ++ refs.unregistered, null },
        .{ &(ref.* ++ ref.*), null },
    });
}

test "hashjoin boundaries" {
    try testing.checkAllAllocationFailures(testing.allocator, testBoundaries, .{});
}

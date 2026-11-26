//! Computes the hash references a string made by joining pieces would track,
//! without building the string itself.
//!
//! Callers assemble the bytes however suits them (patching in place, growing
//! a buffer, gathering into a fresh one), and use this for the tracked hashes.
//! Since it only reads the pieces, they may alias each other or the string
//! being written, as long as the caller doesn't write until this returns.

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

/// The most bytes a token can have on one side of a seam it crosses.
const reach = token_len - 1;

/// A piece's tracked hashes, as stored by the string it was sliced from.
pub const Tracked = struct {
    /// Every token in the source string, sorted by `str_index`. Tokens not
    /// fully inside the piece are ignored.
    hashes: []const HashAndInfo,
    /// Where the piece starts in the source string `hashes` indexes into.
    source_start: usize,

    /// Borrows `obj`'s string `[start, end)` along with its tracked hashes.
    /// `obj` must have a string rep.
    pub fn fromObject(obj: *const Object, start: usize, end: usize) struct { []const u8, ?Tracked } {
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
/// would track, sorted by their index in the joined string. `tracked` is
/// parallel to `bytes`, and is null for bytes that were never scanned. Each
/// non-null `value` carries a reference owned by the caller. Free the result
/// with `release`.
pub fn trackedHashes(gpa: Allocator, bytes: []const []const u8, tracked: []const ?Tracked) error{OutOfMemory}![]HashAndInfo {
    return trackedHashesBuffered(256, gpa, bytes, tracked);
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
    at: usize,
};

fn trackedHashesBuffered(
    comptime buffer_len: usize,
    gpa: Allocator,
    bytes: []const []const u8,
    tracked: []const ?Tracked,
) error{OutOfMemory}![]HashAndInfo {
    assert(bytes.len == tracked.len);

    // Every token in the joined string is either fully inside one piece, or
    // crosses at least one seam. Tokens inside a long piece come from its
    // tracked hashes (or an in-place scan, for raw bytes). Crossing tokens
    // are found by streaming the `reach` bytes on each side of every seam
    // through `seams`.
    //
    // A piece of at most `2 * reach` bytes is streamed whole, which merges
    // the seam windows on either side of it. That stream also finds the
    // tokens inside the piece, so they aren't taken from the piece itself.
    // A longer piece has a gap between its two windows, so the stream is
    // flushed there, and only finds tokens crossing a seam.
    //
    // This first pass is the fallible one, and takes no references. A run's
    // values stay alive through the source strings, and found tokens are
    // only resolved once nothing else can fail.
    var found: std.ArrayList(hashutil.HashInstance) = .empty;
    defer found.deinit(gpa);
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(gpa);
    var runs_len: usize = 0;

    var seams: SeamScanner(buffer_len) = .{};
    var at: usize = 0;
    for (bytes, tracked) |piece, piece_tracked| {
        defer at += piece.len;
        if (piece.len <= 2 * reach) {
            try seams.feed(gpa, &found, piece, at);
            continue;
        }
        try seams.feed(gpa, &found, piece[0..reach], at);
        try seams.flush(gpa, &found);
        if (piece_tracked) |source| {
            const contained = containedHashes(source, piece.len);
            if (contained.len > 0) {
                try runs.append(gpa, .{ .hashes = contained, .source_start = source.source_start, .at = at });
                runs_len += contained.len;
            }
        } else {
            try hashutil.scanStringForHashRefs(gpa, piece, at, &found);
        }
        try seams.feed(gpa, &found, piece[piece.len - reach ..], at + piece.len - reach);
    }
    try seams.flush(gpa, &found);

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
        while (before < remaining.len and remaining[before].index < run.at) before += 1;
        hashutil.resolveHashRefsInner(remaining[0..before], filled.addManyAsSliceAssumeCapacity(before));
        remaining = remaining[before..];

        for (run.hashes) |hash| filled.appendAssumeCapacity(.{
            .str_index = hash.str_index - run.source_start + run.at,
            .value = if (hash.value) |value| value.takeReference() else null,
        });
    }
    hashutil.resolveHashRefsInner(remaining, filled.addManyAsSliceAssumeCapacity(remaining.len));
    assert(filled.items.len == out.len);

    return out;
}

/// The hashes in `source` for tokens fully inside its piece of `piece_len` bytes.
fn containedHashes(source: Tracked, piece_len: usize) []const HashAndInfo {
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

/// Scans a run of the joined string that arrives in pieces, through a fixed
/// buffer. Each run must be contiguous, and `flush` ends it.
fn SeamScanner(comptime capacity: usize) type {
    comptime assert(capacity > reach);
    return struct {
        const Scanner = @This();

        buffer: [capacity]u8 = undefined,
        len: usize = 0,
        /// Where `buffer[0]` is in the joined string.
        start: usize = 0,

        fn feed(scanner: *Scanner, gpa: Allocator, found: *std.ArrayList(hashutil.HashInstance), bytes: []const u8, at: usize) error{OutOfMemory}!void {
            if (scanner.len == 0) scanner.start = at else assert(scanner.start + scanner.len == at);

            var rest = bytes;
            while (rest.len > 0) {
                const copied = @min(rest.len, capacity - scanner.len);
                @memcpy(scanner.buffer[scanner.len..][0..copied], rest[0..copied]);
                scanner.len += copied;
                rest = rest[copied..];

                if (scanner.len == capacity) {
                    try hashutil.scanStringForHashRefs(gpa, &scanner.buffer, scanner.start, found);
                    // A token that runs past the end of the buffer starts in
                    // its last `reach` bytes, so those are scanned again with
                    // what follows. They're too short to hold a whole token,
                    // so nothing already found is found twice.
                    std.mem.copyForwards(u8, scanner.buffer[0..reach], scanner.buffer[capacity - reach ..]);
                    scanner.start += capacity - reach;
                    scanner.len = reach;
                }
            }
        }

        fn flush(scanner: *Scanner, gpa: Allocator, found: *std.ArrayList(hashutil.HashInstance)) error{OutOfMemory}!void {
            try hashutil.scanStringForHashRefs(gpa, scanner.buffer[0..scanner.len], scanner.start, found);
            scanner.len = 0;
        }
    };
}

const TestPiece = struct { []const u8, ?Tracked };

/// Fails unless both buffer sizes give exactly what a full rescan of the
/// joined bytes finds.
fn expectMatchesRescan(pieces: []const TestPiece) !void {
    const gpa = heap.global_gpa;

    const bytes = try gpa.alloc([]const u8, pieces.len);
    defer gpa.free(bytes);
    const tracked = try gpa.alloc(?Tracked, pieces.len);
    defer gpa.free(tracked);
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    for (pieces, bytes, tracked) |piece, *piece_bytes, *piece_tracked| {
        piece_bytes.*, piece_tracked.* = piece;
        try joined.appendSlice(gpa, piece_bytes.*);
    }

    const expected = try hashutil.scanAndResolveHashRefs(gpa, joined.items);
    defer release(gpa, expected);

    inline for (.{ 256, reach + 1 }) |buffer_len| {
        const actual = try trackedHashesBuffered(buffer_len, gpa, bytes, tracked);
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
/// token leaves it to the seam scan to find.
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
            piece.* = Tracked.fromObject(obj, bounds[i], bounds[i + 1]);
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

fn testSeams(ta: Allocator) !void {
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
            Tracked.fromObject(head.asHead(), 0, 15),
            Tracked.fromObject(tail.asHead(), 0, token_len - 10 + 6),
        });
    }

    // One token crossing many seams, with empty pieces between some of them.
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
            Tracked.fromObject(obj, 0, at),
            .{ ref, null },
            Tracked.fromObject(obj, at, len),
            Tracked.fromObject(obj, 0, len),
        });
    }

    // Long raw pieces, scanned in place.
    try expectMatchesRescan(&.{
        .{ "a fairly long raw prefix " ++ ref.* ++ " and " ++ refs.unregistered, null },
        .{ &(ref.* ++ ref.*), null },
    });
}

test "hashjoin seams" {
    try testing.checkAllAllocationFailures(testing.allocator, testSeams, .{});
}

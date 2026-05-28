//! This allocator is directly inspired by mimalloc. It uses a backing allocator
//! for allocating pages, and only allows for small allocations (<= 65536).

const std = @import("std");
const mem = std.mem;
const memutil = @import("memutil.zig");
const assert = std.debug.assert;

threadlocal var theap: Heap = undefined;

fn expensive_assert(ok: bool) void {
    if (!ok) unreachable;
}

fn binIndex(size: u16) u6 {
    // Taken just about verbatim from mimalloc.

    assert(size > 0);
    assert(size <= 2048);

    const word_size = std.math.divCeil(u32, size, 4) catch unreachable;
    if (word_size <= 8) return @intCast(word_size);

    // Find the highest bit...
    const highest = 32 - 1 - @clz(word_size - 1);
    // ...and use the top 3 bits to determine the bin (~12.5% worst internal fragmentation).
    // - adjust with 3 because we use do not round the first 8 sizes which each get an exact bin.
    const bin = ((highest << 2) + (((word_size - 1) >> @intCast(highest - 2)) & 0x03)) - 3;
    return @intCast(bin);
}

test {
    // var i: u16 = 1;
    // var last_size: u6 = 0;
    // while (i <= 2048) : (i += 1) {
    //     const current_size = binIndex(i);
    //     if (current_size > last_size) {
    //         last_size = current_size;
    //         std.debug.print("Current size: {}\n", .{current_size});
    //     }
    // }
}

fn readBlockNext(page: *Page, block: u32) OptionalIndex {
    const relative_block = block - (page.index * blocks_per_bin[page.block_bin]);
    const ptr: *OptionalIndex = @ptrCast(@alignCast(&page.blocks[relative_block * page.block_size]));
    return ptr.*;
}

fn writeBlockNext(page: *Page, block: u32, next: OptionalIndex) void {
    const relative_block = block - (page.index * blocks_per_bin[page.block_bin]);
    const ptr: *OptionalIndex = @ptrCast(@alignCast(&page.blocks[relative_block * page.block_size]));
    ptr.* = next;
}

// Collect freed blocks by us and other threads.
fn collectPageFrees(page: *Page) void {
    // Collect the thread free list.
    const xthread_head = page.xthread_free.swap(.none, .acq_rel);
    if (xthread_head != .none) {
        var count: u32 = 1;
        var tail = xthread_head;
        while (true) {
            const next = readBlockNext(page, tail.toMaybeInt().?);
            if (next == .none) break;
            count += 1;
            tail = next;
        }
        // Append the current local free list.
        writeBlockNext(page, tail.toMaybeInt().?, page.local_free);
        page.local_free = xthread_head;
        page.used -= count;
    }

    // And the local free list.
    if (page.local_free != .none) {
        if (page.free == .none) {
            // Usual case.
            page.free = page.local_free;
            page.local_free = .none;
        }
    }
}

fn pageQueueRemove(pq: *PageQueue, page: *Page) void {
    if (page.prev) |prev| prev.next = page.next;
    if (page.next) |next| next.prev = page.prev;
    if (pq.last == page) pq.last = page.prev;
    if (pq.first == page) pq.first = page.next;
    page.next = null;
    page.prev = null;
}

fn pageQueuePush(pq: *PageQueue, page: *Page) void {
    page.next = pq.first;
    page.prev = null;
    if (pq.first) |first| {
        first.prev = page;
    } else {
        pq.last = page;
    }
    pq.first = page;
}

fn pageQueueMoveToFront(pq: *PageQueue, page: *Page) void {
    if (pq.first == page) return;
    pageQueueRemove(pq, page);
    pageQueuePush(pq, page);
}

fn getFreePage(heap: *Heap, bin: u6) ?*Page {
    return heap.page_queue[bin].first;
}

// Search through the pages in "next fit" order.
fn findFreePage(heap: *Heap, bin: u6) ?*Page {
    const pq = &heap.page_queue[bin];

    // Check the first page: we even do this with candidate search or otherwise we re-search every time.
    if (pq.first) |page| {
        collectPageFrees(page);
        if (page.free != .none) {
            return page; // Fast path.
        }
    }

    // Extended scan.
    var page = pq.first;
    while (page) |p| {
        const next = p.next; // Remember next.
        collectPageFrees(p);
        if (p.free != .none) {
            pageQueueMoveToFront(pq, p);
            return p;
        }
        page = next;
    }

    return null;
}

// Make sure the block is within the page.
fn assertBlockInPage(page: *Page, bin: u6, block: u32) void {
    expensive_assert(block >= page.index * blocks_per_bin[bin]);
    expensive_assert(block < (page.index + 1) * blocks_per_bin[bin]);
}

fn pageAlloc(heap: *Heap, bin: u6) !Index {
    const page = getFreePage(heap, bin) orelse return fullAlloc(heap, bin);
    const block = page.free.toMaybeInt() orelse return fullAlloc(heap, bin);

    assertBlockInPage(page, bin, block);

    const relative_block = block - (page.index * blocks_per_bin[bin]);
    const block_next_ptr: *OptionalIndex = @ptrCast(@alignCast(&page.blocks[relative_block * page.block_size]));
    const next_block = block_next_ptr.*;
    page.free = next_block; // Pop from the page's free list.
    page.used += 1;

    // Make sure the following block is also within the page (if not null).
    if (next_block.toMaybeInt()) |val| {
        assertBlockInPage(page, bin, val);
    }

    return .fromInt(block);
}

// Full allocation routine if the fast path (`pageAlloc`) does not succeed.
fn fullAlloc(heap: *Heap, bin: u6) !Index {
    if (findFreePage(heap, bin)) |page| {
        const block = page.free.toMaybeInt().?;

        assertBlockInPage(page, bin, block);

        const relative_block = block - (page.index * blocks_per_bin[bin]);
        const block_next_ptr: *OptionalIndex = @ptrCast(@alignCast(&page.blocks[relative_block * page.block_size]));
        const next_block = block_next_ptr.*;
        page.free = next_block; // Pop from the page's free list.
        page.used += 1;

        // Make sure the following block is also within the page (if not null).
        if (next_block.toMaybeInt()) |val| {
            assertBlockInPage(page, bin, val);
        }

        return .fromInt(block);
    }

    // Find (or allocate) a page of the right size.
    if (heap.pages[bin].len >= heap.max_pages) {
        return error.OutOfMemory;
    }

    const page_slot = heap.pages[bin].len;
    const page = &heap.pages[bin].ptr[page_slot];

    const block_count = blocks_per_bin[bin];
    const block_size = block_size_per_bin[bin];
    const page_mem_size = @as(usize, block_count) * block_size;

    const blocks = try heap.backing_alloc.allocWithOptions(u8, page_mem_size, .@"4", null);
    errdefer heap.backing_alloc.free(blocks);

    page.* = .{
        .index = @intCast(page_slot),
        .block_bin = bin,
        .block_size = block_size,
        .free = .none,
        .local_free = .none,
        .xthread_free = std.atomic.Value(OptionalIndex).init(.none),
        .blocks = blocks,
        .used = 0,
        .next = null,
        .prev = null,
    };

    // Build the inline free list.
    const start_block = page.index * block_count;
    var i: u32 = 0;
    while (i < block_count) : (i += 1) {
        const next: OptionalIndex = if (i + 1 < block_count) .fromMaybeInt(start_block + i + 1) else .none;
        writeBlockNext(page, start_block + i, next);
    }
    page.free = OptionalIndex.fromMaybeInt(start_block);

    // Push the new page to the front of the queue.
    pageQueuePush(&heap.page_queue[bin], page);

    // And allocate the first block from it.
    const block = page.free.toMaybeInt().?;
    page.free = readBlockNext(page, block);
    page.used = 1;

    heap.pages[bin].len += 1;
    return Index.fromInt(block);
}

pub const Index = enum(u32) {
    _,

    pub fn toInt(self: Index) u32 {
        const as_int = @intFromEnum(self);
        assert(as_int != @intFromEnum(OptionalIndex.none));
        return as_int;
    }

    pub fn fromInt(index: u32) Index {
        assert(index != @intFromEnum(OptionalIndex.none));
        return @enumFromInt(index);
    }
};

pub const OptionalIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn toMaybeInt(self: OptionalIndex) ?u32 {
        return if (self == .none) null else @intFromEnum(self);
    }

    pub fn fromMaybeInt(index: ?u32) OptionalIndex {
        if (index) |val| {
            assert(val != @intFromEnum(OptionalIndex.none));
            return @enumFromInt(val);
        } else return .none;
    }
};

const Page = struct {
    /// Index of this page in the parent array.
    index: u32,
    block_bin: u6,
    block_size: u16,
    /// List of available free blocks (`malloc` allocates from this list).
    free: OptionalIndex,
    // List of deferred free blocks by this thread (migrates to `free`).
    local_free: OptionalIndex,
    // List of deferred free blocks freed by other threads.
    xthread_free: std.atomic.Value(OptionalIndex),
    // Start of the page area containing the blocks.
    blocks: []align(4) u8,

    used: u32,

    /// next page owned by this thread with the same `block_size`
    next: ?*Page,
    /// previous page owned by this thread with the same `block_size`
    prev: ?*Page,
};

const PageQueue = struct {
    first: ?*Page,
    last: ?*Page,
    block_size: u16,
};

const page_size: usize = 65536;

/// `binIndex(2048)` is 32, so since arrays are 0-indexed, we need 33.
const page_bins = 33;

pub const block_size_per_bin: [page_bins]u16 = blk: {
    @setEvalBranchQuota(100000);

    var max_size: [page_bins]u16 = @splat(0);
    var s: u16 = 1;
    while (true) {
        const b = binIndex(s);
        if (s > max_size[b]) max_size[b] = s;
        if (s == 2048) break;
        s += 1;
    }
    break :blk max_size;
};

pub const blocks_per_bin: [page_bins]u16 = blk: {
    var blocks: [page_bins]u16 = undefined;
    blocks[0] = 0;
    for (1..page_bins) |i| {
        blocks[i] = @intCast(page_size / block_size_per_bin[i]);
    }
    break :blk blocks;
};

pub const Heap = struct {
    backing_alloc: mem.Allocator,
    pages: [page_bins][]Page,
    page_queue: [page_bins]PageQueue,
    max_pages: u16,

    const Self = @This();

    pub fn init(heap: *Heap, backing_alloc: mem.Allocator, max_pages: u16) !void {
        // Need to leave room for the null representation of the index.
        assert(max_pages < std.math.maxInt(u16));

        var new_pages: [page_bins][]Page = @splat(undefined);
        var initialized: usize = 0;
        errdefer for (0..initialized) |i| backing_alloc.free(new_pages[i]);
        while (initialized < page_bins) : (initialized += 1) {
            new_pages[initialized] = try memutil.vmemMapItems(Page, max_pages);
        }

        // Shrink slices to len=0; the backing capacity stays at max_pages.
        for (0..page_bins) |i| {
            new_pages[i] = new_pages[i].ptr[0..0];
        }

        var new_page_queue: [page_bins]PageQueue = undefined;
        for (0..page_bins) |i| {
            new_page_queue[i] = .{
                .first = null,
                .last = null,
                .block_size = block_size_per_bin[i],
            };
        }

        heap.* = .{
            .backing_alloc = backing_alloc,
            .pages = new_pages,
            .page_queue = new_page_queue,
            .max_pages = max_pages,
        };
    }

    pub fn bindToThread(heap: *Heap) void {
        theap = heap;
    }

    pub fn deinit(heap: *Heap) void {
        for (0..page_bins) |i| {
            // Free all active page block memory.
            for (0..heap.pages[i].len) |j| {
                heap.backing_alloc.free(heap.pages[i].ptr[j].blocks);
            }
            // Free the page array itself.
            memutil.vmemUnmapItems(Page, @alignCast(heap.pages[i].ptr[0..heap.max_pages]));
        }
    }

    pub fn alloc(heap: *Heap, size: u16) !Index {
        assert(size > 0 and size <= 2048);
        const bin = binIndex(size);
        return pageAlloc(heap, bin);
    }

    pub fn free(heap: *Heap, index: Index, size: u16) void {
        assert(size > 0 and size <= 2048);
        const bin = binIndex(size);
        const block_count = blocks_per_bin[bin];
        const page_index = index.toInt() / block_count;

        const page = &heap.pages[bin][page_index];
        assert(page.used > 0);
        expensive_assert(page.index == page_index);

        if (&theap == heap) {
            // Same thread: local free.
            writeBlockNext(page, index.toInt(), page.local_free);
            page.local_free = OptionalIndex.fromMaybeInt(index.toInt());
            page.used -= 1;
        } else {
            // Cross-thread: atomic push to xthread_free.
            var old = page.xthread_free.load(.monotonic);
            while (true) {
                writeBlockNext(page, index.toInt(), old);
                const result = page.xthread_free.cmpxchgWeak(old, OptionalIndex.fromMaybeInt(index.toInt()), .acq_rel, .monotonic);
                if (result) |new_old| {
                    old = new_old;
                } else break;
            }
        }
    }

    pub fn peek(heap: *Heap, index: Index, size: u16) []align(4) u8 {
        assert(size > 0 and size <= 2048);

        const bin = binIndex(size);
        const block_count = blocks_per_bin[bin];
        const block_size = block_size_per_bin[bin];
        const page_index = index.toInt() / block_count;
        const block_offset = index.toInt() % block_count;
        const page = &heap.pages[bin][page_index];
        const ptr: [*]align(4) u8 = @ptrCast(@alignCast(&page.blocks[block_offset * block_size]));
        return ptr[0..size];
    }
};

const testing = std.testing;
test "basic alloc and free" {
    _ = try initHeap(testing.allocator, 4);
    defer deinitHeap();

    const idx = try theap.alloc(16);
    const p = theap.peek(idx, 16);
    @memset(p[0..16], 0xAB);
    theap.free(idx, 16);
}

test "alloc multiple from same page" {
    _ = try initHeap(testing.allocator, 4);
    defer deinitHeap();

    const idx1 = try theap.alloc(16);
    const idx2 = try theap.alloc(16);
    try std.testing.expect(idx1.toInt() != idx2.toInt());
    theap.free(idx1, 16);
    theap.free(idx2, 16);
}

test "alloc triggers fullAlloc" {
    _ = try initHeap(testing.allocator, 2);
    defer deinitHeap();

    // Exhaust the first page.
    const block_count = blocks_per_bin[binIndex(2048)];
    var idxs = try std.testing.allocator.alloc(Index, block_count);
    defer std.testing.allocator.free(idxs);
    for (0..block_count) |i| {
        idxs[i] = try theap.alloc(2048);
    }
    // This should trigger fullAlloc and create a second page.
    const extra = try theap.alloc(2048);
    theap.free(extra, 2048);

    for (0..block_count) |i| {
        theap.free(idxs[i], 2048);
    }
}

test "cross-thread free" {
    _ = try initHeap(testing.allocator, 4);
    defer deinitHeap();

    const idx = try theap.alloc(16);

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(allocated_on: *Heap, index: Index) void {
            _ = initHeap(testing.allocator, 4) catch unreachable;
            defer deinitHeap();
            allocated_on.free(index, 16);
        }
    }.run, .{ &theap, idx });
    thread.join();

    // The cross-thread free is only collected on the slow path, so the same
    // index is not guaranteed to be reused immediately.
    const idx2 = try theap.alloc(16);
    try std.testing.expect(idx2.toInt() != idx.toInt());
}

pub fn initHeap(gpa: mem.Allocator, max_pages: u16) !*Heap {
    _ = try theap.init(gpa, max_pages);
    return &theap;
}

pub fn deinitHeap() void {
    theap.deinit();
}

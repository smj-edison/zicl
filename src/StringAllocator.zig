//! This allocator is directly inspired by mimalloc. It uses a backing allocator
//! for allocating pages, and only allows for small allocations (<= 65536).

const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;

fn expensive_assert(ok: bool) void {
    if (!ok) unreachable;
}

fn binIndex(size: 16) u5 {
    // Taken just about verbatim from mimalloc.

    assert(size > 0);

    const word_size = std.math.divCeil(u32, size, 4) catch unreachable;
    if (word_size <= 8) return @intCast(word_size);

    // Find the highest bit...
    const highest: u5 = @intCast(32 - 1 - @clz(word_size - 1));
    // ...and use the top 3 bits to determine the bin (~12.5% worst internal fragmentation).
    // - adjust with 3 because we use do not round the first 8 sizes which each get an exact bin.
    const bin = ((highest << 2) + (((word_size - 1) >> (highest - 2)) & 0x03)) - 3;
    return @intCast(bin);
}

fn findFreePage(heap: *Heap, bin: u5) !*Page {
    if (heap.page_queue[bin].first) |found| {
        return found;
    }
}

// Full allocation routine if the fast path (`pageAlloc`) does not succeed.
fn fullAlloc(heap: *Heap, bin: u5) !Index {
    // Find (or allocate) a page of the right size.
}

fn getFreePage(heap: *Heap, bin: u5) ?*Page {
    return heap.page_queue[bin].first;
}

fn pageAlloc(heap: *Heap, bin: u5) !Index {
    const page = getFreePage(heap, bin) orelse return fullAlloc(heap, bin);
    const block = page.free.toIndex() orelse return fullAlloc(heap, bin);

    // Make sure the block is within the page.
    expensive_assert(block >= page.index * blocks_per_bin[bin]);
    expensive_assert(block < (page.index + 1) * blocks_per_bin[bin]);

    const relative_block = block - page.index;
    const block_next_ptr: *OptionalIndex = @ptrCast(@alignCast(&page.blocks[relative_block * page.block_size]));
    const next_block = block_next_ptr.*;
    page.next = next_block; // Pop from the page's free list.
    page.used += 1;

    // Make sure the following block is also within the page (if not null).
    if (next_block.toIndex()) |val| {
        expensive_assert(val >= page.index * blocks_per_bin[bin]);
        expensive_assert(val < (page.index + 1) * blocks_per_bin[bin]);
    }

    return block;
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

    pub fn toIndex(self: OptionalIndex) ?u32 {
        return if (self == .none) null else @intFromEnum(self);
    }

    pub fn fromIndex(index: ?u32) Index {
        if (index) |val| {
            assert(val != @intFromEnum(OptionalIndex.none));
            return @enumFromInt(index);
        } else return .none;
    }
};

const Page = struct {
    /// Index of this page in the parent array.
    index: u32,
    block_size: usize,
    /// List of available free blocks (`malloc` allocates from this list).
    free: OptionalIndex,
    // List of deferred free blocks by this thread (migrates to `free`).
    local_free: OptionalIndex,
    // List of deferred free blocks freed by other threads.
    xthread_free: std.atomic.Value(Index),
    // Start of the page area containing the blocks.
    blocks: []u8,

    used: u32,

    /// next page owned by this thread with the same `block_size`
    next: *Page,
    /// previous page owned by this thread with the same `block_size`
    prev: *Page,

    pub fn pageIndex(page: *const Page, heap: *Heap) u32 {
        const index = page - &heap.pages[binIndex(page)][0];
        return @intCast(index);
    }
};

const PageQueue = struct {
    first: ?*Page,
    last: ?*Page,
    block_size: u5,
};

/// `binIndex(65536)` is 20, so since arrays are 0-indexed, we need 21.
const page_bins = 21;

// FIXME
pub const block_size_per_bin: [page_bins]u16 = undefined;
pub const blocks_per_bin: [page_bins]u16 = undefined;

pub const Heap = struct {
    backing_alloc: mem.Allocator,
    pages: [page_bins][]Page,
    page_queue: [page_bins]PageQueue,

    const Self = @This();

    pub fn init(backing_alloc: mem.Allocator, max_pages: u16) !Self {
        // Need to leave room for the null representation of the index.
        assert(max_pages < std.math.maxInt(u16));

        var new_pages: [u32][]Page = @splat(undefined);
        var initialized: usize = 0;
        errdefer for (0..initialized) |i| backing_alloc.free(new_pages[i]);
        while (initialized < page_bins) : (initialized += 1) {
            new_pages[initialized] = try backing_alloc.alloc(Page, max_pages + 1);
        }

        // First page is reserved for null, hence `max_pages + 1`.
        const pages = try backing_alloc.alloc(Page, max_pages + 1);
        errdefer backing_alloc.free(pages);

        return .{
            .backing_alloc = backing_alloc,
            .pages = new_pages,
        };
    }

    // fn allocInner(alloc: *Heap, size: usize) !Index {
    //     std.math.divCeil(comptime T: type, numerator: T, denominator: T)
    // }
};

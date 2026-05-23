//! Memory-related functions and objects.
//!
//! Buddy allocator based on https://www.kernel.org/doc/gorman/html/understand/understand009.html

const std = @import("std");
const math = std.math;
const heap = std.heap;
const mem = std.mem;
const testing = std.testing;
const assert = std.debug.assert;
const Allocator = mem.Allocator;

pub fn getOrder(count: u32) u5 {
    return @intCast(math.log2_int_ceil(u32, count));
}

pub fn getOrderSize(order: u5) u32 {
    return @as(u32, 1) << order;
}

pub fn buddyOfOrder(index: u32, order: u5) u32 {
    return buddyOf(index, getOrderSize(order));
}

fn buddyOf(index: u32, order_size: u32) u32 {
    const mask = (order_size * 2) - 1;

    if (index & mask == 0) {
        return index + order_size;
    } else {
        return index - order_size;
    }
}

/// Dependant on parent allocator to resize the internal free lists.
///
/// Design:
/// This is a pretty standard buddy allocator, with a small twist: there's a
/// non-thread-safe pool that can be used to quickly allocate/free, and when
/// the pool overflows it allocates/frees from the main list.
pub fn BuddyUnmanaged(comptime cfg: struct {
    max_order: u5,
    max_pool_order: u5,
    pool_size: usize,
}) type {
    const FreeList = std.AutoArrayHashMapUnmanaged(u32, void);

    assert(cfg.max_pool_order <= cfg.max_order);

    return struct {
        gpa: Allocator,
        io: std.Io,
        // TODO: make this one data structure
        free_lists: [cfg.max_order]FreeList,
        alloc_count: [cfg.max_order]usize,
        pools: [cfg.max_pool_order][cfg.pool_size]u32,
        pools_len: [cfg.max_pool_order]usize,

        const Self = @This();

        pub fn init(gpa: Allocator, io: std.Io, initial_capacity: usize) error{OutOfMemory}!Self {
            var new_alloc: Self = .{
                .gpa = gpa,
                .io = io,
                .free_lists = undefined,
                .alloc_count = @splat(0),
                .pools = @splat(@splat(0)),
                .pools_len = @splat(0),
            };

            var initialized: usize = 0;
            errdefer for (0..initialized) |i| {
                new_alloc.free_lists[i].deinit(gpa);
            };
            while (initialized < cfg.max_order) : (initialized += 1) {
                new_alloc.free_lists[initialized] = .empty;
                try new_alloc.free_lists[initialized].ensureTotalCapacity(gpa, initial_capacity);
            }

            // Add the top-most block.
            try new_alloc.free_lists[cfg.max_order - 1].put(gpa, 0, {});

            return new_alloc;
        }

        /// Caller must have the block already allocated. `new_order` must be smaller than
        /// `current_order`.
        pub fn splitBlock(self: *Self, current_order: u5, new_order: u5) void {
            assert(new_order < current_order);

            // 2 ** (current_order - new_order)
            const new_block_count = @as(u32, 1) << (current_order - new_order);

            self.alloc_count[current_order] -= 1;
            self.alloc_count[new_order] += new_block_count;
        }

        pub fn alloc(self: *Self, requested_order: u5) u32 {
            self.alloc_count[requested_order] += 1; // Allocation stats.

            // Ensure that the free list has enough space for when the object needs to be freed.
            self.ensureSufficientCapacity(requested_order);

            // look for an open block of any size >= requested_order (if the open block is too big, we'll split it).
            var open_index: u32 = undefined;
            var open_order = requested_order;
            while (open_order < cfg.max_order) : (open_order += 1) {
                if (self.free_lists[open_order].pop()) |open| {
                    open_index = open.key;
                    break;
                }
            } else @panic("OOM");

            // split blocks (if needed).
            while (open_order > requested_order) : (open_order -= 1) {
                self.free_lists[open_order - 1].putNoClobber(
                    self.gpa,
                    open_index + getOrderSize(open_order - 1),
                    {},
                ) catch @panic("OOM");
                // Lower half is implicitly passed along `open_index`, since
                // the lower block index stays the same as it descends.
            }

            return open_index;
        }

        pub fn free(self: *Self, index: u32, order: u5) void {
            self.alloc_count[order] -= 1; // Allocation stats.

            // If this block has a buddy, merge. If not, add this block to the appropriate free list.
            const freed_buddy = buddyOf(index, getOrderSize(order));
            var buddy_free_list_index: u32 = blk: {
                if (self.free_lists[order].getIndex(freed_buddy)) |buddy_index| {
                    break :blk @intCast(buddy_index); // Found buddy.
                } else {
                    // We can assume as we reserved enough space during alloc.
                    self.free_lists[order].putAssumeCapacityNoClobber(index, {});
                    return; // No buddy, return.
                }
            };

            // This block has a buddy, so do recursive merging.
            var order_being_merged = order;
            var block_being_merged = index;
            var buddy_being_merged = freed_buddy;

            // Why `< max_order - 1`? Because the top order has no sibling to merge with.
            while (order_being_merged < cfg.max_order - 1) {
                // Remove buddy from its free list (no longer free since it's being merged).
                _ = self.free_lists[order_being_merged].swapRemoveAt(buddy_free_list_index);
                // No need to remove the block, since we never added it in the first place.

                // We've effectively merged the two blocks now, but we're not going to put
                // the merged result on the higher free list, because it'll be passed up
                // through block_being_merged anyways. We do however need to update the index,
                // because the higher order is aligned differently.
                order_being_merged += 1;
                block_being_merged = @min(block_being_merged, buddy_being_merged);

                // Now check if the higher order block also needs to be merged, by checking
                // for the presence of its buddy in the free list.

                // Search for its buddy.
                buddy_being_merged = buddyOf(block_being_merged, getOrderSize(order_being_merged));
                if (self.free_lists[order_being_merged].getIndex(buddy_being_merged)) |free_parent_block| {
                    buddy_free_list_index = @intCast(free_parent_block);
                } else {
                    // In this case, we actually _do_ need to append the merged block,
                    // since we're no longer implicitly passing it up `block_being_merged`.
                    self.free_lists[order_being_merged].putAssumeCapacityNoClobber(block_being_merged, {});
                    return;
                }

                // We've found the sibling, so the next iteration will merge.
            }
        }

        fn ensureSufficientCapacity(self: *Self, order: u5) void {
            var free_list_size = self.alloc_count[order] / 2 + 1;
            self.free_lists[order].ensureTotalCapacity(self.gpa, free_list_size) catch @panic("OOM");

            var current_order = order;
            while (current_order > 0) {
                current_order -= 1;
                // Be sure to have enough space on the smaller block list, as we may want
                // to split this block in the future.
                const parent_free_list_size = free_list_size;
                free_list_size = (parent_free_list_size * 2) + self.alloc_count[current_order] / 2 + 1;
                self.free_lists[current_order].ensureTotalCapacity(self.gpa, free_list_size) catch @panic("OOM");
            }
        }
    };
}

pub fn vmemMap(byte_count: usize) ![]align(heap.page_size_min) u8 {
    const mapped = heap.PageAllocator.map(byte_count, .fromByteUnits(heap.page_size_min)) orelse return error.OutOfMemory;

    return @alignCast(mapped[0..byte_count]);
}

pub fn vmemUnmap(memory: []align(heap.page_size_min) u8) void {
    heap.PageAllocator.unmap(memory);
}

pub fn vmemMapItems(comptime T: type, count: usize) ![]align(heap.page_size_min) T {
    const byte_count = @sizeOf(T) * count;
    const mapped = heap.PageAllocator.map(byte_count, .fromByteUnits(@alignOf(T))) orelse return error.OutOfMemory;
    const items: [*]T = @ptrCast(@alignCast(mapped));

    return @alignCast(items[0..count]);
}

pub fn vmemUnmapItems(comptime T: type, items: []align(heap.page_size_min) T) void {
    const byte_count = items.len * @sizeOf(T);
    const bytes: [*]align(heap.page_size_min) u8 = @ptrCast(items.ptr);
    heap.PageAllocator.unmap(bytes[0..byte_count]);
}

pub fn IndexedMemoryPool(comptime Item: type) type {
    // Heavily inspired by std.heap.MemoryPool

    return struct {
        const Self = @This();
        pub const no_next_free: usize = std.math.maxInt(usize);
        pub const empty: Self = .{ .items = &.{} };

        // Make sure we have enough space for a usize.
        const node_align = std.mem.Alignment.of(usize).max(.of(Item));
        /// Designed to use items directly. May move locations after calling `.create()`.
        items: []align(node_align.toByteUnits()) Item,
        /// If == no_next_free, it doesn't point to anything
        next_free: usize = no_next_free,
        /// `len` is the largest index used, while `items.len` is the capacity.
        len: usize = 0,
        /// `count` is how many items are live.
        count: usize = 0,

        /// Capacity must be > 0
        pub fn initWithCapacity(capacity: usize) !Self {
            if (capacity == 0) @panic("Capacity must be larger than 0");
            return .{ .items = try vmemMapItems(Item, capacity) };
        }

        pub fn create(self: *Self) !usize {
            if (self.len >= self.items.len) return error.OutOfMemory;
            return self.createAssumeCapacity();
        }

        pub fn createAssumeCapacity(self: *Self) usize {
            self.count += 1;
            errdefer self.count -= 1;

            // Check if there's anything on the free list.
            if (self.next_free != no_next_free) {
                const next_free = self.next_free;
                // follow to next free
                const item_ptr: *Item = &self.items[next_free];
                const int_ptr: *usize = @ptrCast(item_ptr);
                self.next_free = int_ptr.*;
                return next_free;
            }

            assert(self.len < self.items.len);

            const new_index = self.len;
            self.len += 1;
            assert(new_index != no_next_free);
            return new_index;
        }

        /// Resets the pool to empty while keeping the backing memory allocated.
        pub fn clearRetainingCapacity(self: *Self) void {
            self.next_free = no_next_free;
            self.len = 0;
            self.count = 0;
        }

        pub fn destroy(self: *Self, index: usize) void {
            self.count -= 1;

            self.items[index] = undefined;
            const item_ptr: *Item = &self.items[index];
            const int_ptr: *usize = @ptrCast(item_ptr);
            int_ptr.* = self.next_free;
            self.next_free = index;
        }

        pub fn deinit(self: *Self) void {
            vmemUnmapItems(Item, @alignCast(self.items));
        }
    };
}

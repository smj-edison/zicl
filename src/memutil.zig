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

const FreeList = std.ArrayListUnmanaged(usize);

// These functions are all when appending to the free list (it should have
// already resized itself)
fn null_alloc(ctx: *anyopaque, n: usize, alignment: mem.Alignment, ra: usize) ?[*]u8 {
    _ = ctx;
    _ = n;
    _ = alignment;
    _ = ra;
    return null;
}
fn null_resize(ctx: *anyopaque, buf: []u8, alignment: mem.Alignment, new_size: usize, return_address: usize) bool {
    _ = ctx;
    _ = buf;
    _ = alignment;
    _ = new_size;
    _ = return_address;
    return false;
}
fn null_remap(context: *anyopaque, memory: []u8, alignment: mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
    _ = context;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = return_address;
    return null;
}
fn null_free(ctx: *anyopaque, buf: []u8, alignment: mem.Alignment, return_address: usize) void {
    _ = ctx;
    _ = buf;
    _ = alignment;
    _ = return_address;
}
var null_ctx: usize = 0;
pub const null_allocator: Allocator = .{
    .ptr = &null_ctx,
    .vtable = &.{
        .alloc = null_alloc,
        .resize = null_resize,
        .remap = null_remap,
        .free = null_free,
    },
};

pub fn getOrder(count: usize) u6 {
    return @intCast(math.log2_int_ceil(usize, count));
}

pub fn getOrderSize(order: u6) usize {
    return @as(usize, 1) << order;
}

/// Dependant on parent allocator to resize the internal free lists
pub fn BuddyUnmanaged(max_order: comptime_int) type {
    return struct {
        // TODO: make this one data structure
        free_lists: [max_order]FreeList,
        alloc_count: [max_order]usize,

        const Self = @This();

        pub fn init(allocator: Allocator, initial_capacity: usize) error{OutOfMemory}!Self {
            var new_alloc: Self = .{
                .free_lists = undefined,
                .alloc_count = [_]usize{0} ** max_order,
            };

            var initialized: usize = 0;
            errdefer for (0..initialized) |i| {
                new_alloc.free_lists[i].deinit(allocator);
            };
            while (initialized < max_order) : (initialized += 1) {
                new_alloc.free_lists[initialized] = try FreeList.initCapacity(allocator, initial_capacity);
            }

            try new_alloc.free_lists[max_order - 1].append(allocator, 0);

            return new_alloc;
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            for (0..max_order) |i| {
                self.free_lists[i].deinit(allocator);
            }
        }

        pub fn allocCount(self: *Self, gpa: Allocator, count: usize) !usize {
            assert(count > 0);
            const order: u6 = @intCast(math.log2_int_ceil(usize, count));
            return self.alloc(gpa, order);
        }

        pub fn alloc(self: *Self, allocator: Allocator, requested_order: u6) error{OutOfMemory}!usize {
            // Ensure that the free list has enough space when the object needs to be freed
            try self.free_lists[requested_order].ensureTotalCapacity(
                allocator,
                (self.alloc_count[requested_order] + 1) / 2 + 1,
            );
            self.alloc_count[requested_order] += 1; // Allocation stats.

            // look for an open block of any size >= requested_order (if the open block
            // is too big, we'll split it).
            var open_index: usize = undefined;
            var open_order = requested_order;
            while (open_order < max_order) : (open_order += 1) {
                if (self.free_lists[open_order].pop()) |open| {
                    open_index = open;
                    break;
                }
            } else return error.OutOfMemory;

            // split blocks (if needed).
            while (open_order > requested_order) : (open_order -= 1) {
                try self.free_lists[open_order - 1].append(allocator, open_index + getOrderSize(open_order - 1));
                // Lower half is implicitly passed along `open_index`, since
                // the lower block index stays the same as it descends
            }

            return open_index;
        }

        pub fn freeCount(self: *Self, index: usize, count: usize) void {
            assert(count > 0);
            const order: u6 = @intCast(math.log2_int_ceil(usize, count));
            return self.free(index, order);
        }

        pub fn free(self: *Self, index: usize, order: u6) void {
            // TODO: add safety check that the allocation exists before freeing it.
            self.alloc_count[order] -= 1; // Allocation stats.

            // If this block has a buddy, merge. If not, add this block to the appropriate free list.
            const freed_buddy = buddy_of(index, getOrderSize(order));
            var buddy_free_list_index = blk: {
                for (self.free_lists[order].items, 0..) |block, i| {
                    if (block == freed_buddy) {
                        break :blk i;
                    }
                } else {
                    // Unreachable as we reserved enough space during alloc.
                    self.free_lists[order].append(null_allocator, index) catch unreachable;
                    return; // No buddy, return.
                }
            };

            // This block has a buddy, so do recursive merging.
            var order_being_merged = order;
            var block_being_merged = index;
            var buddy_being_merged = freed_buddy;

            // Why `< max_order - 1`? Because the top order has no sibling to merge with.
            while (order_being_merged < max_order - 1) {
                // Remove buddy from its free list (no longer free since it's being merged)
                _ = self.free_lists[order_being_merged].swapRemove(buddy_free_list_index);
                // No need to remove the block, since we never added it in the first place

                // We've effectively merged the two blocks now, but we're not going to put
                // the merged result on the higher free list, because it'll be passed up
                // through block_being_merged anyways. We do however need to update the index,
                // because the higher order is aligned differently.
                order_being_merged += 1;
                block_being_merged = @min(block_being_merged, buddy_being_merged);

                // Now check if the higher order block also needs to be merged, by checking
                // for the presence of its buddy in the free list.

                // Search for its buddy.
                buddy_being_merged = buddy_of(block_being_merged, getOrderSize(order_being_merged));
                for (self.free_lists[order_being_merged].items, 0..) |block, i| {
                    if (block == buddy_being_merged) {
                        buddy_free_list_index = i;
                        break;
                    }
                } else {
                    // In this case, we actually _do_ need to append the merged block,
                    // since we're no longer implicitly passing it up `block_being_merged`.
                    self.free_lists[order_being_merged].append(
                        null_allocator,
                        block_being_merged,
                    ) catch unreachable;
                    return;
                }

                // We've found the sibling, so the next iteration will merge.
            }
        }

        fn buddy_of(index: usize, order_size: usize) usize {
            const mask = (order_size * 2) - 1;

            if (index & mask == 0) {
                return index + order_size;
            } else {
                return index - order_size;
            }
        }

        fn print_buddy_state(self: Self, beginning: []const u8) void {
            std.debug.print("{s}", .{beginning});
            for (0..self.free_lists.len) |order| {
                std.debug.print("Order: {} ({any}), ", .{ order, self.free_lists[order].items });
            }
            std.debug.print("\n", .{});
        }
    };
}

const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expectEqualSlices = std.testing.expectEqualSlices;

const TestAlloc = BuddyUnmanaged(5);

test "buddy allocator" {
    const ta = std.testing.allocator;

    var alloc = try TestAlloc.init(ta, 16);
    defer alloc.deinit(ta);

    try expectEqual(0, try alloc.alloc(ta, 0));
    try expectEqual(1, try alloc.alloc(ta, 0));
    try expectEqual(2, try alloc.alloc(ta, 0));

    try expectEqual(4, try alloc.alloc(ta, 1));
    try expectEqual(3, try alloc.alloc(ta, 0));

    try expectEqual(8, try alloc.alloc(ta, 3));

    // --- //
    alloc.free(0, 0);
    alloc.free(1, 0);
    alloc.free(2, 0);

    alloc.free(4, 1);
    alloc.free(3, 0);

    alloc.free(8, 3);

    // Ensure the allocator is back to how it started
    try expectEqual(0, alloc.free_lists[0].items.len);
    try expectEqual(0, alloc.free_lists[1].items.len);
    try expectEqual(0, alloc.free_lists[2].items.len);
    try expectEqual(0, alloc.free_lists[3].items.len);
    try expectEqual(1, alloc.free_lists[4].items.len);
    try expectEqual(0, alloc.free_lists[4].items[0]);
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

test "virtual memory" {
    var array = try vmemMap(5);
    array[0] = 5;
    array[1] = 10;
    vmemUnmap(array);

    array = try vmemMap(1 << 32);
    array[1 << 20] = 5;
    array[1 << 30] = 10;
    vmemUnmap(array);
}

pub fn IndexedMemoryPool(comptime Item: type, comptime use_vmem: bool) type {
    // Heavily inspired by std.heap.MemoryPool

    return struct {
        const Self = @This();
        const no_next_free: usize = std.math.maxInt(usize);
        pub const empty: Self = .{ .items = &.{} };

        // Make sure we have enough space for a usize.
        const node_align = std.mem.Alignment.of(usize).max(.of(Item));
        /// Designed to use items directly. May move locations after calling `.create()`.
        items: []align(node_align.toByteUnits()) Item,
        /// If == no_next_free, it doesn't point to anything
        next_free: usize = no_next_free,
        /// `items.len` is the capacity, while `len` is how many
        /// items are being used.
        len: usize = 0,

        /// Capacity must be > 0
        pub fn initWithCapacity(gpa: Allocator, capacity: usize) !Self {
            if (capacity == 0) @panic("Capacity must be larger than 0");

            if (use_vmem) {
                return .{
                    .items = try vmemMapItems(Item, capacity),
                };
            } else {
                return .{
                    .items = try gpa.alloc(Item, capacity),
                };
            }
        }

        pub fn create(self: *Self, gpa: Allocator) !usize {
            // Check if there's anything on the free list
            if (self.next_free != no_next_free) {
                const next_free = self.next_free;
                // follow to next free
                const item_ptr: *Item = &self.items[next_free];
                const int_ptr: *usize = @ptrCast(item_ptr);
                self.next_free = int_ptr.*;
                return next_free;
            }

            // Resize/realloc if needed
            if (self.len >= self.items.len) {
                if (use_vmem) {
                    return error.OutOfMemory;
                } else if (gpa.resize(self.items, self.items.len * 2)) {
                    self.items.len *= 2;
                } else {
                    self.items = try gpa.realloc(self.items, self.items.len * 2);
                }
            }

            const new_index = self.len;
            self.len += 1;
            return new_index;
        }

        pub fn destroy(self: *Self, index: usize) void {
            const item_ptr: *Item = &self.items[index];
            const int_ptr: *usize = @ptrCast(item_ptr);
            int_ptr.* = self.next_free;
            self.next_free = index;
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            if (use_vmem) {
                vmemUnmapItems(Item, @alignCast(self.items));
            } else {
                gpa.free(self.items);
            }
        }
    };
}

test "indexed memory pool" {
    const ta = testing.allocator;

    const TestStruct = struct {
        a: u64,
        b: u64,
    };

    const PoolWithVmem = IndexedMemoryPool(TestStruct, true);
    const PoolWithoutVmem = IndexedMemoryPool(TestStruct, false);

    // Make sure values are created and freed in the correct order
    var vmem_pool = try PoolWithVmem.initWithCapacity(null_allocator, 32);
    defer vmem_pool.deinit(null_allocator);
    try testing.expectEqual(0, vmem_pool.create(null_allocator));
    try testing.expectEqual(1, vmem_pool.create(null_allocator));
    try testing.expectEqual(2, vmem_pool.create(null_allocator));
    vmem_pool.destroy(1);
    vmem_pool.destroy(0);
    try testing.expectEqual(0, vmem_pool.create(null_allocator));
    try testing.expectEqual(1, vmem_pool.create(null_allocator));

    // Make sure values are created and freed in the correct order
    var pool = try PoolWithoutVmem.initWithCapacity(ta, 1);
    defer pool.deinit(ta);
    try testing.expectEqual(0, pool.create(ta));
    try testing.expectEqual(1, pool.create(ta));
    try testing.expectEqual(2, pool.create(ta));
    pool.destroy(1);
    pool.destroy(0);
    try testing.expectEqual(0, pool.create(ta));
    try testing.expectEqual(1, pool.create(ta));
}

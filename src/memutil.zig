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

const options = @import("options");
const ioutil = @import("ioutil.zig");

/// Uses blake3 to make a hash that, in theory, should never
/// overlap with any other byte string.
pub fn hashBytes(bytes: []const u8) u256 {
    var out: [32]u8 = @splat(0);
    std.crypto.hash.Blake3.hash(bytes, &out, .{});
    return @bitCast(out);
}

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

    assert(cfg.max_pool_order < cfg.max_order);

    return struct {
        gpa: Allocator,
        io: std.Io,
        // TODO: make this one data structure
        free_lists: [cfg.max_order]FreeList,
        alloc_count: [cfg.max_order]usize,
        pools: [cfg.max_pool_order][cfg.pool_size]u32,
        pools_len: [cfg.max_pool_order]usize,
        mutex: std.Io.Mutex = .init,

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

        pub fn leakCheck(self: *Self) enum { normal, leaked } {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            self.drainPool();

            var leaked = false;
            for (self.alloc_count) |count| {
                if (count != 0) leaked = true;
            }

            if (leaked) {
                ioutil.debug("Heap alloc counts: {any}\n", .{self.alloc_count});
                for (self.free_lists[0..], 0..) |free_list, order| {
                    if (free_list.count() > 0) {
                        ioutil.debug("Free list for order {}: {any}\n", .{ order, free_list.entries.items(.key) });
                    }
                }
            }

            return if (leaked) .leaked else .normal;
        }

        /// Caller must handle pool draining and synchronization.
        pub fn anyAllocationsPresent(self: *Self) bool {
            var any_present = false;
            for (self.alloc_count) |count| {
                if (count != 0) any_present = true;
            }
            return any_present;
        }

        /// Not synchronized.
        pub fn deinit(self: *Self) void {
            // Synchronize state.
            self.mutex.lockUncancelable(self.io);
            self.mutex.unlock(self.io);

            // Deinit free lists.
            for (0..cfg.max_order) |i| {
                self.free_lists[i].deinit(self.gpa);
            }

            self.* = undefined;
        }

        /// Caller must have the block already allocated. `new_order` must be smaller than
        /// `current_order`.
        pub fn splitBlock(self: *Self, current_order: u5, new_order: u5) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            self.splitBlockInner(current_order, new_order);
        }

        fn splitBlockInner(self: *Self, current_order: u5, new_order: u5) void {
            assert(new_order < current_order);

            // 2 ** (current_order - new_order)
            const new_block_count = @as(u32, 1) << (current_order - new_order);

            self.alloc_count[current_order] -= 1;
            self.alloc_count[new_order] += new_block_count;
        }

        pub fn allocFromAnyThread(self: *Self, requested_order: u5) !u32 {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.allocOnMainList(requested_order);
        }

        pub fn freeFromAnyThread(self: *Self, index: u32, order: u5) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.freeOnMainList(index, order);
        }

        pub fn allocFromOwningThread(self: *Self, requested_order: u5) !u32 {
            // Try allocating from the pool, if available.
            return self.allocOnPool(requested_order) catch |err| switch (err) {
                error.PoolEmpty => {
                    // We'll refill the pool next.
                    self.mutex.lockUncancelable(self.io);
                    defer self.mutex.unlock(self.io);

                    const containing_order: u5 = @intCast(requested_order + std.math.log2(cfg.pool_size));
                    const alloc = try self.allocOnMainList(containing_order);
                    self.splitBlockInner(containing_order, requested_order);
                    const added = @as(u32, 1) << (containing_order - requested_order);

                    const step = getOrderSize(requested_order);
                    for (0..added) |i| {
                        self.freeOnPool(@intCast(alloc + i * step), requested_order) catch unreachable;
                    }

                    return self.allocOnPool(requested_order) catch unreachable;
                },
                error.TooBigForPool => {
                    self.mutex.lockUncancelable(self.io);
                    defer self.mutex.unlock(self.io);

                    return try self.allocOnMainList(requested_order);
                },
            };
        }

        pub fn freeFromOwningThread(self: *Self, index: u32, order: u5) void {
            // Try freeing onto the pool, if there's room left.
            if (order < cfg.max_pool_order) {
                if (self.freeOnPool(index, order)) {
                    return;
                } else |_| {}
            }

            // We should transfer the pool over to the main list, since there wasn't any room
            // left on the pool.
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.drainPool();
            self.freeOnMainList(index, order);
        }

        /// We keep a non-threadsafe pool of recently used addresses, so allocation/free of
        /// small objects is fast. Not threadsafe.
        fn allocOnPool(self: *Self, requested_order: u5) !u32 {
            if (requested_order < cfg.max_pool_order) {
                if (self.pools_len[requested_order] > 0) {
                    const open = self.pools[requested_order][self.pools_len[requested_order] - 1];
                    self.pools_len[requested_order] -= 1;
                    return open;
                }

                return error.PoolEmpty;
            } else {
                return error.TooBigForPool;
            }
        }

        /// Caller is responsible for locking the allocator.
        pub fn allocOnMainList(self: *Self, requested_order: u5) error{OutOfMemory}!u32 {
            self.alloc_count[requested_order] += 1; // Allocation stats.
            errdefer self.alloc_count[requested_order] -= 1;

            // Ensure that the free list has enough space for when the object needs to be freed.
            try self.ensureSufficientCapacity(requested_order);

            // look for an open block of any size >= requested_order (if the open block is too big, we'll split it).
            var open_index: u32 = undefined;
            var open_order = requested_order;
            while (open_order < cfg.max_order) : (open_order += 1) {
                if (self.free_lists[open_order].pop()) |open| {
                    open_index = open.key;
                    break;
                }
            } else return error.OutOfMemory;

            // split blocks (if needed).
            while (open_order > requested_order) : (open_order -= 1) {
                try self.free_lists[open_order - 1].putNoClobber(self.gpa, open_index + getOrderSize(open_order - 1), {});
                // Lower half is implicitly passed along `open_index`, since
                // the lower block index stays the same as it descends.
            }

            return open_index;
        }

        /// We keep a non-threadsafe pool of recently used addresses, so allocation/free of
        /// small objects is fast. We also don't coalesce on the pool, so this also prevents
        /// churning where blocks are split and merged constantly. Not threadsafe.
        fn freeOnPool(self: *Self, index: u32, order: u5) !void {
            assert(order < cfg.max_pool_order);

            if (self.pools_len[order] >= cfg.pool_size) return error.PoolFull;

            self.pools[order][self.pools_len[order]] = index;
            self.pools_len[order] += 1;
        }

        /// Caller is responsible for locking the allocator.
        pub fn freeOnMainList(self: *Self, index: u32, order: u5) void {
            self.alloc_count[order] -= 1; // Allocation stats.

            // If this block has a buddy, merge. If not, add this block to the appropriate free list.
            const freed_buddy = buddyOfOrder(index, order);
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

        /// Caller is responsible for synchronization.
        pub fn drainPool(self: *Self) void {
            for (&self.pools, &self.pools_len, 0..) |pool, *pool_len, order| {
                for (pool[0..pool_len.*]) |to_free| {
                    self.freeOnMainList(to_free, @intCast(order));
                }
                pool_len.* = 0;
            }
        }

        fn ensureSufficientCapacity(self: *Self, order: u5) !void {
            const backup = self.alloc_count;
            errdefer self.alloc_count = backup;

            var free_list_size = self.alloc_count[order] / 2 + 1;
            try self.free_lists[order].ensureTotalCapacity(self.gpa, free_list_size);

            var current_order = order;
            while (current_order > 0) {
                current_order -= 1;
                // Be sure to have enough space on the smaller block list, as we may want
                // to split this block in the future.
                const parent_free_list_size = free_list_size;
                free_list_size = (parent_free_list_size * 2) + self.alloc_count[current_order] / 2 + 1;
                try self.free_lists[current_order].ensureTotalCapacity(self.gpa, free_list_size);
            }
        }

        pub fn forEachAllocated(
            self: *Self,
            context: anytype,
        ) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.drainPool();
            _ = self.forEachAllocatedInner(cfg.max_order - 1, 0, context);
        }

        /// Returns true if this subtree contains any free block. This function is not synchronized.
        fn forEachAllocatedInner(
            self: *Self,
            order: u5,
            index: u32,
            context: anytype,
        ) bool {
            if (self.free_lists[order].getIndex(index) != null) return true;

            const order_allocated_as = context.getOrder(index);
            if (order == order_allocated_as) {
                context.onAllocated(index, order);
                return false;
            }

            const buddy = index + getOrderSize(order - 1);
            const left_has_free = self.forEachAllocatedInner(order - 1, index, context);
            const right_has_free = self.forEachAllocatedInner(order - 1, buddy, context);
            return left_has_free or right_has_free;
        }

        fn printBuddyState(self: Self, beginning: []const u8) void {
            ioutil.debug("{s}", .{beginning});
            for (0..self.free_lists.len) |order| {
                ioutil.debug("Order: {} ({any}), ", .{ order, self.free_lists[order].items });
            }
            ioutil.debug("\n", .{});
        }
    };
}

const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expectEqualSlices = std.testing.expectEqualSlices;

const TestAlloc = BuddyUnmanaged(.{
    .max_order = 5,
    .max_pool_order = 0,
    .pool_size = 0,
});

test "buddy allocator" {
    const ta = std.testing.allocator;

    var alloc = try TestAlloc.init(ta, testing.io, 16);
    defer {
        if (alloc.leakCheck() == .leaked) @panic("Found leaks");
        alloc.deinit();
    }

    try expectEqual(0, try alloc.allocFromAnyThread(0));
    try expectEqual(1, try alloc.allocFromAnyThread(0));
    try expectEqual(2, try alloc.allocFromAnyThread(0));

    try expectEqual(4, try alloc.allocFromAnyThread(1));
    try expectEqual(3, try alloc.allocFromAnyThread(0));

    try expectEqual(8, try alloc.allocFromAnyThread(3));

    // And now free.
    alloc.freeFromAnyThread(0, 0);
    alloc.freeFromAnyThread(1, 0);
    alloc.freeFromAnyThread(2, 0);

    alloc.freeFromAnyThread(4, 1);
    alloc.freeFromAnyThread(3, 0);

    alloc.freeFromAnyThread(8, 3);

    // Ensure the allocator is back to how it started
    try expectEqual(0, alloc.free_lists[0].count());
    try expectEqual(0, alloc.free_lists[1].count());
    try expectEqual(0, alloc.free_lists[2].count());
    try expectEqual(0, alloc.free_lists[3].count());
    try expectEqual(1, alloc.free_lists[4].count());
    try expectEqual(0, alloc.free_lists[4].entries.get(0).key);
}

const BlockTestAlloc = BuddyUnmanaged(.{
    .max_order = 10,
    .max_pool_order = 0,
    .pool_size = 0,
});
test "block splitting" {
    var alloc = try BlockTestAlloc.init(testing.allocator, testing.io, 16);
    defer {
        if (alloc.leakCheck() == .leaked) @panic("Found leaks");
        alloc.deinit();
    }

    // Make sure enough space was allocated on the free list for any split blocks.
    for (0..8) |_| {
        _ = try alloc.allocFromAnyThread(4);
        alloc.splitBlock(4, 0);
    }

    var block_i: u32 = 0;
    while (block_i < (8 * getOrderSize(4))) : (block_i += 2) {
        // Increment by 2 in order to hit every other block, which is the maximum amount
        // of fragmentation a buddy allocator can have.
        alloc.freeFromAnyThread(block_i, 0);
    }

    // Free the rest so we don't have any leaks.
    block_i = 1;
    while (block_i < (8 * getOrderSize(4))) : (block_i += 2) {
        alloc.freeFromAnyThread(block_i, 0);
    }
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

/// Note, this will hand out allocations that potentially alias. Really only useful for debugging.
pub const RingBufferAllocator = struct {
    buffer: []u8,
    end_index: usize,

    pub fn init(buffer: []u8) RingBufferAllocator {
        return .{
            .buffer = buffer,
            .end_index = 0,
        };
    }

    pub fn allocator(self: *RingBufferAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn calculateOffset(self: *RingBufferAllocator, n: usize, alignment: mem.Alignment) ?struct { alloc_at: [*]u8, new_end: usize } {
        const ptr_align = alignment.toByteUnits();
        const adjust_off = mem.alignPointerOffset(self.buffer.ptr + self.end_index, ptr_align) orelse return null;
        const adjusted_index = self.end_index + adjust_off;
        const new_end_index = adjusted_index + n;
        if (new_end_index > self.buffer.len) return null;

        return .{
            .alloc_at = self.buffer.ptr + adjusted_index,
            .new_end = new_end_index,
        };
    }

    pub fn alloc(ctx: *anyopaque, n: usize, alignment: mem.Alignment, ra: usize) ?[*]u8 {
        const self: *RingBufferAllocator = @ptrCast(@alignCast(ctx));
        _ = ra;

        if (self.calculateOffset(n, alignment)) |val| {
            self.end_index = val.new_end;
            return val.alloc_at;
        } else {
            // Wrap the buffer around.
            self.end_index = 0;
            if (self.calculateOffset(n, alignment)) |val| {
                self.end_index = val.new_end;
                return val.alloc_at;
            } else return null;
        }
    }

    pub fn resize(ctx: *anyopaque, buf: []u8, alignment: mem.Alignment, new_size: usize, return_address: usize) bool {
        _ = ctx;
        _ = buf;
        _ = alignment;
        _ = new_size;
        _ = return_address;
        return false;
    }

    pub fn remap(ctx: *anyopaque, memory: []u8, alignment: mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = return_address;
        return null;
    }

    pub fn free(ctx: *anyopaque, buf: []u8, alignment: mem.Alignment, return_address: usize) void {
        _ = ctx;
        _ = buf;
        _ = alignment;
        _ = return_address;
    }
};

pub fn IndexedMemoryPool(comptime Item: type, comptime use_vmem: bool) type {
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
            // Resize/realloc if needed
            const new_size = @max(self.items.len, 4) * 2;
            if (self.len >= self.items.len) {
                if (use_vmem) {
                    return error.OutOfMemory;
                } else if (gpa.resize(self.items, new_size)) {
                    self.items.len = new_size;
                } else {
                    self.items = try gpa.realloc(self.items, new_size);
                }
            }

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

        pub fn deinit(self: *Self, gpa: Allocator) void {
            if (use_vmem) {
                vmemUnmapItems(Item, @alignCast(self.items));
            } else {
                gpa.free(self.items);
            }
        }

        /// For debugging purposes only. Dumps everything that was leaked.
        pub fn dumpLeaked(self: *Self, scratch: Allocator, comptime fmt: []const u8) !void {
            // We'll go through the free list, adding each free item to the `not_leaked` set.
            var not_leaked = std.AutoHashMap(usize, void).init(scratch);
            defer not_leaked.deinit();

            var next_free = self.next_free;
            while (next_free != no_next_free) {
                try not_leaked.put(next_free, undefined);

                const item_ptr: *Item = &self.items[next_free];
                const int_ptr: *usize = @ptrCast(item_ptr);

                next_free = int_ptr.*;
            }

            for (0..self.len) |i| {
                if (!not_leaked.contains(i)) {
                    ioutil.debug(fmt, .{ i, self.items[i] });
                }
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

pub fn expectErrorOrOom(expected_error: anyerror, actual_error_union: anytype) !void {
    if (actual_error_union) |_| {} else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    }

    try testing.expectError(expected_error, actual_error_union);
}

/// Context is a standard hash map context
pub fn LruCache(comptime K: type, comptime V: type, comptime Context: type) type {
    return struct {
        const Self = @This();

        pub const Node = struct {
            prev: ?u32,
            next: ?u32,
            key: K,
            item: V,
        };

        pool: IndexedMemoryPool(Node, false),
        mapping: std.HashMapUnmanaged(K, u32, Context, 80),
        max_size: u32,
        last: ?u32 = null,
        first: ?u32 = null,

        pub fn initWithCapacity(gpa: Allocator, max_size: u32) !Self {
            var new_lru: Self = .{
                .pool = try .initWithCapacity(gpa, max_size),
                .mapping = .{},
                .max_size = max_size,
                .last = null,
                .first = null,
            };
            errdefer new_lru.pool.deinit(gpa);

            try new_lru.mapping.ensureTotalCapacity(gpa, max_size);

            return new_lru;
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.mapping.deinit(gpa);
            self.pool.deinit(gpa);
        }

        fn moveToFirst(self: *Self, index: u32) void {
            const nodes = self.pool.items;
            const node = &nodes[index];

            // Already the first item?
            if (self.first == index) return;

            // Unlink the item.
            if (node.prev) |prev| nodes[prev].next = node.next;
            if (node.next) |next| nodes[next].prev = node.prev;

            // If it was the last, update the last.
            if (index == self.last) self.last = node.prev;

            // Move to first item.
            node.prev = null;
            node.next = self.first;
            if (self.first) |first| nodes[first].prev = index;
            self.first = index;
        }

        pub const ValueIterator = struct {
            nodes: []Node,
            current: ?u32,

            pub fn next(self: *ValueIterator) ?*V {
                const index = self.current orelse return null;
                const node = &self.nodes[index];
                self.current = node.next;
                return &node.item;
            }
        };

        /// Iterates over all values in LRU order (most recently used first).
        pub fn valueIterator(self: *Self) ValueIterator {
            return .{
                .nodes = self.pool.items,
                .current = self.first,
            };
        }

        /// Removes all entries but keeps the underlying capacity allocated.
        pub fn clearRetainingCapacity(self: *Self) void {
            self.mapping.clearRetainingCapacity();
            self.pool.clearRetainingCapacity();
            self.first = null;
            self.last = null;
        }

        pub fn get(self: *Self, key: K) ?V {
            const value = self.mapping.get(key);

            if (value) |val_index| {
                self.moveToFirst(val_index);
                return self.pool.items[val_index].item;
            } else return null;
        }

        /// Returns an old value if it was evicted.
        pub fn put(self: *Self, key: K, value: V) ?V {
            // Check if this key already exists.
            if (self.mapping.get(key)) |val_index| {
                self.moveToFirst(val_index);
                // Save the old value so we can return it to the caller.
                const old_value = self.pool.items[val_index].item;
                // Update in place.
                self.pool.items[val_index].item = value;

                return old_value;
            } else {
                // Doesn't exist, so we need to create it.
                var last_value: ?V = null;

                // Evict the last used item if we've reached `max_size`.
                const new: u32 = blk: {
                    if (self.pool.count >= self.max_size) {
                        const last_index = self.last.?;
                        const last = &self.pool.items[last_index];

                        assert(self.mapping.remove(last.key));
                        self.last = last.prev;
                        if (self.last) |new_last| {
                            self.pool.items[new_last].next = null;
                        }
                        last_value = last.item;
                        last.* = undefined;
                        // No need to destroy the item, since we'll reuse it.
                        break :blk last_index;
                    } else {
                        break :blk @intCast(self.pool.createAssumeCapacity());
                    }
                };

                self.pool.items[new] = .{
                    .prev = null,
                    .next = self.first,
                    .key = key,
                    .item = value,
                };

                // Link the new item in.
                if (self.first) |first| {
                    self.pool.items[first].prev = new;
                    self.first = new;
                } else {
                    self.first = new;
                    self.last = new;
                }

                self.mapping.putAssumeCapacity(key, new);

                return last_value;
            }
        }
    };
}

const StringCache = LruCache([]const u8, []const u8, struct {
    pub fn hash(self: @This(), s: []const u8) u64 {
        _ = self;
        return std.hash.Wyhash.hash(0, s);
    }

    pub fn eql(self: @This(), a: []const u8, b: []const u8) bool {
        _ = self;
        return mem.eql(u8, a, b);
    }
});

test "lru cache" {
    // Basic put and get.
    {
        var cache: StringCache = try .initWithCapacity(testing.allocator, 3);
        defer cache.deinit(testing.allocator);

        try testing.expectEqual(null, cache.put("key1", "value1"));
        try testing.expectEqualStrings("value1", cache.get("key1").?);
        try testing.expectEqual(null, cache.put("key2", "value2"));
        try testing.expectEqual(null, cache.put("key3", "value3"));
        try testing.expectEqual(cache.put("key4", "value4"), "value1");
        try testing.expectEqual(null, cache.get("key1"));
    }

    // Check that get promotes key, saving it from eviction.
    {
        var cache: StringCache = try .initWithCapacity(testing.allocator, 2);
        defer cache.deinit(testing.allocator);

        // Fill cache, then promote key1 by accessing it.
        try testing.expectEqual(null, cache.put("key1", "value1"));
        try testing.expectEqual(null, cache.put("key2", "value2"));
        try testing.expectEqualStrings("value1", cache.get("key1").?);

        // key2 should be evicted, not key1.
        try testing.expectEqualStrings("value2", cache.put("key3", "value3").?);
        try testing.expectEqualStrings("value1", cache.get("key1").?);
        try testing.expectEqual(null, cache.get("key2"));
    }

    // Check that updating existing key returns old value without evicting.
    {
        var cache: StringCache = try .initWithCapacity(testing.allocator, 2);
        defer cache.deinit(testing.allocator);

        // Fill cache, then update key1 in place.
        try testing.expectEqual(null, cache.put("key1", "old"));
        try testing.expectEqual(null, cache.put("key2", "value2"));
        try testing.expectEqualStrings("old", cache.put("key1", "new").?);

        // Both keys should still be present.
        try testing.expectEqualStrings("new", cache.get("key1").?);
        try testing.expectEqualStrings("value2", cache.get("key2").?);
    }

    // Check re-inserting an evicted key.
    {
        var cache: StringCache = try .initWithCapacity(testing.allocator, 2);
        defer cache.deinit(testing.allocator);

        // Evict key1, then re-insert it — evicts key2 (now LRU).
        try testing.expectEqual(null, cache.put("key1", "value1"));
        try testing.expectEqual(null, cache.put("key2", "value2"));
        try testing.expectEqualStrings("value1", cache.put("key3", "value3").?);
        try testing.expectEqualStrings("value2", cache.put("key1", "value1-new").?);

        // key1 and key3 remain; key2 was evicted.
        try testing.expectEqualStrings("value1-new", cache.get("key1").?);
        try testing.expectEqualStrings("value3", cache.get("key3").?);
        try testing.expectEqual(null, cache.get("key2"));
    }
}

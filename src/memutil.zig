//! Memory-related functions and objects.

const builtin = @import("builtin");
const options = @import("options");
const std = @import("std");
const math = std.math;
const heap = std.heap;
const mem = std.mem;
const Alignment = mem.Alignment;
const testing = std.testing;
const assert = std.debug.assert;
const Allocator = mem.Allocator;

var null_ctx: usize = 0;
/// Use to always fail any allocation operation.
pub const null_allocator: Allocator = .{
    .ptr = &null_ctx,
    .vtable = &.{
        .alloc = null_alloc,
        .resize = null_resize,
        .remap = null_remap,
        .free = null_free,
    },
};
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

    fn attemptAllocation(
        self: *RingBufferAllocator,
        n: usize,
        alignment: mem.Alignment,
    ) ?[*]u8 {
        const offset = mem.alignPointerOffset(self.buffer.ptr + self.end_index, alignment.toByteUnits()) orelse return null;
        const aligned_index = self.end_index + offset;
        const new_end_index = aligned_index + n;
        if (new_end_index > self.buffer.len) return null;

        self.end_index = new_end_index;
        return self.buffer.ptr + aligned_index;
    }

    pub fn alloc(ctx: *anyopaque, n: usize, alignment: mem.Alignment, ra: usize) ?[*]u8 {
        const self: *RingBufferAllocator = @ptrCast(@alignCast(ctx));
        _ = ra;

        return self.attemptAllocation(n, alignment) orelse {
            // Not enough room, so we'll wrap the buffer around before trying again.
            self.end_index = 0;
            // Try again after looping around, since we have more room.
            return self.attemptAllocation(n, alignment);
        };
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

/// The `ScopedArena` supports very fast allocation of small chunks of memory.
/// Based on the V8's `Zone` and Zig's `ArenaAllocator`.
pub const ScopedArena = struct {
    child_allocator: Allocator,
    /// Need to track the first node separate from the `current` node, since
    /// when we deinit we need to walk the whole list from the beginning.
    first_segment: ?*Segment = null,
    current_segment: ?*Segment = null,

    /// This is a snapshot of the arena at a certain point in time.
    /// Used when calling `restore` to roll the arena back to this point.
    pub const Snapshot = extern struct {
        /// `null` marks a snapshot taken before any segment existed. Restoring
        /// to it resets the arena to fully empty.
        current: ?*Segment,
        end_index: usize,
    };

    pub const Segment = struct {
        pub const min_size = 8 * 1024;
        pub const max_default_size = 32 * 1024;

        /// Buffer size, not including the size of the segment header.
        size: usize,
        /// End of allocated bytes in this segment.
        end_index: usize,
        next: ?*Segment,

        pub fn buffer(segment: *Segment) []u8 {
            return @as([*]u8, @ptrCast(segment))[@sizeOf(Segment)..][0..segment.size];
        }

        pub fn allocatedSlice(segment: *Segment) []u8 {
            return @as([*]u8, @ptrCast(segment))[0..(@sizeOf(Segment) + segment.size)];
        }

        fn alloc(segment: *Segment, n: usize, alignment: Alignment) ?[*]u8 {
            const buf = segment.buffer();
            const offset = std.mem.alignPointerOffset(buf.ptr + segment.end_index, alignment.toByteUnits()) orelse return null;
            const aligned_index = segment.end_index + offset;
            const new_end_index = aligned_index + n;

            if (new_end_index <= buf.len) {
                segment.end_index = new_end_index;
                return buf[aligned_index..new_end_index].ptr;
            } else return null;
        }
    };

    pub fn init(child_allocator: Allocator) ScopedArena {
        return .{ .child_allocator = child_allocator };
    }

    pub fn deinit(arena: *ScopedArena) void {
        if (arena.first_segment) |start| arena.cascadeFreeSegments(start);
        arena.* = undefined;
    }

    pub fn cascadeFreeSegments(arena: *ScopedArena, start: *Segment) void {
        var it: ?*Segment = start;
        while (it) |segment| {
            it = segment.next;
            arena.child_allocator.rawFree(segment.allocatedSlice(), .of(Segment), @returnAddress());
        }
    }

    pub fn allocator(self: *ScopedArena) Allocator {
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

    /// Queries the current memory use of this arena.
    pub fn queryCapacity(arena: *ScopedArena) usize {
        var capacity: usize = 0;
        var it = arena.first_segment;
        while (it) |node| : (it = node.next) capacity += node.size;
        return capacity;
    }

    pub fn takeSnapshot(arena: *ScopedArena) Snapshot {
        return .{
            .current = arena.current_segment,
            .end_index = if (arena.current_segment) |node| node.end_index else 0,
        };
    }

    pub fn restore(arena: *ScopedArena, snapshot: Snapshot) void {
        if (snapshot.current) |segment| {
            // Free all trailing segments.
            if (segment.next) |next| arena.cascadeFreeSegments(next);
            segment.next = null;

            arena.current_segment = segment;
            segment.end_index = snapshot.end_index;
        } else {
            // Snapshot was taken at a point where we had nothing allocated, so we'll
            // go back to nothing allocated.
            if (arena.first_segment) |first| arena.cascadeFreeSegments(first);
            arena.first_segment = null;
            arena.current_segment = null;
        }
    }

    fn alloc(ctx: *anyopaque, n: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const arena: *ScopedArena = @ptrCast(@alignCast(ctx));
        _ = ra;
        assert(n > 0);

        // Allocate on the current segment if it still has room.
        if (arena.current_segment) |segment| if (segment.alloc(n, alignment)) |new_alloc| return new_alloc;

        // Wasn't enough room, or `arena.current` was never set, so we'll allocate a new segment.
        const previous_segment_size = if (arena.current_segment) |segment| segment.size else 0;
        const proposed_size = @min(@max(previous_segment_size * 2, Segment.min_size), Segment.max_default_size);
        const min_needed_size = @sizeOf(Segment) + alignment.toByteUnits() + n;
        const selected_size = if (min_needed_size > proposed_size) min_needed_size else proposed_size;

        const new_segment_ptr = arena.child_allocator.rawAlloc(selected_size, .of(Segment), @returnAddress()) orelse return null;
        const new_segment: *Segment = @ptrCast(@alignCast(new_segment_ptr));
        new_segment.* = .{
            .size = selected_size - @sizeOf(Segment),
            .end_index = 0,
            .next = null,
        };
        if (arena.current_segment) |current| current.next = new_segment;
        arena.current_segment = new_segment;
        if (arena.first_segment == null) arena.first_segment = new_segment;

        return new_segment.alloc(n, alignment).?;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) bool {
        const arena: *ScopedArena = @ptrCast(@alignCast(ctx));
        _ = alignment;
        _ = ra;
        assert(memory.len > 0);
        assert(new_len > 0);

        const segment = arena.current_segment orelse return false;
        const buffer = segment.buffer();

        if (buffer.ptr + segment.end_index != memory.ptr + memory.len) {
            // It's not the most recent allocation, so it cannot be expanded,
            // but it's fine if they want to make it smaller.
            return new_len <= memory.len;
        }
        // We've now established that this is the last allocation on `segment`.

        if (new_len <= memory.len) {
            segment.end_index -= (memory.len - new_len);
            return true;
        }

        // Saturating arithmetic because `end_index` is not guaranteed to be `<= size`.
        // The allocation we're trying to resize *could* belong to a different segment!
        if (buffer.len -| segment.end_index >= new_len - memory.len) {
            const new_end_index = segment.end_index + (new_len - memory.len);
            assert(buffer.ptr + new_end_index == memory.ptr + new_len);

            segment.end_index = new_end_index;
            return true;
        }

        return false;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        return if (resize(ctx, memory, alignment, new_len, ra)) memory.ptr else null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
        const arena: *ScopedArena = @ptrCast(@alignCast(ctx));
        _ = alignment;
        _ = ra;

        assert(memory.len > 0);

        const segment = arena.current_segment.?;
        if (segment.buffer().ptr + segment.end_index != memory.ptr + memory.len) {
            // Not the most recent allocation; we cannot free it.
            return;
        }
        segment.end_index -= memory.len;
    }
};

fn testScopedArena(ta: mem.Allocator) !void {
    var scoped_arena = ScopedArena.init(ta);
    defer scoped_arena.deinit();
    const arena = scoped_arena.allocator();

    // Check boundary condition with node.
    _ = try arena.alloc(u8, ScopedArena.Segment.max_default_size);
    _ = try arena.alloc(u8, 8);
    // Check that we can allocate large structures.
    _ = try arena.alloc(u8, ScopedArena.Segment.max_default_size * 2);

    // Test restoring.
    {
        const capacity = scoped_arena.queryCapacity();
        const snapshot = scoped_arena.takeSnapshot();

        _ = try arena.alloc(u8, 10);

        {
            const inner_capacity = scoped_arena.queryCapacity();
            const inner_snapshot = scoped_arena.takeSnapshot();

            _ = try arena.alloc(u8, ScopedArena.Segment.max_default_size * 2);

            scoped_arena.restore(inner_snapshot);
            try testing.expectEqual(inner_capacity, scoped_arena.queryCapacity());
        }

        scoped_arena.restore(snapshot);
        // Make sure capacity is back to normal.
        try testing.expectEqual(capacity, scoped_arena.queryCapacity());
    }

    // Test resizing.
    const alloc = try arena.alloc(u8, 16);
    try testing.expect(arena.resize(alloc, 32)); // Can resize bigger if it's the last one.
    try testing.expect(arena.resize(alloc, 8));

    _ = try arena.alloc(u8, 24);
    try testing.expect(!arena.resize(alloc, 32)); // Can no longer resize `alloc` as bigger.
    try testing.expect(arena.resize(alloc, 4)); // ...but can still make it smaller.
}

test "scoped arena" {
    try testing.checkAllAllocationFailures(testing.allocator, testScopedArena, .{});
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
        pub fn initWithCapacity(gpa: Allocator, capacity: usize) !Self {
            if (capacity == 0) @panic("Capacity must be larger than 0");
            return .{ .items = try gpa.alloc(Item, capacity) };
        }

        pub fn create(self: *Self, gpa: Allocator) !usize {
            // Resize/realloc if needed
            const new_size = @max(self.items.len, 4) * 2;
            if (self.len >= self.items.len) {
                self.items = try gpa.realloc(self.items, new_size);
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
            gpa.free(self.items);
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
                    std.debug.print(fmt, .{ i, self.items[i] });
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

    const Pool = IndexedMemoryPool(TestStruct);

    // Make sure values are created and freed in the correct order
    var pool = try Pool.initWithCapacity(ta, 1);
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

/// How a test takes part in allocation-failure testing.
pub const OomTesting = union(enum) {
    exhaustive,
    unsupported: []const u8,
};

/// This only does full sweeping when -Dfull-oom-testing is enabled.
/// Use `checkAllAllocationFailures` directly when a test is cheap enough
/// to always sweep.
pub fn checkAllocationFailures(
    comptime mode: OomTesting,
    comptime func: anytype,
    args: anytype,
) !void {
    const sweep = switch (mode) {
        .exhaustive => options.full_oom_testing,
        .unsupported => false,
    };

    if (sweep) {
        try testing.checkAllAllocationFailures(testing.allocator, func, args);
    } else {
        try @call(.auto, func, .{testing.allocator} ++ args);
    }
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

        pool: IndexedMemoryPool(Node),
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

        pub fn getPtr(self: *Self, key: K) ?*V {
            const value = self.mapping.get(key);

            if (value) |val_index| {
                self.moveToFirst(val_index);
                return &self.pool.items[val_index].item;
            } else return null;
        }

        pub fn get(self: *Self, key: K) ?V {
            return if (self.getPtr(key)) |ptr| ptr.* else null;
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

/// Node = struct, Edge = pointer + field name.
pub const StructIterator = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    arena: std.mem.Allocator,

    pub const Error = std.mem.Allocator.Error;

    pub const NodeInfo = struct {
        parent_info: ?*const NodeInfo,
        node: *const anyopaque,
        enumerate_struct: ?*const EnumerateStructFn,
        /// If this Node is from C, we have a C-compatible signature here.
        /// This will be chosen over `enumerate_struct` if set.
        enumerate_struct_c: ?EnumerateStructCFn = null,
        type_name: []const u8,
        as_string: ?[]const u8,
        /// Whether we created this node on the arena instead of pulling it from the heap.
        is_synthetic: bool = false,
    };

    pub const EnumerateStructFn = fn (ctx: StructIterator, node_info: *const NodeInfo) Error!void;
    /// Return code other than 0 is considered OOM.
    pub const EnumerateStructCFn = *const fn (walker: *CEnumerateContext, node: *const anyopaque) callconv(.c) c_int;
    pub const CEnumerateContext = struct {
        ctx: StructIterator,
        info: *const NodeInfo,
    };
    pub const VTable = struct {
        visit_node: *const fn (ctx: StructIterator, node_info: *const NodeInfo, edge_coming_from: ?[]const u8) Error!void,
    };

    fn getEnumerateStruct(T: type) ?*const EnumerateStructFn {
        switch (@typeInfo(T)) {
            .@"struct", .@"enum", .@"union", .@"opaque" => {
                return if (@hasDecl(T, "enumerateStruct")) &T.enumerateStruct else null;
            },
            else => return null,
        }
    }

    pub fn followUnparentedNode(ctx: StructIterator, T: type, ptr: *const T) Error!void {
        const node_info: NodeInfo = .{
            .parent_info = null,
            .node = ptr,
            .enumerate_struct = getEnumerateStruct(T),
            .type_name = @typeName(T),
            .as_string = null,
        };
        try ctx.vtable.visit_node(ctx, &node_info, null);
    }

    pub fn followNode(
        ctx: StructIterator,
        T: type,
        node_info: *const NodeInfo,
        edge_coming_from: []const u8,
        node_ptr: *const T,
    ) Error!void {
        try ctx.followNodeInner(T, node_info, edge_coming_from, @as(*const anyopaque, node_ptr));
    }

    pub fn followNodeInner(
        ctx: StructIterator,
        T: type,
        node_info: *const NodeInfo,
        edge_coming_from: []const u8,
        node_ptr: *const anyopaque,
    ) Error!void {
        const child_node: NodeInfo = .{
            .parent_info = node_info,
            .node = node_ptr,
            .enumerate_struct = getEnumerateStruct(T),
            .type_name = @typeName(T),
            .as_string = null,
        };
        try ctx.vtable.visit_node(ctx, &child_node, edge_coming_from);
    }

    pub fn addFieldString(
        ctx: StructIterator,
        T: type,
        node_info: *const NodeInfo,
        edge_coming_from: []const u8,
        val: []const u8,
    ) Error!void {
        const dummy_node = try ctx.arena.create(u8);
        const child_node: NodeInfo = .{
            .parent_info = node_info,
            .node = dummy_node,
            .enumerate_struct = null,
            .type_name = @typeName(T),
            .as_string = try ctx.arena.dupe(u8, val),
            .is_synthetic = true,
        };
        try ctx.vtable.visit_node(ctx, &child_node, edge_coming_from);
    }

    pub fn addField(
        ctx: StructIterator,
        T: type,
        node_info: *const NodeInfo,
        edge_coming_from: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) Error!void {
        const dummy_node = try ctx.arena.create(u8);
        const child_node: NodeInfo = .{
            .parent_info = node_info,
            .node = dummy_node,
            .enumerate_struct = null,
            .type_name = @typeName(T),
            .as_string = try std.fmt.allocPrint(ctx.arena, fmt, args),
            .is_synthetic = true,
        };
        try ctx.vtable.visit_node(ctx, &child_node, edge_coming_from);
    }
};

pub const GraphWalker = struct {
    pub const Edge = struct {
        from: *const anyopaque,
        to: *const anyopaque,
        field_name: []const u8,
    };
    pub const Node = struct {
        type_name: []const u8,
        as_string: ?[]const u8,
        is_synthetic: bool,
    };

    nodes: std.AutoHashMapUnmanaged(*const anyopaque, Node),
    edges: std.ArrayList(Edge),

    pub const empty: GraphWalker = .{ .nodes = .empty, .edges = .empty };
    pub const vtable: StructIterator.VTable = .{ .visit_node = visitNode };

    pub fn promote(self: *GraphWalker, arena: std.mem.Allocator) StructIterator {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .arena = arena,
        };
    }

    fn visitNode(
        ctx: StructIterator,
        info: *const StructIterator.NodeInfo,
        edge_coming_from: ?[]const u8,
    ) StructIterator.Error!void {
        const self: *GraphWalker = @ptrCast(@alignCast(ctx.ptr));
        if (info.parent_info) |parent_info| {
            try self.edges.append(ctx.arena, .{
                .from = parent_info.node,
                .to = info.node,
                .field_name = edge_coming_from.?,
            });
        }
        if (self.nodes.contains(info.node)) return; // Avoid double counting and cycles.
        try self.nodes.put(ctx.arena, info.node, .{
            .type_name = info.type_name,
            .as_string = info.as_string,
            .is_synthetic = info.is_synthetic,
        });
        if (info.enumerate_struct_c) |c_fn| {
            var walker: StructIterator.CEnumerateContext = .{ .ctx = ctx, .info = info };
            if (c_fn(&walker, info.node) != 0) return error.OutOfMemory;
        } else if (info.enumerate_struct) |follow_fn| {
            try follow_fn(ctx, info);
        }
    }
};

const StructIteratorTest = struct {
    const NodeInfo = StructIterator.NodeInfo;
    pub const Bar = struct {};

    /// A node with up to two named children (`a`, `b`) for exercising cycles,
    /// diamonds, and the two-child case. `name` is for human inspection only.
    pub const Node = struct {
        name: []const u8,
        a: ?*const Node = null,
        b: ?*const Node = null,

        pub fn enumerateStruct(ctx: StructIterator, node_info: *const NodeInfo) StructIterator.Error!void {
            const self: *const Node = @ptrCast(@alignCast(node_info.node));
            if (self.a) |child| try ctx.followNode(Node, node_info, "a", child);
            if (self.b) |child| try ctx.followNode(Node, node_info, "b", child);
        }
    };
};

test "GraphWalker: single edge records both endpoints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var walker = GraphWalker.empty;
    const iter = walker.promote(arena.allocator());
    var bar: StructIteratorTest.Node = .{ .name = "bar" };
    var foo: StructIteratorTest.Node = .{ .name = "foo", .a = &bar };
    try iter.followUnparentedNode(StructIteratorTest.Node, &foo);

    try std.testing.expectEqual(@as(usize, 2), walker.nodes.count());
    try std.testing.expect(walker.nodes.contains(@ptrCast(&foo)));
    try std.testing.expect(walker.nodes.contains(@ptrCast(&bar)));
    try std.testing.expectEqual(@as(usize, 1), walker.edges.items.len);
    const edge = walker.edges.items[0];
    try std.testing.expectEqual(@as(*const anyopaque, @ptrCast(&foo)), edge.from);
    try std.testing.expectEqual(@as(*const anyopaque, @ptrCast(&bar)), edge.to);
    try std.testing.expectEqualStrings("a", edge.field_name);
}

test "GraphWalker: two children both recorded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var walker = GraphWalker.empty;
    const iter = walker.promote(arena.allocator());
    var b: StructIteratorTest.Node = .{ .name = "b" };
    var c: StructIteratorTest.Node = .{ .name = "c" };
    var a: StructIteratorTest.Node = .{ .name = "a", .a = &b, .b = &c };
    try iter.followUnparentedNode(StructIteratorTest.Node, &a);

    try std.testing.expectEqual(@as(usize, 3), walker.nodes.count());
    try std.testing.expectEqual(@as(usize, 2), walker.edges.items.len);
}

test "GraphWalker: cycle records back-edge without recursing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var walker = GraphWalker.empty;
    const iter = walker.promote(arena.allocator());
    var a: StructIteratorTest.Node = .{ .name = "a" };
    var b: StructIteratorTest.Node = .{ .name = "b" };
    a.a = &b;
    b.a = &a; // back-edge: a -> b -> a
    try iter.followUnparentedNode(StructIteratorTest.Node, &a);

    // Exactly two nodes visited -- the back-edge did not re-enter a.
    try std.testing.expectEqual(@as(usize, 2), walker.nodes.count());
    // Both directions recorded, because edges are recorded before the
    // visited check gates recursion.
    try std.testing.expectEqual(@as(usize, 2), walker.edges.items.len);
}

test "GraphWalker: diamond records both edges into shared child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var walker = GraphWalker.empty;
    const iter = walker.promote(arena.allocator());
    var d: StructIteratorTest.Node = .{ .name = "d" };
    var b: StructIteratorTest.Node = .{ .name = "b", .a = &d };
    var c: StructIteratorTest.Node = .{ .name = "c", .a = &d };
    var a: StructIteratorTest.Node = .{ .name = "a", .a = &b, .b = &c };
    try iter.followUnparentedNode(StructIteratorTest.Node, &a);

    // d is visited once, but both edges into it are recorded.
    try std.testing.expectEqual(@as(usize, 4), walker.nodes.count());
    try std.testing.expectEqual(@as(usize, 4), walker.edges.items.len);
}

test "GraphWalker: leaf root recorded with no edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var walker = GraphWalker.empty;
    const iter = walker.promote(arena.allocator());
    var leaf: StructIteratorTest.Node = .{ .name = "leaf" };
    try iter.followUnparentedNode(StructIteratorTest.Node, &leaf);

    try std.testing.expectEqual(@as(usize, 1), walker.nodes.count());
    try std.testing.expect(walker.nodes.contains(@ptrCast(&leaf)));
    try std.testing.expectEqual(@as(usize, 0), walker.edges.items.len);
}

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
const builtin = @import("builtin");

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

/// Get a pointer to a byte-aligned field in a packed struct, for use in atomic operations.
pub fn packedFieldPtr(T: type, obj: *T, comptime field_name: []const u8) *@FieldType(T, field_name) {
    const Field = @FieldType(T, field_name);
    const info = @typeInfo(T).@"struct";
    // Must be a packed struct, since we make layout assumptions based on that.
    assert(info.layout == .@"packed");

    const bit_offset = @bitOffsetOf(T, field_name);
    const byte_offset = bit_offset / 8;

    // Field must start on a byte boundary.
    comptime assert(bit_offset % 8 == 0);
    // Total size must also be aligned at a byte boundary, because of how we
    // do byte math later on.
    comptime assert(@sizeOf(T) % 8 == 0);

    // Atomic operations are only well-defined for power-of-two sizes up to 8.
    comptime assert(@sizeOf(Field) > 0);
    comptime assert(std.math.isPowerOfTwo(@sizeOf(Field)));
    comptime assert(@sizeOf(Field) <= 8);

    // The resulting pointer must be aligned to the field for both little endian and big endian cases.
    const le_offset = byte_offset;
    const be_offset = @sizeOf(T) - @sizeOf(Field) - byte_offset;
    comptime assert(le_offset % @sizeOf(Field) == 0);
    comptime assert(be_offset % @sizeOf(Field) == 0);

    const offset = switch (comptime builtin.target.cpu.arch.endian()) {
        .little => le_offset,
        .big => be_offset,
    };

    const bytes: [*]u8 = @ptrCast(obj);
    const aligned: [*]align(@alignOf(Field)) u8 = @alignCast(bytes + offset);
    return @ptrCast(aligned);
}

//! Memory-related functions and objects.

const builtin = @import("builtin");
const std = @import("std");
const math = std.math;
const heap = std.heap;
const mem = std.mem;
const testing = std.testing;
const assert = std.debug.assert;
const Allocator = mem.Allocator;

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
        type_name: []const u8,
        as_string: ?[]const u8,
        /// Whether we created this node on the arena instead of pulling it from the heap.
        is_synthetic: bool = false,
    };

    pub const EnumerateStructFn = fn (ctx: StructIterator, node_info: *const NodeInfo) Error!void;
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
            .as_string = try ctx.arena.dupeSentinel(u8, val, 0),
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
        val: T,
    ) Error!void {
        const dummy_node = try ctx.arena.create(u8);
        const child_node: NodeInfo = .{
            .parent_info = node_info,
            .node = dummy_node,
            .enumerate_struct = null,
            .type_name = @typeName(T),
            .as_string = try std.fmt.allocPrint(ctx.arena, fmt, .{val}),
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
        if (info.enumerate_struct) |follow_fn| try follow_fn(ctx, info);
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

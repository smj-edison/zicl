pub const std = @import("std");

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
        });
        if (info.enumerate_struct) |follow_fn| try follow_fn(ctx, info);
    }
};

const Test = struct {
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
    var bar: Test.Node = .{ .name = "bar" };
    var foo: Test.Node = .{ .name = "foo", .a = &bar };
    try iter.followUnparentedNode(Test.Node, &foo);

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
    var b: Test.Node = .{ .name = "b" };
    var c: Test.Node = .{ .name = "c" };
    var a: Test.Node = .{ .name = "a", .a = &b, .b = &c };
    try iter.followUnparentedNode(Test.Node, &a);

    try std.testing.expectEqual(@as(usize, 3), walker.nodes.count());
    try std.testing.expectEqual(@as(usize, 2), walker.edges.items.len);
}

test "GraphWalker: cycle records back-edge without recursing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var walker = GraphWalker.empty;
    const iter = walker.promote(arena.allocator());
    var a: Test.Node = .{ .name = "a" };
    var b: Test.Node = .{ .name = "b" };
    a.a = &b;
    b.a = &a; // back-edge: a -> b -> a
    try iter.followUnparentedNode(Test.Node, &a);

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
    var d: Test.Node = .{ .name = "d" };
    var b: Test.Node = .{ .name = "b", .a = &d };
    var c: Test.Node = .{ .name = "c", .a = &d };
    var a: Test.Node = .{ .name = "a", .a = &b, .b = &c };
    try iter.followUnparentedNode(Test.Node, &a);

    // d is visited once, but both edges into it are recorded.
    try std.testing.expectEqual(@as(usize, 4), walker.nodes.count());
    try std.testing.expectEqual(@as(usize, 4), walker.edges.items.len);
}

test "GraphWalker: leaf root recorded with no edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var walker = GraphWalker.empty;
    const iter = walker.promote(arena.allocator());
    var leaf: Test.Node = .{ .name = "leaf" };
    try iter.followUnparentedNode(Test.Node, &leaf);

    try std.testing.expectEqual(@as(usize, 1), walker.nodes.count());
    try std.testing.expect(walker.nodes.contains(@ptrCast(&leaf)));
    try std.testing.expectEqual(@as(usize, 0), walker.edges.items.len);
}

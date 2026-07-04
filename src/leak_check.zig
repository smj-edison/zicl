pub const std = @import("std");

/// Node = struct, Edge = pointer + field name.
pub const PointerIterator = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Error = std.mem.Allocator.Error;

    pub const NodeInfo = struct {
        parent_info: ?*const NodeInfo,
        node: *const anyopaque,
        walk_children: ?*const WalkChildrenFn,
    };

    pub const WalkChildrenFn = fn (ctx: PointerIterator, node_info: *const NodeInfo) Error!void;
    pub const VTable = struct {
        visit_node: *const fn (ctx: PointerIterator, node_info: *const NodeInfo, edge_coming_from: ?[]const u8) Error!void,
    };

    pub fn followUnparentedNode(ctx: PointerIterator, T: type, ptr: *const T) Error!void {
        const node_info: NodeInfo = .{
            .parent_info = null,
            .node = ptr,
            .walk_children = if (@hasDecl(T, "walkChildren")) &T.walkChildren else null,
        };
        try ctx.vtable.visit_node(ctx, &node_info, null);
    }

    pub fn followNode(
        ctx: PointerIterator,
        T: type,
        node_info: *const NodeInfo,
        edge_coming_from: []const u8,
        child_ptr: *const T,
    ) Error!void {
        const child_node: NodeInfo = .{
            .parent_info = node_info,
            .node = child_ptr,
            .walk_children = if (@hasDecl(T, "walkChildren")) &T.walkChildren else null,
        };
        try ctx.vtable.visit_node(ctx, &child_node, edge_coming_from);
    }
};

pub const GraphWalker = struct {
    arena: std.mem.Allocator,
    visited: std.AutoHashMapUnmanaged(*const anyopaque, void),
    edges: std.ArrayList(Edge),

    pub const Edge = struct { from: *const anyopaque, to: *const anyopaque, field_name: []const u8 };
    pub const vtable: PointerIterator.VTable = .{ .visit_node = visit_node };

    pub fn init(arena: std.mem.Allocator) GraphWalker {
        return .{
            .arena = arena,
            .visited = .empty,
            .edges = .empty,
        };
    }

    pub fn get(self: *GraphWalker) PointerIterator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn visit_node(
        ctx: PointerIterator,
        info: *const PointerIterator.NodeInfo,
        edge_coming_from: ?[]const u8,
    ) PointerIterator.Error!void {
        const self: *GraphWalker = @ptrCast(@alignCast(ctx.ptr));
        if (info.parent_info) |parent_info| {
            try self.edges.append(self.arena, .{
                .from = parent_info.node,
                .to = info.node,
                .field_name = edge_coming_from.?,
            });
        }
        if (self.visited.contains(info.node)) return; // Avoid double counting and cycles.
        try self.visited.put(self.arena, info.node, {});
        if (info.walk_children) |follow_fn| try follow_fn(ctx, info);
    }
};

const Test = struct {
    const NodeInfo = PointerIterator.NodeInfo;
    pub const Bar = struct {};

    /// A node with up to two named children (`a`, `b`) for exercising cycles,
    /// diamonds, and the two-child case. `name` is for human inspection only.
    pub const Node = struct {
        name: []const u8,
        a: ?*const Node = null,
        b: ?*const Node = null,

        pub fn walkChildren(ctx: PointerIterator, node_info: *const NodeInfo) PointerIterator.Error!void {
            const self: *const Node = @ptrCast(@alignCast(node_info.node));
            if (self.a) |child| try ctx.followNode(Node, node_info, "a", child);
            if (self.b) |child| try ctx.followNode(Node, node_info, "b", child);
        }
    };
};

test "GraphWalker: single edge records both endpoints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var walker = GraphWalker.init(arena.allocator());
    const pi = walker.get();
    var bar: Test.Node = .{ .name = "bar" };
    var foo: Test.Node = .{ .name = "foo", .a = &bar };
    try pi.followUnparentedNode(Test.Node, &foo);

    try std.testing.expectEqual(@as(usize, 2), walker.visited.count());
    try std.testing.expect(walker.visited.contains(@ptrCast(&foo)));
    try std.testing.expect(walker.visited.contains(@ptrCast(&bar)));
    try std.testing.expectEqual(@as(usize, 1), walker.edges.items.len);
    const edge = walker.edges.items[0];
    try std.testing.expectEqual(@as(*const anyopaque, @ptrCast(&foo)), edge.from);
    try std.testing.expectEqual(@as(*const anyopaque, @ptrCast(&bar)), edge.to);
    try std.testing.expectEqualStrings("a", edge.field_name);
}

test "GraphWalker: two children both recorded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var walker = GraphWalker.init(arena.allocator());
    const pi = walker.get();
    var b: Test.Node = .{ .name = "b" };
    var c: Test.Node = .{ .name = "c" };
    var a: Test.Node = .{ .name = "a", .a = &b, .b = &c };
    try pi.followUnparentedNode(Test.Node, &a);

    try std.testing.expectEqual(@as(usize, 3), walker.visited.count());
    try std.testing.expectEqual(@as(usize, 2), walker.edges.items.len);
}

test "GraphWalker: cycle records back-edge without recursing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var walker = GraphWalker.init(arena.allocator());
    const pi = walker.get();
    var a: Test.Node = .{ .name = "a" };
    var b: Test.Node = .{ .name = "b" };
    a.a = &b;
    b.a = &a; // back-edge: a -> b -> a
    try pi.followUnparentedNode(Test.Node, &a);

    // Exactly two nodes visited -- the back-edge did not re-enter a.
    try std.testing.expectEqual(@as(usize, 2), walker.visited.count());
    // Both directions recorded, because edges are recorded before the
    // visited check gates recursion.
    try std.testing.expectEqual(@as(usize, 2), walker.edges.items.len);
}

test "GraphWalker: diamond records both edges into shared child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var walker = GraphWalker.init(arena.allocator());
    const pi = walker.get();
    var d: Test.Node = .{ .name = "d" };
    var b: Test.Node = .{ .name = "b", .a = &d };
    var c: Test.Node = .{ .name = "c", .a = &d };
    var a: Test.Node = .{ .name = "a", .a = &b, .b = &c };
    try pi.followUnparentedNode(Test.Node, &a);

    // d is visited once, but both edges into it are recorded.
    try std.testing.expectEqual(@as(usize, 4), walker.visited.count());
    try std.testing.expectEqual(@as(usize, 4), walker.edges.items.len);
}

test "GraphWalker: leaf root recorded with no edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var walker = GraphWalker.init(arena.allocator());
    const pi = walker.get();
    var leaf: Test.Node = .{ .name = "leaf" };
    try pi.followUnparentedNode(Test.Node, &leaf);

    try std.testing.expectEqual(@as(usize, 1), walker.visited.count());
    try std.testing.expect(walker.visited.contains(@ptrCast(&leaf)));
    try std.testing.expectEqual(@as(usize, 0), walker.edges.items.len);
}

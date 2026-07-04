pub const std = @import("std");

pub const PointerIterator = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Error = std.mem.Allocator.Error;

    pub const NodeInfo = struct {
        name: []const u8,
        node: *const anyopaque,
        parent: ?*const NodeInfo,
    };

    pub const FollowPtrsFn = fn (self: *anyopaque, ctx: PointerIterator, node_info: ?*const NodeInfo) Error!void;
    pub const VTable = struct {
        follow_ptr: *const fn (
            ctx: PointerIterator,
            info: *const NodeInfo,
            follow_node: ?*const FollowPtrsFn,
        ) Error!void,
    };

    pub fn enumeratePointersOf(ctx: PointerIterator, T: type, node_info: ?*const NodeInfo, ptr: *const T) Error!void {
        if (!@hasDecl(T, "followPtrs"))
            @compileError("Can't follow structure that doesn't have followPtrs function");
        try T.followPtrs(@ptrCast(ptr), ctx, node_info);
    }

    pub fn followPtr(ctx: PointerIterator, T: type, node_info: ?*const NodeInfo, name: []const u8, ptr: *const T) Error!void {
        const child_info: NodeInfo = .{
            .name = name,
            .node = @ptrCast(ptr),
            .parent = node_info,
        };

        if (@hasDecl(T, "followPtrs")) {
            try ctx.vtable.follow_ptr(ctx, &child_info, &T.followPtrs);
        } else {
            try ctx.vtable.follow_ptr(ctx, &child_info, null);
        }
    }
};

pub const GraphWalker = struct {
    arena: std.mem.Allocator,
    visited: std.AutoHashMapUnmanaged(*anyopaque, void),
    edges: std.ArrayList(Edge),

    pub const Edge = struct { from: *anyopaque, to: *anyopaque, name: []const u8 };
    pub const vtable: PointerIterator.VTable = .{ .follow_ptr = followPtrs };

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

    fn followPtrs(
        ctx: PointerIterator,
        info: *const PointerIterator.NodeInfo,
        follow_node: ?*const PointerIterator.FollowPtrsFn,
    ) PointerIterator.Error!void {
        const self: *GraphWalker = @ptrCast(@alignCast(ctx.ptr));
        if (info.parent) |parent| {
            try self.edges.append(self.arena, .{ .from = parent.node, .to = info.node, .name = info.name });
        }
        if (self.visited.contains(info.node)) return; // Avoid double counting and cycles.
        try self.visited.put(self.arena, info.node, {});
        if (follow_node) |follow_fn| try follow_fn(info.node, ctx, info);
    }
};

const Test = struct {
    const NodeInfo = PointerIterator.NodeInfo;
    pub const Bar = struct {};
    pub const Foo = struct {
        bar: *Bar,

        pub fn followPtrs(self: *const anyopaque, ctx: PointerIterator, node_info: ?*const NodeInfo) PointerIterator.Error!void {
            const as_foo: *const Foo = @ptrCast(@alignCast(self));
            try ctx.followPtr(Bar, node_info, "bar", as_foo.bar);
        }
    };

    pub fn followPtrs(
        ctx: PointerIterator,
        info: *const NodeInfo,
        follow_node: ?*const PointerIterator.FollowPtrsFn,
    ) PointerIterator.Error!void {
        _ = ctx;

        std.debug.print("parent: {s}, ", .{info.name});
        std.debug.print("next: {*}, ", .{info.node});
        std.debug.print("follow node: {?*}\n", .{follow_node});
    }
};

test {
    var bar: Test.Bar = .{};
    var foo: Test.Foo = .{ .bar = &bar };
    var ptr_enum: PointerIterator = .{
        .ptr = undefined,
        .vtable = &.{
            .follow_ptr = Test.followPtrs,
        },
    };

    try ptr_enum.enumeratePointersOf(Test.Foo, null, &foo);
}

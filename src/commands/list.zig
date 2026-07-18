/// [lmap]
pub fn lmapCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    return foreachMapHelper(interp, args, .map);
}

pub fn llengthCmd(interp: *Interp, args: []Shimmerable) !void {
    try interp.setResultInteger(try interp.getListLength(&args[1]));
}

pub fn lappendCmd(interp: *Interp, args: []Shimmerable) !void {
    var list: Mutable = blk: {
        if ((try interp.getVariable(&args[1])).toHandle()) |val| {
            break :blk .{ .original = val.borrow() };
        } else {
            break :blk .{ .original = try objutil.newListWithCapacity(0) };
        }
    };
    defer list.deinit();

    for (args[2..]) |item| {
        _ = try interp.listAppend(&list, item.current());
    }

    try interp.setVariableTo(&args[1], list.current());
    interp.setResult(list.current());
}

pub fn lassignCmd(interp: *Interp, args: []Shimmerable) !void {
    // args[0] = "lassign", args[1] = list, args[2..] = varNames
    const list = &args[1];
    const list_len = try interp.getListLength(list);
    const var_count = args.len - 2;

    // Assign each list element to the corresponding variable.
    for (0..var_count) |i| {
        const var_name = &args[i + 2];
        if (i < list_len) {
            try interp.setVariableTo(var_name, objutil.listItem(list.current(), @intCast(i)));
        } else {
            // If there's no more elements, it becomes the empty string.
            try interp.setVariableTo(var_name, Heap.local_heap.emptyHandle());
        }
    }

    // If there's any remaining list elements, they're returned from [lassign].
    if (list_len > var_count) {
        const remaining_count = list_len - var_count;
        var remaining_list = try objutil.newListWithCapacity(@intCast(remaining_count));
        errdefer remaining_list.decrRefCount();
        for (var_count..list_len) |i| {
            objutil.listAppendAssumeCapacity(remaining_list, objutil.listItem(list.current(), @intCast(i)).dupOrRef());
        }
        interp.setResultOwning(remaining_list);
    } else {
        interp.setEmptyResult();
    }
}

/// [list]
pub fn listCmd(interp: *Interp, args: []Shimmerable) !void {
    interp.setResultOwning(try objutil.newListFromShimmerables(args[1..]));
}

pub fn concatCmd(interp: *Interp, args: []Shimmerable) !void {
    const to_concat = args[1..];
    if (to_concat.len == 0) {
        interp.setEmptyResult();
        return;
    }

    // If all the objects are lists, we can do a fast path.
    not_all_lists: {
        for (to_concat) |arg| {
            if (arg.tag() != .list) break :not_all_lists;
        }

        var total: u32 = 0;
        for (to_concat) |arg| total += objutil.listLength(arg.current());

        const result = try objutil.newListWithCapacity(total);
        errdefer result.decrRefCount();
        for (to_concat) |arg| {
            for (0..objutil.listLength(arg.current())) |i| {
                objutil.listAppendAssumeCapacity(result, objutil.listItem(arg.current(), @intCast(i)).dupOrRef());
            }
        }

        interp.setResultOwning(result);
        return;
    }

    // String path: trim each arg and join with single spaces.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(Heap.global_gpa);

    var first_nonempty = true;
    for (to_concat) |arg| {
        const raw = try arg.getString();
        const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        if (!first_nonempty) try buf.append(Heap.global_gpa, ' ');
        try buf.appendSlice(Heap.global_gpa, trimmed);
        first_nonempty = false;
    }

    try interp.setResultString(buf.items);
}

pub fn joinCmd(interp: *Interp, args: []Shimmerable) !void {
    // join list ?joinString?
    const list_len = try interp.getListLength(&args[1]);
    const join_string = if (args.len > 2) try args[2].getString() else " ";

    if (list_len == 0) {
        interp.setEmptyResult();
        return;
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(Heap.global_gpa);

    for (0..list_len) |i| {
        if (i > 0) try buf.appendSlice(Heap.global_gpa, join_string);
        const item = objutil.listItem(args[1].current(), @intCast(i));
        const item_str = try item.getString();
        try buf.appendSlice(Heap.global_gpa, item_str);
    }

    try interp.setResultString(buf.items);
}

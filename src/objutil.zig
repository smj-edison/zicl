const std = @import("std");
const math = std.math;
const testing = std.testing;
const assert = std.debug.assert;

const pcre2 = @import("pcre2");

const ioutil = @import("ioutil.zig");
const strutil = @import("strutil.zig");
const heap = @import("heap.zig");
const hashutil = heap.hashutil;
const Value = heap.Value;
const OptionalValue = heap.OptionalValue;
const Object = heap.Object;
const Tokenizer = @import("Tokenizer.zig");
const objects = @import("objects.zig");

const DictTable = Heap.ExtraDataValue.Dictionary.Table;
pub fn dictGetTable(dict: Handle) error{OutOfMemory}!*DictTable {
    const metadata = dict.getDictExtraData();
    if (metadata.table) |*table| return table;

    // FIXME make sure that the dict has a table before sending between threads.
    dict.assert(!dict.getMetadata().cross_thread);

    // Table didn't exist, so we need to generate it.
    var new_table: DictTable = .empty;
    errdefer new_table.deinit(Heap.global_gpa);

    // Populate the new table.
    const dict_len = dict.peek().body.dict.len;
    var pair: u32 = 0;
    while (pair < dict_len) : (pair += 2) {
        const key = collectionItemNoFollow(dict, pair, dict_len);
        try new_table.put(Heap.global_gpa, key, pair + 1);
    }

    metadata.table = new_table;
    // Make sure to reference its new location after it moves to `metadata.table`.
    if (metadata.table) |*table| return table else unreachable;
}

pub fn dictMaybeGetTable(dict: Handle) ?*DictTable {
    if (dict.getDictExtraData().table) |*table| return table else return null;
}

pub fn dictInvalidateTable(dict: Handle) void {
    assert(dict.tag() == .dict);
    assert(dict.canShimmer());
    if (dict.getDictExtraData().table) |*table| {
        table.deinit(Heap.global_gpa);
        dict.getDictExtraData().table = null;
    }
}

pub fn shimmerToDict(det: ?*ErrorDetails, wb: *Shimmerable) !void {
    if (wb.tag() == .dict) return;

    // Get length, potentially shimmering.
    const len = listLengthShimmering(det, wb) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadDict,
    };
    const handle_heap = wb.current().getHeap();

    if (@mod(len, 2) == 1) {
        // Unmatched key.
        if (det) |details| details.* = .{
            .message = try newStringFmt(
                "Missing value to go with key when converting \"{f}\" to a dictionary.",
                .{wb.current()},
            ),
        };
        return error.BadDict;
    }

    // Set dict body using the final handle.
    const metadata_index = try handle_heap.createExtraData();
    errdefer handle_heap.destroyExtraData(metadata_index);

    const metadata = handle_heap.getExtraData(metadata_index);
    metadata.* = .{ .dict = .{ .table = null } };

    // Because both lists and dicts store their values directly after,
    // we can just swap out the head to convert to a dict.
    wb.peek().head.tag = .dict;
    wb.peek().body.dict = .{
        .extra_data = metadata_index,
        .len = len,
    };
}

pub fn dictItems(handle: Handle) []Heap.Object {
    assert(handle.tag() == .dict);
    const dict_len = handle.peek().body.dict.len;
    return handle.getHeap().objectSlice(handle.index + 1, handle.index + 1 + dict_len);
}

pub fn dictItemNoFollow(dict: Handle, index: u32) Handle {
    dict.assert(dict.tag() == .dict);
    return collectionItemNoFollow(dict, index, dict.peek().body.dict.len);
}

pub fn dictItem(dict: Handle, index: u32) Handle {
    dict.assert(dict.tag() == .dict);
    return collectionItemFollowRefs(dict, index, dict.peek().body.dict.len);
}

pub fn dictItemLength(dict: Handle) u32 {
    dict.assert(dict.tag() == .dict);
    return dict.peek().body.dict.len;
}

pub fn dictPairLength(dict: Handle) u32 {
    dict.assert(dict.tag() == .dict);
    return dict.peek().body.dict.len / 2;
}

pub fn newDictWithCapacity(len: u32) !Handle {
    assert(@mod(len, 2) == 0);

    // `1 +` to make space for the dict's head.
    const dict_index = try Heap.local_heap.createObjects(1 + len, false);
    errdefer Heap.freeObjectBacking(Heap.local_heap.getHandle(dict_index));
    const dict_metadata = try Heap.local_heap.createExtraData();
    errdefer Heap.local_heap.destroyExtraData(dict_metadata);

    Heap.local_heap.getExtraData(dict_metadata).* = .{ .dict = .{
        .table = null,
    } };

    const dict_head = Heap.local_heap.getLocalObject(dict_index);
    dict_head.* = .{
        .head = .{
            .str = Heap.Object.null_string,
            .tag = .dict,
        },
        .body = .{ .dict = .{
            .extra_data = dict_metadata,
            .len = 0,
        } },
    };

    return Heap.local_heap.getHandle(dict_index);
}

/// `dict` must be mutable. Be careful that you append an even number of elements.
pub fn dictPutAssumeCapacity(dict: Handle, key: Handle, value: Heap.Object) void {
    dict.assert(dict.tag() == .dict);
    dict.assert(dict.canMutate());
    dict.assert(dict.getDictExtraData().table == null);

    const current_len = dict.peek().body.dict.len;
    // `- 3` for dict head, new key, and value.
    dict.assert(current_len <= memutil.getOrderSize(dict.getMetadata().order) - 3);

    dict.peek().body.dict.len += 2;
    dictItemNoFollow(dict, current_len).peek().* = key.dupOrRef();
    dictItemNoFollow(dict, current_len + 1).peek().* = value;
}

/// Caller is responsible that `handles` has handles.len % 2 == 0.
pub fn newDict(handles: []const Handle) !Handle {
    const dict = try newDictWithCapacity(@intCast(handles.len));
    errdefer dict.decrRefCount();
    dict.peek().body.dict.len = @intCast(handles.len);

    const new_items = dictItems(dict);
    for (handles, new_items) |handle, *item| {
        item.* = handle.dupOrRef();
    }

    return dict;
}

/// Asserts `dict` is a .dict. Like `dictLookup`, but returns the raw dict slot handle
/// without following references.
pub fn dictLookupNoFollow(dict: Handle, key: Handle) error{OutOfMemory}!OptionalHandle {
    dict.assert(dict.tag() == .dict);
    _ = try key.getString();

    const table = try dictGetTable(dict);
    if (table.get(key)) |value_offset| {
        return dictItemNoFollow(dict, value_offset).toOptional();
    } else return .none;
}

pub fn dictLookup(dict: Handle, key: Handle) error{OutOfMemory}!OptionalHandle {
    dict.assert(dict.tag() == .dict);
    // Make sure key has a string representation, as table.get isn't allowed to fail.
    _ = try key.getString();

    const table = try dictGetTable(dict);
    if (table.get(key)) |value_offset| {
        return dictItem(dict, value_offset).toOptional();
    } else return .none;
}

pub fn dictLookupFollowLinks(det: ?*ErrorDetails, wb: *Shimmerable, key: Handle) error{ OutOfMemory, LinkLookupFailed }!OptionalHandle {
    wb.current().assert(wb.tag() == .dict);

    // Make sure key has a string representation, as table.get isn't allowed to fail.
    _ = try key.getString();

    const table = try dictGetTable(wb.current());
    if (table.get(key)) |value_offset| {
        return dictItem(wb.current(), value_offset).toOptional();
    } else {
        const parent_key = Heap.local_heap.getInternedString(.@"^parent");
        if ((try dictLookup(wb.current(), parent_key)).toHandle()) |parent_link| {
            var parent_link_wb: Shimmerable = .{ .original = parent_link, .shimmered = .none };
            defer parent_link_wb.discardChanges();
            shimmerToHashReference(det, &parent_link_wb) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.HashLookupFailed => return error.LinkLookupFailed,
                error.NotHashReference => return error.LinkLookupFailed,
            };

            if (parent_link_wb.shimmered.toHandle()) |new_parent_link| {
                // This is delicate, but it's not mutation, since we're switching out the reference
                // for its shimmered representation, so it is transparent to the caller. Note that
                // `dictPutInner` does not invalidate the string representation, so even if the
                // underlying dictionary mutates, we preserve the original string.
                _ = try dictPutInner(wb.asMutable(), parent_key, new_parent_link.reference());
            }

            const parent = parent_link_wb.peek().body.hash_reference;
            var parent_wb: Shimmerable = .{ .original = parent, .shimmered = .none };
            defer parent_wb.discardChanges();
            shimmerToDict(det, &parent_wb) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.LinkLookupFailed,
            };

            const looked_up = try dictLookupFollowLinks(det, &parent_wb, key);
            if (parent_wb.shimmered.toHandle()) |val| {
                _ = try dictPutInner(wb.asMutable(), parent_key, val.hashReference());
            }

            return looked_up;
        }
        // Nothing found, even after checking parent links.
        return .none;
    }
}

fn dictHasDuplicatesRaw(dict: Handle) !bool {
    assert(dict.tag() == .dict);
    const table = try dictGetTable(dict);

    const len = dict.peek().body.dict.len;
    assert(table.size * 2 <= len);
    return table.size * 2 != len;
}

/// Removes duplicate entries. Assumes handle is a dict. If the caller needs to track
/// a key/value as it gets rearranged, set `to_track`. The result will be its new index,
/// unless it was removed.
fn dictRemoveDuplicates(wb: *Mutable, to_track: ?u32) error{OutOfMemory}!?u32 {
    wb.current().assert(wb.tag() == .dict);

    // If the length of the table is the length of the dict, it means we have
    // no duplicates.
    const original_len = wb.peek().body.dict.len;
    if (dictMaybeGetTable(wb.current())) |table| {
        if (table.size * 2 == original_len) return to_track;
    }

    try wb.prepareToMutate();
    var metadata = wb.current().getDictExtraData();

    // Check if any items are shared.
    for (0..original_len) |i| {
        if (dictItemNoFollow(wb.current(), @intCast(i)).isShared()) {
            // Need to duplicate.
            const duplicated = try wb.current().duplicate();
            wb.mutated.swap(duplicated);
            metadata = wb.current().getDictExtraData(); // Need to reload metadata.
            break;
        }
    }

    var to_track_new_location: ?u32 = null;

    const table = try dictGetTable(wb.current());
    if (table.size * 2 == original_len) {
        // No duplicate entries.
        return to_track;
    }

    // From here on out, the dictionary will reach a very unstable intermediate
    // state, so this ensures that no error is returned partway through.
    errdefer comptime unreachable;

    var pair_index: u32 = 0;
    while (pair_index < original_len) : (pair_index += 2) {
        const key_index = pair_index;
        const value_index = pair_index + 1;
        const key_handle = dictItemNoFollow(wb.current(), key_index);
        const value_handle = dictItemNoFollow(wb.current(), value_index);

        // Because keys are immutable, we know that they'll never lose their string rep.
        if (table.get(key_handle).? != value_index) {
            // Found a duplicate entry.
            key_handle.peek().head.tag = .marked;
            value_handle.peek().head.tag = .marked;
        }
    }

    // Why mark all the handles before later removing them? Because the hash map
    // requires all the keys and values to not move, and we use the hash map
    // to see what pairs need to be removed.
    const items = dictItems(wb.current());
    // How many pairs we've removed so far. Increments by 1.
    var removed: u32 = 0;
    pair_index = 0;
    while (pair_index < original_len) : (pair_index += 2) {
        const key_index = pair_index;
        const value_index = pair_index + 1;
        const key_handle = dictItemNoFollow(wb.current(), key_index);
        const value_handle = dictItemNoFollow(wb.current(), value_index);

        if (key_handle.tag() == .marked) {
            removed += 1;

            // We have to invalidate the string here, and not earlier, because
            // the hash map `.get()` uses the string rep of the keys.
            key_handle.invalidateString();
            key_handle.invalidateBody(); // sets tag to .none.
            value_handle.invalidateString();
            value_handle.invalidateBody(); // sets tag to .none.
        } else if (removed > 0) {
            // There was a pair removed at some point, so we need to shift this pair backwards.
            const new_key_index = pair_index - (removed * 2);
            const new_value_index = new_key_index + 1;

            if (key_index == to_track) to_track_new_location = new_key_index;
            if (value_index == to_track) to_track_new_location = new_value_index;

            items[new_key_index] = items[key_index];
            items[new_value_index] = items[value_index];
        } else {
            if (key_index == to_track) to_track_new_location = key_index;
            if (value_index == to_track) to_track_new_location = value_index;
        }
    }

    // "zero" out the removed items.
    for ((original_len - removed * 2)..original_len) |to_zero| {
        const item_handle = collectionItemNoFollow(wb.current(), @intCast(to_zero), original_len);
        item_handle.peek().* = .{
            .head = .{
                .str = Heap.Object.null_string,
                .tag = .none,
            },
            .body = undefined,
        };
        item_handle.trace("Zero out removed", .{});
    }

    wb.peek().body.dict.len -= removed * 2;

    // The table is pretty broken at this point, as all its references have shifted around.
    // TODO PERF For now, it's better just to free it altogether, though this has the
    // potential to slow things down.
    dictInvalidateTable(wb.current());

    return to_track_new_location;
}

/// Takes ownership of `value`, including error cases. Returns a handle to the new value's location.
/// `value` must be in `Heap.local_heap`. Does not invalidate the string rep.
fn dictPutInner(dict: *Mutable, key: Handle, value: Heap.Object) error{OutOfMemory}!Handle {
    dict.current().assert(dict.tag() == .dict);

    var value_mut = value;
    errdefer value_mut.deinitSingle(Heap.local_heap);

    // Make sure the key has a string representation.
    _ = try dict.current().getString();
    // Also make sure we can mutate the dict.
    try dict.prepareToMutate();

    const table = try dictGetTable(dict.current());
    // Does the key already exist?
    if (table.get(key)) |existing_value_index| {
        // Key exists, so replace the value in place.
        var value_handle = dictItemNoFollow(dict.current(), existing_value_index);
        if (value_handle.isShared()) {
            // Looks like this dictionary value is shared, so we can't replace the value in place
            // (else we'd smash up a value someone else is using). Instead, we'll use a new dict,
            // which due to duplication, must have non-shared elements.
            dict.mutated.swap(try dict.current().duplicate());
            value_handle = dictItemNoFollow(dict.current(), existing_value_index);
        }

        var old_value = value_handle.peek().*; // Copy old value.
        defer old_value.deinitSingle(Heap.local_heap);
        value_handle.peek().* = value_mut.take(); // Set new value.
        errdefer {
            // On error, we need to restore the old value we saved.
            value_handle.invalidateBoth(); // Invalidate new value.
            value_handle.peek().* = old_value.take(); // Restore old value.
        }

        // Because we mutated the dictionary, we need to remove any duplicates, if applicable.
        const new_index = new_index: {
            if (try dictHasDuplicatesRaw(dict.current())) {
                const tracked_index = try dictRemoveDuplicates(dict, existing_value_index);
                break :new_index tracked_index.?;
            } else {
                break :new_index existing_value_index;
            }
        };

        return dictItemNoFollow(dict.current(), new_index);
    } else {
        const original_len = dict.peek().body.dict.len;
        const new_length = original_len + 2;

        // Key doesn't exist, so append both key and value.
        const len_before_resize = dict.peek().body.dict.len;
        const new_key_index = len_before_resize;
        const new_value_index = len_before_resize + 1;

        // Local variable for any resized dict. Only committed to dict.mutated at the end.
        var maybe_new_dict: OptionalHandle = .none;
        errdefer maybe_new_dict.decrOptional();

        // Duplicate/reference the key _before_ resizing, so we can't fail
        // after the resize is successful.
        const new_key_handle, const new_value_handle = blk: {
            var key_obj: Heap.Object = key.dupOrRef();
            errdefer key_obj.deinitSingle(Heap.local_heap);

            maybe_new_dict = try setCollectionLengthInner(dict.current(), new_length);
            const work_dict = maybe_new_dict.orElse(dict.current());

            const new_key_handle = dictItemNoFollow(work_dict, new_key_index);
            const new_value_handle = dictItemNoFollow(work_dict, new_value_index);

            new_key_handle.trace("Setting as new key to {f}", .{key_obj});

            // Set the new key and value.
            new_key_handle.peek().* = key_obj.take();
            new_value_handle.peek().* = value_mut.take();

            break :blk .{ new_key_handle, new_value_handle };
        };
        errdefer {
            // Because these are new values, we don't need to restore old
            // values, since there's nothing to restore. Instead, we'll just
            // free the last two new values, and shrink the length.
            new_key_handle.invalidateBoth();
            new_value_handle.invalidateBoth();
            const work_dict = maybe_new_dict.orElse(dict.current());
            work_dict.peek().body.dict.len = original_len;
        }

        // Make sure the key has a string rep.
        _ = try new_key_handle.getString();

        // Only put the key in the table if the table exists. It'll be discovered
        // when the table is generated if not.
        const work_dict = maybe_new_dict.orElse(dict.current());
        if (dictMaybeGetTable(work_dict)) |new_table| {
            try new_table.put(Heap.global_gpa, new_key_handle, new_value_index);
        }

        // Because we mutated the dictionary, we need to remove any duplicates, if applicable.
        const new_index = new_index: {
            if (try dictHasDuplicatesRaw(work_dict)) {
                const tracked_value = try dictRemoveDuplicates(dict, new_key_index + 1);
                break :new_index tracked_value.?;
            } else {
                break :new_index new_key_index + 1;
            }
        };

        // Commit the resize (if any) only after all fallible work is done.
        dict.mutated.swapIfNew(maybe_new_dict);

        return dictItemNoFollow(dict.current(), new_index);
    }
}

pub fn dictPutObject(dict: *Mutable, key: Handle, value: Heap.Object) error{OutOfMemory}!Handle {
    const new_value_handle = try dictPutInner(dict, key, value);
    dict.current().invalidateString();
    return new_value_handle;
}

pub const HandleSliceContext = struct {
    items: []const Handle,
    pub fn len(self: @This()) usize {
        return self.items.len;
    }
    pub fn get(self: @This(), index: usize) Handle {
        return self.items[index];
    }
    pub fn sliceAfter(self: @This(), index: usize) @This() {
        return .{ .items = self.items[index..] };
    }
};

pub const ShimmerableSliceContext = struct {
    items: []const Shimmerable,
    pub fn len(self: @This()) usize {
        return self.items.len;
    }
    pub fn get(self: @This(), index: usize) Handle {
        return self.items[index].current();
    }
    pub fn sliceAfter(self: @This(), index: usize) @This() {
        return .{ .items = self.items[index..] };
    }
};

/// Takes ownership of `value`, including in error cases. `value` must be in the local heap.
pub fn dictPutRecursively(det: ?*ErrorDetails, wb: *Mutable, context: anytype, value: Heap.Object) !Handle {
    return dictPutRecursivelyInner(det, wb, context, value) catch |err| switch (err) {
        error.OutOfMemory => {
            // Only discard changes when OOM occurs.
            wb.discardChanges();
            return error.OutOfMemory;
        },
        else => return err,
    };
}

fn dictPutRecursivelyInner(
    det: ?*ErrorDetails,
    wb: *Mutable,
    context: anytype,
    value: Heap.Object,
) error{ OutOfMemory, BadDict, LinkLookupFailed }!Handle {
    var value_mut = value;
    errdefer value_mut.deinitSingle(Heap.local_heap);

    try shimmerToDict(det, wb.asShimmerable());

    assert(context.len() > 0);
    if (context.len() == 1) {
        // `dictPutObject` always takes ownership, even in error cases.
        return try dictPutObject(wb, context.get(0), value_mut.take());
    }

    // Find/create the child dict.
    const child_dict = blk: {
        if ((try dictLookup(wb.current(), context.get(0))).toHandle()) |existing_dict| {
            // Make sure the parent dict is mutable before the recursive call. If we wait until
            // after the child is modified, the parent may contain a stale .reference to an
            // invalidated child, and duplicating the parent would then panic.
            try wb.prepareToMutate();
            break :blk existing_dict;
        } else {
            // Create a new child dictionary.
            const new_child_dict = try newDictWithCapacity(2);

            _ = try dictPutObject(wb, context.get(0), new_child_dict.referenceOwning());
            break :blk new_child_dict;
        }
    };

    var child_wb: Mutable = .{ .original = child_dict };
    defer child_wb.discardChanges();
    const child_put_result = try dictPutRecursivelyInner(
        det,
        &child_wb,
        context.sliceAfter(1),
        value_mut.take(),
    );
    if (child_wb.takeMutated().toHandle()) |new_child| {
        // The child dict changed, so we need to update ours.
        // Ownership of new_child is transferred to dictPutObject, whether it
        // succeeds or fails (on failure its errdefer cleans up the .reference).
        _ = try dictPutObject(wb, context.get(0), new_child.referenceOwning());
    }

    wb.current().invalidateString();

    return child_put_result;
}

pub fn dictRemoveRecursively(det: ?*ErrorDetails, wb: *Mutable, context: anytype) !bool {
    return dictRemoveRecursivelyInner(det, wb, context);
}

fn dictRemoveRecursivelyInner(det: ?*ErrorDetails, wb: *Mutable, context: anytype) !bool {
    try shimmerToDict(det, wb.asShimmerable());

    assert(context.len() > 0);

    if (context.len() == 1) {
        return try dictRemove(det, wb, context.get(0));
    }

    // Find the child dict.
    if ((try dictLookup(wb.current(), context.get(0))).toHandle()) |child_dict| {
        var child_wb: Mutable = .{ .original = child_dict };
        defer child_wb.discardChanges();

        const did_remove = try dictRemoveRecursivelyInner(det, &child_wb, context.sliceAfter(1));
        if (child_wb.takeMutated().toHandle()) |new_child| {
            // Ownership of new_child is transferred from `child_wb.mutated` to the dict.
            _ = try dictPutObject(wb, context.get(0), new_child.referenceOwning());
        }
        wb.current().invalidateString();

        return did_remove;
    } else {
        if (det) |details| details.* = .{
            .message = try newStringFmt(
                "key \"{f}\" not known in dictionary \"{f}\"",
                .{ context.get(0), wb.current() },
            ),
        };
        return error.PathNonexistent;
    }
}

pub fn dictLookupRecursively(det: ?*ErrorDetails, wb: *Shimmerable, context: anytype) !OptionalHandle {
    return dictLookupRecursivelyInner(det, wb, context);
}

fn dictLookupRecursivelyInner(det: ?*ErrorDetails, wb: *Shimmerable, context: anytype) !OptionalHandle {
    try shimmerToDict(det, wb);

    if (context.len() == 0) return wb.current().toOptional();
    if (context.len() == 1) {
        return try dictLookupFollowLinks(det, wb, context.get(0));
    }

    if ((try dictLookupFollowLinks(det, wb, context.get(0))).toHandle()) |child_dict| {
        var child_wb: Shimmerable = .{ .original = child_dict };
        defer child_wb.discardChanges();
        const child_result = try dictLookupRecursivelyInner(det, &child_wb, context.sliceAfter(1));
        if (child_wb.takeShimmered().toHandle()) |new_child| {
            // The child dict changed, propagate back up.
            _ = try dictPutObject(wb.asMutable(), context.get(0), new_child.referenceOwning());
        }
        return child_result;
    } else {
        return .none;
    }
}

/// Asserts `handle` is a dict.
pub fn dictPut(wb: *Mutable, key: Handle, value: Handle) !Handle {
    return dictPutObject(wb, key, value.dupOrRef());
}

fn dictFlattenInner(det: ?*ErrorDetails, original: Handle) !OptionalHandle {
    if ((try dictLookup(original, Heap.local_heap.getInternedString(.@"^parent"))).toHandle()) |parent_link| {
        var parent_link_wb: Shimmerable = .{ .original = parent_link };
        defer parent_link_wb.discardChanges();
        try shimmerToHashReference(det, &parent_link_wb);

        const parent = parent_link_wb.peek().body.hash_reference;

        var new_dict = try dictFlattenInner(det, parent);
        const to_add_to = if (new_dict.toHandle()) |handle| handle else try parent.duplicate();
        var to_add_to_wb: Mutable = .{ .original = to_add_to };
        errdefer to_add_to_wb.deinit();

        var pair_i: u32 = 0;
        while (pair_i < original.peek().body.dict.len / 2) : (pair_i += 1) {
            _ = try dictPutObject(
                &to_add_to_wb,
                dictItem(original, pair_i * 2),
                dictItem(original, pair_i * 2 + 1).reference(),
            );
        }

        return to_add_to_wb.consume().toOptional();
    } else {
        return .none; // No need to flatten.
    }
}

pub fn dictFlatten(det: ?*ErrorDetails, wb: *Mutable) !void {
    const flattened = try dictFlattenInner(det, wb.current());
    wb.mutated.swapIfNew(flattened);
}

pub const DictKeysContext = struct {
    pub fn hash(_: @This(), key: Handle) u32 {
        const hash_value = key.getHash() catch unreachable;
        return @truncate(hash_value);
    }

    pub fn eql(_: @This(), a: Handle, b: Handle, _: usize) bool {
        return Heap.checkIfEqual(a, b) catch unreachable;
    }
};

pub const DictKvResult = std.array_hash_map.Custom(Handle, Handle, DictKeysContext, true);
pub fn dictGetKvPairs(det: ?*ErrorDetails, arena: std.mem.Allocator, wb: *Shimmerable) !DictKvResult {
    try shimmerToDict(det, wb);

    var result: DictKvResult = .empty;
    errdefer result.deinit(arena);

    errdefer for (result.keys()) |key| key.decrRefCount();
    errdefer for (result.values()) |value| value.decrRefCount();
    try dictGetKvPairsInner(det, arena, wb, &result);

    return result;
}

fn dictGetKvPairsInner(det: ?*ErrorDetails, arena: std.mem.Allocator, wb: *Shimmerable, result: *DictKvResult) !void {
    const parent_key = Heap.local_heap.getInternedString(.@"^parent");
    if ((try dictLookup(wb.current(), parent_key)).toHandle()) |parent_link| {
        var parent_link_wb: Shimmerable = .{ .original = parent_link, .shimmered = .none };
        defer parent_link_wb.discardChanges();
        shimmerToHashReference(det, &parent_link_wb) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.HashLookupFailed, error.NotHashReference => return error.LinkLookupFailed,
        };

        if (parent_link_wb.shimmered.toHandle()) |new_parent_link| {
            // This is very delicate, but it technically isn't a visible mutation, since
            // we're swapping one hash reference with another reference with identical content.
            _ = try dictPutInner(wb.asMutable(), parent_key, new_parent_link.reference());
        }

        const parent = parent_link_wb.peek().body.hash_reference;
        var parent_wb: Shimmerable = .{ .original = parent, .shimmered = .none };
        defer parent_wb.discardChanges();
        shimmerToDict(det, &parent_wb) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.LinkLookupFailed,
        };

        if (parent_wb.shimmered.toHandle()) |val| {
            _ = try dictPutInner(wb.asMutable(), parent_key, val.hashReference());
        }

        // Recurse into parent first so parent keys are inserted before child keys.
        try dictGetKvPairsInner(det, arena, &parent_wb, result);
    }

    const pair_count = dictPairLength(wb.current());
    var pair_i: u32 = 0;
    while (pair_i < pair_count) : (pair_i += 1) {
        const key = dictItem(wb.current(), pair_i * 2);
        const value = dictItem(wb.current(), pair_i * 2 + 1);
        if (try key.equalsString("^parent")) continue;

        const gop = try result.getOrPut(arena, key);
        if (!gop.found_existing) {
            gop.key_ptr.* = key.borrow();
            gop.value_ptr.* = value.borrow();
        }
    }
}

fn testDictFlatten(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    try Heap.testStart(ta, testing.io);

    const key_foo = try newString("foo");
    defer key_foo.decrRefCount();
    const value1 = try newString("1");
    defer value1.decrRefCount();
    const key_bar = try newString("bar");
    defer key_bar.decrRefCount();
    const value2 = try newString("2");
    defer value2.decrRefCount();
    const key_baz = try newString("baz");
    defer key_baz.decrRefCount();
    const value3 = try newString("3");
    defer value3.decrRefCount();

    const dict1 = try newDict(&.{ key_foo, value1, key_bar, value2 });
    defer dict1.decrRefCount();

    const dict2 = try newDict(&.{ key_foo, value2, key_baz, value3 });
    defer dict2.decrRefCount();

    var dict2_wb: Mutable = .{ .original = dict2 };
    defer dict2_wb.discardChanges();

    const parent_key = Heap.local_heap.getInternedString(.@"^parent");
    _ = try dictPutObject(&dict2_wb, parent_key, dict1.hashReference());
    try dictFlatten(null, &dict2_wb);
}
test "dict flatten" {
    try testing.checkAllAllocationFailures(testing.allocator, testDictFlatten, .{});
}

/// Returns true if the value was removed, or false if the value doesn't exist.
/// May merge parent links.
pub fn dictRemove(det: ?*ErrorDetails, wb: *Mutable, key: Handle) !bool {
    return dictRemoveInner(det, wb, key);
}

fn dictRemoveInner(det: ?*ErrorDetails, wb: *Mutable, key: Handle) !bool {
    assert(wb.tag() == .dict);

    try wb.prepareToMutate();
    const key_bytes = try key.getString();

    const parent_key = Heap.local_heap.getInternedString(.@"^parent");
    if ((try dictLookup(wb.current(), parent_key)).toHandle()) |parent_link| {
        // If the parent chain contains the key we're removing, we must flatten first,
        // otherwise removing locally would leave the parent value still visible.
        var parent_link_wb: Shimmerable = .{ .original = parent_link };
        try shimmerToHashReference(det, &parent_link_wb);
        if (parent_link_wb.shimmered.toHandle()) |new_parent_link| {
            _ = try dictPutObject(wb, parent_key, new_parent_link.reference());
        }

        const parent = parent_link_wb.peek().body.hash_reference; // Resolve to value of hash.
        var parent_wb: Shimmerable = .{ .original = parent };
        const key_in_parent = (try dictLookupFollowLinks(det, &parent_wb, key)) != .none;
        if (parent_wb.shimmered.toHandle()) |new_parent| {
            _ = try dictPutObject(wb, parent_key, new_parent.hashReference());
        }

        if (key_in_parent) {
            // Key was found in the parent, so we do need to flatten.
            try dictFlatten(det, wb);
        }
    }

    wb.current().assert(wb.current().canShimmer());
    const dict_len = dictItemLength(wb.current());

    // Locate the first key (note, we can't use `metadata.table.get`, because Tcl removes all
    // key(s), while `metadata.table.get` only returns the last key).
    var first_key_index: u32 = 0;
    while (first_key_index < dict_len) : (first_key_index += 2) {
        const key_checking = try dictItem(wb.current(), first_key_index).getString();
        if (std.mem.eql(u8, key_bytes, key_checking)) {
            break; // Found our key.
        }
    } else {
        return false; // No key found.
    }

    // Make sure any keys/values we'll touch aren't shared. Because we're shifting all
    // other values to the left (to preserve relative order), we  need to check all items
    // following the key and value.
    var shared_values_found = false;
    for (first_key_index..dict_len) |item_index| {
        const item_handle = dictItemNoFollow(wb.current(), @intCast(item_index));
        if (item_handle.isShared()) shared_values_found = true;
    }

    if (shared_values_found) {
        // Looks like this dictionary item is shared, so we can't replace the value in place
        // (else we'd smash up an item someone else is using). Instead, we'll start this whole
        // process over with a new dictionary.
        wb.mutated.swap(try wb.current().duplicate());
    }

    // Make sure all the keys have string reps. If we OOM halfway through removal
    // we'll end in a really ugly state, so it's better to ensure all keys have a
    // string rep to start with. If not, we'll safely propagate the OOM.
    var item_index: u32 = 0;
    while (item_index < dict_len) : (item_index += 2) {
        _ = try dictItem(wb.current(), item_index).getString();
    }

    // This is the start of mutation. From here on there's no going back.
    errdefer comptime unreachable;
    dictInvalidateTable(wb.current());

    // Remove all matching keys and their values, moving the following pair
    // backwards to fill the gap(s).
    item_index = first_key_index;
    var pairs_removed: u32 = 0;
    while (item_index < dict_len) : (item_index += 2) {
        const key_handle = dictItemNoFollow(wb.current(), item_index);
        const value_handle = dictItemNoFollow(wb.current(), item_index + 1);
        key_handle.assert(!key_handle.isShared());
        value_handle.assert(!value_handle.isShared());
        // We checked that all our keys have strings earlier.
        const key_checking = dictItem(wb.current(), item_index).getString() catch unreachable;
        if (std.mem.eql(u8, key_bytes, key_checking)) {
            key_handle.invalidateBoth();
            value_handle.invalidateBoth();
            pairs_removed += 1;
        } else if (pairs_removed > 0) {
            // Move this pair backwards.
            const new_key_handle = dictItemNoFollow(wb.current(), item_index - pairs_removed * 2);
            const new_value_handle = dictItemNoFollow(wb.current(), item_index - pairs_removed * 2 + 1);
            new_key_handle.peek().* = key_handle.peek().*;
            new_value_handle.peek().* = value_handle.peek().*;
        }
    }

    // Be sure to "zero" out all the moved items that weren't replaced with something else.
    const start_of_removed = dict_len - pairs_removed * 2;
    for (start_of_removed..dict_len) |removed| {
        const item_handle = dictItemNoFollow(wb.current(), @intCast(removed));
        item_handle.peek().* = .{ .head = .{ .str = Heap.Object.null_string, .tag = .none }, .body = undefined };
    }

    wb.peek().body.dict.len -= pairs_removed * 2;

    wb.current().invalidateString();

    return true;
}

fn testDicts(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    try Heap.testStart(ta, testing.io);

    const key_foo = try newString("foo");
    defer key_foo.decrRefCount();
    const value1 = try newString("1");
    defer value1.decrRefCount();
    const key_bar = try newString("bar");
    defer key_bar.decrRefCount();
    const value2 = try newString("2");
    defer value2.decrRefCount();

    const dict1 = try newDict(&.{ key_foo, value1, key_bar, value2 });
    defer dict1.decrRefCount();

    const good_key = try newString("foo");
    defer good_key.decrRefCount();
    const bad_key = try newString("bogus");
    defer bad_key.decrRefCount();

    try testing.expectEqualStrings("1", try (try dictLookup(dict1, good_key)).toHandle().?.getString());
    try testing.expectEqual(.none, try dictLookup(dict1, bad_key));

    // Dict with duplicate entries testing.
    var new_dict: OptionalHandle = .none;
    defer new_dict.swapWithNone();

    const dict_with_duplicates = try newString("foo 5 bar 10 foo 15");
    defer dict_with_duplicates.decrRefCount();
    var dict_with_duplicates_wb: Mutable = .{ .original = dict_with_duplicates };
    defer dict_with_duplicates_wb.discardChanges();
    try shimmerToDict(null, dict_with_duplicates_wb.asShimmerable());
    const dup_len = dictPairLength(dict_with_duplicates_wb.current());

    try testing.expectEqual(3, dup_len);
    // When a duplicate key is queried, it should point to the last corrisponding value.
    try testing.expectEqualStrings("15", try (try dictLookup(dict_with_duplicates_wb.current(), key_foo)).toHandle().?.getString());

    _ = try dictRemoveDuplicates(&dict_with_duplicates_wb, null);
    try testing.expectEqual(2, dictPairLength(dict_with_duplicates_wb.current()));

    // Dict put testing.
    const dict_for_put = try newDict(&.{ key_foo, value1, key_bar, value2 });
    defer dict_for_put.decrRefCount();
    const key3 = try newString("baz");
    defer key3.decrRefCount();
    const value3 = try newString("3");
    defer value3.decrRefCount();

    var dict_for_put_wb: Mutable = .{ .original = dict_for_put };
    defer dict_for_put_wb.discardChanges();
    try testing.expectEqual(2, dictPairLength(dict_for_put_wb.current()));
    _ = try dictPut(&dict_for_put_wb, key_bar, value3);
    try testing.expectEqual(2, dictPairLength(dict_for_put_wb.current()));

    _ = try dictPut(&dict_for_put_wb, key3, value3);
    try testing.expectEqual(3, dictPairLength(dict_for_put_wb.current()));
    try testing.expectEqualStrings("3", try (try dictLookup(dict_for_put_wb.current(), key3)).toHandle().?.getString());

    // Dict remove testing.
    var dict_for_remove: Mutable = .{ .original = try newDict(&.{ key_foo, value1, key_bar, value2, key_foo, value3 }) };
    defer dict_for_remove.deinit();
    const did_remove = try dictRemove(null, &dict_for_remove, key_foo);
    try testing.expectEqual(true, did_remove);
    try testing.expectEqualStrings("bar 2", try dict_for_remove.getString());

    // Test dict edge cases.
    var dict_edge_cases = try newDict(&.{ key_foo, value1, key_bar, value2 });
    defer dict_edge_cases.decrRefCount();
    var dict_edge_cases_wb: Mutable = .{ .original = dict_edge_cases };
    defer dict_edge_cases_wb.discardChanges();

    // Try using a value as a key, and a key as the value while not shared (this is to check
    // that this handles using internal objects correctly).
    assert(dict_edge_cases_wb.current().canMutate());
    _ = try dictPut(&dict_edge_cases_wb, dictItem(dict_edge_cases_wb.current(), 1), dictItem(dict_edge_cases_wb.current(), 2));
    try testing.expectEqualStrings("bar", try (try dictLookup(dict_edge_cases_wb.current(), value1)).toHandle().?.getString());

    // Try aliasing a key by using it as key and value.
    _ = try dictPut(&dict_edge_cases_wb, dictItem(dict_edge_cases_wb.current(), 0), dictItem(dict_edge_cases_wb.current(), 0));
    try testing.expectEqualStrings("foo", try (try dictLookup(dict_edge_cases_wb.current(), key_foo)).toHandle().?.getString());

    // Try aliasing a value by using it as key and value.
    _ = try dictPut(&dict_edge_cases_wb, dictItem(dict_edge_cases_wb.current(), 3), dictItem(dict_edge_cases_wb.current(), 3));
    try testing.expectEqualStrings("2", try (try dictLookup(dict_edge_cases_wb.current(), value2)).toHandle().?.getString());
}

test "dicts" {
    try testing.checkAllAllocationFailures(testing.allocator, testDicts, .{});
}

pub const SourceInfo = struct {
    file_name: OptionalHandle,
    line_no: u32,
};

/// `SourceInfo` does not contain a borrowed value from `handle`, it's
/// a temporary reference.
pub fn getSourceInfo(handle: Handle) ?SourceInfo {
    if (handle.tag() != .source) return null;

    const extra_data = handle.getSourceExtraData();

    return .{
        .file_name = extra_data.file_name,
        .line_no = extra_data.line_no,
    };
}

/// Asserts `handle` can shimmer.
pub fn setSourceInfo(handle: Handle, source_info: SourceInfo) !void {
    handle.assert(handle.canShimmer());

    // Check if it already has extra data. If so, we'll modify the existing
    // extra data in place.
    if (handle.tag() == .source) {
        const extra_data_value = handle.getSourceExtraData();

        extra_data_value.file_name.decrOptional();
        extra_data_value.file_name = source_info.file_name.borrowOptional();
        extra_data_value.line_no = source_info.line_no;
    } else {
        assert(handle.getHeap() == Heap.local_heap);
        const extra_data = try Heap.local_heap.createExtraData();

        handle.getHeap().getExtraData(extra_data).* = .{ .source = .{
            .file_name = source_info.file_name.borrowOptional(),
            .line_no = source_info.line_no,
            .hash = .{ .state = .init(.not_computed), .hash = undefined },
        } };
        errdefer handle.getHeap().destroyExtraData(extra_data);

        try handle.prepareToShimmer();
        handle.peek().head.tag = .source;
        handle.peek().body.source = .{ .extra_data = extra_data };
    }
}

fn testSourceInfo(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    try Heap.testStart(ta, testing.io);

    var obj = try Heap.createObject();
    defer obj.decrRefCount();

    const file_name = try newString("test_file.tcl");
    defer file_name.decrRefCount();

    try setSourceInfo(obj, .{ .file_name = file_name.toOptional(), .line_no = 42 });

    // Verify the object has the source tag.
    try testing.expectEqual(.source, obj.tag());
    try testing.expectEqual(@as(u32, 42), obj.getSourceExtraData().line_no);

    const info = getSourceInfo(obj);
    try testing.expectEqualSlices(u8, "test_file.tcl", try obj.getSourceExtraData().file_name.toHandle().?.getString());
    try testing.expectEqual(@as(u32, 42), info.?.line_no);

    const obj2 = try newString("hello");
    defer obj2.decrRefCount();

    const empty_info = getSourceInfo(obj2);
    try testing.expect(empty_info == null);
}

test "source info" {
    try testing.checkAllAllocationFailures(testing.allocator, testSourceInfo, .{});
}

var next_script_id = 1;

////////////////////////////////
//  Script related functions  //

/// Not threadsafe (though this will use `handle` correctly if it's from another thread).
pub fn parseScript(det: ?*ErrorDetails, handle: Handle) !Heap.ParsedScript {
    // Get source info, or use defaults.
    const source_info: SourceInfo = if (getSourceInfo(handle)) |info| info else .{ .file_name = .none, .line_no = 1 };

    // Parse all the tokens of the script, handling any errors that come up.

    const bytes = try handle.getString();
    // Because scripts are deduplicated, there may be scripts from multiple different
    // locations in the Tcl code. This means we can't use an absolute line number for the
    // script, but instead all line numbers are relative (hence why we start at 0 here).
    var parser = Tokenizer.init(bytes, 0);

    // Set up tokens list (to be added to).
    var tokens = try std.ArrayList(Tokenizer.Token).initCapacity(Heap.global_gpa, bytes.len / 8);
    defer tokens.deinit(Heap.global_gpa);

    // Used to ignore the first token if it's .command_separator (effectively
    // trimming any starting whitespace)
    var is_trimming_start = true;
    // Add all tokens to the list, handling any errors that may come up.
    while (true) {
        const next_token = parser.nextScriptToken();
        if (next_token) |token| {
            switch (token.tag) {
                .command_separator, .word_separator => {
                    if (!is_trimming_start) try tokens.append(Heap.global_gpa, token);
                },
                .end_of_file => {
                    // Be sure to trim the ending spacing.
                    while (tokens.getLastOrNull()) |last| {
                        if (last.tag == .command_separator or last.tag == .word_separator) {
                            _ = tokens.pop();
                        } else {
                            break;
                        }
                    }
                    try tokens.append(Heap.global_gpa, token);
                    break;
                },
                else => {
                    is_trimming_start = false;
                    try tokens.append(Heap.global_gpa, token);
                },
            }
        } else |err| {
            if (det) |details| {
                details.* = try convertTokenizerError(err);
                if (parser.error_details) |parser_details| {
                    details.index = parser_details.index;
                }
            }
            return err;
        }

        is_trimming_start = false;
    }

    if (options.token_debugging) {
        for (tokens.items, 0..) |token, i| {
            ioutil.debug("[{: >3}@{: >3}]  .{s: <20}  \"{s}\"\n", .{
                i,
                token.loc.line_no,
                @tagName(token.tag),
                bytes[token.loc.start..token.loc.end],
            });
        }
    }

    // Worst case: every token becomes a parsed token, plus one .start_of_command.
    const new_token_capacity: u32 = @intCast(tokens.items.len + 1);

    // Initialize the Heap-stored list that will contain the corrisponding value for each token.
    var new_token_values = try newListWithCapacity(new_token_capacity);
    errdefer new_token_values.decrRefCount();

    var new_token_tags: std.ArrayList(Tokenizer.Token.Tag) = try .initCapacity(Heap.global_gpa, new_token_capacity);
    errdefer new_token_tags.deinit(Heap.global_gpa);

    // The current script line's token index.
    var script_command_idx: u32 = 0;
    // The number of arguments for this command.
    var command_arg_count: u32 = 0;
    var i: usize = 0;
    while (i < tokens.items.len) {
        // Skip any leading separators.
        while (tokens.items[i].tag == .word_separator) i += 1;
        if (i >= tokens.items.len) break;

        // Look ahead to see when the next separator is.
        var arg_token_count: usize = 0;
        var found_expansion: bool = false;
        while (i + arg_token_count < tokens.items.len) : (arg_token_count += 1) {
            switch (tokens.items[i + arg_token_count].tag) {
                .argument_expansion => found_expansion = true,
                .command_separator, .word_separator, .end_of_file => break,
                else => {},
            }
        }

        // We'll only reach here if the current token is .command_separator or .end_of_file, because
        // word_token_count counts all tokens except those (well, and it doesn't count .word_separator,
        // but that's ruled out at the beginning when we skipped leading separators).
        if (arg_token_count == 0) {
            if (tokens.items[i].tag == .end_of_file) {
                if (command_arg_count > 0) {
                    const script_command = listItemNoFollow(new_token_values, script_command_idx).peek();
                    script_command.body.parsed_script_command.word_count = command_arg_count;
                }
                break; // Don't append a .script_command for EOF
            }

            i += 1; // Skip command separator.

            if (command_arg_count > 0) {
                const script_command = listItemNoFollow(new_token_values, script_command_idx).peek();
                script_command.body.parsed_script_command.word_count = command_arg_count;
                command_arg_count = 0;
            }

            continue;
        }

        // First word of a new command.
        if (command_arg_count == 0) {
            new_token_tags.appendAssumeCapacity(.start_of_command);
            listAppendAssumeCapacity(new_token_values, .{
                .head = .{ .tag = .parsed_script_command },
                .body = .{
                    .parsed_script_command = .{
                        .line = tokens.items[i].loc.line_no,
                        .word_count = 0,
                    },
                },
            });
            script_command_idx = listLength(new_token_values) - 1;
        }

        // Append the start of the word (only if necessary).
        if (found_expansion or arg_token_count > 1) {
            if (found_expansion) {
                new_token_tags.appendAssumeCapacity(.argument_expansion);
            } else {
                new_token_tags.appendAssumeCapacity(.start_of_word);
            }

            _ = listAppendAssumeCapacity(new_token_values, integerObject(
                // The argument_expansion token itself is not stored in the values
                // list (it's skipped in the loop below), so subtract 1 from the
                // count to reflect the actual number of tokens that follow.
                @intCast(if (found_expansion) arg_token_count - 1 else arg_token_count),
            ));
        }

        command_arg_count += 1;

        // Now append the tokens to the new list, escaping as necessary.
        for (i..(i + arg_token_count)) |token_idx| {
            const token = tokens.items[token_idx];

            const str_handle = blk: {
                switch (token.tag) {
                    .argument_expansion => break :blk null,
                    .escaped_string => {
                        new_token_tags.appendAssumeCapacity(.simple_string);
                        listAppendAssumeCapacity(new_token_values, .{ .head = .{ .tag = .none }, .body = undefined });
                        const item = listItemNoFollow(new_token_values, listLength(new_token_values) - 1);
                        setStringFromEscaped(item, bytes[token.loc.start..token.loc.end]) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.OtherThreadSet => unreachable,
                        };

                        break :blk item;
                    },
                    else => {
                        new_token_tags.appendAssumeCapacity(token.tag);
                        listAppendAssumeCapacity(new_token_values, .{ .head = .{ .tag = .none }, .body = undefined });
                        const item = listItemNoFollow(new_token_values, listLength(new_token_values) - 1);
                        Heap.setString(item, bytes[token.loc.start..token.loc.end]) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.OtherThreadSet => unreachable,
                        };

                        break :blk item;
                    },
                }
            };

            if (str_handle) |token_str| {
                try setSourceInfo(token_str, .{
                    .file_name = source_info.file_name,
                    .line_no = token.loc.line_no + source_info.line_no,
                });
            }
        }

        // Be sure to advance our index to the next word.
        i += arg_token_count;
    }

    if (command_arg_count > 0) {
        const script_command = listItemNoFollow(new_token_values, script_command_idx).peek();
        script_command.body.parsed_script_command.word_count = command_arg_count;
    }

    const parsed_script: Heap.ParsedScript = .{
        .tags = new_token_tags,
        .values = new_token_values,
    };
    if (options.token_debugging) {
        ioutil.debug("Dumping tokens\n", .{});
        parsed_script.printTokens();
    }

    return parsed_script;
}

fn testScriptParsing(ta: std.mem.Allocator) !void {
    try Heap.testStart(ta, testing.io);
    defer Heap.testFinish();

    const script1 = try newString(
        \\ set x 5
        \\ set y $x[set x]
    );
    defer script1.decrRefCount();
    var parsed = try parseScript(null, script1);
    defer parsed.deinit();

    const tokens = parsed.tags.items;
    const values = listItems(parsed.values);

    // set x 5
    try testing.expectEqual(.start_of_command, tokens[0]);
    try testing.expectEqual(0, values[0].body.parsed_script_command.line);
    try testing.expectEqual(3, values[0].body.parsed_script_command.word_count);
    try expectEqualToken(&parsed, 1, .simple_string, "set");
    try expectEqualToken(&parsed, 2, .simple_string, "x");
    try expectEqualToken(&parsed, 3, .simple_string, "5");

    try testing.expectEqual(.start_of_command, tokens[4]);
    try testing.expectEqual(1, values[4].body.parsed_script_command.line);
    try testing.expectEqual(3, values[4].body.parsed_script_command.word_count);
    try expectEqualToken(&parsed, 5, .simple_string, "set");
    try expectEqualToken(&parsed, 6, .simple_string, "y");
    try testing.expectEqual(.start_of_word, tokens[7]);
    try testing.expectEqual(2, values[7].body.integer);
    try expectEqualToken(&parsed, 8, .variable_subst, "x");
    try expectEqualToken(&parsed, 9, .command_subst, "set x");
}

test "script parsing" {
    try testing.checkAllAllocationFailures(testing.allocator, testScriptParsing, .{});
}

pub fn getScript(det: ?*ErrorDetails, handle: Handle, cache_key: u256) !Heap.ParsedScript {
    if (Heap.local_heap.parsed_scripts.get(cache_key)) |parsed| {
        return parsed.script;
    } else {
        const new_script = try parseScript(det, handle);
        if (Heap.local_heap.parsed_scripts.put(cache_key, .{ .script = new_script })) |ejected| {
            var old = ejected;
            old.script.deinit();
        }
        return new_script;
    }
}

fn testScriptShimmering(ta: std.mem.Allocator) !void {
    try Heap.testStart(ta, testing.io);
    defer Heap.testFinish();

    var script = try newString(
        \\ set foo 5
        \\ set y $foo[set foo]
    );
    defer script.decrRefCount();

    const cache_key = try script.getHash();

    // First call parses and caches.
    const parsed1 = try getScript(null, script, cache_key);
    try testing.expectEqualSlices(Tokenizer.Token.Tag, &[_]Tokenizer.Token.Tag{
        .start_of_command,
        .simple_string,
        .simple_string,
        .simple_string,
        .start_of_command,
        .simple_string,
        .simple_string,
        .start_of_word,
        .variable_subst,
        .command_subst,
    }, parsed1.tags.items);

    // Second call with the same key returns the cached version.
    const parsed2 = try getScript(null, script, cache_key);
    try testing.expectEqual(parsed1.tags.items.ptr, parsed2.tags.items.ptr);

    // A different script gets its own cache entry.
    var script2 = try newString("set x 5");
    defer script2.decrRefCount();

    const cache_key2 = try script2.getHash();
    const parsed3 = try getScript(null, script2, cache_key2);
    try testing.expect(parsed1.tags.items.ptr != parsed3.tags.items.ptr);
}

test "script shimmering" {
    try testing.checkAllAllocationFailures(testing.allocator, testScriptShimmering, .{});
}

fn expectEqualToken(script: *const Heap.ParsedScript, index: u32, tag: Tokenizer.Token.Tag, value: []const u8) !void {
    try testing.expectEqual(tag, script.tags.items[index]);
    try testing.expectEqualStrings(value, try listItemNoFollow(script.values, index).getString());
}

pub fn parseExpression(det: ?*ErrorDetails, handle: Handle) !Heap.ParsedExpression {
    const source_info: SourceInfo = getSourceInfo(handle) orelse .{ .file_name = .none, .line_no = 1 };
    var file_name = source_info.file_name.borrowOptional();
    errdefer file_name.swapWithNone();
    const line_no = source_info.line_no;

    // Parse all the tokens of the expr, handling any errors that come up.
    const bytes = try handle.getString();
    var tokenizer = Tokenizer.init(bytes, line_no);
    var tokens = std.MultiArrayList(Tokenizer.Token).empty;
    defer tokens.deinit(Heap.global_gpa);
    while (true) {
        const next_token = tokenizer.nextExpressionToken();
        if (next_token) |token| {
            try tokens.append(Heap.global_gpa, token);
            if (token.tag == .end_of_file) break;
        } else |err| if (det) |details| {
            details.* = try convertTokenizerError(err);
            if (tokenizer.error_details) |parser_details| {
                details.index = parser_details.index;
            }
            return err;
        }
    }

    if (tokens.len == 0) {
        if (det) |details| details.* = .{
            .message = try newString("empty expression"),
        };
        return error.ParseError;
    }

    // Next, go ahead and parse the expression from the tokens.
    const parsed: Heap.ParsedExpression = blk: {
        var parser = expr_parse.Parse.init(file_name, bytes, tokens.slice());
        errdefer parser.deinit();
        if (parser.parseExpr()) |root_node| {
            break :blk .{ .nodes = parser.nodes, .root_node = root_node.? };
            // Note we don't deinit parser here, since we take ownership.
        } else |err| {
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ParseError => {
                    if (det) |details| {
                        var aw = std.Io.Writer.Allocating.init(Heap.global_gpa);
                        errdefer aw.deinit();
                        const err_details = parser.err.?;
                        parser.renderError(err_details, &aw.writer) catch return error.OutOfMemory;
                        const rendered_error = try aw.toOwnedSlice();
                        defer Heap.global_gpa.free(rendered_error);
                        const err_on_heap = try newString(rendered_error);
                        errdefer err_on_heap.decrRefCount();

                        details.* = .{
                            .message = err_on_heap,
                            .index = err_details.sourceIndex(&parser),
                        };
                    }
                    return error.ParseError;
                },
            }
        }
    };

    return parsed;
}

pub fn getExpression(det: ?*ErrorDetails, handle: Handle, cache_key: u256) !Heap.ParsedExpression {
    if (Heap.local_heap.parsed_exprs.get(cache_key)) |parsed| {
        return parsed.expr;
    } else {
        const new_expr = try parseExpression(det, handle);
        if (Heap.local_heap.parsed_exprs.put(cache_key, .{ .expr = new_expr })) |ejected| {
            var old = ejected;
            old.expr.deinit();
        }
        return new_expr;
    }
}

fn testExpressions(ta: std.mem.Allocator) !void {
    try Heap.testStart(ta, testing.io);
    defer Heap.testFinish();

    var expr1 = try newString("1 + 2 * 3 + 4");
    defer expr1.decrRefCount();

    const parsed = try getExpression(null, expr1, try expr1.getHash());
    try testing.expectEqual(.add, parsed.nodes.get(@intFromEnum(parsed.root_node)).tag);
}

test "expressions" {
    try testing.checkAllAllocationFailures(testing.allocator, testExpressions, .{});
}

pub fn parseSubstitution(det: ?*ErrorDetails, handle: Handle, flags: Tokenizer.SubstFlags) !Heap.ParsedScript {
    // Get source info, or use defaults.
    const source_info: SourceInfo = if (getSourceInfo(handle)) |info| info else .{ .file_name = .none, .line_no = 1 };

    // Parse all the tokens of the script, handling any errors that come up.

    const bytes = try handle.getString();
    // Because scripts are deduplicated, there may be scripts from multiple different
    // locations in the Tcl code. This means we can't use an absolute line number for the
    // script, but instead all line numbers are relative (hence why we start at 0 here).
    var parser = Tokenizer.init(bytes, 0);

    // Set up tokens list (to be added to).
    var tokens = try std.ArrayList(Tokenizer.Token).initCapacity(Heap.global_gpa, bytes.len / 8);
    defer tokens.deinit(Heap.global_gpa);

    // Add all tokens to the list, handling any errors that may come up.
    while (true) {
        const next_token = parser.nextSubstToken(flags);
        if (next_token) |token| {
            if (token.tag == .end_of_file) break;
            try tokens.append(Heap.global_gpa, token);
        } else |err| {
            if (det) |details| {
                details.* = try convertTokenizerError(err);
                if (parser.error_details) |parser_details| {
                    details.index = parser_details.index;
                }
            }
            return err;
        }
    }

    if (options.token_debugging) {
        ioutil.debug("Substitution tokens:\n", .{});
        for (tokens.items, 0..) |token, i| {
            ioutil.debug("[{: >3}@{: >3}]  .{s: <20}  \"{s}\"\n", .{
                i,
                token.loc.line_no,
                @tagName(token.tag),
                bytes[token.loc.start..token.loc.end],
            });
        }
    }

    // Initialize the Heap-stored list that will contain the corrisponding value for each token.
    var new_token_values = try newListWithCapacity(@intCast(tokens.items.len));
    errdefer new_token_values.decrRefCount();
    new_token_values.peek().body.list.len = @intCast(tokens.items.len);

    var new_token_tags = try std.ArrayList(Tokenizer.Token.Tag).initCapacity(Heap.global_gpa, tokens.items.len);
    errdefer new_token_tags.deinit(Heap.global_gpa);

    // Append the tokens to the new list, escaping as necessary.
    for (0..tokens.items.len) |token_idx| {
        const token = tokens.items[token_idx];

        const str_handle = blk: {
            switch (token.tag) {
                .escaped_string => {
                    try new_token_tags.append(Heap.global_gpa, .simple_string);
                    const item_handle = listItemNoFollow(new_token_values, @intCast(token_idx));
                    setStringFromEscaped(item_handle, bytes[token.loc.start..token.loc.end]) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.OtherThreadSet => unreachable,
                    };
                    break :blk item_handle;
                },
                else => {
                    try new_token_tags.append(Heap.global_gpa, token.tag);
                    const item_handle = listItemNoFollow(new_token_values, @intCast(token_idx));
                    Heap.setString(item_handle, bytes[token.loc.start..token.loc.end]) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.OtherThreadSet => unreachable,
                    };
                    break :blk item_handle;
                },
            }
        };

        try setSourceInfo(str_handle, .{
            .file_name = source_info.file_name,
            .line_no = token.loc.line_no + source_info.line_no,
        });
    }

    const parsed_subst: Heap.ParsedScript = .{
        .tags = new_token_tags,
        .values = new_token_values,
    };
    if (options.token_debugging) {
        ioutil.debug("Dumping substitution tokens\n", .{});
        parsed_subst.printTokens();
    }

    return parsed_subst;
}

pub fn getSubstitution(det: ?*ErrorDetails, handle: Handle, cache_key: u256, flags: Tokenizer.SubstFlags) !Heap.Substitution {
    if (Heap.local_heap.parsed_substs.get(cache_key)) |parsed| {
        return parsed;
    } else {
        const new_subst = try parseSubstitution(det, handle, flags);
        if (Heap.local_heap.parsed_substs.put(cache_key, .{ .subst = new_subst, .flags = flags })) |evicted| {
            var evicted_mut = evicted;
            evicted_mut.subst.deinit();
        }
        return .{ .subst = new_subst, .flags = flags };
    }
}

pub fn shimmerToBoolean(det: ?*ErrorDetails, wb: *Shimmerable) !void {
    if (wb.tag() == .bool) return;

    // Fast case: if it's an int, we can get the value directly.
    if (wb.tag() == .integer) {
        const new_value = wb.peek().body.integer != 0;

        try wb.prepareToShimmer();
        wb.peek().head.tag = .bool;
        wb.peek().body.bool = .{ .data = new_value };
        return;
    }

    const Mapping = std.StaticStringMap(bool).initComptime(Tokenizer.boolean_mapping);

    const bytes = try wb.current().getString();
    const new_value = Mapping.get(bytes) orelse blk: {
        // It might be an integer, so be sure to try parsing it as an int before giving up.
        const as_int = integerGetNoShimmer(null, wb.current()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                // Finally, give up.
                if (det) |details| details.* = .{
                    .message = try newStringFmt("expected boolean but got \"{f}\"", .{wb.current()}),
                };
                return error.BadBoolean;
            },
        };
        break :blk as_int != 0;
    };

    try wb.prepareToShimmer();
    wb.peek().head.tag = .bool;
    wb.peek().body.bool = .{ .data = new_value };
}

pub fn getBoolean(det: ?*ErrorDetails, wb: *Shimmerable) !bool {
    try shimmerToBoolean(det, wb);
    return wb.peek().body.bool.data;
}

pub fn newBoolean(value: bool) !Handle {
    const handle = try Heap.createObject();
    handle.peek().head.tag = .bool;
    handle.peek().body.bool = .{ .data = value };
    return handle;
}

pub fn shimmerToRegexp(det: ?*ErrorDetails, wb: *Shimmerable, compile_opts: u32) !void {
    if (wb.tag() == .regexp and wb.peek().body.regexp.options == compile_opts) return;

    const pattern = try wb.current().getString();

    var err_code: c_int = 0;
    var err_offset: usize = 0;
    const compile_ctx = pcre2.pcre2_compile_context_create_8(regex.pcre2_ctx) orelse return error.OutOfMemory;
    defer pcre2.pcre2_compile_context_free_8(compile_ctx);

    const re = pcre2.pcre2_compile_8(
        pattern.ptr,
        pattern.len,
        compile_opts,
        &err_code,
        &err_offset,
        compile_ctx,
    ) orelse {
        if (err_code == pcre2.PCRE2_ERROR_NOMEMORY) return error.OutOfMemory;
        if (det) |details| {
            var buf: [256]u8 = undefined;
            const msg_len = pcre2.pcre2_get_error_message_8(err_code, &buf, buf.len);
            const msg = buf[0..@intCast(msg_len)];
            details.* = .{ .message = try newString(msg) };
        }
        return error.BadRegexp;
    };

    const heap = wb.current().getHeap();
    const extra = try heap.createExtraData();
    errdefer heap.destroyExtraData(extra);

    heap.getExtraData(extra).* = .{ .regexp = re };

    try wb.prepareToShimmer();
    wb.peek().head.tag = .regexp;
    wb.peek().body.regexp = .{ .options = compile_opts, .extra_data = extra };
}

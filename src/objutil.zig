const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const testing = std.testing;

const options = @import("options");
const memutil = @import("memutil.zig");
const Heap = @import("Heap.zig");
const Handle = Heap.Handle;
const OptionalHandle = Heap.OptionalHandle;

pub const Error = std.mem.Allocator.Error || error{
    BadIndex,
    NotMutable,
    BadEnumVariant,
    BadBoolean,
    BadDict,
    BadInteger,
    IntegerOverflow,
    DivisionByZero,
    NegativeDenominator,
    BadFloat,
    ParseError,
    MissingDictKey,
};

pub const ErrorDetails = struct {
    message: Handle,
    index: ?u32 = null,
};

/// If the object changed locations, `new_handle` will be non-null.
pub fn shimmerToString(provided_handle: Handle, new_handle: *OptionalHandle) !void {
    if (provided_handle.tag() == .string) return;
    errdefer new_handle.swapWithNone();

    try Heap.ensureShimmerableOrDup(provided_handle, new_handle);
    const handle = new_handle.orElse(provided_handle);

    try handle.prepareToShimmer();
    handle.peek().head.tag = .string;
    handle.peek().body = .{
        .string = .{
            .utf8_length = 0,
            // Don't know the utf-8 length yet.
            .length_determined = false,
        },
    };
}

/// Copies provided string.
pub fn newString(heap: *Heap, bytes: []const u8) !Handle {
    var handle = try heap.createObject();
    errdefer handle.decrRefCount();

    try Heap.setString(handle, bytes);
    var new_handle: OptionalHandle = .none;
    try shimmerToString(handle, &new_handle);
    assert(new_handle == .none);

    return handle;
}

pub fn newListWithCapacity(capacity: u32) !Handle {
    // `1 +` to make space for the list's head
    const list_index = try Heap.local_heap.createObjects(1 + capacity);
    const list_head = Heap.local_heap.getLocalObject(list_index);

    list_head.* = .{
        .head = .{
            .str = Heap.Object.null_string,
            .tag = .list,
        },
        .body = .{
            .list = .{
                .len = 0,
            },
        },
    };

    return Heap.local_heap.getHandle(list_index);
}

pub fn newList(handles: []const Handle) !Handle {
    const list = try newListWithCapacity(@intCast(handles.len));
    errdefer list.decrRefCount();
    list.peek().body.list.len = @intCast(handles.len);

    const new_items = listItems(list);
    for (handles, new_items) |handle, *item| {
        item.* = handle.dupOrRef();
    }

    return list;
}

pub fn listLength(list: Handle) u32 {
    assert(list.tag() == .list);

    return list.peek().body.list.len;
}

pub fn followIfRef(handle: Handle) Handle {
    if (handle.tag() == .reference) return handle.peek().body.reference;
    return handle;
}

fn collectionItem(handle: Handle, index: u32, len: u32) Handle {
    handle.assert(handle.tag() == .list or handle.tag() == .dict);
    handle.assert(index < len);

    return .{
        .index = handle.index + 1 + index,
        .heap = handle.heap,
    };
}

fn collectionItemFollowRefs(handle: Handle, index: u32, len: u32) Heap.Handle {
    assert(handle.tag() == .list or handle.tag() == .dict);

    if (index < len) {
        const elem: Heap.Handle = .{
            .index = handle.index + 1 + index,
            .heap = handle.heap,
        };

        return followIfRef(elem);
    } else @panic("Element out of bounds");
}

pub fn collectionItems(handle: Handle, len: u32) []Heap.Object {
    assert(handle.tag() == .list or handle.tag() == .dict);

    return handle.getHeap().objectSlice(handle.index + 1, handle.index + 1 + len);
}

/// The reason this returns a new object instead of having a `new_handle` parameter is
/// that we need to prevent a situation where `provided_handle` and the theoretical
/// `new_handle` alias, as that would lead to UAF.
fn setCollectionLength(provided_handle: Handle, new_len: u32) !OptionalHandle {
    const current_len = blk: {
        switch (provided_handle.tag()) {
            .list => break :blk provided_handle.peek().body.list.len,
            .dict => break :blk provided_handle.peek().body.dict.len,
            else => unreachable,
        }
    };

    // If it's the same length, no need to do anything.
    if (current_len == new_len) return .none;

    new_collection_needed: {
        // We can only do these quick changes if the collection can mutate in-place.
        if (!provided_handle.canMutate()) break :new_collection_needed;

        // No need to realloc if we're shrinking.
        if (new_len < current_len) {
            // We need to check if any of the abandoned items are shared. If so, we'll need to
            // split this collection and create a new one.
            const freed_count = current_len - new_len;
            for (0..freed_count) |to_free| {
                const to_free_handle = listItem(provided_handle, @intCast(current_len - freed_count + to_free));
                if (to_free_handle.getRefCount() > 1) break :new_collection_needed;
            }

            // Be sure to free the abandoned items when we shrink.
            for (0..freed_count) |to_free| {
                const to_free_handle = collectionItem(provided_handle, @intCast(current_len - freed_count + to_free), current_len);
                to_free_handle.invalidateBoth();
            }

            unreachable;
        } else {
            // Even if there's not enough length, there may be enough capacity.
            const capacity = memutil.getOrderSize(provided_handle.getMetadata().order) - 1; // -1 for list head
            if (new_len <= capacity) {
                switch (provided_handle.tag()) {
                    .list => provided_handle.peek().body.list.len = new_len,
                    .dict => provided_handle.peek().body.dict.len = new_len,
                    else => unreachable,
                }

                return .none;
            }
        }
    }

    // We've exhausted all other options, so we'll need to make a new collection.
    const new_handle = switch (provided_handle.tag()) {
        .list => try newListWithCapacity(new_len),
        .dict => try newDictWithCapacity(Heap.local_heap, new_len),
        else => unreachable,
    };
    errdefer new_handle.decrRefCount();
    const new_items = collectionItems(new_handle, new_len);

    if (provided_handle.canMutate()) {
        var found_shared_items = false;

        // If the collection isn't shared, we can move the objects over to the new
        // collection without any duplication.
        for (new_items[0..current_len], 0..) |*new_item, i| {
            const old_item = collectionItem(provided_handle, @intCast(i), current_len);
            // However, if an item within the list was shared, we can't move it, we instead have to reference
            // it. (Why not use `item_handle.reference()`? Because that would create one too many references
            // as the list already has one ref count for owning the item.)
            if (old_item.getRefCount() > 1) {
                found_shared_items = true;
                new_item.* = old_item.referenceTakeOwnership();
            } else {
                new_item.* = old_item.peek().*;
                // Be sure to "zero" out the old item after we steal it.
                old_item.peek().* = .{
                    .head = .{
                        .str = Heap.Object.null_string,
                        .tag = .none,
                    },
                    .body = undefined,
                };
            }
        }

        if (found_shared_items) {
            assert(current_len > 0);
            // Because we found shared items, we can't free the backing directly, as that would
            // free an item that someone else is currently referencing. Instead, we'll split the
            // allocation, and free all non-shared objects.
            provided_handle.getHeap().splitAlloc(provided_handle.index, 0);

            for (0..current_len) |i| {
                const item_handle: Handle = collectionItem(provided_handle, @intCast(i), current_len);

                // Only free the backing of non-shared objects, so we don't release the backing of a shared item.
                // Why only a backing free? Because the non-shared objectes were moved to the new collection.
                if (item_handle.getRefCount() > 1) {
                    // If this was a dict, and a key was marked as not mutable, we need to be sure to undo that.
                    // This is fine to do on list items, since they're already mutable.
                    item_handle.getMetadata().mutable = true;
                } else {
                    Heap.freeObjectBacking(item_handle);
                }
            }
        }

        // We don't free the collection here, since that would violate the caller's expectations.
        // But, we still don't want anyone using this incredibly broken object, so we'll set
        // it to .invalid.

        // We don't invalidate the old body, as that would double-free the collection items.
        // Hence, we have to manually handle freeing the old table.
        if (provided_handle.tag() == .dict) {
            dictInvalidateTable(provided_handle);
            provided_handle.getHeap().destroyExtraData(provided_handle.peek().body.dict.extra_data);
        }
        provided_handle.invalidateString();
        provided_handle.peek().head.tag = .invalid;
        provided_handle.peek().body = undefined;

        switch (new_handle.tag()) {
            .dict => new_handle.peek().body.dict.len = new_len,
            .list => new_handle.peek().body.list.len = new_len,
            else => unreachable,
        }
    } else {
        // If the collection is shared, we need to duplicate all the items.
        for (0.., new_items) |i, *new_item| {
            new_item.* = collectionItemFollowRefs(provided_handle, @intCast(i), current_len).dupOrRef();
        }

        switch (new_handle.tag()) {
            .dict => new_handle.peek().body.dict.len = new_len,
            .list => new_handle.peek().body.list.len = new_len,
            else => unreachable,
        }
    }

    return new_handle.toOptional();
}

/// Assumes provided handle is a list.
pub fn listItem(handle: Handle, index: u32) Handle {
    assert(handle.tag() == .list);

    return collectionItem(handle, index, handle.peek().body.list.len);
}

/// Assumes provided handle is a list.
pub fn listItemFollowRefs(handle: Handle, index: u32) Handle {
    assert(handle.tag() == .list);

    return collectionItemFollowRefs(handle, index, handle.peek().body.list.len);
}

/// Assumes handle is a list.
pub fn listItems(handle: Handle) []Heap.Object {
    assert(handle.tag() == .list);

    return handle.getHeap().objects.items(.object)[(handle.index + 1)..][0..handle.peek().body.list.len];
}

/// `list` must be mutable.
pub fn listAppendAssumeCapacity(list: Handle, object: Heap.Object) void {
    list.assert(list.tag() == .list);
    list.assert(list.canMutate());

    const current_len = list.peek().body.list.len;
    list.assert(current_len < memutil.getOrderSize(list.getMetadata().order) - 1); // -1 for list head.
    list.peek().body.list.len += 1;

    listItem(list, current_len).peek().* = object;
}

const DictTable = Heap.ExtraDataValue.Dictionary.Table;
pub fn dictGetTable(dict: Handle) !*DictTable {
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
        const key = collectionItem(dict, pair, dict_len);
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

pub fn dictItems(handle: Handle) []Heap.Object {
    assert(handle.tag() == .dict);
    const dict_len = handle.peek().body.dict.len;
    return handle.getHeap().objectSlice(handle.index + 1, handle.index + 1 + dict_len);
}

pub fn dictItem(dict: Handle, index: u32) Handle {
    dict.assert(dict.tag() == .dict);
    return collectionItem(dict, index, dict.peek().body.dict.len);
}

pub fn dictItemFollowRefs(dict: Handle, index: u32) Handle {
    dict.assert(dict.tag() == .dict);
    return collectionItemFollowRefs(dict, index, dict.peek().body.dict.len);
}

pub fn dictItemLength(handle: Handle) u32 {
    assert(handle.tag() == .dict);
    return handle.peek().body.dict.len;
}

pub fn dictPairLengthRaw(handle: Handle) u32 {
    assert(handle.tag() == .dict);
    return handle.peek().body.dict.len / 2;
}

pub fn newDictWithCapacity(heap: *Heap, len: u32) !Handle {
    assert(@mod(len, 2) == 0);

    // `1 +` to make space for the dict's head.
    const dict_index = try heap.createObjects(1 + len);
    errdefer Heap.freeObjectBacking(heap.getHandle(dict_index));
    const dict_metadata = try heap.createExtraData();
    errdefer heap.destroyExtraData(dict_metadata);

    heap.getExtraData(dict_metadata).* = .{ .dict = .{
        .table = null,
        .parent_link = .none,
    } };

    const dict_head = heap.getLocalObject(dict_index);
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

    return heap.getHandle(dict_index);
}

/// Caller is responsible that `handles` has handles.len % 2 == 0.
pub fn newDict(heap: *Heap, handles: []const Handle) !Handle {
    const dict = try newDictWithCapacity(heap, @intCast(handles.len));
    errdefer dict.decrRefCount();
    dict.peek().body.dict.len = @intCast(handles.len);

    const new_items = dictItems(dict);

    for (handles, new_items) |handle, *item| {
        item.* = heap.dupOrReference(handle);
    }

    return dict;
}

pub fn dictLookup(dict: Handle, key: Handle) error{OutOfMemory}!OptionalHandle {
    dict.assert(dict.tag() == .dict);
    // Make sure key has a string representation, as table.get isn't allowed to fail.
    _ = try key.getString();

    const table = try dictGetTable(dict);
    if (table.get(key)) |value_offset| {
        return dictItemFollowRefs(dict, value_offset).toOptional();
    } else return .none;
}

pub const DictAndValueResult = struct { new_dict: OptionalHandle, new_value: Heap.Handle };
/// Takes ownership of `value`, including error cases. Returns a handle to the new value's location.
/// `value` must be in `Heap.local_heap`.
pub fn dictPutInner(provided_dict: Handle, key: Handle, value: Heap.Object) !DictAndValueResult {
    var value_mut = value;

    // Because there's so many points at which this function can hit OOM,
    // we model this as a FSM, in order to handle error cases correctly.
    const State = union(enum) {
        start,
        ensured_mutable: struct {
            new_dict: OptionalHandle,
        },
        changed_value: struct {
            new_dict: OptionalHandle,
            old_value: Heap.Object,
            /// Index relative to the dict.
            value_index: u32,
        },
        appended_pair: struct {
            new_dict: OptionalHandle,
            /// Index relative to the dict.
            new_key_index: u32,
        },
    };

    var current_state: State = .start;
    while (true) current_state = next_state: switch (current_state) {
        .start => {
            errdefer value_mut.deinitSingle(Heap.local_heap);

            // Make sure the key has a string representation.
            _ = try key.getString();
            // Also make sure we can mutate the dict.
            var new_dict: OptionalHandle = .none;
            try Heap.ensureMutableOrDup(provided_dict, &new_dict);

            break :next_state .{ .ensured_mutable = .{
                .new_dict = new_dict,
            } };
        },
        .ensured_mutable => |state| {
            errdefer value_mut.deinitSingle(Heap.local_heap);
            var new_dict = state.new_dict;
            errdefer new_dict.swapWithNone();
            var dict = new_dict.orElse(provided_dict);

            const table = try dictGetTable(dict);
            // Does the key already exist?
            if (table.get(key)) |_| {
                // Key exists, so replace the value in place.
                unreachable; // Currently no code uses this branch.
            } else {
                const original_len = dict.peek().body.dict.len;
                const new_length = original_len + 2;
                try table.ensureTotalCapacity(Heap.global_gpa, new_length / 2);

                // Key doesn't exist, so append both key and value.
                const len_before_resize = dict.peek().body.dict.len;
                const new_key_index = len_before_resize;
                const new_value_index = len_before_resize + 1;

                // Duplicate/reference the key _before_ resizing, so we can't fail
                // after the resize is successful.
                const new_key_handle, const new_value_handle = blk: {
                    var key_obj: Heap.Object = Heap.dupOrReference(Heap.local_heap, key);
                    errdefer key_obj.deinitSingle(Heap.local_heap);

                    new_dict.swapRefIfNew(try setCollectionLength(dict, new_length));
                    dict = new_dict.orElse(dict);

                    const new_key_handle = dictItem(dict, new_key_index);
                    const new_value_handle = dictItem(dict, new_value_index);

                    // Set the new key and value.
                    new_key_handle.peek().* = key_obj;
                    new_key_handle.getMetadata().mutable = false;
                    new_value_handle.peek().* = value;

                    break :blk .{ new_key_handle, new_value_handle };
                };
                errdefer {
                    new_key_handle.invalidateBoth();
                    new_value_handle.invalidateBoth();
                    dict.peek().body.dict.len = original_len;
                }

                // Make sure the key has a string rep.
                _ = try new_key_handle.getString();

                // Only put the key in the table if the table exists. It'll be discovered
                // when the table is generated if not.
                if (dictMaybeGetTable(dict)) |new_table| {
                    new_table.putAssumeCapacity(new_key_handle, new_value_index);
                }

                // Need to add a new pair.
                break :next_state .{ .appended_pair = .{
                    .new_dict = new_dict,
                    .new_key_index = new_key_index,
                } };
            }
        },
        .changed_value => |state| {
            var old_value = state.old_value;
            var new_dict = state.new_dict;
            errdefer new_dict.swapWithNone();
            const dict = new_dict.orElse(provided_dict);
            errdefer {
                const value_handle = dictItem(dict, state.value_index);
                // Invalidate new value.
                value_handle.invalidateBoth();
                // Restore old value.
                value_handle.peek().* = old_value;
            }

            const new_index = state.value_index;

            // Success! We can now safely deinit the old value, since there's no need
            // to restore it anymore.
            old_value.deinitSingle(Heap.local_heap);

            return .{ .new_dict = new_dict, .new_value = dictItem(dict, new_index) };
        },
        .appended_pair => |state| {
            var new_dict = state.new_dict;
            errdefer new_dict.swapWithNone();
            var dict = new_dict.orElse(provided_dict);
            errdefer {
                // Because these are new values, we don't need to restore old values--
                // there's nothing to restore. Instead, we'll just free the last two
                // new values, and shrink the length.
                const len = dict.peek().body.dict.len;
                assert(state.new_key_index == len - 2);

                dictItem(dict, len - 2).getMetadata().mutable = true;
                dictItem(dict, len - 2).invalidateBoth();
                dictItem(dict, len - 1).invalidateBoth();
                dict.peek().body.dict.len -= 2;
            }

            // Because we mutated the dictionary, we need to remove any duplicates, if applicable.
            const new_index = state.new_key_index + 1;

            return .{ .new_dict = new_dict, .new_value = dictItem(dict, new_index) };
        },
    };
}

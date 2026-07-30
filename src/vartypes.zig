const std = @import("std");
const testing = std.testing;

const memutil = @import("memutil.zig");
const StructIterator = memutil.StructIterator;
const heap = @import("heap.zig");
const Object = heap.Object;
const Value = heap.Value;
const objects = @import("objects.zig");
const IterHelper = objects.IterHelper;
const Shimmerable = objects.Shimmerable;
const ErrorDetails = objects.ErrorDetails;
const Dictionary = objects.Dictionary;
const allocPrintZ = objects.allocPrintZ;
const Interp = @import("Interp.zig");

pub const CachedLocalVar = struct {
    dictionary_in: *objects.Dictionary,
    index: usize,
    call_epoch: u64,

    pub fn asHead(self: *CachedLocalVar) *Object {
        return Object.from(CachedLocalVar, self);
    }

    fn makeCrossthread(obj: *Object) void {
        obj.vtable = &objects.None.vtable;
    }

    pub fn getCurrentValue(self: *const CachedLocalVar) Value {
        return self.dictionary_in.items[self.index];
    }

    pub const vtable: Object.VTable = .{
        .duplicate = Object.duplicateStringOnly,
        .update_string = null,
        .free_internal_rep = null,
        .make_crossthread = makeCrossthread,
        // TODO it would be nice to be able to walk the cached local var,
        // but we'd need the call epoch invalidation logic embedded in it.
        .enumerate_struct = null,
        .name = @typeName(CachedLocalVar),
    };
};

pub const CachedLexicalVar = struct {
    ref: Value,
    /// We still need to track the call epoch for the cached lexical var, since it's
    /// possible that this was shadowed by a local variable.
    call_epoch: u64,

    pub fn asHead(self: *CachedLexicalVar) *Object {
        return Object.from(CachedLexicalVar, self);
    }

    fn makeCrossthread(obj: *Object) void {
        obj.vtable = &objects.None.vtable;
    }

    pub const vtable: Object.VTable = .{
        .duplicate = Object.duplicateStringOnly,
        .update_string = null,
        .free_internal_rep = null,
        .make_crossthread = makeCrossthread,
        // TODO same issue as `CachedLocalVar.vtable`.
        .enumerate_struct = null,
        .name = @typeName(CachedLexicalVar),
    };
};

pub const UpvarLink = struct {
    /// An object containing the name of the variable in the linked
    /// scope. Whenever someone shimmers this to a variable, they should
    /// always do it in `call_frame`.
    linked_name: Value,
    /// The call frame the linked variable lives in.
    call_frame: u32,

    fn freeInternalRep(src: *Object) void {
        src.asType(UpvarLink).?.linked_name.release();
    }

    fn enumerateStruct(_: *const Object, ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const upvar: *const UpvarLink = @ptrCast(@alignCast(info.node));
        const helper: IterHelper = .{ .ctx = ctx, .info = info };
        try helper.followValue("linked_name", upvar.linked_name);
        try helper.addField(u32, "call_frame", "{}", .{upvar.call_frame});
    }

    pub const vtable: Object.VTable = .{
        .duplicate = null,
        .free_internal_rep = freeInternalRep,
        .update_string = null,
        .make_crossthread = null,
        .enumerate_struct = enumerateStruct,
        .name = @typeName(UpvarLink),
    };
};

/// `dict_name` points  to an object that contains the name of the dictionary
/// (and most likely specializes to whatever type of variable caching is necessary),
/// while `dict_path` points to a list containing all parts of the path. For
/// example, `foo::bar::baz` would turn into roughly
/// ```
/// dict_name: foo
/// dict_path: {bar baz}
/// ```
pub const DictSugar = struct {
    dict_name: Value,
    dict_path: *objects.List,

    pub fn isValidDictSugar(var_name: [:0]const u8) error{BadVariableName}!bool {
        // Can't start with `~parent`.
        if (std.mem.startsWith(u8, var_name[0..], "~parent")) return error.BadVariableName;

        const double_colons = std.mem.indexOf(u8, var_name, "::");
        // Must have at least one set of double colons.
        const start_at = if (double_colons) |val| val else return false;

        // Can't have dict sugar start with colons.
        if (start_at == 0) return false;
        // Also can't end with colons.
        const ending_colons = std.mem.lastIndexOf(u8, var_name, "::").?;
        if (ending_colons == var_name.len - 2) return false;

        return true;
    }

    pub fn parseDictSugar(var_name: [:0]const u8) error{ BadVariableName, OutOfMemory }!?struct {
        dict_name: Value,
        dict_path: *objects.List,
    } {
        if (!(try isValidDictSugar(var_name))) return null;

        const start_at = std.mem.indexOf(u8, var_name, "::").?;
        const dict_name = try objects.String.newValue(var_name[0..start_at]);
        errdefer dict_name.release();

        var dict_path: *objects.List = try objects.List.new(&.{});
        errdefer dict_path.asHead().release();

        var last_path_start: ?usize = null;
        var i = start_at;
        while (i <= var_name.len) : (i += 1) {
            if (i == var_name.len or (var_name[i] == ':' and var_name[i + 1] == ':')) {
                if (last_path_start) |val| {
                    const path_section = var_name[val..i];
                    const path_section_value = try objects.String.newValue(path_section);
                    defer path_section_value.release();
                    try dict_path.append(path_section_value);
                }

                // Keep advancing until we've passed the colon(s).
                while (i < var_name.len and var_name[i + 1] == ':') i += 1;
                last_path_start = i + 1;
            }
        }

        return .{ .dict_name = dict_name, .dict_path = dict_path };
    }

    /// This should only ever be called if you know that this variable is in dict sugar form.
    pub fn shimmerAssumeValid(name: *Shimmerable) error{OutOfMemory}!*const DictSugar {
        if (name.current().asType(DictSugar)) |dict_sugar| return dict_sugar;

        const maybe_dict_sugar = parseDictSugar(try name.current().getString()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadVariableName => unreachable,
        };
        const dict_sugar = maybe_dict_sugar.?;
        errdefer dict_sugar.dict_name.release();
        errdefer dict_sugar.dict_path.asHead().release();

        const as_dict_sugar = try name.prepareToShimmer(DictSugar);
        as_dict_sugar.* = .{
            .dict_name = dict_sugar.dict_name,
            .dict_path = dict_sugar.dict_path,
        };

        return as_dict_sugar;
    }

    fn freeInternalRep(src: *Object) void {
        const as_dict_sugar = src.asType(DictSugar).?;
        as_dict_sugar.dict_name.release();
        as_dict_sugar.dict_path.asHead().release();
    }

    fn makeCrossthread(obj: *Object) void {
        freeInternalRep(obj);
        obj.vtable = &objects.None.vtable;
    }

    fn enumerateStruct(_: *const Object, ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const dict_sugar: *const DictSugar = @ptrCast(@alignCast(info.node));
        const helper: IterHelper = .{ .ctx = ctx, .info = info };
        try helper.followValue("dict_name", dict_sugar.dict_name);
        try helper.follow(Object, "dict_path", dict_sugar.dict_path.asHead());
    }

    pub const vtable: Object.VTable = .{
        .name = @typeName(DictSugar),
        .duplicate = Object.duplicateStringOnly,
        .free_internal_rep = freeInternalRep,
        .update_string = null,
        .make_crossthread = makeCrossthread,
        .enumerate_struct = enumerateStruct,
    };
};

const VariableLookupResult = enum { not_found, dict_sugar, normal };
pub const VariableValue = union(enum) {
    local_variable: struct {
        dictionary_in: *objects.Dictionary,
        index: usize,
    },
    /// Variable in a parent scope. Immutable.
    lexical_variable: Value,
};

/// Resolves to the variable's value, if any. Does not account for dict sugar.
fn resolveVariable(interp: *Interp, det: ?*ErrorDetails, var_call_frame: u32, var_name: Value) error{
    OutOfMemory,
    LookupFailed,
    BadVariableName,
}!?VariableValue {
    if (var_name.asPtr()) |obj| _ = try obj.getString();

    if (try var_name.equalsString("~parent")) {
        if (det) |details| details.* = .{
            .message = try std.fmt.allocPrintSentinel(heap.global_gpa, "bad variable name: \"{s}\"", .{try var_name.getString()}, 0),
        };
        return error.BadVariableName;
    }

    const var_dict = interp.call_frames.items[var_call_frame].variables;
    const maybe_scope_hash_ref = &interp.call_frames.items[var_call_frame].signature.scope_hash_ref;

    // Check the variables dictionary. Don't follow refs here so the
    // cached index points at the dict slot, not the ref target.
    if (var_dict.table.get(var_name)) |local_var| {
        return .{
            .local_variable = .{
                .dictionary_in = var_dict,
                .index = local_var,
            },
        };
    }

    // Wasn't in the variables, maybe it's in a parent scope instead?
    if (maybe_scope_hash_ref.*) |*scope_hash_ref| {
        const hash_ref = try scope_hash_ref.get();
        var dict_shim: Shimmerable = .{ .original = hash_ref.ref.asValue() };
        defer dict_shim.discardChanges();
        const in_linked_scope = try objects.Dictionary.getFollowingLinks(det, &dict_shim, var_name);

        if (dict_shim.shimmered.asValue()) |new_dict_raw| {
            const new_hash_ref = try objects.HashReference.new(new_dict_raw.asPtr().?);
            const old_inner = scope_hash_ref.*.inner;
            scope_hash_ref.*.inner = new_hash_ref.asHead();
            old_inner.release();
        }

        if (in_linked_scope.asValue()) |val| {
            return .{ .lexical_variable = val };
        }
    }

    return null;
}

/// This always recalculates the variable. You probably should be using `ensureValidVariableType`.
fn reshimmerToVariable(
    interp: *Interp,
    det: ?*ErrorDetails,
    var_call_frame: u32,
    name: *Shimmerable,
) error{ OutOfMemory, LookupFailed, BadVariableName }!VariableLookupResult {
    const call_frame = &interp.call_frames.items[var_call_frame];
    if (try resolveVariable(interp, det, var_call_frame, name.current())) |var_value| {
        switch (var_value) {
            .local_variable => |local_var| {
                const as_cached_local_var = try name.prepareToShimmer(CachedLocalVar);
                as_cached_local_var.* = .{
                    .dictionary_in = local_var.dictionary_in,
                    .index = local_var.index,
                    .call_epoch = call_frame.call_epoch,
                };
                return .normal;
            },
            .lexical_variable => |lexical_var| {
                const as_cached_lexical_var = try name.prepareToShimmer(CachedLexicalVar);
                as_cached_lexical_var.* = .{
                    .ref = lexical_var,
                    .call_epoch = call_frame.call_epoch,
                };
                return .normal;
            },
        }
    } else {
        return .not_found;
    }
}

/// Ensures that this is a valid variable or upvar. If not, it'll shimmer it to whichever one applies.
/// Returns an error if it's DictSugar, since that requires special handling and there's not a good
/// way to handle it in the general case.
pub fn ensureValidVariableType(
    interp: *Interp,
    det: ?*ErrorDetails,
    var_call_frame: u32,
    name: *Shimmerable,
) error{ OutOfMemory, LookupFailed, BadVariableName }!VariableLookupResult {
    const call_frame = interp.call_frames.items[var_call_frame];

    if (name.current().asType(CachedLocalVar)) |cached_var| {
        // Fast case: if we're in the same epoch as last time, so we don't
        // need to do anything.
        if (cached_var.call_epoch == call_frame.call_epoch) {
            return .normal;
        } else {
            // Need to re-resolve the variable in the current call frame.
            // `name` will be valid after this function completes.
            return try reshimmerToVariable(interp, det, var_call_frame, name);
        }
    } else if (name.current().asType(CachedLexicalVar)) |lexical_var| {
        // Fast case: if we're in the same epoch as last time, we don't need
        // to do anything.
        if (lexical_var.call_epoch == call_frame.call_epoch) {
            return .normal;
        } else {
            // Since this is a lexical value lookup, and the lexical scopes are immutable,
            // the only case where this lookup becomes invalid is if it were shadowed by
            // a local variable.
            if ((try call_frame.variables.getNoFollow(name.current())).asValue()) |_| {
                // Shadowed, so we need to look up again.
                return try reshimmerToVariable(interp, det, var_call_frame, name);
            } else {
                // Wasn't shadowed, so be sure to update its epoch so we don't do
                // this expensive lookup again.
                lexical_var.call_epoch = call_frame.call_epoch;
                return .normal;
            }
        }
    } else if (name.current().asType(DictSugar)) |_| {
        return .dict_sugar;
    }

    // We don't know whether this is a normal variable or dict sugar yet.
    const var_name = try name.current().getString();
    if (try DictSugar.isValidDictSugar(var_name)) return .dict_sugar;

    // Make sure the variable exists.
    return try reshimmerToVariable(interp, det, var_call_frame, name);
}

// Must be called with a heap-native variable name. Does not account for dict sugar.
fn createVariable(interp: *Interp, call_frame_idx: u32, name: *Shimmerable, value: Value) !void {
    const call_frame = &interp.call_frames.items[call_frame_idx];
    call_frame.call_epoch = interp.nextCallEpoch();

    // Add variable. `getMutable` duplicates the dict if it's shared (COW),
    // so the returned pointer is the one we cache in the CachedLocalVar.
    const index = try call_frame.variables.put(name.current(), value);

    const as_cached_local_var = try name.prepareToShimmer(CachedLocalVar);
    as_cached_local_var.* = .{
        .call_epoch = call_frame.call_epoch,
        .dictionary_in = call_frame.variables,
        .index = index,
    };
}

pub fn setVariable(interp: *Interp, det: ?*ErrorDetails, call_frame_idx: u32, name: *Shimmerable, value: Value) error{
    OutOfMemory,
    LookupFailed,
    BadVariableName,
}!void {
    switch (try ensureValidVariableType(interp, det, call_frame_idx, name)) {
        .not_found => {
            try createVariable(interp, call_frame_idx, name, value);
        },
        .dict_sugar => {
            const dict_sugar = try DictSugar.shimmerAssumeValid(name);
            var dict_name: Shimmerable = .{ .original = dict_sugar.dict_name };
            defer dict_name.discardChanges(); // Shouldn't happen in practice, since `dict_name` is threadlocal.

            const call_frame = &interp.call_frames.items[call_frame_idx];

            if (try getVariable(interp, det, call_frame_idx, &dict_name)) |existing_dict| {
                var existing_dict_shim: Shimmerable = .{ .original = existing_dict };
                defer existing_dict_shim.discardChanges();
                _ = Dictionary.shimmerFrom(det, &existing_dict_shim) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.BadDict => return error.LookupFailed,
                };

                if (existing_dict_shim.shimmered.isNone() and existing_dict.canMutate()) {
                    // Mutate in place.
                    const as_dict_mut = existing_dict.asType(Dictionary).?;
                    as_dict_mut.putRecursively(
                        det,
                        objects.ValueSliceContext{ .items = dict_sugar.dict_path.items },
                        value,
                    ) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.BadDict => return error.LookupFailed,
                    };

                    // We've modified the dictionary in place, so nothing
                    // fallible can occur next without breaking atomicity.
                    errdefer comptime unreachable;
                    // Since the variable mutated in place, we need to
                    // invalidate the variable's dictionary's string.
                    call_frame.variables.asHead().invalidateString();
                } else {
                    const new_dict = existing_dict_shim.getMutable(Dictionary, det) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.BadDict => return error.LookupFailed,
                    };
                    defer new_dict.asHead().release();
                    new_dict.putRecursively(
                        det,
                        objects.ValueSliceContext{ .items = dict_sugar.dict_path.items },
                        value,
                    ) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.BadDict => return error.LookupFailed,
                    };
                    try setVariable(interp, det, call_frame_idx, &dict_name, new_dict.asHead().asValue());
                }
            } else {
                // Create a new dictionary, since this variables doesn't exist.
                const new_dict = try Dictionary.new(&.{});
                defer new_dict.asHead().release();

                new_dict.putRecursively(
                    det,
                    objects.ValueSliceContext{ .items = dict_sugar.dict_path.items },
                    value,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.BadDict => unreachable,
                };

                try setVariable(interp, det, call_frame_idx, &dict_name, new_dict.asHead().asValue());
            }
        },
        .normal => {
            if (name.current().asType(CachedLocalVar)) |local_var| {
                const current_value = &local_var.dictionary_in.items[local_var.index];
                if (current_value.asType(UpvarLink)) |link| {
                    var name_shim: Shimmerable = .{ .original = link.linked_name };
                    defer name_shim.discardChanges();
                    // Set the value through the linked name in the linked frame.
                    try setVariable(interp, det, link.call_frame, &name_shim, value);
                } else {
                    current_value.swap(value.borrow());
                    local_var.dictionary_in.asHead().invalidateString();
                }
            } else if (name.current().asType(CachedLexicalVar)) |_| {
                // We can't mutate a lexical var, so we instead shadow it in the local scope.
                try createVariable(interp, call_frame_idx, name, value);
            } else unreachable;
        },
    }
}

pub fn setVariableUpvar(
    interp: *Interp,
    det: ?*ErrorDetails,
    call_frame_idx: u32,
    name: *Shimmerable,
    target_call_frame_idx: u32,
    target_name: Value,
) !void {
    try name.ensureShimmerable();

    switch (try ensureValidVariableType(interp, null, call_frame_idx, name)) {
        .normal => {
            if (name.current().asType(CachedLocalVar) != null) {
                // Variable already exists.
                if (det) |details| details.* = .{ .message = try allocPrintZ(
                    "variable \"{s}\" already exists",
                    .{try name.current().getString()},
                ) };
                return error.VariableAlreadyExists;
            }
            // Else fall through, as we can shadow a lexical variable.
        },
        .not_found => {
            // Fall through.
        },
        .dict_sugar => {
            if (det) |details| details.* = .{
                .message = try allocPrintZ("cannot create an upvar name that has dict sugar", .{}),
            };
            return error.DictSugarInUpvarName;
        },
    }

    // Check for cycles (only possible with `upvar 0`, such as `upvar 0 x y; upvar 0 y x`).
    if (call_frame_idx == target_call_frame_idx) {
        // Traverse the upvar chain until either we reach the end of the chain
        // or we find ourselves.
        var obj_currently_checking = target_name;
        while (true) {
            if (try name.current().equals(obj_currently_checking)) {
                // We'd create a circular reference at this point, since
                // we managed to find ourselves when traversing the upvar
                // chain. Obviously, we can't let this happen.
                if (det) |details| details.* = .{
                    .message = try allocPrintZ("can't upvar from variable to itself", .{}),
                };
                return error.CircularUpvar;
            }

            // See what kind of variable this is, so we can determine whether it has
            // the potential for a cycle.
            var obj_currently_checking_shim: Shimmerable = .{ .original = obj_currently_checking };
            defer obj_currently_checking_shim.discardChanges();
            const ensure_result = ensureValidVariableType(
                interp,
                det,
                target_call_frame_idx,
                &obj_currently_checking_shim,
            ) catch |err| switch (err) {
                error.LookupFailed => return error.LookupFailed,
                error.OutOfMemory => return error.OutOfMemory,
                error.BadVariableName => {
                    // If the target var doesn't exist, then of course the var name != nothing,
                    // so it's not equal to itself.
                    break;
                },
            };
            switch (ensure_result) {
                .dict_sugar => {
                    // `name` can never be dict sugar, which means we can never have circular dict
                    // sugar to dict sugar. Hence, it's safe to conclude there's no cycle here.
                    break;
                },
                .not_found => {
                    // If the target var doesn't exist, then of course the var name != nothing,
                    // so it's not equal to itself.
                    break;
                },
                .normal => {
                    // Can't use `getVariable` here, as it follows upvars.
                    if (obj_currently_checking.asType(CachedLocalVar)) |local_var| {
                        if (local_var.getCurrentValue().asType(UpvarLink)) |upvar_link| {
                            // Keep traversing.
                            obj_currently_checking = upvar_link.linked_name;
                        } else {
                            break; // Not upvar, so chain is broken.
                        }
                    } else {
                        break; // It's not a variable in the local scope, so the chain is broken.
                    }
                },
            }
        }
    }

    const target_name_duped = try target_name.duplicateAsBoxed();
    defer target_name_duped.release();
    const link = try Object.newObject(UpvarLink);
    defer link.head.release();
    link.body.* = .{
        .call_frame = target_call_frame_idx,
        .linked_name = target_name_duped.borrow().asValue(),
    };

    try setVariable(interp, det, call_frame_idx, name, link.head.asValue());
}

pub fn unsetVariable(
    interp: *Interp,
    det: ?*ErrorDetails,
    call_frame_idx: u32,
    name: *Shimmerable,
) !void {
    switch (try ensureValidVariableType(interp, det, call_frame_idx, name)) {
        .not_found => {
            if (det) |details| details.* = .{
                .message = try allocPrintZ("can't unset \"{s}\": no such variable", .{try name.current().getString()}),
            };
            return error.VariableNotFound;
        },
        .dict_sugar => {
            const dict_sugar = try DictSugar.shimmerAssumeValid(name);
            var dict_name_shim: Shimmerable = .{ .original = dict_sugar.dict_name };
            defer dict_name_shim.discardChanges(); // Shouldn't happen in practice, since `dict_name` is threadlocal.

            const resolved_dict = try getVariable(interp, null, call_frame_idx, &dict_name_shim) orelse {
                if (det) |details| details.* = .{
                    .message = try allocPrintZ("can't unset \"{s}\": no such element in dictionary", .{try name.current().getString()}),
                };
                return error.VariableNotFound;
            };
            var resolved_dict_shim: Shimmerable = .{ .original = resolved_dict };
            defer resolved_dict_shim.discardChanges();
            _ = try Dictionary.shimmerFrom(det, &resolved_dict_shim);

            const dict_items = objects.ValueSliceContext{ .items = dict_sugar.dict_path.items };
            const did_remove = blk: {
                if (resolved_dict_shim.current().canMutate()) {
                    const as_dict_mut = resolved_dict_shim.current().asType(Dictionary).?;
                    const did_remove = as_dict_mut.removeRecursively(null, dict_items) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {
                            if (det) |details| details.* = .{ .message = try allocPrintZ(
                                "can't unset \"{s}\": no such element in dictionary",
                                .{try name.current().getString()},
                            ) };
                            return error.VariableNotFound;
                        },
                    };
                    interp.call_frames.items[call_frame_idx].variables.asHead().invalidateString();
                    break :blk did_remove;
                } else {
                    const new_dict = try resolved_dict_shim.getMutable(Dictionary, det);
                    defer new_dict.asHead().release();
                    const did_remove = new_dict.removeRecursively(det, dict_items) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {
                            if (det) |details| details.* = .{ .message = try allocPrintZ(
                                "can't unset \"{s}\": no such element in dictionary",
                                .{try name.current().getString()},
                            ) };
                            return error.VariableNotFound;
                        },
                    };
                    try setVariable(interp, null, call_frame_idx, &dict_name_shim, new_dict.asHead().asValue());
                    break :blk did_remove;
                }
            };

            if (!did_remove) {
                if (det) |details| details.* = .{ .message = try allocPrintZ(
                    "can't unset \"{s}\": no such element in dictionary",
                    .{try name.current().getString()},
                ) };
                return error.VariableNotFound;
            }
            return;
        },
        .normal => {
            // Fall through.
        },
    }

    if (name.current().asType(CachedLocalVar)) |local_var| {
        // If this local variable is an upvar link, unset through the link rather
        // than removing the link itself from this scope.
        const current_value = &local_var.dictionary_in.items[local_var.index];
        if (current_value.asType(UpvarLink)) |link| {
            var name_shim: Shimmerable = .{ .original = link.linked_name };
            defer name_shim.discardChanges();
            try unsetVariable(interp, det, link.call_frame, &name_shim);
            return;
        }

        const call_frame = &interp.call_frames.items[call_frame_idx];
        const did_remove = try call_frame.variables.remove(det, name.current());
        if (!did_remove) {
            if (det) |details| details.* = .{
                .message = try allocPrintZ("can't unset \"{s}\": no such variable", .{try name.current().getString()}),
            };
            return error.VariableNotFound;
        }
        call_frame.call_epoch = interp.nextCallEpoch();
    } else if (name.current().asType(CachedLexicalVar)) |_| {
        // A lexical variable lives in a parent scope, not this frame's
        // variables dictionary, so there's no local slot to remove.
        if (det) |details| details.* = .{
            .message = try allocPrintZ("can't unset \"{s}\": no such variable", .{try name.current().getString()}),
        };
        return error.VariableNotFound;
    } else unreachable;
}

/// Resolves to the variable's value.
pub fn getVariable(interp: *Interp, det: ?*ErrorDetails, call_frame_idx: u32, name: *Shimmerable) error{
    OutOfMemory,
    LookupFailed,
    BadVariableName,
}!?Value {
    switch (try ensureValidVariableType(interp, det, call_frame_idx, name)) {
        .not_found => return null,
        .dict_sugar => {
            const dict_sugar = try DictSugar.shimmerAssumeValid(name);

            var dict_name: Shimmerable = .{ .original = dict_sugar.dict_name };
            defer dict_name.discardChanges(); // Shouldn't happen in practice, since `dict_name` is threadlocal.
            const resolved_dict = try getVariable(interp, det, call_frame_idx, &dict_name) orelse return null;
            var resolved_dict_shim: Shimmerable = .{ .original = resolved_dict };
            defer resolved_dict_shim.discardChanges();
            const lookup_ctx = objects.ValueSliceContext{ .items = dict_sugar.dict_path.items };
            const result = Dictionary.getRecursively(null, &resolved_dict_shim, lookup_ctx) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    if (det) |details| details.* = .{ .message = try allocPrintZ(
                        "variable \"{s}\" is not a valid dictionary",
                        .{try dict_sugar.dict_name.getString()},
                    ) };
                    return error.LookupFailed;
                },
            };

            if (resolved_dict_shim.shimmered.asValue()) |new| {
                try setVariable(interp, det, call_frame_idx, &dict_name, new);
            }

            return result.asValue();
        },
        .normal => {
            // Fall through.
        },
    }

    if (name.current().asType(CachedLocalVar)) |local_var| {
        const resolved = local_var.dictionary_in.items[local_var.index];
        if (resolved.asType(UpvarLink)) |upvar_link| {
            // Recursively follow upvar.
            var name_in_other_scope: Shimmerable = .{ .original = upvar_link.linked_name };
            defer name_in_other_scope.discardChanges();
            return try getVariable(interp, det, upvar_link.call_frame, &name_in_other_scope);
        } else {
            return local_var.dictionary_in.items[local_var.index];
        }
    } else if (name.current().asType(CachedLexicalVar)) |lexical_var| {
        return lexical_var.ref;
    } else unreachable;
}

pub fn getVariableOrError(
    interp: *Interp,
    det: ?*ErrorDetails,
    call_frame_idx: u32,
    name: *Shimmerable,
) error{ VariableNotFound, OutOfMemory, LookupFailed, BadVariableName }!Value {
    return try getVariable(interp, det, call_frame_idx, name) orelse {
        if (det) |details| details.* = .{
            .message = try allocPrintZ("can't read \"{s}\": no such variable", .{try name.current().getString()}),
        };
        return error.VariableNotFound;
    };
}

pub fn expectErrorOrOom(expected_error: anyerror, actual_error_union: anytype) !void {
    if (actual_error_union) |_| {
        try testing.expectError(expected_error, actual_error_union);
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => try testing.expectError(expected_error, actual_error_union),
    }
}
fn testVariables(ta: std.mem.Allocator) !void {
    try heap.testStart(ta, testing.io);
    defer heap.testFinish();
    var interp = try Interp.init(.{});
    defer interp.deinit();

    var str_foo: Shimmerable = .{ .original = try objects.String.newValue("foo") };
    defer str_foo.deinit();

    // Make sure it doesn't resolve to anything.
    try testing.expect(null == try resolveVariable(&interp, null, 0, str_foo.current()));

    const str_value = try objects.String.newValue("value");
    defer str_value.release();
    try setVariable(&interp, null, 0, &str_foo, str_value);

    const cached_lookup = (try resolveVariable(&interp, null, 0, str_foo.current())).?.local_variable;
    const cached_lookup_value = cached_lookup.dictionary_in.items[cached_lookup.index];
    try testing.expectEqualStrings("value", try cached_lookup_value.getString());
    // Also try resolving the value from a new string.
    const str2_foo = try objects.String.newValue("foo");
    defer str2_foo.release();
    const lookup = (try resolveVariable(&interp, null, 0, str2_foo)).?.local_variable;
    const lookup_value = lookup.dictionary_in.items[lookup.index];
    try testing.expectEqualStrings("value", try lookup_value.getString());

    // Next, we test dict sugar.
    var str_foo_bar: Shimmerable = .{ .original = try objects.String.newValue("foo::bar") };
    defer str_foo_bar.deinit();
    const str_baz = try objects.String.newValue("baz");
    defer str_baz.release();

    // Make sure trying to read a dict value fails when it's not a dict.
    try expectErrorOrOom(error.LookupFailed, getVariable(&interp, null, 0, &str_foo_bar));

    // Clear foo so we can set it to a dictionary.
    try setVariable(&interp, null, 0, &str_foo, heap.interned_empty_string);
    try setVariable(&interp, null, 0, &str_foo_bar, str_baz);

    try testing.expectEqual(str_baz.asPtr().?, (try getVariable(&interp, null, 0, &str_foo_bar)).?.asPtr().?);
}

test "variable basics" {
    try testing.checkAllAllocationFailures(testing.allocator, testVariables, .{});
}

fn testVariableLink(ta: std.mem.Allocator) !void {
    try heap.testStart(ta, testing.io);
    defer heap.testFinish();
    var interp = try Interp.init(.{});
    defer interp.deinit();

    // Create a variable `foo` containing `value`, then upvar `bar` to `foo`.
    var str_foo: Shimmerable = .{ .original = try objects.String.newValue("foo") };
    defer str_foo.deinit();

    try testing.expect(null == try resolveVariable(&interp, null, 0, str_foo.current()));
    const str_value = try objects.String.newValue("value");
    defer str_value.release();
    try setVariable(&interp, null, 0, &str_foo, str_value);

    var str_bar: Shimmerable = .{ .original = try objects.String.newValue("bar") };
    defer str_bar.deinit();
    try setVariableUpvar(&interp, null, 0, &str_bar, 0, str_foo.current());

    // Make sure we can get the value of `foo` through `bar`.
    var lookup_value = (try getVariable(&interp, null, 0, &str_bar)).?;
    try testing.expectEqualStrings("value", try lookup_value.getString());

    // Modify `foo` through `bar`.
    const str_new_value = try objects.String.newValue("new value");
    defer str_new_value.release();
    try setVariable(&interp, null, 0, &str_bar, str_new_value);
    lookup_value = (try getVariable(&interp, null, 0, &str_foo)).?;
    try testing.expectEqualStrings("new value", try lookup_value.getString());
}

test "variable link" {
    try testing.checkAllAllocationFailures(testing.allocator, testVariableLink, .{});
}

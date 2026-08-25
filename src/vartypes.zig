const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

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

/// What a single variable slot holds. An upvar is a variant here rather than its
/// own object type, since a slot is never handed to Tcl as a value: only the
/// resolved target of an upvar ever escapes the table.
pub const VariableSlot = union(enum) {
    normal: Value,
    upvar: Upvar,

    pub const Upvar = struct {
        /// The name of the variable in the linked scope. Whenever someone
        /// shimmers this to a variable, they should always do it in `call_frame`.
        linked_name: Value,
        /// The call frame the linked variable lives in.
        call_frame: u32,
    };

    pub fn takeReference(slot: VariableSlot) VariableSlot {
        switch (slot) {
            .normal => |value| _ = value.takeReference(),
            .upvar => |link| _ = link.linked_name.takeReference(),
        }
        return slot;
    }

    pub fn dropReference(slot: VariableSlot) void {
        switch (slot) {
            .normal => |value| value.dropReference(),
            .upvar => |link| link.linked_name.dropReference(),
        }
    }
};

/// The variables of one call frame.
///
/// This is deliberately not an `Object`, which buys three things a `Dictionary`
/// could not. It is never handed to Tcl as a value (`Interp.captureScope`
/// materializes a separate `Dictionary` for that), so it has no string
/// representation to keep in sync and no invalidate-on-every-write obligation.
/// Not being a value, it also cannot be referenced, so a frame's variables can
/// never outlive the frame that owns them. And having no vtable, it can never
/// shimmer away from being a table, which a shared `Dictionary` always could.
///
/// Insertion order is preserved for two reasons. `captureScope`'s output is
/// content-hashed into the `HashRegistry`, so two structurally identical scopes
/// must iterate identically or they hash differently and stop sharing. Ordering
/// is also the least surprising behavior, given that Tcl dictionaries are
/// ordered and variables have no reason to differ.
pub const VarTable = struct {
    map: Map,

    /// Both of these are infallible, since `cacheQuickHash` ensured
    /// that hashes exist, and by extension, that they both have a string rep.
    const Context = struct {
        pub fn hash(_: Context, key: Value) u32 {
            return @truncate(heap.hashutil.quickHash(key) catch unreachable);
        }
        pub fn eql(_: Context, a: Value, b: Value, _: usize) bool {
            return a.equals(b) catch unreachable;
        }
    };

    const Map = std.array_hash_map.Custom(Value, VariableSlot, Context, true);

    pub const empty: VarTable = .{ .map = .empty };

    /// Allocate an empty table. Call frames hold these by pointer so that
    /// `CachedLocalVar` survives `Interp.call_frames` reallocating.
    pub fn create() !*VarTable {
        const table = try heap.global_gpa.create(VarTable);
        table.* = .empty;
        return table;
    }

    pub fn destroy(table: *VarTable) void {
        for (table.map.keys()) |key| key.dropReference();
        for (table.map.values()) |slot| slot.dropReference();
        table.map.deinit(heap.global_gpa);
        heap.global_gpa.destroy(table);
    }

    pub fn count(table: *const VarTable) usize {
        return table.map.count();
    }

    pub fn getIndex(table: *const VarTable, name: Value) error{OutOfMemory}!?usize {
        try heap.hashutil.cacheQuickHash(name);
        return table.map.getIndex(name);
    }

    pub fn slotAt(table: *VarTable, index: usize) *VariableSlot {
        return &table.map.values()[index];
    }

    /// Insert or overwrite `name`, referencing both the name and the slot's
    /// contents. Returns the entry's index, which is stable until a variable is
    /// removed from this frame (which bumps the frame's call epoch).
    pub fn put(table: *VarTable, name: Value, slot: VariableSlot) !usize {
        try heap.hashutil.cacheQuickHash(name);
        const result = try table.map.getOrPut(heap.global_gpa, name);
        if (result.found_existing) {
            result.value_ptr.dropReference();
        } else {
            result.key_ptr.* = name.takeReference();
        }
        result.value_ptr.* = slot.takeReference();
        return result.index;
    }

    /// Remove `name`, returning whether it was present. Ordered so that the
    /// iteration order the capture hash depends on survives the removal.
    pub fn remove(table: *VarTable, name: Value) error{OutOfMemory}!bool {
        try heap.hashutil.cacheQuickHash(name);
        const entry = table.map.fetchOrderedRemove(name) orelse return false;
        entry.key.dropReference();
        entry.value.dropReference();
        return true;
    }
};

pub const CachedLocalVar = struct {
    table_in: *VarTable,
    index: usize,
    call_epoch: u64,

    pub fn asHead(self: *CachedLocalVar) *Object {
        return Object.from(CachedLocalVar, self);
    }

    fn makeCrossthread(obj: *Object) void {
        assert(obj.maybeGetString() != null);
        obj.vtable = &objects.None.vtable;
    }

    pub fn getCurrentSlot(self: *const CachedLocalVar) *VariableSlot {
        return self.table_in.slotAt(self.index);
    }

    pub const vtable: Object.VTable = .zig(@typeName(CachedLocalVar), .{
        .duplicate = Object.duplicateStringOnly,
        .update_string = null,
        .free_internal_rep = null,
        .make_crossthread = makeCrossthread,
        // TODO it would be nice to be able to walk the cached local var,
        // but we'd need the call epoch invalidation logic embedded in it.
        .enumerate_struct = null,
    });
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
        assert(obj.maybeGetString() != null);
        obj.vtable = &objects.None.vtable;
    }

    pub const vtable: Object.VTable = .zig(@typeName(CachedLexicalVar), .{
        .duplicate = Object.duplicateStringOnly,
        .update_string = null,
        .free_internal_rep = null,
        .make_crossthread = makeCrossthread,
        // TODO same issue as `CachedLocalVar.vtable`.
        .enumerate_struct = null,
    });
};

/// `dict_name` points to an object that contains the name of the dictionary
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

    fn isValidDictSugar(var_name: [:0]const u8) bool {
        const double_colons = std.mem.find(u8, var_name, "::");
        // Must have at least one set of double colons.
        const start_at = if (double_colons) |val| val else return false;

        // Can't have dict sugar start with colons.
        if (start_at == 0) return false;
        // Also can't end with colons.
        const ending_colons = std.mem.lastIndexOf(u8, var_name, "::").?;
        if (ending_colons == var_name.len - 2) return false;

        return true;
    }

    pub fn parseDictSugar(det: ?*ErrorDetails, var_name: [:0]const u8) error{ BadVariableName, OutOfMemory }!?struct {
        dict_name: Value,
        dict_path: *objects.List,
    } {
        if (!isValidDictSugar(var_name)) return null;

        const start_at = std.mem.find(u8, var_name, "::").?;
        const dict_name = try objects.String.newValue(var_name[0..start_at]);
        errdefer dict_name.dropReference();

        var dict_path: *objects.List = try objects.List.new(&.{});
        errdefer dict_path.asHead().dropReference();

        var last_path_start: ?usize = null;
        var i = start_at;
        while (i <= var_name.len) : (i += 1) {
            if (i == var_name.len or (var_name[i] == ':' and var_name[i + 1] == ':')) {
                if (last_path_start) |val| {
                    const path_section = var_name[val..i];
                    // No part of the path can contain `~parent`, since that would allow for
                    // dict sugar to traverse up the parent chain.
                    if (std.mem.eql(u8, path_section, "~parent")) return badVariableNameError(det, path_section);

                    const path_section_value = try objects.String.newValue(path_section);
                    defer path_section_value.dropReference();
                    try dict_path.append(path_section_value);
                }

                // Keep advancing until we've passed the colon(s).
                while (i < var_name.len and var_name[i + 1] == ':') i += 1;
                last_path_start = i + 1;
            }
        }

        return .{ .dict_name = dict_name, .dict_path = dict_path };
    }

    fn freeInternalRep(src: *Object) void {
        const as_dict_sugar = src.asType(DictSugar).?;
        as_dict_sugar.dict_name.dropReference();
        as_dict_sugar.dict_path.asHead().dropReference();
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

    pub const vtable: Object.VTable = .zig(@typeName(DictSugar), .{
        .duplicate = Object.duplicateStringOnly,
        .free_internal_rep = freeInternalRep,
        .update_string = null,
        .make_crossthread = makeCrossthread,
        .enumerate_struct = enumerateStruct,
    });
};

const VariableLookupResult = enum { not_found, dict_sugar, normal };
pub const VariableValue = union(enum) {
    local_variable: struct {
        table_in: *VarTable,
        index: usize,
    },
    /// Variable in a parent scope. Immutable.
    lexical_variable: Value,
};

pub fn badVariableNameError(det: ?*ErrorDetails, name: []const u8) error{ OutOfMemory, BadVariableName } {
    if (det) |details| details.* = .{
        .message = try objects.allocPrintZ("bad variable name: \"{s}\"", .{name}),
    };
    return error.BadVariableName;
}

/// Resolves to the variable's value, if any. Does not account for dict sugar.
fn resolveVariable(interp: *Interp, det: ?*ErrorDetails, var_call_frame: u32, var_name: Value) error{
    OutOfMemory,
    LookupFailed,
    BadVariableName,
}!?VariableValue {
    if (var_name.asPtr()) |obj| _ = try obj.getString();

    // `~parent` is reserved for the lexical scope link, so it can never name a
    // variable. Note that the reservation holds even though the variables table
    // has no `~parent` key of its own, because `Interp.captureScope` writes one
    // into the dictionary it produces.
    if (try var_name.equals(objects.interned_tilde_parent)) return badVariableNameError(det, "~parent");

    const var_table = interp.call_frames.items[var_call_frame].variables;
    const maybe_letrec_scope = &interp.call_frames.items[var_call_frame].signature.letrec_scope;
    const maybe_scope = &interp.call_frames.items[var_call_frame].signature.scope;

    if (try var_table.getIndex(var_name)) |index| {
        return .{
            .local_variable = .{
                .table_in = var_table,
                .index = index,
            },
        };
    }

    // Wasn't in the variables, maybe it's in a parent scope instead?
    if (maybe_letrec_scope.*) |*letrec_scope| {
        var dict_shim: Shimmerable = .{ .original = letrec_scope.*.asHead().asValue() };
        defer dict_shim.discardChanges();
        const in_linked_scope = try Dictionary.shimGetFollowingLinks(det, &dict_shim, var_name);

        if (dict_shim.takeShimmered().asValue()) |new_dict| {
            const old_inner = letrec_scope.*;
            letrec_scope.* = new_dict.asType(Dictionary).?; // Shimmer writeback.
            old_inner.asHead().dropReference();
        }

        if (in_linked_scope) |val| {
            return .{ .lexical_variable = val };
        }
    }

    if (maybe_scope.*) |*scope| {
        var dict_shim: Shimmerable = .{ .original = scope.*.asHead().asValue() };
        defer dict_shim.discardChanges();
        const in_linked_scope = try objects.Dictionary.shimGetFollowingLinks(det, &dict_shim, var_name);

        if (dict_shim.takeShimmered().asValue()) |new_dict| {
            const old_inner = scope.*;
            scope.* = new_dict.asType(Dictionary).?; // Shimmer writeback.
            old_inner.asHead().dropReference();
        }

        if (in_linked_scope) |val| {
            return .{ .lexical_variable = val };
        }
    }

    return null;
}

/// This always recalculates the variable. You probably should be using `ensureValidVariableType`.
/// Does not account for dict sugar.
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
                    .table_in = local_var.table_in,
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
        // Fast case: if we're in the same epoch as last time, we don't need
        // to do anything.
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
            if (try call_frame.variables.getIndex(name.current()) != null) {
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
    if (try DictSugar.parseDictSugar(det, var_name)) |parsed| {
        errdefer parsed.dict_name.dropReference();
        errdefer parsed.dict_path.asHead().dropReference();

        const as_dict_sugar = try name.prepareToShimmer(DictSugar);
        as_dict_sugar.* = .{
            .dict_name = parsed.dict_name,
            .dict_path = parsed.dict_path,
        };
        return .dict_sugar;
    } else {
        // Not dict sugar, so fall through.
    }

    // Make sure the variable exists.
    return try reshimmerToVariable(interp, det, var_call_frame, name);
}

// Must be called with a heap-native variable name. Does not account for dict sugar.
fn createVariable(interp: *Interp, call_frame_idx: u32, name: *Shimmerable, slot: VariableSlot) !void {
    const call_frame = &interp.call_frames.items[call_frame_idx];

    // `prepareToShimmer` below preserves the string rep, so the key stays valid
    // even though it is the same object the name shimmers into.
    const index = try call_frame.variables.put(name.current(), slot);
    call_frame.call_epoch = interp.nextCallEpoch();

    // Failing here leaves the variable set but uncached, which the next lookup
    // recovers from by re-resolving.
    const as_cached_local_var = try name.prepareToShimmer(CachedLocalVar);
    as_cached_local_var.* = .{
        .call_epoch = call_frame.call_epoch,
        .table_in = call_frame.variables,
        .index = index,
    };
}

fn dictSugarReadInner(
    interp: *Interp,
    det: ?*ErrorDetails,
    call_frame_idx: u32,
    dict_sugar: *DictSugar,
    get_for_mutation: bool,
) !?Value {
    var dict_name: Shimmerable = .{ .original = dict_sugar.dict_name };
    defer dict_name.discardChanges();
    const resolved_dict = try getVariableInner(interp, det, call_frame_idx, &dict_name, false) orelse return null;

    var resolved_dict_shim: Shimmerable = .{ .original = resolved_dict };
    defer resolved_dict_shim.discardChanges();
    _ = try Dictionary.shimmerFrom(det, &resolved_dict_shim);

    const lookup_ctx = objects.ValueSliceContext{ .items = dict_sugar.dict_path.items };
    if (get_for_mutation) {
        if (resolved_dict_shim.shimmered.isNone() and resolved_dict.canMutate()) {
            return try resolved_dict.asType(Dictionary).?.getRecursivelyAllMutable(det, lookup_ctx);
        } else {
            const dict_mut = try resolved_dict_shim.getMutable(Dictionary, det);
            defer dict_mut.asHead().dropReference();
            const looked_up = try dict_mut.getRecursivelyAllMutable(det, lookup_ctx);
            try setVariable(interp, det, call_frame_idx, &dict_name, dict_mut.asHead().asValue());
            return looked_up;
        }
    } else {
        const looked_up = Dictionary.getRecursively(null, &resolved_dict_shim, lookup_ctx) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return badDictSugar(det, try dict_sugar.dict_name.getString()),
        };
        if (resolved_dict_shim.shimmered.asValue()) |new_dict|
            try setVariable(interp, det, call_frame_idx, &dict_name, new_dict);
        if (dict_name.shimmered.asValue()) |new_dict_name| dict_sugar.dict_name.swap(new_dict_name);

        return looked_up;
    }
}

fn dictSugarRead(
    interp: *Interp,
    det: ?*ErrorDetails,
    call_frame_idx: u32,
    dict_sugar: *DictSugar,
    get_for_mutation: bool,
) error{ OutOfMemory, LookupFailed, BadVariableName }!?Value {
    return dictSugarReadInner(interp, det, call_frame_idx, dict_sugar, get_for_mutation) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadDict => {
            if (det) |details| heap.global_gpa.free(details.message);
            return badDictSugar(det, try dict_sugar.dict_name.getString());
        },
        error.LookupFailed => return error.LookupFailed,
        error.BadVariableName => return error.BadVariableName,
    };
}

fn dictSugarWriteInner(
    interp: *Interp,
    det: ?*ErrorDetails,
    call_frame_idx: u32,
    dict_sugar: *DictSugar,
    value: Value,
) !void {
    const put_ctx = objects.ValueSliceContext{ .items = dict_sugar.dict_path.items };

    var dict_name: Shimmerable = .{ .original = dict_sugar.dict_name };
    defer dict_name.discardChanges();

    const resolved_dict = try getVariableInner(interp, det, call_frame_idx, &dict_name, false) orelse {
        // Create a new dictionary, since this variable doesn't exist.
        const new_dict = try Dictionary.new(&.{});
        defer new_dict.asHead().dropReference();

        new_dict.putRecursively(det, put_ctx, value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadDict => unreachable, // Freshly built, so it is a dict.
        };

        try setVariable(interp, det, call_frame_idx, &dict_name, new_dict.asHead().asValue());
        return;
    };

    const as_mut_in_place = try resolved_dict.asMutableInPlace(Dictionary, det);
    if (as_mut_in_place) |dict_mut| {
        try dict_mut.putRecursively(det, put_ctx, value);
    } else {
        const dict_mut = try resolved_dict.duplicateAsType(Dictionary, det);
        defer dict_mut.asHead().dropReference();
        try dict_mut.putRecursively(det, put_ctx, value);
        try setVariable(interp, det, call_frame_idx, &dict_name, dict_mut.asHead().asValue());
    }
}

fn dictSugarWrite(
    interp: *Interp,
    det: ?*ErrorDetails,
    call_frame_idx: u32,
    dict_sugar: *DictSugar,
    value: Value,
) error{ OutOfMemory, LookupFailed, BadVariableName }!void {
    dictSugarWriteInner(interp, det, call_frame_idx, dict_sugar, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadDict => {
            if (det) |details| heap.global_gpa.free(details.message);
            return badDictSugar(det, try dict_sugar.dict_name.getString());
        },
        error.LookupFailed => return error.LookupFailed,
        error.BadVariableName => return error.BadVariableName,
    };
}

pub fn setVariable(interp: *Interp, det: ?*ErrorDetails, call_frame_idx: u32, name: *Shimmerable, value: Value) error{
    OutOfMemory,
    LookupFailed,
    BadVariableName,
}!void {
    switch (try ensureValidVariableType(interp, det, call_frame_idx, name)) {
        .not_found => {
            try createVariable(interp, call_frame_idx, name, .{ .normal = value });
        },
        .dict_sugar => {
            const as_dict_sugar = name.current().asType(DictSugar).?;
            try dictSugarWrite(interp, det, call_frame_idx, as_dict_sugar, value);
        },
        .normal => {
            if (name.current().asType(CachedLocalVar)) |local_var| {
                switch (local_var.getCurrentSlot().*) {
                    .upvar => |link| {
                        var name_shim: Shimmerable = .{ .original = link.linked_name };
                        defer name_shim.discardChanges();
                        // Set the value through the linked name in the linked frame.
                        try setVariable(interp, det, link.call_frame, &name_shim, value);
                    },
                    .normal => {
                        const slot = local_var.getCurrentSlot();
                        slot.dropReference();
                        slot.* = .{ .normal = value.takeReference() };
                    },
                }
            } else if (name.current().asType(CachedLexicalVar)) |_| {
                // We can't mutate a lexical var, so we instead shadow it in the local scope.
                try createVariable(interp, call_frame_idx, name, .{ .normal = value });
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
                        switch (local_var.getCurrentSlot().*) {
                            // Keep traversing.
                            .upvar => |link| obj_currently_checking = link.linked_name,
                            .normal => break, // Not upvar, so chain is broken.
                        }
                    } else {
                        break; // It's not a variable in the local scope, so the chain is broken.
                    }
                },
            }
        }
    }

    // Duplicated so the link is unaffected by whatever the caller's name object
    // later shimmers into.
    const target_name_duped = try target_name.duplicateAsBoxed();
    defer target_name_duped.dropReference();

    const slot: VariableSlot = .{ .upvar = .{
        .call_frame = target_call_frame_idx,
        .linked_name = target_name_duped.asValue(),
    } };

    // An upvar always occupies a slot of its own: `ensureValidVariableType` above
    // rejected the case where a local of this name already exists, so anything
    // still here is a lexical variable this link shadows.
    try createVariable(interp, call_frame_idx, name, slot);
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
            const dict_sugar = name.current().asType(DictSugar).?;
            var dict_name_shim: Shimmerable = .{ .original = dict_sugar.dict_name };
            defer dict_name_shim.discardChanges(); // Shouldn't happen in practice, since `dict_name` is threadlocal.

            const resolved_dict = try getVariableForMutation(interp, null, call_frame_idx, &dict_name_shim) orelse {
                if (det) |details| details.* = .{
                    .message = try allocPrintZ("can't unset \"{s}\": no such element in dictionary", .{try name.current().getString()}),
                };
                return error.VariableNotFound;
            };
            const path = objects.ValueSliceContext{ .items = dict_sugar.dict_path.items };

            if (try resolved_dict.asMutableInPlace(Dictionary, det)) |dict_mut| {
                // Start transaction.
                const removed = dict_mut.removeRecursively(null, path) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => false,
                };
                if (!removed) {
                    // Didn't complete/didn't remove, so aborting the transaction is safe here.
                    if (det) |details| details.* = .{ .message = try allocPrintZ(
                        "can't unset \"{s}\": no such element in dictionary",
                        .{try name.current().getString()},
                    ) };
                    return error.VariableNotFound;
                }
                return; // End transaction.
            } else {
                const duped = try resolved_dict.duplicateAsType(Dictionary, det);
                defer duped.asHead().dropReference();
                const removed = duped.removeRecursively(null, path) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => false,
                };
                if (!removed) {
                    if (det) |details| details.* = .{ .message = try allocPrintZ(
                        "can't unset \"{s}\": no such element in dictionary",
                        .{try name.current().getString()},
                    ) };
                    return error.VariableNotFound;
                }
                try setVariable(interp, null, call_frame_idx, &dict_name_shim, duped.asHead().asValue());
                return;
            }
        },
        .normal => {
            // Fall through.
        },
    }

    if (name.current().asType(CachedLocalVar)) |local_var| {
        // If this local variable is an upvar link, unset through the link rather
        // than removing the link itself from this scope.
        if (local_var.getCurrentSlot().* == .upvar) {
            const link = local_var.getCurrentSlot().upvar;
            var name_shim: Shimmerable = .{ .original = link.linked_name };
            defer name_shim.discardChanges();
            try unsetVariable(interp, det, link.call_frame, &name_shim);
            return;
        }

        const call_frame = &interp.call_frames.items[call_frame_idx];
        const did_remove = try call_frame.variables.remove(name.current());
        if (!did_remove) {
            if (det) |details| details.* = .{
                .message = try allocPrintZ("can't unset \"{s}\": no such variable", .{try name.current().getString()}),
            };
            return error.VariableNotFound;
        }
        call_frame.call_epoch = interp.nextCallEpoch();
    } else if (name.current().asType(CachedLexicalVar)) |_| {
        // A lexical variable lives in a parent scope, not this frame's
        // variables table, so there's no local slot to remove.
        if (det) |details| details.* = .{
            .message = try allocPrintZ("can't unset \"{s}\": no such variable", .{try name.current().getString()}),
        };
        return error.VariableNotFound;
    } else unreachable;
}

fn badDictSugar(det: ?*ErrorDetails, variable_name: []const u8) error{ OutOfMemory, LookupFailed } {
    if (det) |details| details.* = .{
        .message = try allocPrintZ("variable \"{s}\" is not a valid dictionary", .{variable_name}),
    };
    return error.LookupFailed;
}

pub fn getVariableInner(
    interp: *Interp,
    det: ?*ErrorDetails,
    call_frame_idx: u32,
    name: *Shimmerable,
    get_for_mutation: bool,
) error{ OutOfMemory, LookupFailed, BadVariableName }!?Value {
    switch (try ensureValidVariableType(interp, det, call_frame_idx, name)) {
        .not_found => return null,
        .dict_sugar => {
            const as_dict_sugar = name.current().asType(DictSugar).?;
            return try dictSugarRead(interp, det, call_frame_idx, as_dict_sugar, get_for_mutation);
        },
        .normal => {
            // Fall through.
        },
    }

    if (name.current().asType(CachedLocalVar)) |local_var| {
        switch (local_var.getCurrentSlot().*) {
            .upvar => |*link| {
                // Recursively follow upvar.
                var name_in_other_scope: Shimmerable = .{ .original = link.linked_name };
                defer name_in_other_scope.discardChanges();
                const lookup_result = try getVariableInner(interp, det, link.call_frame, &name_in_other_scope, get_for_mutation);
                if (name_in_other_scope.shimmered.asValue()) |shimmered| link.linked_name.swap(shimmered);
                return lookup_result;
            },
            .normal => |value| {
                return value;
            },
        }
    } else if (name.current().asType(CachedLexicalVar)) |lexical_var| {
        return lexical_var.ref;
    } else unreachable;
}

pub fn getVariableForMutation(interp: *Interp, det: ?*ErrorDetails, call_frame_idx: u32, name: *Shimmerable) error{
    OutOfMemory,
    LookupFailed,
    BadVariableName,
}!?Value {
    return try getVariableInner(interp, det, call_frame_idx, name, true);
}

/// Resolves to the variable's value.
pub fn getVariableTakingRef(interp: *Interp, det: ?*ErrorDetails, call_frame_idx: u32, name: *Shimmerable) error{
    OutOfMemory,
    LookupFailed,
    BadVariableName,
}!?Value {
    const get_result = try getVariableInner(interp, det, call_frame_idx, name, false);
    return if (get_result) |val| val.takeReference() else null;
}

pub fn getVariableTakingRefOrError(
    interp: *Interp,
    det: ?*ErrorDetails,
    call_frame_idx: u32,
    name: *Shimmerable,
) error{ VariableNotFound, OutOfMemory, LookupFailed, BadVariableName }!Value {
    return try getVariableTakingRef(interp, det, call_frame_idx, name) orelse {
        if (det) |details| details.* = .{
            .message = try allocPrintZ("can't read \"{s}\": no such variable", .{try name.current().getString()}),
        };
        return error.VariableNotFound;
    };
}

pub fn getVariableForMutationOrError(
    interp: *Interp,
    det: ?*ErrorDetails,
    call_frame_idx: u32,
    name: *Shimmerable,
) error{ VariableNotFound, OutOfMemory, LookupFailed, BadVariableName }!Value {
    return try getVariableForMutation(interp, det, call_frame_idx, name) orelse {
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
    defer str_value.dropReference();
    try setVariable(&interp, null, 0, &str_foo, str_value);

    const cached_lookup = (try resolveVariable(&interp, null, 0, str_foo.current())).?.local_variable;
    const cached_lookup_value = cached_lookup.table_in.slotAt(cached_lookup.index).normal;
    try testing.expectEqualStrings("value", try cached_lookup_value.getString());
    // Also try resolving the value from a new string.
    const str2_foo = try objects.String.newValue("foo");
    defer str2_foo.dropReference();
    {
        const lookup = (try resolveVariable(&interp, null, 0, str2_foo)).?.local_variable;
        const lookup_value = lookup.table_in.slotAt(lookup.index).normal;
        try testing.expectEqualStrings("value", try lookup_value.getString());
    }

    // Next, we test dict sugar.
    var str_foo_bar: Shimmerable = .{ .original = try objects.String.newValue("foo::bar") };
    defer str_foo_bar.deinit();
    const str_baz = try objects.String.newValue("baz");
    defer str_baz.dropReference();

    // Make sure trying to read a dict value fails when it's not a dict.
    try expectErrorOrOom(error.LookupFailed, getVariableTakingRef(&interp, null, 0, &str_foo_bar));

    // Clear foo so we can set it to a dictionary.
    try setVariable(&interp, null, 0, &str_foo, heap.interned_empty_string);
    try setVariable(&interp, null, 0, &str_foo_bar, str_baz);

    {
        const lookup = (try getVariableTakingRef(&interp, null, 0, &str_foo_bar)).?;
        defer lookup.dropReference();
        try testing.expectEqual(str_baz.asPtr().?, lookup.asPtr().?);
    }
}

test "variable basics" {
    try memutil.checkAllocationFailures(.exhaustive, testVariables, .{});
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
    defer str_value.dropReference();
    try setVariable(&interp, null, 0, &str_foo, str_value);

    var str_bar: Shimmerable = .{ .original = try objects.String.newValue("bar") };
    defer str_bar.deinit();
    try setVariableUpvar(&interp, null, 0, &str_bar, 0, str_foo.current());

    // Make sure we can get the value of `foo` through `bar`.
    {
        const lookup_value = (try getVariableTakingRef(&interp, null, 0, &str_bar)).?;
        defer lookup_value.dropReference();
        try testing.expectEqualStrings("value", try lookup_value.getString());
    }

    // Modify `foo` through `bar`.
    const str_new_value = try objects.String.newValue("new value");
    defer str_new_value.dropReference();
    try setVariable(&interp, null, 0, &str_bar, str_new_value);
    {
        const lookup_value = (try getVariableTakingRef(&interp, null, 0, &str_foo)).?;
        defer lookup_value.dropReference();
        try testing.expectEqualStrings("new value", try lookup_value.getString());
    }
}

test "variable link" {
    try memutil.checkAllocationFailures(.exhaustive, testVariableLink, .{});
}

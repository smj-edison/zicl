const std = @import("std");
const math = std.math;
const testing = std.testing;
const mem = std.mem;
const assert = std.debug.assert;

const pcre2 = @import("pcre2");

const ioutil = @import("ioutil.zig");
const memutil = @import("memutil.zig");
const StructIterator = memutil.StructIterator;
const strutil = @import("strutil.zig");
const heap = @import("heap.zig");
const hashutil = heap.hashutil;
const Value = heap.Value;
const OptionalValue = heap.OptionalValue;
const Object = heap.Object;
const Tokenizer = @import("Tokenizer.zig");
const objects = @import("objects.zig");
const allocPrintZ = objects.allocPrintZ;
const Shimmerable = objects.Shimmerable;
const ErrorDetails = objects.ErrorDetails;
const IterHelper = objects.IterHelper;
const Dictionary = objects.Dictionary;

const Interp = @This();
/// The result from a procedure or eval call
result: Value,
/// Eval frames are separate from call frames, as eval calls can be
/// nested while staying in the same scope. For example,
/// `puts [+ 2 2]` has one call frame (the global scope), and two
/// eval frames (one for puts, and while puts is running, another
/// for +).
eval_frames: std.ArrayList(EvalFrame),
/// All call frames. Note, index is _not_ stack depth. Why? Because
/// when you run `uplevel`, it creates a new call frame, it doesn't
/// jump back.
call_frames: std.ArrayList(CallFrame),
/// Used to invalidate cached variable lookups.
current_call_epoch: u64,
/// Used to invalidate cached procedures.
global_procedure_epoch: u64,
global_commands: CommandHashTable,

eval_depth: usize,
max_eval_depth: usize,
max_call_depth: usize,
/// Depth of [unknown] calls. Used to catch infinite recursion.
unknown_depth: usize,
/// String containing `unknown`. Used to cache unknown lookup.
unknown_str: Value = heap.makeInterned("unknown"),
/// If this is greater than 0, it means we're catching and handling
/// signals. Otherwise signals are ignored. This gets incremented
/// when running [catch -signal].
signal_depth: usize,
/// Bit mask of caught signals, or 0 if none.
signal: u64,

/// Used to propagate `error.Continue` or `error.Break` up multiple
/// loop levels. This is a separate counter from return_propagate, since
/// this counter only goes down when going through a loop command, not
/// just any ol' command.
loop_propagate: u32 = 0,
/// Used for propagating a return code up multiple eval levels.
return_propagate: struct {
    left_to_go: u32 = 0,
    return_at_end: ?EvalError = null,
} = .{},
/// Stack trace captured at the error site.
stack_trace: OptionalValue,
/// Error code set by `[error]` or `[return -errorcode ...]`. Not a Tcl-visible
/// global, it lives here only to cross the Zig call boundary to `[catch]`/`[try]`.
/// Note that this is not the same as a return code. For example, a return code
/// would be error.OutOfMemory, but an error code would be "ZICL OOM".
pending_error_code: OptionalValue,
/// If an error occurs while a `on`/`trap`/`finally` executes, it can be easy to
/// lose track of the original error. So instead when this happens we store the
/// original error in a `-pending` key, inside of the new error.
pending_error_during: OptionalValue,

parsed_scripts: ParsedScripts,
parsed_exprs: ParsedExpressions,
parsed_closures: ParsedClosures,
parsed_substs: ParsedSubstitutions,

prng: std.Random.DefaultPrng,

const FullHashContext = struct {
    pub fn hash(self: @This(), full_hash: u256) u64 {
        _ = self;
        return @truncate(full_hash);
    }
    pub fn eql(self: @This(), a: u256, b: u256) bool {
        _ = self;
        return a == b;
    }
};
const ParsedScripts = memutil.LruCache(u256, struct { script: objects.ParsedScript }, FullHashContext);
const ParsedExpressions = memutil.LruCache(u256, struct { expr: objects.ParsedExpression }, FullHashContext);
const ParsedClosures = memutil.LruCache(u256, struct { closure: objects.ClosureValues }, FullHashContext);
pub const Substitution = struct {
    subst: objects.ParsedScript,
    /// Mainly used for integrity checks.
    flags: Tokenizer.SubstFlags,
};
const ParsedSubstitutions = memutil.LruCache(u256, Substitution, FullHashContext);

pub const CommandHashTable = std.StringArrayHashMapUnmanaged(NativeCommand);
pub const CommandFn = fn (interp: *Interp, args: []Shimmerable) Error!void;
pub const CCommandFn = fn (interp: *Interp, argc: c_int, argv: [*]Shimmerable) callconv(.c) ReturnCode;

pub const EvalError = error{
    OutOfMemory,
    EvalError,
    PropagateResult,
    Break,
    Continue,
    Signal,
    Exit,
};
pub const Error = EvalError || error{
    WrongUsage,
    Tailcall,
};

pub fn narrowError(err: anyerror) EvalError {
    return switch (err) {
        error.Break => error.Break,
        error.Continue => error.Continue,
        error.EvalError => error.EvalError,
        error.Exit => error.Exit,
        error.OutOfMemory => error.OutOfMemory,
        error.Signal => error.Signal,
        else => error.EvalError,
    };
}
pub fn narrowToEvalError(result: anytype) blk: {
    const info = @typeInfo(@TypeOf(result));
    break :blk if (info == .error_set) EvalError else EvalError!info.error_union.payload;
} {
    if (@typeInfo(@TypeOf(result)) == .error_set) {
        return narrowError(result);
    } else if (result) |val| {
        return val;
    } else |err| return narrowError(err);
}

const Tailcall = struct {
    args: []Shimmerable,
};

fn wrapErrorDetailsReturnType(ResultType: type) type {
    if (comptime std.meta.activeTag(@typeInfo(ResultType)) == .error_set) {
        return error{ OutOfMemory, EvalError };
    } else {
        return error{ OutOfMemory, EvalError }!@typeInfo(ResultType).error_union.payload;
    }
}
/// Used to convert from an object error to an interpreter error (e.g. putting
/// it in the interpreter result, instead of det)
pub fn wrapError(interp: *Interp, det: *objects.ErrorDetails, result: anytype) wrapErrorDetailsReturnType(@TypeOf(result)) {
    if (comptime std.meta.activeTag(@typeInfo(@TypeOf(result))) == .error_set) {
        if (result == error.OutOfMemory) {
            return error.OutOfMemory;
        } else {
            interp.setResultOwning(det.message);
            return error.EvalError;
        }
    }

    return result catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            // This error should have error details, if it's not OOM.
            interp.setResultOwning(det.message);
            return error.EvalError;
        },
    };
}

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
        src.castTo(UpvarLink).linked_name.release();
    }

    fn enumerateStruct(ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const upvar: *const UpvarLink = @ptrCast(@alignCast(info.node));
        const helper: IterHelper = .{ .ctx = ctx, .info = info };
        try helper.followValue("linked_name", upvar.linked_name);
        try helper.addField(u32, "call_frame", "{}", upvar.call_frame);
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

        const obj = try name.prepareToShimmer();
        obj.vtable = &vtable;
        const as_dict_sugar = obj.castTo(DictSugar);
        as_dict_sugar.* = .{
            .dict_name = dict_sugar.dict_name,
            .dict_path = dict_sugar.dict_path,
        };

        return as_dict_sugar;
    }

    fn freeInternalRep(src: *Object) void {
        const as_dict_sugar = src.castTo(DictSugar);
        as_dict_sugar.dict_name.release();
        as_dict_sugar.dict_path.asHead().release();
    }

    fn makeCrossthread(obj: *Object) void {
        freeInternalRep(obj);
        obj.vtable = &objects.None.vtable;
    }

    fn enumerateStruct(ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
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

pub const ClosureValues = struct {
    /// Argument list of the procedure.
    args: []Value,
    /// Default values of optional arguments.
    optional_values: []Value,
    /// Value for the script's body.
    body: Value,
    /// We do our best to track the closure's name.
    name: OptionalValue,
    /// Hash reference pointing to the scope.
    scope_hash_ref: ?*objects.HashReference,
    /// Whether `args` is provided as an argument name. `args`, if present, is always
    /// the last argument name.
    has_args_parameter: bool,
    /// Whether this is a method. If so, `self` is injected as the first variable at call time.
    is_method: bool,
    /// Unique identifier for cache keying.
    cache_id: u64,

    pub fn requiredArity(closure: *const ClosureValues) usize {
        return closure.args.len - closure.optional_values.len - if (closure.has_args_parameter) 1 else 0;
    }

    pub fn duplicate(closure: *const ClosureValues) !ClosureValues {
        const duplicated_args = try heap.global_gpa.dupe(Value, closure.args);
        errdefer heap.global_gpa.free(duplicated_args);
        const duplicated_optional_values = try heap.global_gpa.dupe(Value, closure.optional_values);
        for (duplicated_args) |arg| arg.incrRefCount();
        for (duplicated_optional_values) |value| value.incrRefCount();

        const borrowed_hash_ref = closure.scope_hash_ref;
        if (borrowed_hash_ref) |obj| obj.asHead().incrRefCount();

        return .{
            .args = duplicated_args,
            .optional_values = duplicated_optional_values,
            .body = closure.body.borrow(),
            .name = closure.name.borrow(),
            .scope_hash_ref = borrowed_hash_ref,
            .has_args_parameter = closure.has_args_parameter,
            .is_method = closure.is_method,
            .cache_id = closure.cache_id,
        };
    }

    pub fn deinit(closure: *ClosureValues) void {
        for (closure.args) |arg| arg.release();
        heap.global_gpa.free(closure.args);
        for (closure.optional_values) |value| value.release();
        heap.global_gpa.free(closure.optional_values);

        closure.body.release();
        closure.name.release();
        if (closure.scope_hash_ref) |val| val.asHead().release();
    }

    pub fn enumerateStruct(ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const closure: *const ClosureValues = @ptrCast(@alignCast(info.node));
        const helper: IterHelper = .{ .ctx = ctx, .info = info };
        try helper.followValueSlice("args", closure.args);
        try helper.followValueSlice("optional_values", closure.optional_values);
        try helper.followValue("body", closure.body);
        try helper.followOptionalValue("name", closure.name);
        try helper.followOptional(Object, "scope_hash_ref", if (closure.scope_hash_ref) |val| val.asHead() else null);
        try helper.addField(bool, "has_args_parameter", "{}", closure.has_args_parameter);
        try helper.addField(bool, "is_method", "{}", closure.is_method);
        try helper.addField(u64, "cache_id", "{}", closure.cache_id);
    }
};

pub const Closure = struct {
    closure: *ClosureValues,

    fn duplicate(src: *const Object) !*Object {
        const new_obj = try Object.newObjectUninitialized(Closure);
        errdefer new_obj.head.freeBacking();
        try src.duplicateHeadOnto(new_obj.head);
        errdefer new_obj.head.invalidateString();

        const new_closure = try heap.global_gpa.create(ClosureValues);
        errdefer heap.global_gpa.destroy(new_closure);
        new_closure.* = try src.constCastTo(Closure).closure.duplicate();

        new_obj.body.* = .{ .closure = new_closure };

        return new_obj.head;
    }

    fn freeInternalRep(src: *Object) void {
        const as_closure = src.castTo(Closure);
        as_closure.closure.deinit();
        heap.global_gpa.destroy(as_closure.closure);
    }

    fn updateString(obj: *Object) !void {
        const as_closure = obj.castTo(Closure);
        const closure = as_closure.closure;
        const required = closure.requiredArity();
        const optional = closure.optional_values.len;

        // Step 1: Rebuild the arguments list from required and optional args.

        var rebuilt_args = try heap.local_arena.alloc([]const u8, closure.args.len);

        // Get all the strings (we'll overwrite the strings for the optional arguments).
        for (closure.args, &rebuilt_args) |arg, *str| str.* = try arg.getString();

        // Next, copy over the optional args.
        var optional_written: usize = 0;
        while (optional_written < optional) : (optional_written += 1) {
            const name_and_value: [2][]const u8 = .{
                try closure.args[required + optional_written].getString(), // Argument name.
                try closure.optional_values[optional_written].getString(), // Default value.
            };
            const bytes = try strutil.quoteStrings(heap.local_arena, name_and_value);
            rebuilt_args[required + optional_written] = bytes;
        }

        // Combine all the arguments together to get the args string.
        const args_as_string = try strutil.quoteStrings(heap.local_arena, rebuilt_args);

        // Step 2: build the closure string from its parts.

        // Build the closure: fn|method ?name <name>? impl <impl> ?scope <scope>?
        var backing: [7][]const u8 = undefined;
        var result = std.ArrayList([]const u8).initBuffer(&backing);

        result.appendAssumeCapacity(if (closure.is_method) "method" else "fn");

        if (closure.name.asValue()) |val| {
            result.appendAssumeCapacity("name");
            result.appendAssumeCapacity(try val.getString());
        }

        // `impl` is a two element list: {args body}.
        const args_and_body: [2][]const u8 = .{ args_as_string, try closure.body.getString() };
        result.appendAssumeCapacity("impl");
        result.appendAssumeCapacity(try strutil.quoteStrings(heap.local_arena, args_and_body));

        if (closure.scope_hash_ref) |hash_ref| {
            result.appendAssumeCapacity("scope");
            result.appendAssumeCapacity(try hash_ref.asHead().getString());
        }

        try obj.setStringDuplicating(try strutil.quoteStrings(heap.local_arena, result.items));
    }

    fn enumerateStruct(obj: *const Object, ctx: StructIterator, info: *const StructIterator.NodeInfo) StructIterator.Error!void {
        const closure = obj.constCastTo(Closure);
        const helper: IterHelper = .{ .ctx = ctx, .info = info };
        try helper.follow(ClosureValues, "closure", closure.closure);
    }

    pub const vtable: Object.VTable = .{
        .duplicate = duplicate,
        .free_internal_rep = freeInternalRep,
        .update_string = updateString,
        .make_crossthread = null,
        .enumerate_struct = enumerateStruct,
        .name = @typeName(Closure),
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
    LinkLookupFailed,
    BadVariableName,
}!?VariableValue {
    if (var_name.asPtr()) |obj| _ = try obj.getString();

    if (try var_name.equalsString("~parent")) {
        if (det) |details| details.* = .{
            .message = try std.fmt.allocPrintSentinel(heap.global_gpa, "bad variable name: \"{f}\"", .{var_name}, 0),
        };
        return error.BadVariableName;
    }

    const var_dict = interp.call_frames.items[var_call_frame].variables;
    const maybe_scope_hash_ref = &interp.call_frames.items[var_call_frame].signature.scope_hash_ref;

    // Check the variables dictionary. Don't follow refs here so the
    // cached index points at the dict slot, not the ref target.
    if (try var_dict.table.get(var_name)) |local_var| {
        return .{
            .dictionary_in = var_dict,
            .index = local_var,
        };
    }

    // Wasn't in the variables, maybe it's in a parent scope instead?
    if (maybe_scope_hash_ref.*) |*scope_hash_ref| {
        var dict_shim: Shimmerable = .{ .original = scope_hash_ref.*.ref.asValue() };
        defer dict_shim.discardChanges();
        const in_linked_scope = try objects.Dictionary.getFollowingLinks(det, &dict_shim, var_name);

        if (dict_shim.shimmered.asValue()) |new_dict_raw| {
            const new_hash_ref = try objects.HashReference.new(new_dict_raw.asPtr().?);
            const old = scope_hash_ref.*;
            scope_hash_ref.* = new_hash_ref;
            old.asHead().release();
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
) error{ OutOfMemory, LinkLookupFailed, BadVariableName }!VariableLookupResult {
    const call_frame = &interp.call_frames.items[var_call_frame];
    if (try interp.resolveVariable(det, var_call_frame, name.current())) |var_value| {
        switch (var_value) {
            .local_variable => |local_var| {
                const obj = try name.prepareToShimmer();
                obj.vtable = &CachedLocalVar.vtable;
                obj.castTo(CachedLocalVar).* = .{
                    .dictionary_in = local_var.dictionary_in,
                    .index = local_var.index,
                    .call_epoch = call_frame.call_epoch,
                };
                return .normal;
            },
            .lexical_variable => |lexical_var| {
                const obj = try name.prepareToShimmer();
                obj.vtable = &CachedLexicalVar.vtable;
                obj.castTo(CachedLexicalVar).* = .{
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
fn ensureValidVariableType(
    interp: *Interp,
    det: ?*ErrorDetails,
    var_call_frame: u32,
    name: *Shimmerable,
) error{ OutOfMemory, LinkLookupFailed, BadVariableName }!VariableLookupResult {
    const call_frame = interp.call_frames.items[var_call_frame];

    if (name.current().asType(CachedLocalVar)) |cached_var| {
        // Fast case: if we're in the same epoch as last time, so we don't
        // need to do anything.
        if (cached_var.call_epoch == call_frame.call_epoch) {
            return .normal;
        } else {
            // Need to re-resolve the variable in the current call frame.
            // `name` will be valid after this function completes.
            return try interp.reshimmerToVariable(det, var_call_frame, name);
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
                return try interp.reshimmerToVariable(det, var_call_frame, name);
            } else {
                // Wasn't shadowed, so be sure to update its epoch so we don't do
                // this expensive lookup again.
                lexical_var.call_epoch = call_frame.call_epoch;
                return .normal;
            }
        }
    } else if (name.current().asType(objects.DictSugar)) |_| {
        return .dict_sugar;
    }

    // We don't know whether this is a normal variable or dict sugar yet.
    const var_name = try name.current().getString();
    if (try DictSugar.isValidDictSugar(var_name)) return .dict_sugar;

    // Make sure the variable exists.
    return try interp.reshimmerToVariable(det, var_call_frame, name);
}

// Must be called with a heap-native variable name. Does not account for dict sugar.
fn createVariable(interp: *Interp, call_frame_idx: u32, name: *Shimmerable, value: Value) !void {
    const call_frame = &interp.call_frames.items[call_frame_idx];
    call_frame.call_epoch = interp.nextCallEpoch();

    // Add variable.
    const index = try call_frame.variables.put(name.current(), value);

    const obj = try name.prepareToShimmer();
    obj.vtable = &CachedLocalVar.vtable;
    obj.castTo(CachedLocalVar).* = .{
        .call_epoch = call_frame.call_epoch,
        .dictionary_in = call_frame.variables,
        .index = index,
    };
}

/// Must be called with a heap-native name.
pub fn setVariableInner(interp: *Interp, det: ?*ErrorDetails, call_frame_idx: u32, name: *Shimmerable, value: Value) error{
    OutOfMemory,
    LinkLookupFailed,
    BadVariableName,
}!void {
    switch (try interp.ensureValidVariableType(det, call_frame_idx, name)) {
        .not_found => {
            try createVariable(interp, call_frame_idx, name, value);
        },
        .dict_sugar => {
            const dict_sugar = try DictSugar.shimmerAssumeValid(name);
            var dict_name: Shimmerable = .{ .original = dict_sugar.dict_name };
            defer dict_name.discardChanges(); // Shouldn't happen in practice, since `dict_name` is threadlocal.

            const resolved_dict = blk: {
                const resolved_dict = interp.getVariableInner(det, call_frame_idx, &dict_name) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.LinkLookupFailed => return error.LinkLookupFailed,
                    error.BadVariableName => return error.BadVariableName,
                    error.BadDict => unreachable, // `dict_name` can't be .dict_sugar.
                };
                // If it doesn't exist, we'll create it.
                break :blk if (resolved_dict) |dict| dict.borrow() else (try Dictionary.new(&.{})).asHead().asValue();
            };
            defer resolved_dict.release();
            var resolved_dict_shim: Shimmerable = .{ .original = resolved_dict };
            defer resolved_dict_shim.discardChanges();
            _ = try Dictionary.shimmerFrom(det, &resolved_dict_shim);

            if (resolved_dict_shim.current().canMutate()) {
                const as_dict_mut = resolved_dict_shim.current().asType(Dictionary).?;
                try as_dict_mut.putRecursively(det, objects.ValueSliceContext{ .items = dict_sugar.dict_path.items }, value);
                interp.call_frames.items[call_frame_idx].variables.asHead().invalidateString();
            } else {
                const new_dict = try resolved_dict_shim.getMutable(Dictionary, det);
                errdefer new_dict.asHead().release();
                try new_dict.putRecursively(det, objects.ValueSliceContext{ .items = dict_sugar.dict_path.items }, value);
                try interp.setVariableInner(det, call_frame_idx, &dict_name, new_dict.asHead().asValue());
            }
        },
        .normal => {
            if (name.current().asType(CachedLocalVar)) |local_var| {
                const current_value = &local_var.dictionary_in.items[local_var.index];
                if (current_value.asType(UpvarLink)) |link| {
                    var name_shim: Shimmerable = .{ .original = link.linked_name };
                    defer name_shim.discardChanges();
                    // Set the value through the linked name in the linked frame.
                    try interp.setVariableInner(det, link.call_frame, &name_shim, value);
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

pub fn setVariableUpvarInner(
    interp: *Interp,
    det: ?*ErrorDetails,
    call_frame_idx: u32,
    name: *Shimmerable,
    target_call_frame_idx: u32,
    target_name: Value,
) !void {
    try name.ensureShimmerable();

    switch (try interp.ensureValidVariableType(null, call_frame_idx, name)) {
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
                .message = try allocPrintZ("cannot create an upvar name that has dict sugar"),
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
                    .message = try allocPrintZ("can't upvar from variable to itself"),
                };
                return error.CircularUpvar;
            }

            // See what kind of variable this is, so we can determine whether it has
            // the potential for a cycle.
            const ensure_result = interp.ensureValidVariableType(
                det,
                target_call_frame_idx,
                obj_currently_checking,
            ) catch |err| switch (err) {
                error.LinkLookupFailed => return error.LinkLookupFailed,
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
                    // Can't use `getVariableInner` here, as it follows upvars.
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
        .linked_name = target_name_duped.borrow(),
    };

    try interp.setVariableInner(det, call_frame_idx, name, link.head.asValue());
}

pub fn unsetVariableInner(
    interp: *Interp,
    det: ?*ErrorDetails,
    call_frame_idx: u32,
    name: *Shimmerable,
) !void {
    switch (try interp.ensureValidVariableType(det, call_frame_idx, name)) {
        .not_found => {
            if (det) |details| details.* = .{
                .message = try allocPrintZ("can't unset \"{s}\": no such variable", .{try name.current().getString()}),
            };
            return error.VariableNotFound;
        },
        .dict_sugar => {
            const dict_sugar = try DictSugar.shimmerAssumeValid(name);
            var dict_name: Shimmerable = .{ .original = dict_sugar.dict_name };
            defer dict_name.discardChanges(); // Shouldn't happen in practice, since `dict_name` is threadlocal.

            const resolved_dict = try interp.getVariableInner(null, call_frame_idx, dict_sugar.dict_name) orelse {
                if (det) |details| details.* = .{
                    .message = try allocPrintZ("can't unset \"{f}\": no such element in dictionary", .{name}),
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
                    errdefer new_dict.asHead().release();
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
                    try interp.setVariableInner(null, call_frame_idx, &dict_name, new_dict.asHead().asValue());
                    break :blk did_remove;
                }
            };

            if (!did_remove) {
                if (det) |details| details.* = .{ .message = try allocPrintZ(
                    "can't unset \"{s}\": no such element in dictionary",
                    .{try name.getString()},
                ) };
                return error.VariableNotFound;
            }
            return;
        },
        .normal => {
            // Fall through.
        },
    }

    // We've fallen through from the `.normal` case above, so the name shimmered
    // to either a `CachedLocalVar` or a `CachedLexicalVar`.
    if (name.current().asType(CachedLocalVar)) |local_var| {
        // If this local variable is an upvar link, unset through the link rather
        // than removing the link itself from this scope.
        const current_value = &local_var.dictionary_in.items[local_var.index];
        if (current_value.asType(UpvarLink)) |link| {
            var name_shim: Shimmerable = .{ .original = link.linked_name };
            defer name_shim.discardChanges();
            // Unset the value through the linked name in the linked frame.
            try interp.unsetVariableInner(det, link.call_frame, &name_shim);
            return;
        }

        const call_frame = &interp.call_frames.items[call_frame_idx];
        // The frame's variables dictionary is always uniquely owned, so we can
        // remove from it in place.
        const did_remove = try call_frame.variables.remove(det, name.current());
        if (!did_remove) {
            if (det) |details| details.* = .{
                .message = try allocPrintZ("can't unset \"{s}\": no such variable", .{try name.current().getString()}),
            };
            return error.VariableNotFound;
        }
        call_frame.call_epoch = interp.nextCallEpoch();
    } else if (name.current().asType(CachedLexicalVar)) |_| {
        // A lexical var lives in a parent scope, not this frame's variables
        // dictionary, so there's no local slot to remove. This mirrors [set],
        // which shadows a lexical var rather than mutating the parent scope.
        if (det) |details| details.* = .{
            .message = try allocPrintZ("can't unset \"{s}\": no such variable", .{try name.current().getString()}),
        };
        return error.VariableNotFound;
    } else unreachable;
}

/// Resolves to the variable's value.
pub fn getVariableInner(interp: *Interp, det: ?*ErrorDetails, call_frame_idx: u32, name: *Shimmerable) error{
    OutOfMemory,
    LinkLookupFailed,
    BadDict,
    BadVariableName,
}!?Value {
    switch (try interp.ensureValidVariableType(det, call_frame_idx, name)) {
        .not_found => return null,
        .dict_sugar => {
            const dict_sugar = try DictSugar.shimmerAssumeValid(name);

            var dict_name: Shimmerable = .{ .original = dict_sugar.dict_name };
            defer dict_name.discardChanges(); // Shouldn't happen in practice, since `dict_name` is threadlocal.
            const resolved_dict = try interp.getVariableInner(det, call_frame_idx, &dict_name) orelse return null;
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
                    return error.BadDict;
                },
            };

            if (resolved_dict_shim.shimmered.asValue()) |new| {
                try interp.setVariableInner(det, call_frame_idx, &dict_name, new);
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
            return try interp.getVariableInner(det, upvar_link.call_frame, &name_in_other_scope);
        } else {
            return local_var.dictionary_in.items[local_var.index];
        }
    } else if (name.current().asType(CachedLexicalVar)) |lexical_var| {
        return lexical_var.ref;
    } else unreachable;
}

pub fn getVariableOrErrorInner(
    interp: *Interp,
    det: ?*ErrorDetails,
    call_frame_idx: u32,
    name: Handle,
) error{ VariableNotFound, OutOfMemory, LinkLookupFailed, BadDict, BadVariableName }!Handle {
    return try getVariableInner(interp, det, call_frame_idx, name) orelse {
        if (det) |details| details.* = .{
            .message = try objutil.newStringFmt("can't read \"{f}\": no such variable", .{name}),
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
    defer Heap.testFinish();
    try Heap.testStart(ta, testing.io);
    var interp = try Interp.init();
    defer interp.deinit();

    var str_foo: Shimmerable = .{ .original = try objutil.newString("foo") };
    defer str_foo.deinit();

    // Make sure it doesn't resolve to anything.
    try testing.expectEqual(null, interp.resolveVariable(null, 0, str_foo.current()));

    const str_value = try objutil.newString("value");
    defer str_value.decrRefCount();
    try interp.setVariableTo(&str_foo, str_value);

    const cached_lookup_value = (try interp.resolveVariable(null, 0, str_foo.current())).?.local_variable.target;
    try testing.expectEqualStrings("value", try cached_lookup_value.getString());
    // Also try resolving the value from a new string.
    var str2_foo = try objutil.newString("foo");
    defer str2_foo.decrRefCount();
    const lookup_value = (try interp.resolveVariable(null, 0, str2_foo)).?.local_variable.target;
    try testing.expectEqualStrings("value", try lookup_value.getString());

    // Next, we test dict sugar.
    var str_foo_bar = try objutil.newString("foo::bar");
    defer str_foo_bar.decrRefCount();
    var str_baz = try objutil.newString("baz");
    defer str_baz.decrRefCount();

    // Make sure trying to read a dict value fails when it's not a dict.
    try expectErrorOrOom(error.BadDict, interp.getVariableInner(null, 0, str_foo_bar));

    // Clear foo so we can set it to a dictionary.
    try interp.setVariableInner(null, 0, str_foo.current(), Heap.emptyObject());
    try interp.setVariableInner(null, 0, str_foo_bar, str_baz.reference());
    try testing.expectEqual(str_baz, try interp.getVariableInner(null, 0, str_foo_bar));
}

test "variable basics" {
    try testing.checkAllAllocationFailures(testing.allocator, testVariables, .{});
}

fn testVariableLink(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    try Heap.testStart(ta, testing.io);
    var interp = try Interp.init();
    defer interp.deinit();

    // Create a variable `foo` containing `value`, then upvar `bar` to `foo`.
    var str_foo: Shimmerable = .{ .original = try objutil.newString("foo") };
    defer str_foo.deinit();

    try testing.expectEqual(null, interp.resolveVariable(null, 0, str_foo.current()));
    const str_value = try objutil.newString("value");
    defer str_value.decrRefCount();
    try interp.setVariableTo(&str_foo, str_value);

    var str_bar = try objutil.newString("bar");
    defer str_bar.decrRefCount();
    try interp.setVariableUpvarInner(null, 0, str_bar, 0, str_foo.current());

    // Make sure we can get the value of `foo` through `bar`.
    var lookup_value = (try interp.getVariableInner(null, 0, str_bar)).?;
    try testing.expectEqualStrings("value", try lookup_value.getString());

    // Modify `foo` through `bar`.
    const str_new_value = try objutil.newString("new value");
    defer str_new_value.decrRefCount();
    try interp.setVariableInner(null, 0, str_bar, str_new_value.reference());
    lookup_value = (try interp.getVariableInner(null, 0, str_foo.current())).?;
    try testing.expectEqualStrings("new value", try lookup_value.getString());
}

test "variable link" {
    try testing.checkAllAllocationFailures(testing.allocator, testVariableLink, .{});
}

pub const NativeCommand = struct {
    description: ?[]const u8 = "",
    min_arity: usize = 0,
    max_arity: ?usize = null,
    /// If the command argument length needs to be a multiple of some
    /// amount, set this. A good example is `dict create`, as it needs
    /// an even number of arguments.
    multiple_of: ?usize = null,

    call_info: union(enum) {
        zig: *const CommandFn,
        c: *const CCommandFn,
    },

    /// Returns a string containing all the usage information. Allocates the string
    /// onto `gpa`. Produces something like `cmd ...`, or `cmd arg1 arg2 ?arg3?`
    pub fn getUsageInfo(command: *NativeCommand, gpa: std.mem.Allocator, command_name: []const u8) ![]const u8 {
        var aw = std.Io.Writer.Allocating.init(gpa);
        defer aw.deinit();

        // Write command name.
        aw.writer.writeAll(command_name) catch return error.OutOfMemory;

        if (command.description) |description| {
            aw.writer.print(" {s}", .{description}) catch return error.OutOfMemory;
        } else {
            aw.writer.writeAll(" ...") catch return error.OutOfMemory;
        }

        return try aw.toOwnedSlice();
    }

    pub fn minArity(command: NativeCommand) usize {
        switch (command.call_info) {
            .zig => |info| return info.min_arity,
            .c => |info| return @intCast(info.min_arity),
        }
    }

    pub fn maxArity(command: NativeCommand) ?usize {
        switch (command.call_info) {
            .zig => |info| return info.max_arity,
            .c => |info| if (info.max_arity >= 0) {
                return @intCast(info.max_arity);
            } else return null,
        }
    }

    pub fn multipleOf(command: NativeCommand) ?usize {
        switch (command.call_info) {
            .zig => |info| return info.multiple_of,
            .c => |info| if (info.multiple_of >= 0) {
                return @intCast(info.multiple_of);
            } else return null,
        }
    }
};

fn getClosureUsage(closure: Heap.Closure, gpa: std.mem.Allocator, command_name: []const u8) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(gpa);
    defer aw.deinit();

    aw.writer.writeAll(command_name) catch return error.OutOfMemory;

    const signature_len = objutil.listLength(closure.args);
    const optional_start = if (closure.has_args_parameter) closure.required_arity - 1 else closure.required_arity;

    for (0..signature_len) |i| {
        const var_name_handle = objutil.listItem(closure.args, @intCast(i));
        const var_name = try var_name_handle.getString();

        if (i == signature_len - 1 and closure.has_args_parameter) {
            aw.writer.writeAll(" ?arg ...?") catch return error.OutOfMemory;
        } else if (i >= optional_start) {
            aw.writer.print(" ?{s}?", .{var_name}) catch return error.OutOfMemory;
        } else {
            aw.writer.print(" {s}", .{var_name}) catch return error.OutOfMemory;
        }
    }

    return try aw.toOwnedSlice();
}

fn wrongArgumentCountError(det: ?*ErrorDetails, command_usage: []const u8) !void {
    if (det) |details| details.* = .{
        .message = try objutil.newStringFmt("wrong # args: should be \"{s}\"", .{command_usage}),
    };

    return Error.WrongUsage;
}

/// `name` should be a static variable guaranteed to exist as long as the
/// interpreter exists.
pub fn registerCommand(interp: *Interp, name: []const u8, command: NativeCommand) !void {
    try interp.global_commands.put(Heap.global_gpa, name, command);

    var var_name = try objutil.newString(name);
    defer var_name.decrRefCount();

    const var_name_escaped = try objutil.newList(&.{var_name});
    defer var_name_escaped.decrRefCount();
    var combined = std.ArrayList(u8).empty;
    defer combined.deinit(Heap.global_gpa);
    try combined.appendSlice(Heap.global_gpa, "nativefn ");
    try combined.appendSlice(Heap.global_gpa, try var_name_escaped.getString());
    const var_value = try objutil.newString(combined.items);

    var var_name_wb: Shimmerable = .{ .original = var_name };
    defer var_name_wb.discardChanges();
    try interp.setVariableToObject(&var_name_wb, var_value.referenceOwning());

    // FIXME need to handle this if it wraps around.
    interp.global_procedure_epoch += 1;
}

pub fn parseClosure(det: ?*ErrorDetails, bytes: []const u8) !Heap.Closure {
    const is_method, const prefix_len = blk: {
        if (bytes.len > 3 and std.mem.eql(u8, bytes[0..3], "fn "))
            break :blk .{ false, @as(usize, 3) };
        if (bytes.len > 7 and std.mem.eql(u8, bytes[0..7], "method "))
            break :blk .{ true, @as(usize, 7) };
        if (det) |details| details.* = .{
            .message = try objutil.newStringFmt("not a valid function: \"{s}\"", .{bytes}),
        };
        return error.BadClosure;
    };

    var closure_value: Shimmerable = .{ .original = try objutil.newString(bytes[prefix_len..]) };
    defer closure_value.deinit();

    objutil.shimmerToDict(null, &closure_value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (det) |details| details.* = .{
                .message = try objutil.newStringFmt("not a valid function: \"{s}\"", .{bytes}),
            };
            return error.BadClosure;
        },
    };

    const maybe_name = try objutil.dictLookupFollowLinks(det, &closure_value, Heap.local_heap.getInternedString(.name));
    const maybe_impl = try objutil.dictLookupFollowLinks(det, &closure_value, Heap.local_heap.getInternedString(.impl));
    const maybe_scope = try objutil.dictLookupFollowLinks(det, &closure_value, Heap.local_heap.getInternedString(.scope));

    var args, const body = blk: {
        if (maybe_impl.toHandle()) |impl| {
            var impl_wb: Shimmerable = .{ .original = impl };
            defer impl_wb.discardChanges();
            objutil.shimmerToList(null, &impl_wb) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    if (det) |details| details.* = .{
                        .message = try objutil.newStringFmt("not a valid function implementation: \"{s}\"", .{bytes}),
                    };
                    return error.BadClosure;
                },
            };

            if (objutil.listLength(impl_wb.current()) != 2) {
                if (det) |details| details.* = .{
                    .message = try objutil.newStringFmt("not a valid function implementation: \"{s}\"", .{bytes}),
                };
                return error.BadClosure;
            }

            break :blk .{
                objutil.listItem(impl_wb.current(), 0).borrow(),
                objutil.listItem(impl_wb.current(), 1).borrow(),
            };
        } else {
            if (det) |details| details.* = .{
                .message = try objutil.newStringFmt("function missing implementation: \"{s}\"", .{bytes}),
            };
            return error.BadClosure;
        }
    };
    defer args.decrRefCount();
    errdefer body.decrRefCount();

    // Make sure args is a list.
    var args_wb: Shimmerable = .{ .original = args };
    objutil.shimmerToList(null, &args_wb) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (det) |details| details.* = .{
                .message = try objutil.newStringFmt("function args is not a valid list: \"{f}\"", .{args}),
            };
            return error.BadClosure;
        },
    };
    args = args_wb.consume();

    // Scope must always be a hash reference.
    var scope_hash_ref: OptionalHandle = .none;
    if (maybe_scope.toHandle()) |scope| {
        var scope_wb: Shimmerable = .{ .original = scope.borrow() };
        errdefer scope_wb.deinit();
        try objutil.shimmerToHashReference(det, &scope_wb);
        scope_hash_ref = scope_wb.consume().toOptional();
    }

    const parsed_args = try parseClosureArgList(det, args);

    return .{
        .args = parsed_args.arg_names,
        .body = body,
        .name = maybe_name.borrowOptional(),
        .scope_hash_ref = scope_hash_ref,
        .required_arity = parsed_args.required_arity,
        .optional_arity = parsed_args.optional_arity,
        .optional_values = parsed_args.optional_values,
        .has_args_parameter = parsed_args.has_args_parameter,
        .is_method = is_method,
        .cache_id = Heap.nextCacheId(),
    };
}

const ParsedArgList = struct {
    required_arity: u32,
    optional_arity: u32,
    arg_names: Handle,
    optional_values: OptionalHandle,
    has_args_parameter: bool,

    pub fn deinit(self: ParsedArgList) void {
        self.optional_values.decrOptional();
        self.arg_names.decrRefCount();
    }
};

/// Validates a closure argument list and extracts arity information. Modifies
/// the list in-place to strip default values from optional parameter specifiers.
/// `args` must already be shimmered to a list.
pub fn parseClosureArgList(det: ?*ErrorDetails, args: Handle) !ParsedArgList {
    const arg_list_len = objutil.listLength(args);

    var arg_names = try objutil.newListWithCapacity(objutil.listLength(args));
    errdefer arg_names.decrRefCount();
    // Pre-allocate for optional default values. arg_list_len is an upper bound.
    var optional_values: OptionalHandle = .none;
    errdefer optional_values.decrOptional();

    var args_parameter_found = false;
    var required_arity: u32 = 0;
    var optional_arity: u32 = 0;

    for (0..arg_list_len) |i| {
        if (args_parameter_found) {
            if (det) |details| details.* = .{
                .message = try objutil.newString("parameter after 'args' not allowed"),
            };
            return error.BadClosure;
        }

        var arg: Shimmerable = .{ .original = objutil.listItem(args, @intCast(i)) };
        defer arg.discardChanges();
        objutil.shimmerToList(null, &arg) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                if (det) |details| details.* = .{
                    .message = try objutil.newStringFmt("too many fields in argument specifier \"{f}\"", .{arg.current()}),
                };
                return error.BadClosure;
            },
        };
        const arg_len = objutil.listLength(arg.current());

        if (arg_len == 0) {
            if (det) |details| details.* = .{
                .message = try objutil.newString("argument with no name"),
            };
            return error.BadClosure;
        } else if (arg_len > 2) {
            if (det) |details| details.* = .{
                .message = try objutil.newStringFmt("too many fields in argument specifier \"{f}\"", .{arg.current()}),
            };
            return error.BadClosure;
        } else if (arg_len == 2) {
            // Optional parameter.
            if (optional_values == .none) {
                // We haven't created a list for optional args yet, so we'll go ahead and init it.
                optional_values = (try objutil.newListWithCapacity(arg_list_len)).toOptional();
            }

            if (try objutil.listItem(arg.current(), 0).equalsString("args")) {
                if (det) |details| details.* = .{
                    .message = try objutil.newString("\"args\" must be a required parameter"),
                };
                return error.BadClosure;
            }

            // Add the optional parameter onto the optional parameters list.
            objutil.listAppendAssumeCapacity(optional_values.toHandle().?, objutil.listItem(arg.current(), 1).dupOrRef());

            // Pull out the name from the default list (`{name default}`).
            objutil.listAppendAssumeCapacity(arg_names, objutil.listItem(arg.current(), 0).dupOrRef());

            optional_arity += 1;
        } else {
            if (optional_values != .none) {
                if (det) |details| details.* = .{
                    .message = try objutil.newString("required parameter after optional parameter not allowed"),
                };
                return error.BadClosure;
            }

            const arg_name = try objutil.listItem(arg.current(), 0).getString();
            if (std.mem.eql(u8, arg_name, "args")) {
                args_parameter_found = true;
            } else {
                required_arity += 1;
            }

            objutil.listAppendAssumeCapacity(arg_names, objutil.listItem(arg.current(), 0).dupOrRef());
        }
    }

    return .{
        .arg_names = arg_names,
        .required_arity = required_arity,
        .optional_arity = optional_arity,
        .optional_values = optional_values,
        .has_args_parameter = args_parameter_found,
    };
}

/// Creates a heap object with the `.closure` tag and associated extra data.
/// The closure's fields are borrowed, so the caller retains ownership of the
/// inputs. Returns an owned handle.
pub fn createClosureObject(closure: Heap.Closure) !Handle {
    const obj = try Heap.createObject();
    errdefer obj.decrRefCount();
    const extra_data = try Heap.local_heap.createExtraData();
    errdefer Heap.local_heap.destroyExtraData(extra_data);
    Heap.local_heap.getExtraData(extra_data).* = .{ .closure = closure.borrow() };
    obj.peek().head.tag = .closure;
    obj.peek().body = .{ .closure = .{ .extra_data = extra_data } };
    return obj;
}

const ClosureAndCacheKey = struct {
    closure: Heap.Closure,
    cache_key: u256,
};
/// Caller is responsible for borrowing the returned closure
/// if they intend to use it beyond temporarily.
pub fn getClosure(interp: *Interp, det: ?*ErrorDetails, handle: Handle, can_be_method: bool) !ClosureAndCacheKey {
    _ = interp;

    const closure_and_key: ClosureAndCacheKey = blk: {
        if (handle.tag() == .closure) {
            const closure = handle.getClosureExtraData().*;
            break :blk .{ .closure = closure, .cache_key = @as(u256, closure.cache_id) };
        }

        const cache_key = try handle.getHashNoRegister();

        if (Heap.local_heap.parsed_closures.get(cache_key)) |cached| {
            break :blk .{ .closure = cached.closure, .cache_key = cache_key };
        } else {
            // We need to parse the closure.
            const closure: Heap.Closure = try parseClosure(det, try handle.getString());
            if (Heap.local_heap.parsed_closures.put(cache_key, .{ .closure = closure })) |old_value| {
                var old = old_value;
                old.closure.deinit();
            }
            const cached = Heap.local_heap.parsed_closures.get(cache_key).?;
            break :blk .{ .closure = cached.closure, .cache_key = cache_key };
        }
    };

    if (!can_be_method and closure_and_key.closure.is_method) {
        if (det) |details| details.* = .{
            .message = try objutil.newString("method cannot be invoked as function"),
        };
        return error.CannotBeMethod;
    }

    return closure_and_key;
}

/// If called with a closure, this will _modify_ `args[1]`, not just shimmer it.
pub fn callClosure(interp: *Interp, closure: Heap.Closure, cache_key: u256, args: []Shimmerable) !void {
    const arg_count = args.len - 1; // - 1 to skip command name as first argument.

    // Check arity.
    const too_few_arguments: bool = arg_count < closure.required_arity;
    const has_args: bool = closure.has_args_parameter;
    const too_many_arguments: bool = !has_args and arg_count > closure.required_arity + closure.optional_arity;
    if (too_few_arguments or too_many_arguments) {
        // Wrong argument count, error accordingly.
        var sf = std.heap.stackFallback(64, Heap.global_gpa);
        const scratch = sf.get();
        const command_name = try args[0].getString();
        const command_usage = try getClosureUsage(closure, scratch, command_name);
        defer scratch.free(command_usage);
        var det: ErrorDetails = undefined;
        return interp.wrapError(&det, wrongArgumentCountError(&det, command_usage));
    }

    // Check for infinite recursion.
    if (interp.callFrameIdx() >= interp.max_call_depth) {
        try interp.setResultString("Too many nested calls. Infinite recursion?");
        return error.InfiniteRecursion;
    }

    const call_frame_idx = try interp.pushCallFrame(args, closure);
    defer {
        var frame = interp.call_frames.pop().?;
        frame.deinit();
    }

    // Next, we'll populate the call frame.

    // Where we are in the arguments that this was called with.
    var called_idx: usize = 1;
    // Where we are in the signature.
    var signature_idx: u32 = 0;
    const signature_len = objutil.listLength(closure.args);

    while (signature_idx < signature_len) : (signature_idx += 1) {
        const var_name = objutil.listItem(closure.args, signature_idx);

        // Are we at the last argument? If so, is it `args`?
        if (signature_idx == signature_len - 1 and closure.has_args_parameter) {
            // Assign remaining arguments to `args`.
            const list = try objutil.newListWithCapacity(@intCast(args[called_idx..].len));
            defer list.decrRefCount();
            for (args[called_idx..]) |arg| objutil.listAppendAssumeCapacity(list, arg.current().dupOrRef());

            var det: ErrorDetails = undefined;
            interp.setVariableInner(&det, call_frame_idx, var_name, list.reference()) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.LinkLookupFailed, error.BadVariableName => {
                    interp.setResultOwning(det.message);
                    return error.EvalError;
                },
            };
        } else if (signature_idx >= closure.required_arity) {
            // This is an optional argument.

            // Are there any remaining unassigned arguments?
            if (called_idx < args.len) {
                var det: ErrorDetails = undefined;
                try interp.wrapError(&det, interp.setVariableInner(&det, call_frame_idx, var_name, args[called_idx].current().dupOrRef()));
                called_idx += 1;
            } else {
                // Else populate it with its default value.
                const default_value = objutil.listItem(closure.optional_values.toHandle().?, signature_idx - closure.required_arity);
                var det: ErrorDetails = undefined;
                try interp.wrapError(&det, interp.setVariableInner(&det, call_frame_idx, var_name, default_value.dupOrRef()));
            }
        } else {
            var det: ErrorDetails = undefined;
            try interp.wrapError(&det, interp.setVariableInner(&det, call_frame_idx, var_name, args[called_idx].current().dupOrRef()));
            called_idx += 1;
        }
    }

    try interp.evalObjectInner(call_frame_idx, closure.body, cache_key);

    // When called as a method, we write back `self` to `args[1]`, so that the
    // caller can update the new method.
    if (closure.is_method) {
        const self_var_name = objutil.listItem(closure.args, 0);
        if (interp.getVariableOrErrorInner(null, call_frame_idx, self_var_name)) |updated_self| {
            // The very last thing we do is swap out `args[1]`, because otherwise error
            // handling code may see the new (mutated) object, and error handling code should
            // only ever see the original object.
            args[1].asMutable().mutated.swap(updated_self.borrow());
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadVariableName => {
                // This variable name was already checked when setting the arguments.
                unreachable;
            },
            error.VariableNotFound, error.LinkLookupFailed, error.BadDict => {
                try interp.setResultFormatted("{f} was removed while calling method", .{self_var_name});
                return error.EvalError;
            },
        }
    }
}

fn callNative(interp: *Interp, command: *NativeCommand, args: []Shimmerable) !void {
    const arg_count = args.len - 1;
    wrong_arg_count: {
        // Check arg count.
        if (arg_count < command.min_arity) break :wrong_arg_count;
        if (command.max_arity) |max_arity| {
            if (arg_count > max_arity) break :wrong_arg_count;
        }
        if (command.multiple_of) |multiple_of| {
            if (@mod(arg_count - command.min_arity, multiple_of) != 0) break :wrong_arg_count;
        }

        switch (command.call_info) {
            .zig => |to_call| try to_call(interp, args),
            .c => |to_call| {
                const args_as_handles = try Heap.global_gpa.alloc(Handle, args.len);
                defer Heap.global_gpa.free(args_as_handles);
                for (args, args_as_handles) |arg, *native_arg| native_arg.* = arg.current().borrow();

                const retcode = ReturnCode.toError(to_call(interp, @intCast(args_as_handles.len), args_as_handles.ptr));

                for (args, args_as_handles) |*arg, native_arg| {
                    if (native_arg != arg.current()) {
                        arg.shimmered.swap(native_arg);
                    } else {
                        native_arg.decrRefCount();
                    }
                }

                return retcode;
            },
        }

        return;
    }

    var sf = std.heap.stackFallback(64, Heap.global_gpa);
    const scratch = sf.get();
    const command_name = try args[0].getString();
    const command_usage = try command.getUsageInfo(scratch, command_name);
    defer scratch.free(command_usage);
    var det: ErrorDetails = undefined;
    return interp.wrapError(&det, wrongArgumentCountError(&det, command_usage));
}

fn freeLastResult(interp: *Interp) void {
    interp.result.decrRefCount();
    interp.result = Heap.local_heap.emptyHandle();
}

pub fn setResult(interp: *Interp, handle: Handle) void {
    interp.freeLastResult();
    interp.result = handle.borrow();
}

pub fn setResultOwning(interp: *Interp, handle: Handle) void {
    interp.freeLastResult();
    interp.result = handle;
}

pub fn setResultInteger(interp: *Interp, value: i64) !void {
    interp.setResultOwning(try objutil.newInteger(value));
}

pub fn setResultFloat(interp: *Interp, value: f64) !void {
    interp.setResultOwning(try objutil.newFloat(value));
}

pub fn setResultString(interp: *Interp, bytes: []const u8) !void {
    const bytes_handle = try objutil.newString(bytes);
    interp.setResultOwning(bytes_handle);
}

pub fn setResultBoolean(interp: *Interp, value: bool) !void {
    interp.setResultOwning(try objutil.newBoolean(value));
}

pub fn setResultInterned(interp: *Interp, interned: Heap.InternedString) void {
    interp.setResultOwning(Heap.local_heap.getInternedString(interned));
}

pub fn setResultFormatted(interp: *Interp, comptime fmt: []const u8, args: anytype) !void {
    const fmt_handle = try objutil.newStringFmt(fmt, args);

    interp.setResultOwning(fmt_handle);
}

pub fn setEmptyResult(interp: *Interp) void {
    interp.freeLastResult();
}

/// Caller must ensure `stack_trace` is already a list.
pub fn makeErrorMessage(error_mesage: Handle, stack_trace: Handle) !Handle {
    const list_len = objutil.listLength(stack_trace);
    if (list_len == 0 or @mod(list_len, 4) != 0) return error.WrongSize;

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(Heap.global_gpa);

    const first_file = objutil.listItem(stack_trace, 1);
    const first_line = objutil.listItem(stack_trace, 2);

    try buf.print(Heap.global_gpa, "{f}:{f}: Error: {f}\n", .{ first_file, first_line, error_mesage });
    try buf.print(Heap.global_gpa, "Traceback:\n", .{});

    if (list_len <= 4) {
        // Stack trace only had one entry, so there's no point in printing the traceback.
        return try objutil.newString(buf.items);
    }

    // Stack trace is a flat list of {command file line args} repeated per frame.
    const stack_trace_len = objutil.listLength(stack_trace);
    var i: u32 = 0;
    while (i < stack_trace_len) : (i += 4) {
        const fn_name = try objutil.listItem(stack_trace, i + 0).getString();
        const file = try objutil.listItem(stack_trace, i + 1).getString();
        const line = try objutil.listItem(stack_trace, i + 2).getString();
        const args = try objutil.listItem(stack_trace, i + 3).getString();

        if (file.len > 0) {
            try buf.print(Heap.global_gpa, "  File \"{s}\", line {s}", .{ file, line });
        }

        if (fn_name.len > 0) {
            if (file.len > 0) {
                try buf.print(Heap.global_gpa, ", in {s}", .{fn_name});
            } else {
                try buf.print(Heap.global_gpa, "  In {s}", .{fn_name});
            }
        }

        if (file.len > 0 or fn_name.len > 0) {
            try buf.append(Heap.global_gpa, '\n');
        }

        if (args.len > 0) {
            if (std.mem.indexOfScalar(u8, args, '\n')) |args_newline| {
                const shortened = args[0..args_newline];
                try buf.print(Heap.global_gpa, "    {s}...\n", .{shortened});
            } else {
                try buf.print(Heap.global_gpa, "    {s}\n", .{args});
            }
        }
    }

    // Remove trailing \n
    if (buf.getLastOrNull()) |last| if (last == '\n') {
        _ = buf.pop();
    };

    return try objutil.newString(buf.items);
}

/// Call frame.
const CallFrame = struct {
    /// Dictionary containing the frame's variables.
    variables: *objects.Dictionary,
    /// Arguments of this procedure call. Lifetime managed by creator.
    args: []Shimmerable,
    /// Signature of this procedure.
    signature: ClosureValues,
    /// Call epoch. Used to invalidate previous variable lookups.
    call_epoch: u64,
    /// Set this during evaluation to trigger a tailcall.
    tailcall: ?Tailcall,

    pub fn deinit(frame: *CallFrame) void {
        // Args are managed externally, so we don't free them.
        frame.variables.asHead().release();
        frame.signature.deinit();
    }
};

pub fn callFrameIdx(interp: *Interp) u32 {
    return interp.currentEvalFrame().call_frame;
}

pub fn callFrame(interp: *Interp) *CallFrame {
    return &interp.call_frames.items[interp.callFrameIdx()];
}

/// Returns a dict containing this call frame's variables.
pub fn captureScope(interp: *Interp, det: ?*ErrorDetails, call_frame_idx: u32) !Handle {
    const frame = &interp.call_frames.items[call_frame_idx];
    const pairs = objutil.dictPairLength(frame.variables);

    // Make sure there's no upvars.
    for (0..pairs) |i_usize| {
        const i: u32 = @intCast(i_usize);
        const value = objutil.dictItemNoFollow(frame.variables, i * 2 + 1);
        if (value.tag() == .upvar_link) break;
    } else {
        // No upvars found, so we can just reference the variables dict.
        return try objutil.createHashReference(frame.variables);
    }

    // Found upvars if we made it to this point, so we need
    // to duplicate everything, and follow any upvars.
    const upvar_free_dict = try objutil.newDictWithCapacity(pairs * 2);
    errdefer upvar_free_dict.decrRefCount();
    for (0..pairs) |i_usize| {
        const i: u32 = @intCast(i_usize);
        const key = objutil.dictItemNoFollow(frame.variables, i * 2);
        const value = objutil.dictItemNoFollow(frame.variables, i * 2 + 1);

        if (value.tag() == .upvar_link) {
            const upvar_link = value.peek().body.upvar_link;
            if (interp.getVariableOrErrorInner(det, upvar_link.call_frame, Heap.local_heap.getHandle(upvar_link.linked_name))) |upvar_val| {
                objutil.dictPutAssumeCapacity(upvar_free_dict, key, upvar_val.dupOrRef());
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.BadVariableName => return error.BadVariableName,
                error.VariableNotFound, error.BadDict => {
                    if (det) |details| {
                        details.message.decrRefCount();
                        details.* = .{ .message = try objutil.newStringFmt(
                            "failed to capture the variable \"{f}\", as it was an upvar that pointed at nothing",
                            .{key},
                        ) };
                    }
                    return error.UninitializedUpvar;
                },
                error.LinkLookupFailed => return error.LinkLookupFailed,
            }
        } else {
            objutil.dictPutAssumeCapacity(upvar_free_dict, key, value.dupOrRef());
        }
    }

    // Create a hash reference so the scope can be shared across threads
    // and is consistent with the ^parent link representation.
    const hash_ref = try objutil.createHashReference(upvar_free_dict);
    upvar_free_dict.decrRefCount();
    return hash_ref;
}

/// Returns a dict capturing the current call frame's variables.
pub fn captureCurrentScope(interp: *Interp) !Handle {
    var det: ErrorDetails = undefined;
    return try interp.wrapError(&det, interp.captureScope(&det, interp.callFrameIdx()));
}

var global_call_epoch: std.atomic.Value(u64) = .init(0);
fn nextCallEpoch(interp: *Interp) u64 {
    const epoch = interp.current_call_epoch;
    interp.current_call_epoch = global_call_epoch.fetchAdd(1, .monotonic) + 1;
    return epoch;
}

/// Evaluation frame.
pub const EvalFrame = struct {
    /// Pointer to the corrisponding call frame.
    call_frame: u32,
    /// Arguments of the command currently being dispatched in this eval frame.
    args: []Shimmerable,
    /// The line number of the command currently being dispatched, within
    /// the script being evaluated (note that this is relative, since that's
    /// how parsed scripts are stored). Combine with `source_info.line_no`
    /// to recover the absolute line at error-reporting time.
    current_line: u32,
    /// The object currently being evaluated.
    currently_evaluating: Handle,
};

pub fn currentEvalFrameIndex(interp: *Interp) u32 {
    return @intCast(interp.eval_frames.items.len - 1);
}

pub fn currentEvalFrame(interp: *Interp) *EvalFrame {
    return &interp.eval_frames.items[interp.currentEvalFrameIndex()];
}

fn pushCallFrame(interp: *Interp, args: []Shimmerable, signature: Heap.Closure) !u32 {
    var vars_handle = try objutil.newDictWithCapacity(30);
    errdefer vars_handle.decrRefCount();
    const borrowed_signature = signature.borrow();
    errdefer borrowed_signature.deinit();

    if (borrowed_signature.scope_hash_ref.toHandle()) |scope_hash_ref| {
        var vars_handle_wb: Mutable = .{ .original = vars_handle };
        assert(scope_hash_ref.tag() == .hash_reference);
        // Safe since vars_handle is freshly allocated.
        _ = try objutil.dictPutObject(
            &vars_handle_wb,
            Heap.local_heap.getInternedString(.@"^parent"),
            scope_hash_ref.peek().body.hash_reference.hashReference(),
        );
        vars_handle.swapIfNew(vars_handle_wb.mutated);
    }

    const new_call_frame_idx = interp.call_frames.items.len;
    try interp.call_frames.append(Heap.global_gpa, .{
        .args = args,
        .call_epoch = interp.nextCallEpoch(),
        .signature = borrowed_signature,
        // TODO PERF recycle variable hash table if possible.
        .variables = vars_handle,
        .tailcall = null,
    });

    return @intCast(new_call_frame_idx);
}

fn pushEvalFrame(interp: *Interp, call_frame: u32, script: Handle) !u32 {
    try interp.eval_frames.append(Heap.global_gpa, .{
        .call_frame = call_frame,
        .args = &.{},
        .current_line = 0,
        .currently_evaluating = script,
    });
    return interp.currentEvalFrameIndex();
}

fn popEvalFrame(interp: *Interp) void {
    _ = interp.eval_frames.pop() orelse unreachable;
}

/// Caller should release return value when they're done.
fn substituteOneToken(interp: *Interp, tag: Tokenizer.Token.Tag, value: Handle) !Handle {
    switch (tag) {
        .simple_string => {
            return value.borrow();
        },
        .variable_subst => {
            var det: ErrorDetails = undefined;
            const var_target: Handle = try interp.wrapError(
                &det,
                interp.getVariableOrErrorInner(&det, interp.callFrameIdx(), value),
            );
            return var_target.borrow();
        },
        .expression_sugar => {
            @panic("Expression sugar unimplemented");
        },
        .command_subst => {
            const nested_cache_key = @as(u256, interp.callFrame().signature.cache_id) ^ try value.getHashNoRegister();
            try interp.evalObjectInner(interp.callFrameIdx(), value, nested_cache_key);
            return interp.result.borrow();
        },
        else => {
            std.debug.panic("Tried to substitute token {}", .{tag});
        },
    }
}

fn interpolateTokens(
    interp: *Interp,
    tags: []const Tokenizer.Token.Tag,
    value_list: Handle,
    value_start: u32,
    value_len: u32,
) !Handle {
    var sf = std.heap.stackFallback(@sizeOf(Handle) * 8, Heap.global_gpa);
    const tokens_alloc = sf.get();

    var new_values = try std.ArrayList(Handle).initCapacity(tokens_alloc, value_len);
    defer new_values.deinit(tokens_alloc);
    defer for (new_values.items) |value| value.decrRefCount();

    // Substitute all the tokens, placing them in `new_values`.
    for (tags, value_start..(value_start + value_len)) |tag, value_index| {
        if (interp.substituteOneToken(tag, objutil.listItem(value_list, @intCast(value_index)))) |new_value| {
            new_values.appendAssumeCapacity(new_value);
        } else |err| switch (err) {
            error.Break => {
                try interp.setResultString("invoked \"break\" outside of a loop");
                return error.EvalError;
            },
            error.Continue => {
                try interp.setResultString("invoked \"continue\" outside of a loop");
                return error.EvalError;
            },
            else => return err,
        }
    }

    var new_str_len: usize = 0;
    for (new_values.items) |new_value| {
        new_str_len += (try new_value.getString()).len;
    }

    if (new_str_len == 0) return Heap.local_heap.emptyHandle();

    var new_bytes = try Heap.global_gpa.alloc(u8, new_str_len);
    defer Heap.global_gpa.free(new_bytes);
    var written: usize = 0;
    for (new_values.items) |new_value| {
        const value_str = try new_value.getString();
        @memcpy(new_bytes[written..][0..value_str.len], value_str);
        written += value_str.len;
    }

    return try objutil.newString(new_bytes);
}

const CommandOrClosure = union(enum) {
    closure: ClosureAndCacheKey,
    command: *NativeCommand,
};

/// `name` must be from the threadlocal heap.
fn getCommandInner(
    interp: *Interp,
    det: ?*ErrorDetails,
    call_frame: u32,
    name: Handle,
    can_be_method: bool,
) !CommandOrClosure {
    if (interp.getVariableOrErrorInner(det, call_frame, name)) |var_val| {
        if (var_val.tag() == .closure) {
            return .{ .closure = try interp.getClosure(det, var_val, can_be_method) };
        }

        // TODO PERF probably should cache nativefn lookup.
        const bytes = try var_val.getString();
        if (bytes.len > 9 and std.mem.eql(u8, bytes[0..9], "nativefn ")) {
            // TODO `bytes[9..]` doesn't account for a nativefn name in braces or with escapes.
            const cmd_name = bytes[9..];
            if (interp.global_commands.getPtr(cmd_name)) |command| {
                return .{ .command = command };
            }

            // Command not registered locally, so check the shared lazy-init registry.
            if (Heap.nativefn_registry.get(cmd_name)) |init_fn| {
                init_fn(@ptrCast(interp));
                // Retry after initialization.
                if (interp.global_commands.getPtr(cmd_name)) |command| {
                    return .{ .command = command };
                }
            }

            if (det) |details| details.* = .{
                .message = try objutil.newStringFmt("invalid native command name \"{s}\"", .{cmd_name}),
            };
            return error.CommandNotFound;
        } else {
            const closure = try interp.getClosure(det, var_val, can_be_method);
            return .{ .closure = closure };
        }
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.LinkLookupFailed => return error.LinkLookupFailed,
        error.BadVariableName => return error.BadVariableName,
        error.VariableNotFound, error.BadDict => {
            if (det) |details| {
                details.message.decrRefCount();
                details.* = .{
                    .message = try objutil.newStringFmt("invalid command name \"{f}\"", .{name}),
                };
            }
            return error.CommandNotFound;
        },
    }
}

pub fn getCommand(interp: *Interp, call_frame_idx: u32, wb: *Shimmerable, can_be_method: bool) !CommandOrClosure {
    try wb.ensureShimmerable();
    var det: ErrorDetails = undefined;
    return interp.getCommandInner(&det, call_frame_idx, wb.current(), can_be_method) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CommandNotFound => {
            interp.setResultOwning(det.message);
            return error.CommandNotFound;
        },
        else => {
            interp.setResultOwning(det.message);
            return error.EvalError;
        },
    };
}

fn invokeUnknown(interp: *Interp, args: []Shimmerable) !void {
    var unknown_str: Shimmerable = .{ .original = interp.unknown_str };
    defer unknown_str.discardChanges();
    const unknown_cmd = interp.getCommand(0, &unknown_str, false) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CommandNotFound => {
            // No [unknown] command exists, so we'll default to the "no command found" error.
            try interp.setResultFormatted("invalid command name \"{f}\"", .{args[0].current()});
            return error.EvalError;
        },
        error.EvalError => return error.EvalError,
    };

    if (interp.unknown_depth > 50) {
        try interp.setResultString("infinite recursion in [unknown]");
        return error.EvalError;
    }

    interp.unknown_depth += 1;
    defer interp.unknown_depth -= 1;

    var new_args = std.ArrayList(Shimmerable).empty;
    defer new_args.deinit(Heap.global_gpa);
    try new_args.append(Heap.global_gpa, .{ .original = interp.unknown_str });
    assert(new_args.items.len == 1);
    defer new_args.items[0].discardChanges();
    try new_args.appendSlice(Heap.global_gpa, args[1..]);

    try interp.invokeCommand(unknown_cmd, new_args.items);
}

const CommandError = Error || error{InfiniteRecursion};
fn invokeCommand(interp: *Interp, command_or_closure: CommandOrClosure, args: []Shimmerable) CommandError!void {
    if (interp.eval_depth >= interp.max_eval_depth) {
        try interp.setResultString("Infinite eval recursion");
        return error.InfiniteRecursion;
    }

    interp.eval_depth += 1;
    defer interp.eval_depth -= 1;

    // Loop the calling section, as there may be a tailcall.
    var current_args = args;
    var tailcall_info: ?Tailcall = null;
    defer if (tailcall_info) |info| Heap.global_gpa.free(info.args);
    while (true) {
        interp.currentEvalFrame().args = args;
        // TODO implement tracing.

        // Be sure to clear the previous result.
        interp.setEmptyResult();

        const result = blk: {
            switch (command_or_closure) {
                .command => |command| {
                    break :blk interp.callNative(command, current_args);
                },
                .closure => |closure| {
                    break :blk interp.callClosure(closure.closure, closure.cache_key, current_args);
                },
            }
        };

        var tailcall_found = false;

        result catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Tailcall => {
                tailcall_found = true;
                const tailcall = interp.callFrame().tailcall.?;

                // Be sure to free the previous tailcall.
                if (tailcall_info) |prev_tailcall| {
                    for (prev_tailcall.args) |*arg| arg.deinit();
                    Heap.global_gpa.free(prev_tailcall.args);
                }

                tailcall_info = tailcall;
                current_args = tailcall.args;
                interp.callFrame().tailcall = null;
            },
            error.EvalError => {
                try interp.setErrorStack();
                return error.EvalError;
            },
            else => return err,
        };

        if (tailcall_found == false) {
            tailcall_info = null; // Avoid double free.
            break;
        }
    }
}

pub const IntegerOrFloat = union(enum) {
    int: i64,
    float: f64,
};
pub fn getIntegerOrFloat(interp: *Interp, wb: *Shimmerable) !IntegerOrFloat {
    if (wb.tag() == .integer) {
        return .{ .int = wb.peek().body.integer };
    } else if (wb.tag() == .float) {
        return .{ .float = wb.peek().body.float };
    }

    const int_result = objutil.integerGet(null, wb) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .float = try interp.getFloat(wb) },
    };

    return .{ .int = int_result };
}

pub fn getIntegerOrFloatInPlace(interp: *Interp, ref: *Handle) !IntegerOrFloat {
    var ref_wb: Shimmerable = .{ .original = ref.* };
    const result = interp.getIntegerOrFloat(&ref_wb);
    ref.* = ref_wb.consume();
    return result;
}

fn exprResultAsBool(interp: *Interp, result: *ExprResult) !bool {
    switch (result.*) {
        .int => |int| return int != 0,
        .float => |float| {
            try interp.setResultFormatted("expected boolean but got \"{}\"", .{float});
            return error.BadBoolean;
        },
        .owned_handle => |string| return try interp.getBooleanInPlace(string),
        .stack_handle => |*string| return try interp.getBooleanInPlace(string),
    }
}

fn boolToExprResult(value: bool) ExprResult {
    return .{ .int = @intFromBool(value) };
}

fn exprResultAsNumber(interp: *Interp, result: *ExprResult) !ExprResult {
    switch (result.*) {
        .int, .float => return result.*,
        .owned_handle => |string| {
            switch (try interp.getIntegerOrFloatInPlace(string)) {
                .int => |val| return .{ .int = val },
                .float => |val| return .{ .float = val },
            }
        },
        .stack_handle => |*string| {
            switch (try interp.getIntegerOrFloatInPlace(string)) {
                .int => |val| return .{ .int = val },
                .float => |val| return .{ .float = val },
            }
        },
    }
}

pub const negative_denom_message = "negative denominator";
fn exprBinaryOperatorInteger(interp: *Interp, oper: expr_parse.Node.Tag, lhs: i64, rhs: i64) !i64 {
    var det: ErrorDetails = undefined;
    return switch (oper) {
        .mul => blk: {
            break :blk std.math.mul(i64, lhs, rhs) catch {
                const rendered = std.math.mulWide(i64, lhs, rhs);
                return interp.wrapError(&det, objutil.integerOverflowErrorWithWide(&det, rendered));
            };
        },
        .div => std.math.divFloor(i64, lhs, rhs) catch |err| switch (err) {
            error.Overflow => {
                return interp.wrapError(&det, objutil.integerOverflowError(&det, null));
            },
            error.DivisionByZero => {
                interp.setResultInterned(.@"division by zero");
                return error.DivisionByZero;
            },
        },
        .mod => std.math.mod(i64, lhs, rhs) catch |err| switch (err) {
            error.NegativeDenominator => {
                try interp.setResultString(negative_denom_message);
                return error.NegativeDenominator;
            },
            error.DivisionByZero => {
                interp.setResultInterned(.@"division by zero");
                return error.DivisionByZero;
            },
        },
        .sub => std.math.sub(i64, lhs, rhs) catch return interp.wrapError(&det, objutil.integerOverflowError(&det, null)),
        .add => std.math.add(i64, lhs, rhs) catch return interp.wrapError(&det, objutil.integerOverflowError(&det, null)),
        .shiftl => blk: {
            const rhs_constrained: u6 = @intCast(std.math.clamp(rhs, 0, 64));
            break :blk @as(i64, @bitCast(@as(u64, @bitCast(lhs)) << rhs_constrained));
        },
        .shiftr => blk: {
            const rhs_constrained: u6 = @intCast(std.math.clamp(rhs, 0, 64));
            break :blk @as(i64, @bitCast(@as(u64, @bitCast(lhs)) >> rhs_constrained));
        },
        .rotl => blk: {
            const rhs_constrained: u6 = @intCast(std.math.clamp(rhs, 0, 64));
            break :blk @as(i64, @bitCast(std.math.rotl(u64, @bitCast(lhs), rhs_constrained)));
        },
        .rotr => blk: {
            const rhs_constrained: u6 = @intCast(std.math.clamp(rhs, 0, 64));
            break :blk @as(i64, @bitCast(std.math.rotr(u64, @bitCast(lhs), rhs_constrained)));
        },
        .less_than => @intFromBool(lhs < rhs),
        .greater_than => @intFromBool(lhs > rhs),
        .less_or_equal => @intFromBool(lhs <= rhs),
        .greater_or_equal => @intFromBool(lhs >= rhs),
        .equal => @intFromBool(lhs == rhs),
        .not_equal => @intFromBool(lhs != rhs),
        .bit_and => lhs & rhs,
        .bit_xor => lhs ^ rhs,
        .bit_or => lhs | rhs,
        .bool_and => @intFromBool((lhs != 0) and (rhs != 0)),
        .bool_or => @intFromBool((lhs != 0) or (rhs != 0)),
        .pow => std.math.powi(i64, lhs, rhs) catch {
            // Report overflow for both underflow and overflow. Maybe I should report both?
            return interp.wrapError(&det, objutil.integerOverflowError(&det, null));
        },
        else => unreachable,
    };
}

fn exprBinaryOperatorFloat(interp: *Interp, oper: expr_parse.Node.Tag, lhs: f64, rhs: f64) !ExprResult {
    return switch (oper) {
        .mul => .{ .float = lhs * rhs },
        .div => blk: {
            if (rhs == 0.0) {
                interp.setResultInterned(.@"division by zero");
                return error.DivisionByZero;
            } else {
                break :blk .{ .float = lhs / rhs };
            }
        },
        .mod => .{
            .float = std.math.mod(f64, lhs, rhs) catch |err| switch (err) {
                error.DivisionByZero => {
                    interp.setResultInterned(.@"division by zero");
                    return error.DivisionByZero;
                },
                error.NegativeDenominator => {
                    try interp.setResultString(negative_denom_message);
                    return error.NegativeDenominator;
                },
            },
        },
        .sub => .{ .float = lhs - rhs },
        .add => .{ .float = lhs + rhs },
        .shiftl, .shiftr, .rotl, .rotr => {
            try interp.setResultFormatted("cannot bit shift on floats {} and {}", .{ lhs, rhs });
            return error.BadInteger;
        },
        .less_than => boolToExprResult(lhs < rhs),
        .greater_than => boolToExprResult(lhs > rhs),
        .less_or_equal => boolToExprResult(lhs <= rhs),
        .greater_or_equal => boolToExprResult(lhs >= rhs),
        .equal => boolToExprResult(lhs == rhs),
        .not_equal => boolToExprResult(lhs != rhs),
        .bit_and, .bit_xor, .bit_or, .bool_and, .bool_or => {
            try interp.setResultFormatted("cannot do bitwise operations on floats {} and {}", .{ lhs, rhs });
            return error.BadInteger;
        },
        .pow => .{ .float = std.math.pow(f64, lhs, rhs) },
        else => unreachable,
    };
}

const ExprResult = union(enum) {
    int: i64,
    float: f64,
    /// An owned handle is owned by the expression. It can be shimmered, replaced, etc.
    owned_handle: *Handle,
    /// A temp handle is on the stack, so it needs to be referenced every time.
    stack_handle: Handle,

    pub fn release(result: ExprResult) void {
        switch (result) {
            .stack_handle => |handle| handle.decrRefCount(),
            .owned_handle => {
                // Owned by the expr, so no need to decr ref count.
            },
            .int, .float => {},
        }
    }

    pub fn toObject(result: ExprResult) !Handle {
        switch (result) {
            .int => |int| return try objutil.newInteger(int),
            .float => |float| return try objutil.newFloat(float),
            .owned_handle => |handle| return handle.borrow(),
            .stack_handle => |handle| return handle,
        }
    }
};
fn evalExpressionNode(interp: *Interp, nodes: std.MultiArrayList(expr_parse.Node), node_index: expr_parse.Node.Index) !ExprResult {
    const node_tag = nodes.items(.tag)[@intFromEnum(node_index)];
    const node_data: *expr_parse.Node.Data = &nodes.items(.data)[@intFromEnum(node_index)];
    switch (node_tag) {
        .mul,
        .div,
        .mod,
        .sub,
        .add,
        .shiftl,
        .shiftr,
        .rotl,
        .rotr,
        .less_than,
        .greater_than,
        .less_or_equal,
        .greater_or_equal,
        .equal,
        .not_equal,
        .bit_and,
        .bit_xor,
        .bit_or,
        .bool_and,
        .bool_or,
        .pow,
        => {
            const children = node_data.binary;
            var lhs_value = try interp.evalExpressionNode(nodes, children.@"0");
            defer lhs_value.release();
            var rhs_value = try interp.evalExpressionNode(nodes, children.@"1");
            defer rhs_value.release();
            const lhs_tag = std.meta.activeTag(lhs_value);
            const rhs_tag = std.meta.activeTag(rhs_value);

            // Fast case, both integers, or both floats.
            if (lhs_tag == .int and rhs_tag == .int) {
                return .{
                    .int = try interp.exprBinaryOperatorInteger(node_tag, lhs_value.int, rhs_value.int),
                };
            } else if (lhs_tag == .float and rhs_tag == .float) {
                return try interp.exprBinaryOperatorFloat(node_tag, lhs_value.float, rhs_value.float);
            }

            // Slow case: 1. try to get both as integers, 2. try getting both as floats, 3. error.
            const lhs_converted: ExprResult = try interp.exprResultAsNumber(&lhs_value);
            const rhs_converted: ExprResult = try interp.exprResultAsNumber(&rhs_value);

            if (std.meta.activeTag(lhs_converted) == .int and std.meta.activeTag(rhs_converted) == .int) {
                return .{
                    .int = try interp.exprBinaryOperatorInteger(node_tag, lhs_converted.int, rhs_converted.int),
                };
            } else {
                const lhs_as_float: f64 = switch (lhs_converted) {
                    .int => |int| @floatFromInt(int),
                    .float => |float| float,
                    .owned_handle, .stack_handle => unreachable,
                };
                const rhs_as_float: f64 = switch (rhs_converted) {
                    .int => |int| @floatFromInt(int),
                    .float => |float| float,
                    .owned_handle, .stack_handle => unreachable,
                };
                return try interp.exprBinaryOperatorFloat(node_tag, lhs_as_float, rhs_as_float);
            }
        },
        .string_equal,
        .string_not_equal,
        .string_in,
        .string_not_in,
        .string_less_than,
        .string_greater_than,
        .string_less_than_or_equal,
        .string_greater_than_or_equal,
        => {
            const children = node_data.binary;
            const lhs_value = try interp.evalExpressionNode(nodes, children.@"0");
            const rhs_value = try interp.evalExpressionNode(nodes, children.@"1");
            defer lhs_value.release();
            defer rhs_value.release();

            var lhs_buffer: [50]u8 = @splat(0);
            var lhs_alloc = std.heap.FixedBufferAllocator.init(lhs_buffer[0..]);
            const lhs_string = switch (lhs_value) {
                .float => |val| std.fmt.allocPrint(lhs_alloc.allocator(), "{}", .{val}) catch unreachable,
                .int => |val| std.fmt.allocPrint(lhs_alloc.allocator(), "{}", .{val}) catch unreachable,
                .owned_handle => |val| (try val.*.getString())[0..],
                .stack_handle => |val| (try val.getString())[0..],
            };
            var rhs_buffer: [50]u8 = @splat(0);
            var rhs_alloc = std.heap.FixedBufferAllocator.init(rhs_buffer[0..]);
            const rhs_string = switch (rhs_value) {
                .float => |val| std.fmt.allocPrint(rhs_alloc.allocator(), "{}", .{val}) catch unreachable,
                .int => |val| std.fmt.allocPrint(rhs_alloc.allocator(), "{}", .{val}) catch unreachable,
                .owned_handle => |val| (try val.*.getString())[0..],
                .stack_handle => |val| (try val.getString())[0..],
            };

            const result = switch (node_tag) {
                .string_equal => std.mem.eql(u8, lhs_string, rhs_string),
                .string_not_equal => !std.mem.eql(u8, lhs_string, rhs_string),
                .string_in => std.mem.indexOf(u8, rhs_string, lhs_string) != null,
                .string_not_in => std.mem.indexOf(u8, rhs_string, lhs_string) == null,
                .string_less_than => std.mem.order(u8, rhs_string, lhs_string).compare(.lt),
                .string_greater_than => std.mem.order(u8, rhs_string, lhs_string).compare(.gt),
                .string_less_than_or_equal => std.mem.order(u8, rhs_string, lhs_string).compare(.lte),
                .string_greater_than_or_equal => std.mem.order(u8, rhs_string, lhs_string).compare(.gte),
                inline else => unreachable,
            };

            return if (result) .{ .int = 1 } else .{ .int = 0 };
        },
        .ternary_conditional => {
            const children = node_data.ternary;
            var condition = try interp.evalExpressionNode(nodes, children.@"0");

            if (try exprResultAsBool(interp, &condition)) {
                return interp.evalExpressionNode(nodes, children.@"1");
            } else {
                return interp.evalExpressionNode(nodes, children.@"2");
            }
        },
        .string => {
            const obj = &node_data.object;
            obj.incrRefCount();
            return .{ .owned_handle = obj };
        },
        .integer => return .{ .int = node_data.integer },
        .float => return .{ .float = node_data.float },
        .command_subst => {
            const nested_cache_key = @as(u256, interp.callFrame().signature.cache_id) ^ try node_data.object.getHashNoRegister();
            const result = interp.evalObjectInner(interp.callFrameIdx(), node_data.object, nested_cache_key);

            if (result) {
                return .{ .stack_handle = interp.result.borrow() };
            } else |err| {
                return err;
            }
        },
        .variable_subst => {
            // This should not change, since it should be a local heap object.
            var det: ErrorDetails = undefined;
            const var_value = try interp.wrapError(&det, interp.getVariableOrErrorInner(&det, interp.callFrameIdx(), node_data.object));

            return .{ .stack_handle = var_value.borrow() };
        },
        .value_false => return .{ .int = 0 },
        .value_true => return .{ .int = 1 },
        .bool_not => {
            var result = try interp.evalExpressionNode(nodes, node_data.unary);
            defer result.release();
            const result_bool = try interp.exprResultAsBool(&result);
            return .{ .int = if (result_bool) 0 else 1 };
        },
        .bit_not => {
            var result = try interp.evalExpressionNode(nodes, node_data.unary);
            const value = switch (result) {
                .int => |val| val,
                .float => |val| {
                    try interp.setResultFormatted("cannot bit invert on float {}", .{val});
                    return error.BadInteger;
                },
                .owned_handle => |val| blk: {
                    break :blk try interp.getIntegerInPlace(val);
                },
                .stack_handle => |*val| blk: {
                    break :blk try interp.getIntegerInPlace(val);
                },
            };

            return .{ .int = ~value };
        },
        .identity => {
            var result = try interp.evalExpressionNode(nodes, node_data.unary);
            defer result.release();
            return try interp.exprResultAsNumber(&result);
        },
        .negation => {
            var result = try interp.evalExpressionNode(nodes, node_data.unary);
            defer result.release();
            const value = try interp.exprResultAsNumber(&result);
            switch (value) {
                .int => |int| return .{ .int = -int },
                .float => |float| return .{ .float = -float },
                .owned_handle, .stack_handle => unreachable,
            }
        },
        .to_int, .to_wide => {
            var result = try interp.evalExpressionNode(nodes, node_data.unary);
            defer result.release();
            const value = try interp.exprResultAsNumber(&result);
            switch (value) {
                .int => |int| return .{ .int = int },
                .float => |float| {
                    bad_int: {
                        if (float > @as(f64, @floatFromInt(std.math.maxInt(i64)))) break :bad_int;
                        if (float < @as(f64, @floatFromInt(std.math.minInt(i64)))) break :bad_int;
                        if (std.math.isNan(float)) break :bad_int;
                        return .{ .int = @intFromFloat(float) };
                    }
                    try interp.setResultFormatted("could not convert float \"{}\" to integer", .{float});
                    return error.BadInteger;
                },
                .owned_handle, .stack_handle => unreachable,
            }
        },
        .abs => {
            var result = try interp.evalExpressionNode(nodes, node_data.unary);
            defer result.release();
            const value = try interp.exprResultAsNumber(&result);
            switch (value) {
                .int => |int| {
                    if (@abs(int) > std.math.maxInt(i64)) {
                        var det: ErrorDetails = undefined;
                        return interp.wrapError(&det, objutil.integerOverflowErrorWithWide(&det, @abs(int)));
                    } else {
                        return .{ .int = @intCast(@abs(int)) };
                    }
                },
                .float => |float| return .{ .float = @abs(float) },
                .owned_handle, .stack_handle => unreachable,
            }
        },
        .to_double => {
            var result = try interp.evalExpressionNode(nodes, node_data.unary);
            defer result.release();
            const value = try interp.exprResultAsNumber(&result);
            switch (value) {
                .int => |int| return .{ .float = @floatFromInt(int) },
                .float => return value,
                .owned_handle, .stack_handle => unreachable,
            }
        },
        .round => {
            var result = try interp.evalExpressionNode(nodes, node_data.unary);
            defer result.release();
            const value = try interp.exprResultAsNumber(&result);
            switch (value) {
                .float => |float| return .{ .float = @round(float) },
                .int => return value,
                .owned_handle, .stack_handle => unreachable,
            }
        },
        .rand => {
            return .{ .float = interp.nextRandomFloat() };
        },
        .srand => {
            var result = try interp.evalExpressionNode(nodes, node_data.unary);
            defer result.release();
            const value = switch (result) {
                .int => |val| val,
                .float => |val| {
                    try interp.setResultFormatted("cannot seed random with {}", .{val});
                    return error.BadInteger;
                },
                .owned_handle => |val| try interp.getIntegerInPlace(val),
                .stack_handle => |*val| try interp.getIntegerInPlace(val),
            };

            interp.prng.seed(@bitCast(value));

            return .{ .float = interp.nextRandomFloat() };
        },
        .sin,
        .cos,
        .tan,
        .asin,
        .acos,
        .atan,
        .sinh,
        .cosh,
        .tanh,
        .ceil,
        .floor,
        .exp,
        .log,
        .log10,
        .sqrt,
        => {
            var result = try interp.evalExpressionNode(nodes, node_data.unary);
            defer result.release();
            const value = try interp.exprResultAsNumber(&result);
            const as_float: f64 = switch (value) {
                .int => |int| @floatFromInt(int),
                .float => |float| float,
                .owned_handle, .stack_handle => unreachable,
            };

            const computed = switch (node_tag) {
                .sin => @sin(as_float),
                .cos => @cos(as_float),
                .tan => @tan(as_float),
                .asin => std.math.asin(as_float),
                .acos => std.math.acos(as_float),
                .atan => std.math.atan(as_float),
                .sinh => std.math.sinh(as_float),
                .cosh => std.math.cosh(as_float),
                .tanh => std.math.tanh(as_float),
                .ceil => @ceil(as_float),
                .floor => @floor(as_float),
                .exp => @exp(as_float),
                .log => @log(as_float),
                .log10 => @log10(as_float),
                .sqrt => @sqrt(as_float),
                inline else => unreachable,
            };

            return .{ .float = computed };
        },
        .atan2, .fmod, .hypot => {
            var lhs_result = try interp.evalExpressionNode(nodes, node_data.binary.@"0");
            defer lhs_result.release();
            var rhs_result = try interp.evalExpressionNode(nodes, node_data.binary.@"0");
            defer rhs_result.release();
            const lhs_number = try interp.exprResultAsNumber(&lhs_result);
            const rhs_number = try interp.exprResultAsNumber(&rhs_result);
            const lhs: f64 = switch (lhs_number) {
                .int => |int| @floatFromInt(int),
                .float => |float| float,
                .owned_handle, .stack_handle => unreachable,
            };
            const rhs: f64 = switch (rhs_number) {
                .int => |int| @floatFromInt(int),
                .float => |float| float,
                .owned_handle, .stack_handle => unreachable,
            };

            const computed = switch (node_tag) {
                .atan2 => std.math.atan2(lhs, rhs),
                .fmod => @mod(lhs, rhs),
                .hypot => @sqrt(lhs * lhs + rhs + rhs),
                inline else => unreachable,
            };
            return .{ .float = computed };
        },
        .none => unreachable,
    }
}

pub fn evalExpression(interp: *Interp, handle: Handle) !ExprResult {
    // Combine the signature's cache id with the expression's content
    // hash, so identical expressions at different call sites get their
    // own cached variable lookups.
    var det: ErrorDetails = undefined;
    const cache_key = @as(u256, interp.callFrame().signature.cache_id) ^ try handle.getHashNoRegister();
    const expr: Heap.ParsedExpression = try interp.wrapError(&det, objutil.getExpression(&det, handle, cache_key));

    return evalExpressionNode(interp, expr.nodes, expr.root_node) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => {
            // Give the caller some context for what failed.
            try interp.setResultFormatted("error occured when evaluating expression {f}: {f}", .{ handle, interp.result });
            return error.EvalError;
        },
    };
}

pub fn getBoolFromExpression(interp: *Interp, handle: Handle) !bool {
    var expr_result = try interp.evalExpression(handle);
    defer expr_result.release();
    const value = interp.exprResultAsBool(&expr_result) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => error.EvalError,
    };
    return value;
}

test "eval expression" {
    defer Heap.testFinish();
    try Heap.testStart(testing.allocator, testing.io);
    var interp = try Interp.init();
    defer interp.deinit();

    var expr = try objutil.newString("5 + 10");
    defer expr.decrRefCount();
    const result = try interp.evalExpression(expr);
    try testing.expectEqual(ExprResult{ .int = 15 }, result);
}

pub fn evalSubstitution(interp: *Interp, handle: Handle, flags: Tokenizer.SubstFlags) !Handle {
    var cache_key: u256 = try handle.getHashNoRegister();
    // Combine the signature's cache id with the expression's content
    // hash, so identical expressions at different call sites get their
    // own cached variable lookups.
    cache_key ^= @as(u256, interp.callFrame().signature.cache_id);
    // Also make sure to include the flags in the cache id.
    cache_key ^= @as(u256, @as(u3, @bitCast(flags))) << @sizeOf(@TypeOf(interp.callFrame().signature.cache_id));

    var det: ErrorDetails = undefined;
    const subst: Heap.Substitution = try interp.wrapError(&det, objutil.getSubstitution(&det, handle, cache_key, flags));
    assert(subst.flags == flags); // Integrity check.

    return try interp.interpolateTokens(subst.subst.tags.items, subst.subst.values, 0, @intCast(subst.subst.tags.items.len));
}

pub fn setErrorStack(interp: *Interp) error{OutOfMemory}!void {
    if (interp.stack_trace != .none) return;
    interp.stack_trace.swap(try buildErrorStack(interp));
}

/// Builds the stack trace as a flat list of {name file line args} repeated once per call
/// frame. The top (innermost) frame is emitted first.
fn buildErrorStack(interp: *Interp) error{OutOfMemory}!Handle {
    var trace = try objutil.newListWithCapacity(@intCast(interp.eval_frames.items.len * 4));
    errdefer trace.decrRefCount();

    var last_call_frame_idx: ?u32 = null;

    // Eval frames are walked from top to bottom. Each one is followed to its
    // corresponding call frame.
    var i = interp.eval_frames.items.len;
    while (i > 0) {
        i -= 1;
        const eval_frame = &interp.eval_frames.items[i];

        // Skip duplicates by taking the topmost eval frame per call frame.
        if (last_call_frame_idx == eval_frame.call_frame) continue;
        last_call_frame_idx = eval_frame.call_frame;

        const call_frame = &interp.call_frames.items[eval_frame.call_frame];
        const closure_name = call_frame.signature.name.orEmpty();

        const source_info = objutil.getSourceInfo(eval_frame.currently_evaluating);
        const file_name = if (source_info) |info| info.file_name.orEmpty() else Heap.local_heap.emptyHandle();
        const base_line = if (source_info) |info| info.line_no else null;

        const base = if (base_line) |val| val else 1;
        const absolute_line = base + eval_frame.current_line;

        const args_list = try objutil.newListWithCapacity(@intCast(eval_frame.args.len));
        defer args_list.decrRefCount();

        for (eval_frame.args) |arg| {
            objutil.listAppendAssumeCapacity(args_list, arg.original.reference());
        }

        objutil.listAppendAssumeCapacity(trace, closure_name.dupOrRef());
        objutil.listAppendAssumeCapacity(trace, file_name.dupOrRef());
        objutil.listAppendAssumeCapacity(trace, objutil.integerObject(@intCast(absolute_line)));
        objutil.listAppendAssumeCapacity(trace, args_list.dupOrRef());
    }

    return trace;
}

/// Self will be returned borrowed. Caller is responsible for decrementing the ref count.
fn getCommandAndSelfParam(interp: *Interp, args: []Shimmerable) !struct { command: ?CommandOrClosure, self: OptionalHandle } {
    const command = interp.getCommand(interp.callFrameIdx(), &args[0], true) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EvalError => return error.EvalError,
        error.CommandNotFound => {
            // If the command name is unknown, we don't know if it's a method or not,
            // so we'll pretend like it's a function and invoke [unknown] with the
            // args passed in, and not inject self.
            try interp.invokeUnknown(args);
            return .{ .command = null, .self = .none };
        },
    };

    const is_method = switch (command) {
        .closure => |closure| closure.closure.is_method,
        .command => false,
    };
    if (is_method) {
        // `interp.getCommand` already made sure `args[0]` is a variable, so we can just
        // check if it's .dict_sugar.
        const method_dict_path = &args[0];
        if (method_dict_path.tag() != .dict_sugar) {
            try interp.setResultFormatted("method \"{f}\" cannot be invoked as function", .{method_dict_path.current()});
            return error.EvalError;
        }
        const dict_sugar = method_dict_path.peek().body.dict_sugar;

        // Next, we need to find `self`, the second-to-last part of the dict path. For example, calling
        // foo::bar would have foo as `self`, or foo::bar::baz would have foo::bar as `self`.
        const dict_name = method_dict_path.current().getHeap().getHandle(dict_sugar.dict_name_index);
        const dict_resolved = interp.getVariableOrErrorInner(null, interp.callFrameIdx(), dict_name) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // This should always succeed, since when `interp.getCommand` was run earlier,
            // it ensured that the dict sugar resolved to something.
            else => unreachable,
        };
        const dict_path = method_dict_path.current().getHeap().getHandle(dict_sugar.path_index);

        var handles = try objutil.listToHandles(Heap.global_gpa, dict_path);
        defer handles.deinit(Heap.global_gpa);
        const all_but_last = handles.items[0..(handles.items.len - 1)];

        var dict_wb: Shimmerable = .{ .original = dict_resolved };
        const method_ctx = objutil.HandleSliceContext{ .items = all_but_last };
        var det: ErrorDetails = undefined;
        const maybe_self: OptionalHandle = try interp.wrapError(
            &det,
            objutil.dictLookupRecursively(&det, &dict_wb, method_ctx),
        );
        if (dict_wb.shimmered.toHandle()) |new_dict| {
            det = undefined;
            try interp.wrapError(&det, interp.setVariableInner(&det, interp.callFrameIdx(), dict_name, new_dict.referenceOwning()));
        }

        if (maybe_self.toHandle()) |self| {
            return .{ .command = command, .self = self.borrow().toOptional() };
        } else {
            const var_name = try method_dict_path.getString();
            // Shave off the end, because we're looking up `self`, not the method in this case.
            var ending = std.mem.lastIndexOf(u8, var_name, "::").?;
            while (ending > 0 and var_name[ending - 1] == ':') ending -= 1;
            try interp.setResultFormatted("can't read \"{s}\": no such variable", .{var_name[0..ending]});
            return error.EvalError;
        }
    } else {
        return .{ .command = command, .self = .none };
    }
}

/// Takes care of populating the `self` parameter. `args_raw` should be one item
/// larger than `args`, and `args` should be `args_raw[1..]`. If called with a
/// method, `args_raw[1]` will become `args_raw[0]`, opening up a space for the
/// `self` parameter.
fn invokeCommandMaybeMethod(
    interp: *Interp,
    args_raw: []Shimmerable,
) CommandError!void {
    var args = args_raw[1..];

    const cmd_and_self = try interp.getCommandAndSelfParam(args);
    const command = if (cmd_and_self.command) |val| val else {
        // [unknown] was invoked and terminated normally, so there's nothing else to do.
        return;
    };
    const maybe_self = cmd_and_self.self;

    // If the command ended up being a method, we move the command name to the
    // left, which opens up a hole for putting the `self` argument in.
    if (maybe_self.toHandle()) |self| {
        args_raw[0] = args_raw[1]; // Move command name to the left.
        args_raw[1] = .{ .original = self };
        args = args_raw[0..]; // Include all the allocated args now.
    }

    // Now that we've populated the arguments for this command, we'll go ahead and run it.
    try interp.invokeCommand(command, args);

    if (maybe_self.toHandle()) |_| {
        // Be sure to write back `self`.

        const call_frame = interp.callFrameIdx();
        const method_dict_path = &args[0];
        // `self` is returned back through `args[1]`.
        const new_self = &args[1];
        new_self.current().assert(new_self.asMutable().mutated != .none);

        // Make sure `method_dict_path` is still .dict_sugar, as it technically could have shimmered.
        var det: ErrorDetails = undefined;
        try method_dict_path.ensureShimmerable();

        const ensure_result = try interp.wrapError(
            &det,
            interp.ensureValidVariableType(&det, call_frame, method_dict_path.current()),
        );
        switch (ensure_result) {
            .not_found => {
                try interp.setResultFormatted(
                    "Could not update \"{f}\" as it was unset when calling method",
                    .{objutil.listItem(command.closure.closure.args, 0)},
                );
                return error.EvalError;
            },
            .normal => unreachable,
            .dict_sugar => {
                // What we want.
                try shimmerToDictSugarAssumeValid(method_dict_path.current());
            },
        }

        method_dict_path.current().assert(method_dict_path.tag() == .dict_sugar);
        const dict_sugar = method_dict_path.peek().body.dict_sugar;

        const dict_name = method_dict_path.current().getHeap().getHandle(dict_sugar.dict_name_index);
        const dict_resolved = interp.getVariableOrErrorInner(&det, call_frame, dict_name) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.LinkLookupFailed, error.VariableNotFound, error.BadDict, error.BadVariableName => {
                interp.setResultOwning(det.message);
                return error.EvalError;
            },
        };
        const dict_path = method_dict_path.current().getHeap().getHandle(dict_sugar.path_index);

        if (objutil.listLength(dict_path) == 1) {
            interp.setVariableInner(&det, call_frame, dict_name, new_self.current().reference()) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.LinkLookupFailed, error.BadVariableName => {
                    interp.setResultOwning(det.message);
                    return error.EvalError;
                },
            };
        } else {
            var handles = try objutil.listToHandles(Heap.global_gpa, dict_path);
            defer handles.deinit(Heap.global_gpa);
            const all_but_last = handles.items[0..(handles.items.len - 1)];

            var dict_resolved_wb: Mutable = .{ .original = dict_resolved };
            const put_ctx = objutil.HandleSliceContext{ .items = all_but_last };
            _ = try interp.wrapError(&det, objutil.dictPutRecursively(
                &det,
                &dict_resolved_wb,
                put_ctx,
                new_self.current().reference(),
            ));

            if (dict_resolved_wb.mutated.toHandle()) |new_dict| {
                interp.setVariableInner(&det, call_frame, dict_name, new_dict.referenceOwning()) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.LinkLookupFailed, error.BadVariableName => {
                        interp.setResultOwning(det.message);
                        return error.EvalError;
                    },
                };
            }
        }
    }
}

fn evalCommand(interp: *Interp, call_frame: u32, script: Handle, parsed: Heap.ParsedScript, command_token_i: *u32) !void {
    _ = try interp.pushEvalFrame(call_frame, script);
    defer interp.popEvalFrame();

    const tags = parsed.tags.items;
    const values = objutil.listItems(parsed.values);

    // First token of the command is always .parsed_script_command.
    const first_token = objutil.listItemNoFollow(parsed.values, command_token_i.*);
    first_token.assert(first_token.tag() == .parsed_script_command);
    const command_info = first_token.peek().body.parsed_script_command;
    command_token_i.* += 1; // Skip .parsed_script_command.
    interp.currentEvalFrame().current_line = command_info.line;

    // `args_raw` has one extra space at the beginning that can be used to store the
    // `self` param if needed later on. We don't do the shifting in this function though.
    var sf = std.heap.stackFallback(@sizeOf(Handle) * 8, Heap.global_gpa);
    var args_alloc = sf.get();
    var args_raw = try args_alloc.alloc(Shimmerable, command_info.word_count + 1);
    defer args_alloc.free(args_raw);
    // Contains what is considered to be the current arguments.
    var args = args_raw[1..];
    args_raw[0] = .{ .original = Heap.local_heap.emptyHandle() };

    {
        // This is not always the same as which word token we're on, as argument expansion
        // may write multiple arguments from one word.
        var args_written: usize = 0;
        errdefer for (args[0..args_written]) |*arg| arg.deinit();

        // Populate the arguments by looping through each word of the command and
        // substituting.
        var word_token_i: u32 = command_token_i.*;
        // We don't know the length of each word, but we know there's `word_count` words,
        // so we advance `word_count` times.
        for (0..command_info.word_count) |_| {
            var word_parts: u32 = 1;
            const argument_expansion = tags[word_token_i] == .argument_expansion;
            if (tags[word_token_i] == .start_of_word or argument_expansion) {
                word_parts = @intCast(values[word_token_i].body.integer);
                word_token_i += 1;
            }

            var resultant_word: Handle = blk: {
                if (word_parts == 1) {
                    // Simple one-to-one substitution, so an easy case.
                    const res = try interp.substituteOneToken(
                        tags[word_token_i],
                        objutil.listItem(parsed.values, word_token_i),
                    );
                    word_token_i += 1;
                    break :blk res;
                } else {
                    // Helper function that'll interpolate all the word
                    // parts and merge them into a string.
                    const res = try interp.interpolateTokens(
                        tags[word_token_i..][0..word_parts],
                        parsed.values,
                        word_token_i,
                        word_parts,
                    );
                    word_token_i += word_parts;
                    break :blk res;
                }
            };

            if (argument_expansion) {
                // Argument expansion, so we'll need to shimmer the result to a list.
                const expansion_len = try interp.getListLengthInPlace(&resultant_word);
                defer resultant_word.decrRefCount();

                if (expansion_len != 1) {
                    // Expanded into multiple tokens, so we'll need to resize args.
                    // Note: len == 0 means the word disappears, so we shrink by 1.
                    args_raw = try args_alloc.realloc(args_raw, args_raw.len + expansion_len - 1);
                    args = args_raw[1..];
                }

                for (0..expansion_len) |list_idx| {
                    args[args_written] = .{ .original = objutil.listItem(resultant_word, @intCast(list_idx)).borrow() };
                    args_written += 1;
                }
            } else {
                args[args_written] = .{ .original = resultant_word };
                args_written += 1;
            }
        }

        assert(args_written == args.len);

        command_token_i.* = word_token_i;
    }
    defer for (args_raw) |*arg| arg.deinit();

    try interp.invokeCommandMaybeMethod(args_raw);
}

pub fn evalObjectInner(interp: *Interp, call_frame: u32, script: Handle, cache_key: u256) EvalError!void {
    // Try to get the script, parsing if necessary.
    var det: ErrorDetails = undefined;
    const parsed: Heap.ParsedScript = try interp.wrapError(&det, objutil.getScript(&det, script, cache_key));
    // Don't evaluate empty scripts.
    if (parsed.tags.items.len <= 1) return;

    // Reset the interpreter result. This is useful to return the empty result in the case of empty program.
    interp.setEmptyResult();

    // TODO implement JIM_OPTIMIZATION speedups

    // Execute every command sequentially until the end of the script or an error occurs.
    var command_token_i: u32 = 0;

    // Loop through the script's commands.
    while (command_token_i < parsed.tags.items.len) {
        const token_i_at_start = command_token_i;

        const command_result = interp.evalCommand(call_frame, script, parsed, &command_token_i);

        // TODO actually check for signals.
        if (false) {
            return error.Signal;
        } else {
            command_result catch |err| switch (err) {
                error.PropagateResult => {
                    interp.return_propagate.left_to_go -= 1;
                    if (interp.return_propagate.left_to_go == 0) {
                        if (interp.return_propagate.return_at_end) |return_at_end| {
                            return return_at_end;
                        } else {
                            // Equivalent of TCL_OK.
                            return;
                        }
                    } else {
                        return error.PropagateResult;
                    }
                },
                else => |narrowed_err| {
                    if (narrowed_err == error.OutOfMemory) {
                        // In the case of OOM, the inside function almost certainly didn't
                        // set a result, so we set it here.
                        interp.setResultInterned(.@"out of memory");
                        interp.pending_error_code.swap(Heap.local_heap.getInternedString(.@"ZICL OOM"));
                    }

                    if (narrowed_err == error.WrongUsage) {
                        try interp.setResultString("FIXME: prolly should explain how to use the command");
                    }

                    if (narrowed_err == error.EvalError) {
                        if (interp.stack_trace == .none) {
                            // Something went wrong when initializing the eval frame,
                            // so we'll set up a dummy frame, so there's at least a
                            // line number and file name.
                            const frame = try interp.pushEvalFrame(call_frame, script);
                            defer interp.popEvalFrame();

                            const first_token = objutil.listItem(parsed.values, token_i_at_start);
                            first_token.assert(first_token.tag() == .parsed_script_command);
                            const command_info = first_token.peek().body.parsed_script_command;

                            interp.eval_frames.items[frame].current_line = command_info.line;

                            try interp.setErrorStack();
                        } else {
                            try interp.setErrorStack();
                        }
                    }

                    return narrowToEvalError(narrowed_err);
                },
            };
        }
    }
}

/// Return code values matching Tcl's convention.
pub const ReturnCode = enum(u8) {
    ok = 0,
    @"error" = 1,
    @"return" = 2,
    @"break" = 3,
    @"continue" = 4,
    signal = 5,
    exit = 6,
    oom = 7,
    usage = 8,
    tailcall = 9,
    _,

    pub fn fromErrorUnion(value: Error!void) ReturnCode {
        if (value) {
            return .ok;
        } else |err| {
            return ReturnCode.fromError(err);
        }
    }

    pub fn fromError(err: Error) ReturnCode {
        return switch (err) {
            error.EvalError => .@"error",
            error.PropagateResult => .@"return",
            error.Break => .@"break",
            error.Continue => .@"continue",
            error.Signal => .signal,
            error.Exit => .exit,
            error.OutOfMemory => .oom,
            error.WrongUsage => .usage,
            error.Tailcall => .tailcall,
        };
    }

    pub fn toError(self: ReturnCode) Error!void {
        switch (self) {
            .ok => return,
            .@"error" => return error.EvalError,
            .@"return" => return error.PropagateResult,
            .@"break" => return error.Break,
            .@"continue" => return error.Continue,
            .signal => return error.Signal,
            .exit => return error.Exit,
            .oom => return error.OutOfMemory,
            .usage => return error.WrongUsage,
            .tailcall => return error.Tailcall,
        }
    }
};
pub const ReturnCodeEnum = objutil.TclEnum(Interp.ReturnCode, "return code", true);

pub fn evalObject(interp: *Interp, script: Handle) EvalError!void {
    // Reset the stack trace at each new top-level invocation.
    interp.stack_trace.swapWithNone();
    const cache_key = @as(u256, interp.callFrame().signature.cache_id) ^ try script.getHashNoRegister();
    return evalObjectInner(interp, interp.callFrameIdx(), script, cache_key);
}

pub fn evalFile(interp: *Interp, filename: []const u8) EvalError!void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        Heap.global_io,
        filename,
        Heap.global_gpa,
        .unlimited,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try interp.setResultFormatted("couldn't read file \"{s}\": {}", .{ filename, err });
            return;
        },
    };
    defer Heap.global_gpa.free(bytes);

    const filename_handle = try objutil.newString(filename);
    defer filename_handle.decrRefCount();
    const script = try objutil.newString(bytes);
    defer script.decrRefCount();
    try objutil.setSourceInfo(script, .{
        .file_name = filename_handle.toOptional(),
        .line_no = 1,
    });

    try interp.evalObject(script);
}

pub fn init() !Interp {
    const unknown_str = try objutil.newString("unknown");
    errdefer unknown_str.decrRefCount();

    var new_interp: Interp = .{
        .result = Heap.local_heap.emptyHandle(),
        .eval_frames = .empty,
        .call_frames = .empty,
        .current_call_epoch = global_call_epoch.fetchAdd(1, .monotonic) + 1,
        .global_procedure_epoch = 0,
        .global_commands = .empty,
        .eval_depth = 0,
        .max_eval_depth = 1000,
        .max_call_depth = 1000,
        .unknown_depth = 0,
        .unknown_str = unknown_str,
        .stack_trace = .none,
        .pending_error_code = .none,
        .pending_error_during = .none,
        .signal_depth = 0,
        .signal = 0,
        // TODO: init per interpreter
        .prng = .init(0),
    };

    _ = try new_interp.pushCallFrame(&.{}, .{
        .args = Heap.local_heap.emptyHandle(),
        .body = Heap.local_heap.emptyHandle(),
        .name = .none,
        .scope_hash_ref = .none,
        .required_arity = 0,
        .optional_arity = 0,
        .optional_values = .none,
        .has_args_parameter = false,
        .is_method = false,
        .cache_id = Heap.nextCacheId(),
    });
    errdefer new_interp.call_frames.deinit(Heap.global_gpa);
    errdefer new_interp.call_frames.items[0].deinit();

    _ = try new_interp.eval_frames.append(Heap.global_gpa, .{
        .args = &.{},
        .call_frame = 0,
        .current_line = 0,
        .currently_evaluating = Heap.local_heap.emptyHandle(),
    });
    errdefer new_interp.eval_frames.deinit(Heap.global_gpa);

    return new_interp;
}

pub fn deinit(interp: *Interp) void {
    interp.result.decrRefCount();
    interp.stack_trace.decrOptional();
    interp.pending_error_code.decrOptional();
    interp.unknown_str.decrRefCount();
    interp.global_commands.deinit(Heap.global_gpa);

    // Deinit all frames.
    for (interp.call_frames.items) |*frame| {
        frame.deinit();
    }
    interp.call_frames.deinit(Heap.global_gpa);

    interp.eval_frames.deinit(Heap.global_gpa);
}

// Export various utility functions with a nicer interface.
pub fn integerOverflowError(interp: *Interp, value: ?[]const u8) error{ OutOfMemory, EvalError } {
    var det: ErrorDetails = undefined;
    interp.wrapError(&det, objutil.integerOverflowError(&det, value)) catch return error.EvalError;
}

pub fn wrapShimmerFn(
    interp: *Interp,
    wb: *objutil.Shimmerable,
    to_call: fn (?*ErrorDetails, *objutil.Shimmerable) anyerror!void,
) !void {
    var det: ErrorDetails = undefined;
    try wrapError(interp, &det, to_call(&det, wb));
}

pub fn wrapShimmerInPlaceFn(
    interp: *Interp,
    ref: *Handle,
    to_call: fn (?*ErrorDetails, *objutil.Shimmerable) anyerror!void,
) !void {
    var ref_wb: Shimmerable = .{ .original = ref.* };
    var det: ErrorDetails = undefined;
    try wrapError(interp, &det, to_call(&det, &ref_wb));
    ref.* = ref_wb.consume();
}

pub fn wrapMutableFn(
    interp: *Interp,
    wb: *objutil.Mutable,
    to_call: fn (?*ErrorDetails, *objutil.Mutable) anyerror!void,
) !void {
    var det: ErrorDetails = undefined;
    try wrapError(interp, &det, to_call(&det, wb));
}

/// Shimmers `wb` to `.integer`. Returns the `i64` value.
pub fn getInteger(interp: *Interp, wb: *objutil.Shimmerable) !i64 {
    try interp.wrapShimmerFn(wb, objutil.shimmerToInteger);
    return wb.peek().body.integer;
}

pub fn getIntegerInPlace(interp: *Interp, ref: *Handle) !i64 {
    try interp.wrapShimmerInPlaceFn(ref, objutil.shimmerToInteger);
    return ref.peek().body.integer;
}

pub fn getIntegerNoShimmer(interp: *Interp, handle: Handle) Interp.Error!i64 {
    var det: ErrorDetails = undefined;
    return interp.wrapError(&det, objutil.integerGetNoShimmer(&det, handle));
}

/// Shimmers `wb` to `.float`. Returns the `f64` value.
pub fn getFloat(interp: *Interp, wb: *objutil.Shimmerable) !f64 {
    try interp.wrapShimmerFn(wb, objutil.shimmerToFloat);
    return wb.peek().body.float;
}

pub fn getFloatNoShimmer(interp: *Interp, handle: Handle) Interp.Error!f64 {
    var det: ErrorDetails = undefined;
    return interp.wrapError(&det, objutil.floatGetNoShimmer(&det, handle));
}

/// Shimmers `wb` to `.bool`. Returns the `bool` value.
pub fn getBoolean(interp: *Interp, wb: *objutil.Shimmerable) !bool {
    try interp.wrapShimmerFn(wb, objutil.shimmerToBoolean);
    return wb.peek().body.bool.data;
}

pub fn getBooleanInPlace(interp: *Interp, ref: *Handle) !bool {
    try interp.wrapShimmerInPlaceFn(ref, objutil.shimmerToBoolean);
    return ref.peek().body.bool.data;
}

/// Shimmers `wb` to `.index`. Returns the `Heap.ListIndex` value.
pub fn getIndex(interp: *Interp, wb: *objutil.Shimmerable) !Heap.ListIndex {
    try interp.wrapShimmerFn(wb, objutil.shimmerToIndex);
    return wb.peek().body.index.data;
}

/// Shimmers `wb` to `.hash_reference`. Returns the resolved handle.
pub fn resolveHash(interp: *Interp, wb: *objutil.Shimmerable) !Handle {
    try interp.wrapShimmerFn(wb, objutil.shimmerToHashReference);
    return wb.peek().body.hash_reference;
}

/// Shimmers a handle to a dict, updating it in place if a duplicate was
/// created. Converts errors to EvalError via the interpreter result.
pub fn shimmerToDict(interp: *Interp, wb: *objutil.Shimmerable) !void {
    try interp.wrapShimmerFn(wb, objutil.shimmerToDict);
}

/// Shimmers a handle to a list, updating it in place if a duplicate was
/// created. Converts errors to EvalError via the interpreter result.
pub fn shimmerToList(interp: *Interp, wb: *objutil.Shimmerable) !void {
    try interp.wrapShimmerFn(wb, objutil.shimmerToList);
}

pub fn shimmerToListInPlace(interp: *Interp, ref: *Handle) !void {
    try interp.wrapShimmerInPlaceFn(ref, objutil.shimmerToList);
}

/// Shimmers `wb` to `.list` and returns the item count.
pub fn getListLength(interp: *Interp, wb: *objutil.Shimmerable) !u32 {
    try interp.wrapShimmerFn(wb, objutil.shimmerToList);
    return wb.peek().body.list.len;
}

pub fn getListLengthInPlace(interp: *Interp, ref: *Handle) !u32 {
    try interp.wrapShimmerInPlaceFn(ref, objutil.shimmerToList);
    return ref.peek().body.list.len;
}

/// Appends `item` to `wb` (which is shimmered to a list first). Returns a
/// non-owning handle to the appended item.
pub fn listAppend(interp: *Interp, wb: *objutil.Mutable, item: Handle) !Handle {
    var det: ErrorDetails = undefined;
    try interp.wrapError(&det, objutil.shimmerToList(&det, wb.asShimmerable()));
    return try interp.wrapError(&det, objutil.listAppend(&det, wb, item));
}

pub fn listAppendInPlace(interp: *Interp, ref: *Handle, item: Handle) !Handle {
    var wb: Mutable = .{ .original = ref.* };
    const result = try interp.listAppend(&wb, item);
    ref.* = wb.consume();
    return result;
}

pub fn getCodepointLength(interp: *Interp, wb: *Shimmerable) !usize {
    _ = interp;
    return try objutil.getCodepointLength(wb);
}

pub fn setVariableToObject(interp: *Interp, name: *Shimmerable, obj: Heap.Object) !void {
    try name.ensureShimmerable();
    var det: ErrorDetails = undefined;
    try interp.wrapError(&det, interp.setVariableInner(&det, interp.callFrameIdx(), name.current(), obj));
}

pub fn setVariableSilent(interp: *Interp, name: *Shimmerable, handle: Handle) !void {
    try name.ensureShimmerable();
    try interp.setVariableInner(null, interp.callFrameIdx(), name.*, handle.dupOrRef());
}

pub fn setVariableTo(interp: *Interp, name: *Shimmerable, handle: Handle) !void {
    try name.ensureShimmerable();
    var det: ErrorDetails = undefined;
    try interp.wrapError(&det, interp.setVariableInner(&det, interp.callFrameIdx(), name.current(), handle.dupOrRef()));
}

pub fn getVariable(interp: *Interp, name: *Shimmerable) !OptionalHandle {
    try name.ensureShimmerable();

    var det: ErrorDetails = undefined;
    const value = interp.getVariableInner(&det, interp.callFrameIdx(), name.current()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadDict, error.LinkLookupFailed, error.BadVariableName => {
            interp.setResultOwning(det.message);
            return error.EvalError;
        },
    };
    return OptionalHandle.fromHandle(value);
}

pub fn getVariableOrError(interp: *Interp, name: *Shimmerable) !Handle {
    try name.ensureShimmerable();
    var det: ErrorDetails = undefined;
    return try interp.wrapError(&det, interp.getVariableInner(&det, interp.callFrameIdx(), name.current())) orelse {
        try interp.setResultFormatted("can't read \"{f}\": no such variable", .{name.current()});
        return error.EvalError;
    };
}

pub fn unsetVariable(interp: *Interp, name: *Shimmerable) !void {
    try name.ensureShimmerable();
    var det: ErrorDetails = undefined;
    try interp.wrapError(&det, interp.unsetVariableInner(&det, interp.callFrameIdx(), name.current()));
}

pub fn unsetVariableSilent(interp: *Interp, name: *Shimmerable) !void {
    try name.ensureShimmerable();
    try interp.unsetVariableInner(null, interp.callFrameIdx(), name.current());
}

pub fn getDictValue(interp: *Interp, dict: Handle, new_dict: OptionalHandle, key: Handle) Interp.Error!?Handle {
    var det: ErrorDetails = undefined;
    try interp.wrapError(&det, objutil.shimmerToDict(&det, dict));
    return try interp.wrapError(det, objutil.dictLookupFollowLinks(det, new_dict.orElse(dict), new_dict, key));
}

pub fn getDictValueOrError(interp: *Interp, dict: Handle, new_dict: OptionalHandle, key: Handle) Interp.Error!?Handle {
    const result = interp.getDictValue(dict, new_dict, key);
    if (result.value) |val| {
        return val;
    } else {
        try interp.setResultFormatted("could not find value for key \"{f}\"", .{key});
        return error.EvalError;
    }
}

pub fn getDictValueInPlace(interp: *Interp, dict: *Handle, key: Handle) !?Handle {
    var maybe_new_dict: OptionalHandle = .none;
    const result = try interp.getDictValue(dict.*, &maybe_new_dict, key);
    dict.swapIfNew(maybe_new_dict);
    return result;
}

pub fn getDictValueRecursively(interp: *Interp, wb: *Shimmerable, context: anytype) Interp.Error!OptionalHandle {
    var det: ErrorDetails = undefined;
    return try interp.wrapError(&det, objutil.dictLookupRecursively(&det, wb, context));
}

pub fn getDictValueRecursivelyOrError(interp: *Interp, wb: *Shimmerable, context: anytype) Interp.Error!Handle {
    const result = try interp.getDictValueRecursively(wb, context);
    if (result.toHandle()) |val| return val;

    // Else, create a useful error message.
    if (context.len() == 1) {
        try interp.setResultFormatted("could not find value for key \"{f}\"", .{context.get(0)});
    } else {
        const keys_list = try objutil.newListWithCapacity(@intCast(context.len()));
        defer keys_list.decrRefCount();
        for (0..context.len()) |i| objutil.listAppendAssumeCapacity(keys_list, context.get(i).dupOrRef());

        try interp.setResultFormatted("could not find value for keys \"{f}\"", .{keys_list});
    }

    return error.EvalError;
}

pub fn putDictValue(interp: *Interp, wb: *Mutable, key: Handle, value: Handle) Interp.Error!Handle {
    var det: ErrorDetails = undefined;
    try interp.wrapError(&det, objutil.shimmerToDict(&det, wb.asShimmerable()));
    return try objutil.dictPut(wb, key, value);
}

/// Like `putDictValue`, but updates the dict handle in place when the dict
/// has to be moved (e.g. because it was shared or inline).
pub fn putDictValueInPlace(interp: *Interp, ref: *Handle, key: Handle, value: Handle) Interp.Error!Handle {
    var ref_wb: Mutable = .{ .original = ref.* };
    const result = try interp.putDictValue(&ref_wb, key, value);
    ref.* = ref_wb.consume();
    return result;
}

pub fn putDictValueRecursively(interp: *Interp, wb: *Mutable, context: anytype, value: Handle) Interp.Error!Handle {
    var det: ErrorDetails = undefined;
    return try interp.wrapError(&det, objutil.dictPutRecursively(&det, wb, context, value.dupOrRef()));
}

/// Returns whether the value was removed.
pub fn removeDictValue(interp: *Interp, original: Handle, new: *OptionalHandle, key: Handle) !bool {
    errdefer new.swapWithNone();

    var det: ErrorDetails = undefined;
    try interp.wrapError(&det, objutil.shimmerToDict(&det, original, new));
    return try interp.wrapError(&det, objutil.dictRemove(&det, original, new, key));
}

pub fn removeDictValueRecursively(interp: *Interp, dict: *Mutable, context: anytype) Interp.Error!bool {
    var det: ErrorDetails = undefined;
    return try interp.wrapError(&det, objutil.dictRemoveRecursively(&det, dict, context));
}

test "recursive dict keys" {
    defer Heap.testFinish();
    try Heap.testStart(testing.allocator, testing.io);
    var interp = try Interp.init();
    defer interp.deinit();

    var dict: Mutable = .{ .original = try objutil.newDict(&.{}) };
    defer dict.deinit();
    var key_foo = try objutil.newString("foo");
    defer key_foo.decrRefCount();
    var key_bar = try objutil.newString("bar");
    defer key_bar.decrRefCount();
    var key_baz = try objutil.newString("baz");
    defer key_baz.decrRefCount();
    const value_qux = try objutil.newString("qux");
    defer value_qux.decrRefCount();

    _ = try interp.putDictValueRecursively(
        &dict,
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar, key_baz } },
        value_qux,
    );
    try testing.expectEqualStrings("foo {bar {baz qux}}", try dict.getString());

    // Try taking ownership of one of the intermediate dictionaries.
    const to_take = (try interp.getDictValueRecursively(
        dict.asShimmerable(),
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar } },
    )).toHandle().?;

    // See if setting still works correctly.
    _ = try interp.putDictValueRecursively(
        &dict,
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar, key_baz } },
        value_qux,
    );
    try testing.expectEqual(1, to_take.getRefCount());

    // Let's try some very cursed aliasing.
    _ = try interp.putDictValueRecursively(
        &dict,
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar } },
        objutil.dictItemNoFollow(dict.current(), 0),
    );
    try testing.expectEqualStrings("foo {bar foo}", try dict.getString());

    const value_result = (try interp.getDictValueRecursively(
        dict.asShimmerable(),
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar } },
    )).toHandle().?;
    try testing.expectEqualStrings("foo", try value_result.getString());
}

fn testRecursiveDictRemoval(ta: std.mem.Allocator) !void {
    defer Heap.testFinish();
    try Heap.testStart(ta, testing.io);
    var interp = try Interp.init();
    defer interp.deinit();

    var dict: Mutable = .{ .original = try objutil.newDict(&.{}) };
    defer dict.deinit();
    var key_foo = try objutil.newString("foo");
    defer key_foo.decrRefCount();
    var key_bar = try objutil.newString("bar");
    defer key_bar.decrRefCount();
    var key_baz = try objutil.newString("baz");
    defer key_baz.decrRefCount();
    const value_qux = try objutil.newString("qux");
    defer value_qux.decrRefCount();

    // Test 1: Remove a deeply nested value (3 levels).
    _ = try interp.putDictValueRecursively(
        &dict,
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar, key_baz } },
        value_qux,
    );

    try testing.expectEqualStrings("foo {bar {baz qux}}", try dict.getString());
    var did_remove = try interp.removeDictValueRecursively(
        &dict,
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar, key_baz } },
    );
    try testing.expect(did_remove);
    try testing.expectEqualStrings("foo {bar {}}", try dict.getString());

    // Test 2: Try to remove the same key again (should return false).
    did_remove = try interp.removeDictValueRecursively(
        &dict,
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar, key_baz } },
    );
    try testing.expect(!did_remove);
    try testing.expectEqualStrings("foo {bar {}}", try dict.getString());

    // Test 3: Remove a non-existent key from an existing intermediate dict.objutil.HandleSliceContext{ .items =
    did_remove = try interp.removeDictValueRecursively(
        &dict,
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar, key_foo } },
    );
    try testing.expect(!did_remove);
    try testing.expectEqualStrings("foo {bar {}}", try dict.getString());

    // Test 4: Remove from a non-existent intermediate dict.
    try memutil.expectErrorOrOom(
        error.EvalError,
        interp.removeDictValueRecursively(&dict, objutil.HandleSliceContext{ .items = &.{ key_bar, key_baz, key_foo } }),
    );
    try testing.expectEqualStrings(
        \\key "bar" not known in dictionary "foo {bar {}}"
    , try interp.result.getString());
    try testing.expectEqualStrings("foo {bar {}}", try dict.getString());

    // Test 5: Single-level removal (base case).
    did_remove = try interp.removeDictValueRecursively(&dict, objutil.HandleSliceContext{ .items = &.{key_foo} });
    try testing.expect(did_remove);
    try testing.expectEqualStrings("", try dict.getString());

    // Test 6: Two-level removal.
    _ = try interp.putDictValueRecursively(
        &dict,
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar } },
        value_qux,
    );
    try testing.expectEqualStrings("foo {bar qux}", try dict.getString());
    did_remove = try interp.removeDictValueRecursively(&dict, objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar } });
    try testing.expect(did_remove);
    try testing.expectEqualStrings("foo {}", try dict.getString());

    // Test 7: Removal when intermediate dict is shared (copy-on-write).
    var interm_test_dict: Mutable = .{ .original = try objutil.newDict(&.{}) };
    defer interm_test_dict.deinit();
    _ = try interp.putDictValueRecursively(
        &interm_test_dict,
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar, key_baz } },
        value_qux,
    );
    _ = try interp.putDictValueRecursively(
        &interm_test_dict,
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar, key_foo } },
        value_qux,
    );

    // Borrow the intermediate dict.
    const intermediate = (try interp.getDictValueRecursively(
        interm_test_dict.asShimmerable(),
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar } },
    )).toHandle().?;
    intermediate.incrRefCount();
    defer intermediate.decrRefCount();

    const initial_refcount = intermediate.getRefCount();
    try testing.expectEqualStrings("baz qux foo qux", try intermediate.getString());

    // Remove from the nested dict while it's owned elsewhere.
    did_remove = try interp.removeDictValueRecursively(
        &interm_test_dict,
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar, key_baz } },
    );
    try testing.expect(did_remove);

    // The intermediate dict we own should be unchanged (copy-on-write).
    try testing.expectEqualStrings("baz qux foo qux", try intermediate.getString());
    // But the main dict should have a new copy without 'baz'.
    const foo_bar_result = (try interp.getDictValueRecursively(
        interm_test_dict.asShimmerable(),
        objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar } },
    )).toHandle().?;
    try testing.expectEqualStrings("foo qux", try foo_bar_result.getString());
    // Reference count should drop by 1 since the parent no longer references it.
    try testing.expectEqual(initial_refcount - 1, intermediate.getRefCount());

    // Test 8: Remove multiple items from a nested dict.
    dict.deinit();
    dict = .{ .original = try objutil.newDict(&.{}) };
    _ = try interp.putDictValueRecursively(&dict, objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar } }, value_qux);
    _ = try interp.putDictValueRecursively(&dict, objutil.HandleSliceContext{ .items = &.{ key_foo, key_baz } }, value_qux);
    try testing.expectEqualStrings("foo {bar qux baz qux}", try dict.getString());
    did_remove = try interp.removeDictValueRecursively(&dict, objutil.HandleSliceContext{ .items = &.{ key_foo, key_bar } });
    try testing.expect(did_remove);
    try testing.expectEqualStrings("foo {baz qux}", try dict.getString());
    did_remove = try interp.removeDictValueRecursively(&dict, objutil.HandleSliceContext{ .items = &.{ key_foo, key_baz } });
    try testing.expect(did_remove);
    try testing.expectEqualStrings("foo {}", try dict.getString());
}

test "recursive dict removal" {
    try testing.checkAllAllocationFailures(testing.allocator, testRecursiveDictRemoval, .{});
}

pub fn testRunScript(interp: *Interp, script: []const u8) !Handle {
    var script_handle = try objutil.newString(script);
    defer script_handle.decrRefCount();
    try interp.evalObject(script_handle);
    return interp.result;
}

pub fn testExpectScriptResult(interp: *Interp, expected: []const u8, script: []const u8) !void {
    const result = testRunScript(interp, script);
    if (result) |success| {
        try testing.expectEqualStrings(expected, try success.getString());
    } else |err| {
        ioutil.debug("Test failed with zig error {}", .{err});
        ioutil.debug(" and error message \"{f}\"\n", .{interp.result});
        return err;
    }
}

pub fn testExpectScriptError(interp: *Interp, expected_error: anyerror, expected_str: []const u8, script: []const u8) !void {
    if (testRunScript(interp, script)) |_| {
        ioutil.debug("Expected error {}, but got success\n", .{expected_error});
        return error.TestUnexpectedResult;
    } else |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        const error_str = try interp.result.getString();
        if (err == expected_error) {
            try testing.expectEqualStrings(expected_str, error_str);
        } else {
            ioutil.debug("Expected error {}, but got {} instead\n", .{ expected_error, err });
            return error.TestUnexpectedResult;
        }
    }
}

pub fn checkSignal(interp: *Interp) bool {
    return interp.signal_depth > 0 and interp.signal != 0;
}

// Maps signal numbers to their interned name handle. Only includes signals
// available on the current platform.
const signal_name_map = blk: {
    const SIG = std.posix.SIG;
    const Entry = struct { num: u6, name: Heap.InternedString };
    const candidates = .{
        .{ "HUP", .SIGHUP },       .{ "INT", .SIGINT },   .{ "QUIT", .SIGQUIT },
        .{ "ILL", .SIGILL },       .{ "TRAP", .SIGTRAP }, .{ "ABRT", .SIGABRT },
        .{ "BUS", .SIGBUS },       .{ "FPE", .SIGFPE },   .{ "KILL", .SIGKILL },
        .{ "USR1", .SIGUSR1 },     .{ "SEGV", .SIGSEGV }, .{ "USR2", .SIGUSR2 },
        .{ "PIPE", .SIGPIPE },     .{ "ALRM", .SIGALRM }, .{ "TERM", .SIGTERM },
        .{ "CHLD", .SIGCHLD },     .{ "CONT", .SIGCONT }, .{ "STOP", .SIGSTOP },
        .{ "TSTP", .SIGTSTP },     .{ "TTIN", .SIGTTIN }, .{ "TTOU", .SIGTTOU },
        .{ "URG", .SIGURG },       .{ "XCPU", .SIGXCPU }, .{ "XFSZ", .SIGXFSZ },
        .{ "VTALRM", .SIGVTALRM }, .{ "PROF", .SIGPROF }, .{ "WINCH", .SIGWINCH },
        .{ "IO", .SIGIO },         .{ "PWR", .SIGPWR },   .{ "SYS", .SIGSYS },
    };
    var entries: []const Entry = &.{};
    for (candidates) |pair| {
        if (@hasDecl(SIG, pair[0])) {
            entries = entries ++ &[_]Entry{.{ .num = @field(SIG, pair[0]), .name = pair[1] }};
        }
    }
    break :blk entries;
};

/// Build a list of signal name strings for each signal bit set in `mask`.
pub fn signalMaskToList(mask: u64) !Handle {
    const list = try objutil.newListWithCapacity(@popCount(mask));
    errdefer list.decrRefCount();
    inline for (signal_name_map) |entry| {
        if (mask & (@as(u64, 1) << entry.num) != 0) {
            const str = Heap.local_heap.getInternedString(entry.name);
            objutil.listAppendAssumeCapacity(list, str.peek().*);
        }
    }
    return list;
}

pub fn nextRandomFloat(interp: *Interp) f64 {
    // https://stackoverflow.com/questions/46901022/how-to-convert-a-uint64-t-to-a-double-float-between-0-and-1-with-maximum-accurac
    const two63: u64 = 0x8000000000000000;
    const two64f = @as(f64, @bitCast(two63)) * 2.0;
    const as_float = @as(f64, @bitCast(interp.prng.next())) / two64f;
    return as_float;
}

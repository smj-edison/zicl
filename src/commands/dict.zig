const std = @import("std");

const strutil = @import("../strutil.zig");
const control_flow = @import("control_flow.zig");

const common = @import("common.zig");
const heap = common.heap;
const objects = common.objects;
const String = objects.String;
const Value = common.Value;
const ErrorDetails = common.ErrorDetails;
const Interp = common.Interp;
const Shimmerable = common.Shimmerable;
const registerCommand = common.registerCommand;
const memutil = common.memutil;

const Dictionary = objects.Dictionary;
const List = objects.List;

/// Equivalent to [append], but for a dict key.
fn dictAppendValue(interp: *Interp, dict_mut: *Dictionary, key: Value, pieces: []Shimmerable) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(heap.global_gpa);
    if (try interp.getMutDictValue(dict_mut, key)) |existing| {
        try buf.appendSlice(heap.global_gpa, try existing.getString());
    }
    for (pieces) |*value_shim| {
        try buf.appendSlice(heap.global_gpa, try value_shim.current().getString());
    }
    const new_str = try String.newOwning(try buf.toOwnedSliceSentinel(heap.global_gpa, 0));
    defer new_str.asHead().dropReference();
    try dict_mut.put(key, new_str.asHead().asValue());
}

/// Equivalent to [lappend], but for a dict key.
fn dictLappendValue(interp: *Interp, dict_mut: *Dictionary, key: Value, items: []Shimmerable) !void {
    if (try interp.getMutDictValue(dict_mut, key)) |existing| {
        if (try interp.asMutableInPlace(List, existing)) |list_mut| {
            try list_mut.ensureUnusedCapacity(items.len);
            errdefer comptime unreachable; // Start of transaction.
            for (items) |*value_shim| list_mut.appendAssumeCapacity(value_shim.current());
            dict_mut.asHead().commitMutation();
            return; // End of transaction.
        } else {
            const list_mut = try interp.duplicateAsType(List, existing);
            defer list_mut.asHead().dropReference();
            for (items) |*value_shim| try list_mut.append(value_shim.current());
            try dict_mut.put(key, list_mut.asHead().asValue());
        }
    } else {
        const list_mut = try List.newFromShimmerables(items);
        defer list_mut.asHead().dropReference();
        try dict_mut.put(key, list_mut.asHead().asValue());
    }
}

/// Equivalent to [incr], but for a dict key.
fn dictIncrValue(interp: *Interp, dict_mut: *Dictionary, key: Value, increment: i64) !void {
    const base: i64 = if (try interp.getMutDictValue(dict_mut, key)) |val| blk: {
        var val_shim: Shimmerable = .{ .original = val };
        defer val_shim.discardChanges();
        break :blk try interp.getInteger(&val_shim);
    } else 0;

    const new_contents = std.math.add(i64, base, increment) catch {
        return interp.integerOverflowError(i65, @as(i65, base) + @as(i65, increment));
    };
    try dict_mut.put(key, Value.newInt(new_contents));
}

/// [dict]
pub fn dictCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const Subcommands = enum {
        create,
        get,
        getdef,
        set,
        unset,
        exists,
        keys,
        size,
        merge,
        append,
        lappend,
        incr,
        remove,
        values,
        @"for",
        replace,
        update,
        link,
        assign,
    };
    const Parser = objects.SubcommandParser(Subcommands, &.{
        .{ .variant = .create, .usage = "?key value ...?", .stride = 2 },
        .{ .variant = .get, .usage = "dictionary ?key ...?", .min_args = 1 },
        .{ .variant = .getdef, .usage = "dictionary ?key ...? key default", .min_args = 3 },
        .{ .variant = .set, .usage = "varName key ?key ...? value", .min_args = 3 },
        .{ .variant = .unset, .usage = "varName key ?key ...?", .min_args = 2 },
        .{ .variant = .exists, .usage = "dictionary key ?key ...?", .min_args = 2 },
        .{ .variant = .keys, .usage = "dictionary ?pattern?", .min_args = 1, .max_args = 2 },
        .{ .variant = .size, .usage = "dictionary", .min_args = 1, .max_args = 1 },
        .{ .variant = .merge, .usage = "?...?" },
        .{ .variant = .append, .usage = "varName key ?value ...?", .min_args = 2 },
        .{ .variant = .lappend, .usage = "varName key ?value ...?", .min_args = 2 },
        .{ .variant = .incr, .usage = "varName key ?increment?", .min_args = 2, .max_args = 3 },
        .{ .variant = .remove, .usage = "dictionary ?key ...?", .min_args = 1 },
        .{ .variant = .values, .usage = "dictionary ?pattern?", .min_args = 1, .max_args = 2 },
        .{ .variant = .@"for", .usage = "vars dictionary script", .min_args = 3, .max_args = 3 },
        .{ .variant = .replace, .usage = "dictionary ?key value ...?", .min_args = 1 },
        .{ .variant = .update, .usage = "varName ?arg ...? script", .min_args = 2 },
        .{ .variant = .link, .usage = "linkTo dict", .min_args = 2, .max_args = 2 },
        .{ .variant = .assign, .usage = "dictionary varName ?varName ...?", .min_args = 2 },
    });

    var det: ErrorDetails = undefined;
    const subcommand: Subcommands = try interp.wrapError(&det, Parser.parse(&det, args));

    switch (subcommand) {
        .create => {
            const pairs = args[2..];
            if (@mod(pairs.len, 2) != 0) return error.WrongUsage;
            const new_dict = try Dictionary.newWithCapacity(&.{}, pairs.len);
            errdefer new_dict.asHead().dropReference();
            var arg_i: usize = 2;
            while (arg_i < args.len) : (arg_i += 2) try new_dict.put(args[arg_i].current(), args[arg_i + 1].current());
            interp.setResultOwning(new_dict.asHead().asValue());
        },
        .get => {
            const dict = &args[2];
            const path = args[3..];
            interp.setResult(try interp.getDictValueRecursivelyOrError(dict, objects.ShimmerableSliceContext{ .items = path }));
        },
        .getdef => {
            const getdef_ctx = objects.ShimmerableSliceContext{ .items = args[3..(args.len - 1)] };
            if ((try interp.getDictValueRecursively(&args[2], getdef_ctx)).asValue()) |val| {
                interp.setResult(val);
            } else {
                interp.setResult(args[args.len - 1].current());
            }
        },
        .set => {
            const var_name = &args[2];
            const key_context: objects.ShimmerableSliceContext = .{ .items = args[3..(args.len - 1)] };
            const value = args[args.len - 1].current();

            if ((try interp.getVariable(var_name)).asValue()) |dict_raw| {
                if (try interp.wrapError(&det, dict_raw.asMutableInPlace(Dictionary, &det))) |dict_mut| {
                    try interp.putDictValueRecursively(dict_mut, key_context, value);
                } else {
                    const duped = try interp.wrapError(&det, dict_raw.duplicateAsType(Dictionary, &det));
                    defer duped.asHead().dropReference();
                    try interp.putDictValueRecursively(duped, key_context, value);
                    try interp.setVariable(var_name, duped.asHead().asValue());
                }
            } else {
                const new_dict = try objects.Dictionary.newWithCapacity(&.{}, 4);
                defer new_dict.asHead().dropReference();
                try interp.putDictValueRecursively(new_dict, key_context, value);
                try interp.setVariable(var_name, new_dict.asHead().asValue());
            }
        },
        .unset => {
            const var_name = &args[2];
            if (args.len < 4) return error.WrongUsage;

            const unset_ctx: objects.ShimmerableSliceContext = .{ .items = args[3..args.len] };

            if ((try interp.getVariable(var_name)).asValue()) |dict_raw| {
                if (try interp.wrapError(&det, dict_raw.asMutableInPlace(Dictionary, &det))) |dict_mut| {
                    _ = try interp.removeDictValueRecursively(dict_mut, unset_ctx);
                } else {
                    const duped = try interp.wrapError(&det, dict_raw.duplicateAsType(Dictionary, &det));
                    defer duped.asHead().dropReference();
                    _ = try interp.removeDictValueRecursively(duped, unset_ctx);
                    try interp.setVariable(var_name, duped.asHead().asValue());
                }
            } else {
                const new_dict = try objects.Dictionary.new(&.{});
                defer new_dict.asHead().dropReference();
                try interp.setVariable(var_name, new_dict.asHead().asValue());
            }
        },
        .exists => {
            const dict = &args[2];
            const exists_ctx: objects.ShimmerableSliceContext = .{ .items = args[3..] };
            interp.setResultBoolean((try interp.getDictValueRecursively(dict, exists_ctx)).isSome());
        },
        .keys, .values => {
            var kv_result: Dictionary.KvResult = try interp.wrapError(&det, Dictionary.getKvPairs(&det, heap.local_arena, &args[2]));
            defer kv_result.deinit(heap.local_arena);
            const kv_map = kv_result.mapping;

            const items = if (subcommand == .keys) kv_map.keys() else kv_map.values();

            if (args.len == 4) {
                const pattern = try args[3].current().getString();
                var filtered = try objects.List.newWithCapacity(&.{}, kv_map.count());
                for (items) |item| {
                    const bytes = try item.getString();
                    if (strutil.globMatch(pattern, bytes, false)) filtered.appendAssumeCapacity(item);
                }

                interp.setResultOwning(filtered.asHead().asValue());
            } else {
                interp.setResultOwning((try objects.List.new(items)).asHead().asValue());
            }
        },
        .merge => {
            const dicts = args[2..];

            if (dicts.len == 0) {
                interp.setResultOwning((try Dictionary.new(&.{})).asHead().asValue());
                return;
            } else if (dicts.len == 1) {
                interp.setResult(dicts[0].current());
                return;
            }

            var result = try Dictionary.new(&.{});
            errdefer result.asHead().dropReference();

            for (dicts) |*dict| {
                const as_dict: *const Dictionary = try interp.wrapError(&det, Dictionary.shimmerFrom(&det, dict));

                var key_i: usize = 0;
                while (key_i < as_dict.items.len) : (key_i += 2) {
                    try result.put(as_dict.items[key_i], as_dict.items[key_i + 1]);
                }
            }

            interp.setResultOwning(result.asHead().asValue());
        },
        .link => {
            const referent = &args[2];
            const dict = &args[3];

            const dict_mut: *Dictionary = try interp.wrapError(&det, dict.getMutable(Dictionary, &det));
            errdefer dict_mut.asHead().dropReference();

            const hash_ref = try objects.HashReference.newFromValue(referent.current());
            defer hash_ref.asHead().dropReference();
            try dict_mut.put(objects.interned_tilde_parent, hash_ref.asHead().asValue());

            interp.setResultOwning(dict_mut.asHead().asValue());
        },
        .assign => {
            const dict = &args[2];
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                const key = args[i].current();
                const found = try interp.wrapError(&det, Dictionary.getFollowingLinks(&det, dict, key));
                const value = found.asValue() orelse return interp.wrapError(&det, Dictionary.keyNotFoundError(&det, key));
                try interp.setVariable(&args[i], value);
            }
            interp.setResult(dict.current());
        },
        .size => {
            var kv_result: Dictionary.KvResult = try interp.wrapError(&det, Dictionary.getKvPairs(&det, heap.local_arena, &args[2]));
            defer kv_result.deinit(heap.local_arena); // Still need to drop the values.
            interp.setResultInteger(@intCast(kv_result.mapping.count()));
        },
        .remove => {
            const dict = &args[2];
            const dict_mut: *Dictionary = try interp.wrapError(&det, dict.getMutable(Dictionary, &det));
            errdefer dict_mut.asHead().dropReference();

            for (args[3..]) |*key_shim| {
                _ = try interp.wrapError(&det, dict_mut.remove(&det, key_shim.current()));
            }

            interp.setResultOwning(dict_mut.asHead().asValue());
        },
        .replace => {
            const dict = &args[2];
            const pairs = args[3..];
            if (@mod(pairs.len, 2) != 0) return error.WrongUsage;

            const dict_mut: *Dictionary = try interp.wrapError(&det, dict.getMutable(Dictionary, &det));
            errdefer dict_mut.asHead().dropReference();

            var idx: usize = 0;
            while (idx < pairs.len) : (idx += 2) {
                try dict_mut.put(pairs[idx].current(), pairs[idx + 1].current());
            }

            interp.setResultOwning(dict_mut.asHead().asValue());
        },
        .append => {
            const var_name = &args[2];
            const key = args[3].current();
            const pieces = args[4..];

            if ((try interp.getVariable(var_name)).asValue()) |dict_raw| {
                if (try interp.asMutableInPlace(Dictionary, dict_raw)) |dict_mut| {
                    try dictAppendValue(interp, dict_mut, key, pieces);
                    // Mutated in place, so no `setVariable` needed.
                    interp.setResult(dict_mut.asHead().asValue());
                } else {
                    const dict_mut = try interp.duplicateAsType(Dictionary, dict_raw);
                    defer dict_mut.asHead().dropReference();
                    try dictAppendValue(interp, dict_mut, key, pieces);
                    try interp.setVariable(var_name, dict_mut.asHead().asValue());
                    interp.setResult(dict_mut.asHead().asValue());
                }
            } else {
                const dict_mut = try Dictionary.newWithCapacity(&.{}, 4);
                defer dict_mut.asHead().dropReference();
                try dictAppendValue(interp, dict_mut, key, pieces);
                try interp.setVariable(var_name, dict_mut.asHead().asValue());
                interp.setResult(dict_mut.asHead().asValue());
            }
        },
        .lappend => {
            const var_name = &args[2];
            const key = args[3].current();
            const pieces = args[4..];

            if ((try interp.getVariable(var_name)).asValue()) |dict_raw| {
                if (try interp.asMutableInPlace(Dictionary, dict_raw)) |dict_mut| {
                    try dictLappendValue(interp, dict_mut, key, pieces);
                    interp.setResult(dict_mut.asHead().asValue());
                } else {
                    const dict_mut = try interp.duplicateAsType(Dictionary, dict_raw);
                    defer dict_mut.asHead().dropReference();
                    try dictLappendValue(interp, dict_mut, key, pieces);
                    try interp.setVariable(var_name, dict_mut.asHead().asValue());
                    interp.setResult(dict_mut.asHead().asValue());
                }
            } else {
                const dict_mut = try Dictionary.newWithCapacity(&.{}, 4);
                defer dict_mut.asHead().dropReference();
                try dictLappendValue(interp, dict_mut, key, pieces);
                try interp.setVariable(var_name, dict_mut.asHead().asValue());
                interp.setResult(dict_mut.asHead().asValue());
            }
        },
        .incr => {
            const var_name = &args[2];
            const key = args[3].current();
            const increment: i64 = if (args.len == 5) (try interp.getInteger(&args[4])) else 1;

            if ((try interp.getVariable(var_name)).asValue()) |dict_raw| {
                if (try interp.asMutableInPlace(Dictionary, dict_raw)) |dict_mut| {
                    try dictIncrValue(interp, dict_mut, key, increment);
                    interp.setResult(dict_mut.asHead().asValue());
                } else {
                    const dict_mut = try interp.duplicateAsType(Dictionary, dict_raw);
                    defer dict_mut.asHead().dropReference();
                    try dictIncrValue(interp, dict_mut, key, increment);
                    try interp.setVariable(var_name, dict_mut.asHead().asValue());
                    interp.setResult(dict_mut.asHead().asValue());
                }
            } else {
                const dict_mut = try Dictionary.newWithCapacity(&.{}, 4);
                defer dict_mut.asHead().dropReference();
                try dictIncrValue(interp, dict_mut, key, increment);
                try interp.setVariable(var_name, dict_mut.asHead().asValue());
                interp.setResult(dict_mut.asHead().asValue());
            }
        },
        .@"for" => {
            const var_list = try interp.getList(&args[2]);
            if (var_list.items.len != 2) {
                try interp.setResultString("must have exactly two variable names");
                return error.EvalError;
            }
            var key_var: Shimmerable = .{ .original = var_list.items[0] };
            defer key_var.discardChanges();
            var value_var: Shimmerable = .{ .original = var_list.items[1] };
            defer value_var.discardChanges();

            var kv_result: Dictionary.KvResult = try interp.wrapError(&det, Dictionary.getKvPairs(&det, heap.local_arena, &args[3]));
            defer kv_result.deinit(heap.local_arena);
            const keys = kv_result.mapping.keys();
            const values = kv_result.mapping.values();

            const body = &args[4];

            var idx: usize = 0;
            while (idx < keys.len) : (idx += 1) {
                try interp.setVariable(&key_var, keys[idx]);
                try interp.setVariable(&value_var, values[idx]);

                switch (try control_flow.propagateLoopControl(interp, interp.evalValue(body.current()))) {
                    .@"break" => break,
                    .@"continue" => continue,
                    .none => {},
                }
            }

            interp.setEmptyResult();
        },
        else => {
            try interp.setResultFormatted("dict {s} is not yet implemented", .{@tagName(subcommand)});
            return error.EvalError;
        },
    }
}

pub fn registerCommands(interp: *Interp) !void {
    try registerCommand(interp, "dict", dictCmd, "subcommand ?arg ...?", 1, null);
}

fn testDictUnset(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Dictionaries can be created by unsetting.
    try interp.testExpectScriptResult("", "dict unset nonexistent alsononexistent");
    try interp.testExpectScriptResult("", "set nonexistent"); // Shouldn't error.
}

test "dict unset" {
    try memutil.checkAllocationFailures(.exhaustive, testDictUnset, .{});
}

fn testDictCommands(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptError(error.EvalError,
        \\Missing value to go with key when converting "10" to a dictionary.
    ,
        \\ dict set x a 10
        \\ puts [dict get $x a 5]
    );

    try interp.testExpectScriptResult("qux",
        \\ dict set foo bar baz qux
        \\ dict get $foo bar baz
    );
}

test "dict commands" {
    try memutil.checkAllocationFailures(.exhaustive, testDictCommands, .{});
}

fn testDictAssign(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("1 2 3",
        \\ set d {a 1 b 2 c 3}
        \\ dict assign $d a b c
        \\ list $a $b $c
    );

    try interp.testExpectScriptError(error.EvalError,
        \\could not find value for key "missing"
    ,
        \\ dict assign {a 1} missing
    );
}

test "dict assign" {
    try memutil.checkAllocationFailures(.exhaustive, testDictAssign, .{});
}

fn testDictParentLinks(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("value",
        \\ set a {key value}
        \\ set b "~parent [ref $a] key2 value2"
        \\ dict get $b key
    );
}

test "dict parent links" {
    try memutil.checkAllocationFailures(.exhaustive, testDictParentLinks, .{});
}

fn testDictLinkCommand(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("value",
        \\ set a {key value}
        \\ set b {key2 value2}
        \\ set c [dict link $a $b]
        \\ dict get $c key
    );
}

test "dict link command" {
    try memutil.checkAllocationFailures(.exhaustive, testDictLinkCommand, .{});
}

fn testDictLinkParentIsNotMutatedThroughChild(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Appending to a key the child only sees *through* its parent link must
    // shadow it with the child's own entry, never mutate the parent's value
    // in place. `dict link` freezes the referent (see HashReference.new) so
    // the interior list isn't mistaken for exclusively owned; before that,
    // whether this corrupted the parent depended on the list's refcount,
    // so it only showed up when nothing else held a reference to it.
    try interp.testExpectScriptResult("{base extra} | base | base",
        \\ set proto {flags base}
        \\ set child [dict link $proto {}]
        \\ dict lappend child flags extra
        \\ set sibling [dict link $proto {}]
        \\ list [dict get $child flags] | [dict get $proto flags] | [dict get $sibling flags]
    );

    // Same for a key reached through two levels of link.
    try interp.testExpectScriptResult("{base deep} | base",
        \\ set proto {flags base}
        \\ set mid [dict link $proto {}]
        \\ set leaf [dict link $mid {}]
        \\ dict lappend leaf flags deep
        \\ list [dict get $leaf flags] | [dict get $proto flags]
    );
}

test "dict link: appending through a link does not mutate the parent" {
    try memutil.checkAllocationFailures(.exhaustive, testDictLinkParentIsNotMutatedThroughChild, .{});
}

fn testDictSugar(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("a b y 10",
        \\ set x {a b}
        \\ set x::y 10
        \\ set x
    );
}

test "dict sugar" {
    try memutil.checkAllocationFailures(.exhaustive, testDictSugar, .{});
}

fn testDictKeys(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Basic dict keys.
    try interp.testExpectScriptResult("a b", "dict keys {a 1 b 2}");

    // Keys with pattern.
    try interp.testExpectScriptResult("a", "dict keys {a 1 b 2} a*");

    const foo_str = try String.newValue("foo");
    defer foo_str.dropReference();
    const bar_str = try String.newValue("bar");
    defer bar_str.dropReference();
    const baz_str = try String.newValue("baz");
    defer baz_str.dropReference();
    const one_str = try String.newValue("1");
    defer one_str.dropReference();
    const two_str = try String.newValue("2");
    defer two_str.dropReference();
    const three_str = try String.newValue("3");
    defer three_str.dropReference();
    const four_str = try String.newValue("4");
    defer four_str.dropReference();

    // Parent links: parent keys first, then child keys not already present.
    const parent = try objects.Dictionary.new(&.{ foo_str, one_str, bar_str, two_str });
    defer parent.asHead().dropReference();

    var child = try objects.Dictionary.new(&.{
        foo_str, three_str,
        baz_str, four_str,
    });
    defer child.asHead().dropReference();

    var hash_ref = try objects.HashReference.new(parent.asHead());
    defer hash_ref.asHead().dropReference();
    try child.put(objects.interned_tilde_parent, hash_ref.asHead().asValue());

    {
        var var_name: Shimmerable = .{ .original = try String.newValue("d") };
        defer var_name.deinit();
        try interp.setVariable(&var_name, child.asHead().asValue());
    }

    // foo is in both parent and child; parent foo takes precedence in order.
    // bar is only in parent.
    // baz is only in child.
    // Order: parent keys first (foo, bar), then new child keys (baz).
    try interp.testExpectScriptResult("foo bar baz", "dict keys $d");
}

test "dict keys" {
    try memutil.checkAllocationFailures(.exhaustive, testDictKeys, .{});
}

/// Build `{ <key> <value> }` linked to `parent`, and register `parent` so the
/// link resolves. The caller owns the returned dictionary.
fn linkedDict(parent: *objects.Dictionary, key: heap.Value, value: heap.Value) !*objects.Dictionary {
    _ = try parent.asHead().getHashRegistering();
    const hash_ref = try objects.HashReference.new(parent.asHead());
    defer hash_ref.asHead().dropReference();

    const child = try objects.Dictionary.new(&.{ key, value });
    errdefer child.asHead().dropReference();
    try child.put(objects.interned_tilde_parent, hash_ref.asHead().asValue());
    return child;
}

fn testPartialFlatten(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Interned keys and inline values throughout, because registering a parent
    // marks it cross-thread, and a `String` object declares no
    // `make_crossthread` and so cannot be shared. See the task about leaf types.
    const a = heap.InternedString.newValue("a");
    const c = heap.InternedString.newValue("c");

    // 1: {c 30}  <-  2: {a 20}  <-  3: {a 10}
    // Removing `a` from 3 has to absorb 2, which also holds `a`, but must leave
    // 1 linked since nothing there shadows `a`.
    const gp = try objects.Dictionary.new(&.{ c, objects.Integer.new(30) });
    defer gp.asHead().dropReference();
    const parent = try linkedDict(gp, a, objects.Integer.new(20));
    defer parent.asHead().dropReference();
    const child = try linkedDict(parent, a, objects.Integer.new(10));
    defer child.asHead().dropReference();

    var det: ErrorDetails = undefined;
    try std.testing.expect(try child.remove(&det, a));

    // `a` is gone even though a parent held it.
    try std.testing.expect((try child.getNoFollow(a)).isNone());
    var child_shim: Shimmerable = .{ .original = child.asHead().asValue() };
    defer child_shim.discardChanges();
    try std.testing.expect((try Dictionary.getFollowingLinks(&det, &child_shim, a)).isNone());

    // The grandparent was not absorbed: the link survives and its key is still
    // reachable through it. A full flatten would have copied `c` in and dropped
    // `~parent` entirely.
    try std.testing.expect((try child.getNoFollow(objects.interned_tilde_parent)).isSome());
    try std.testing.expect((try child.getNoFollow(c)).isNone());
    try std.testing.expect((try Dictionary.getFollowingLinks(&det, &child_shim, c)).isSome());
}

test "dict remove flattens only as far as the key reaches" {
    try memutil.checkAllocationFailures(.exhaustive, testPartialFlatten, .{});
}

fn testDictSize(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("0", "dict size {}");
    try interp.testExpectScriptResult("2", "dict size {a 1 b 2}");
}

test "dict size" {
    try memutil.checkAllocationFailures(.exhaustive, testDictSize, .{});
}

fn testDictRemoveCommand(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("a 1 c 3", "dict remove {a 1 b 2 c 3} b");
    // Doesn't mutate the original variable.
    try interp.testExpectScriptResult("a 1 b 2 c 3",
        \\ set d {a 1 b 2 c 3}
        \\ dict remove $d b
        \\ set d
    );
}

test "dict remove command" {
    try memutil.checkAllocationFailures(.exhaustive, testDictRemoveCommand, .{});
}

fn testDictReplace(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("a 1 b 20 c 3", "dict replace {a 1 b 2 c 3} b 20");
    try interp.testExpectScriptResult("a 1 b 2 c 30", "dict replace {a 1 b 2} c 30");
}

test "dict replace" {
    try memutil.checkAllocationFailures(.exhaustive, testDictReplace, .{});
}

fn testDictAppendLappendIncr(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Force COW path on `shared`.
    try interp.testExpectScriptResult("a 1 k v",
        \\ set shared {a 1}
        \\ set alias $shared
        \\ dict append shared k v
        \\ set shared
    );

    try interp.testExpectScriptResult("ab",
        \\ dict append seq k a
        \\ dict append seq k b
        \\ set seq::k
    );

    // Stress test [dict lappend], by making sure that its COW logic works
    // correctly when a dictionary value is aliased.
    try interp.testExpectScriptResult("1 2 3 | 1 2",
        \\ set inner {1 2}
        \\ set d1 [dict create k $inner]
        \\ set d2 [dict create k $inner]
        \\ dict lappend d1 k 3
        \\ concat [dict get $d1 k] | [dict get $d2 k]
    );

    // Create a new dictionary when the variable doesn't exist.
    try interp.testExpectScriptResult("helloworld",
        \\ dict append d k hello world
        \\ dict get $d k
    );

    try interp.testExpectScriptResult("1 2 3",
        \\ dict lappend l k 1
        \\ dict lappend l k 2 3
        \\ dict get $l k
    );

    try interp.testExpectScriptResult("5",
        \\ dict set i k 2
        \\ dict incr i k 3
        \\ dict get $i k
    );

    try interp.testExpectScriptResult("newKey 1", "dict incr newDict newKey");
}

test "dict append, lappend, incr" {
    try memutil.checkAllocationFailures(.exhaustive, testDictAppendLappendIncr, .{});
}

fn testDictFor(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("a=1 b=2 c=3",
        \\ set out {}
        \\ dict for {k v} {a 1 b 2 c 3} {
        \\     lappend out "$k=$v"
        \\ }
        \\ join $out " "
    );

    try interp.testExpectScriptResult("a",
        \\ set out {}
        \\ dict for {k v} {a 1 b 2 c 3} {
        \\     lappend out $k
        \\     break
        \\ }
        \\ join $out " "
    );
}

test "dict for" {
    try memutil.checkAllocationFailures(.exhaustive, testDictFor, .{});
}

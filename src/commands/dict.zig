const std = @import("std");

const strutil = @import("../strutil.zig");

const common = @import("common.zig");
const heap = common.heap;
const objects = common.objects;
const String = objects.String;
const ErrorDetails = common.ErrorDetails;
const Interp = common.Interp;
const Shimmerable = common.Shimmerable;
const registerCommand = common.registerCommand;

const Dictionary = objects.Dictionary;

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
        info,
        merge,
        with,
        append,
        lappend,
        incr,
        remove,
        values,
        @"for",
        replace,
        update,
        link,
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
        .{ .variant = .info, .usage = "dictionary", .min_args = 1, .max_args = 1 },
        .{ .variant = .merge, .usage = "?...?" },
        .{ .variant = .with, .usage = "dictVar ?key ...? script", .min_args = 2 },
        .{ .variant = .append, .usage = "varName key ?value ...?", .min_args = 2 },
        .{ .variant = .lappend, .usage = "varName key ?value ...?", .min_args = 2 },
        .{ .variant = .incr, .usage = "varName key ?increment?", .min_args = 2, .max_args = 3 },
        .{ .variant = .remove, .usage = "dictionary ?key ...?", .min_args = 1 },
        .{ .variant = .values, .usage = "dictionary ?pattern?", .min_args = 1, .max_args = 2 },
        .{ .variant = .@"for", .usage = "vars dictionary script", .min_args = 3, .max_args = 3 },
        .{ .variant = .replace, .usage = "dictionary ?key value ...?", .min_args = 1 },
        .{ .variant = .update, .usage = "varName ?arg ...? script", .min_args = 2 },
        .{ .variant = .link, .usage = "linkTo dict", .min_args = 2, .max_args = 2 },
    });

    var det: ErrorDetails = undefined;
    const subcommand: Subcommands = try interp.wrapError(&det, Parser.parse(&det, args));

    switch (subcommand) {
        .create => {
            const pairs = args[2..];
            if (@mod(pairs.len, 2) != 0) return error.WrongUsage;
            const new_dict = try Dictionary.newWithCapacity(&.{}, pairs.len);
            errdefer new_dict.asHead().release();
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
                    defer duped.asHead().release();
                    try interp.putDictValueRecursively(duped, key_context, value);
                    try interp.setVariable(var_name, duped.asHead().asValue());
                }
            } else {
                const new_dict = try objects.Dictionary.newWithCapacity(&.{}, 4);
                defer new_dict.asHead().release();
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
                    defer duped.asHead().release();
                    _ = try interp.removeDictValueRecursively(duped, unset_ctx);
                    try interp.setVariable(var_name, duped.asHead().asValue());
                }
            } else {
                const new_dict = try objects.Dictionary.new(&.{});
                defer new_dict.asHead().release();
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
            errdefer result.asHead().release();

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
            errdefer dict_mut.asHead().release();

            const hash_ref = try objects.HashReference.newFromValue(referent.current());
            defer hash_ref.asHead().release();
            try dict_mut.put(objects.interned_tilde_parent, hash_ref.asHead().asValue());

            interp.setResultOwning(dict_mut.asHead().asValue());
        },
        else => std.debug.panic("unimplemented: {}", .{subcommand}),
    }
}

pub fn registerCommands(interp: *Interp) !void {
    try registerCommand(interp, "dict", dictCmd, "subcommand ?arg ...?", 1, null, null);
}

test "dict unset" {
    var interp = try common.testStart(std.testing.allocator);
    defer common.testFinish(&interp);

    // Dictionaries can be created by unsetting.
    try interp.testExpectScriptResult("", "dict unset nonexistent alsononexistent");
    try interp.testExpectScriptResult("", "set nonexistent"); // Shouldn't error.
}

test "dict commands" {
    var interp = try common.testStart(std.testing.allocator);
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

test "dict parent links" {
    var interp = try common.testStart(std.testing.allocator);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("value",
        \\ set a {key value}
        \\ set b "~parent [ref $a] key2 value2"
        \\ dict get $b key
    );
}

test "dict link command" {
    var interp = try common.testStart(std.testing.allocator);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("value",
        \\ set a {key value}
        \\ set b {key2 value2}
        \\ set c [dict link $a $b]
        \\ dict get $c key
    );
}

test "dict sugar" {
    var interp = try common.testStart(std.testing.allocator);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("a b y 10",
        \\ set x {a b}
        \\ set x::y 10
        \\ set x
    );
}

test "dict keys" {
    var interp = try common.testStart(std.testing.allocator);
    defer common.testFinish(&interp);

    // Basic dict keys.
    try interp.testExpectScriptResult("a b", "dict keys {a 1 b 2}");

    // Keys with pattern.
    try interp.testExpectScriptResult("a", "dict keys {a 1 b 2} a*");

    const foo_str = try String.newValue("foo");
    defer foo_str.release();
    const bar_str = try String.newValue("bar");
    defer bar_str.release();
    const baz_str = try String.newValue("baz");
    defer baz_str.release();
    const one_str = try String.newValue("1");
    defer one_str.release();
    const two_str = try String.newValue("2");
    defer two_str.release();
    const three_str = try String.newValue("3");
    defer three_str.release();
    const four_str = try String.newValue("4");
    defer four_str.release();

    // Parent links: parent keys first, then child keys not already present.
    const parent = try objects.Dictionary.new(&.{ foo_str, one_str, bar_str, two_str });
    defer parent.asHead().release();

    var child = try objects.Dictionary.new(&.{
        foo_str, three_str,
        baz_str, four_str,
    });
    defer child.asHead().release();

    var hash_ref = try objects.HashReference.new(parent.asHead());
    defer hash_ref.asHead().release();
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

/// Build `{ <key> <value> }` linked to `parent`, and register `parent` so the
/// link resolves. The caller owns the returned dictionary.
fn linkedDict(parent: *objects.Dictionary, key: heap.Value, value: heap.Value) !*objects.Dictionary {
    _ = try parent.asHead().getHashRegistering();
    const hash_ref = try objects.HashReference.new(parent.asHead());
    defer hash_ref.asHead().release();

    const child = try objects.Dictionary.new(&.{ key, value });
    errdefer child.asHead().release();
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
    defer gp.asHead().release();
    const parent = try linkedDict(gp, a, objects.Integer.new(20));
    defer parent.asHead().release();
    const child = try linkedDict(parent, a, objects.Integer.new(10));
    defer child.asHead().release();

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
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testPartialFlatten, .{});
}

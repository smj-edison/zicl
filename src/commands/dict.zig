const std = @import("std");

const common = @import("common.zig");

const objects = common.objects;
const ErrorDetails = common.ErrorDetails;
const Interp = common.Interp;
const Shimmerable = common.Shimmerable;

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
            const new_dict = try Dictionary.new(&.{});
            var arg_i: usize = 2;
            while (arg_i < args.len) : (arg_i += 2) try new_dict.put(args[arg_i].current(), args[arg_i + 1].current());
            interp.setResultOwning(new_dict);
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
            const keys = args[3..(args.len - 1)];

            var dict: Mutable = blk: {
                if ((try interp.getVariable(var_name)).toHandle()) |val| {
                    break :blk .{ .original = val };
                } else {
                    const new_variable_dict = try objutil.newDictWithCapacity(2);
                    defer new_variable_dict.decrRefCount();
                    try interp.setVariableTo(var_name, new_variable_dict);
                    break :blk .{ .original = (try interp.getVariable(var_name)).toHandle().? };
                }
            };
            defer dict.discardChanges();

            if (keys.len == 0) {
                interp.setResult(dict.current());
                return;
            }

            const new_value = args[args.len - 1].current().dupOrRef();
            const set_ctx = objutil.ShimmerableSliceContext{ .items = keys };
            _ = try interp.wrapError(&det, objutil.dictPutRecursively(&det, &dict, set_ctx, new_value));

            if (dict.takeMutated().toHandle()) |new| {
                defer new.decrRefCount();
                try interp.setVariableTo(var_name, new);
                // TODO probably can do this faster than looking back up every time.
                interp.setResult((try interp.getVariable(var_name)).toHandle().?);
            } else {
                interp.setResult(dict.current());
            }
        },
        .unset => {
            const var_name = &args[2];
            if (args.len < 4) return error.WrongUsage;

            var dict: Mutable = blk: {
                if ((try interp.getVariable(var_name)).toHandle()) |val| {
                    break :blk .{ .original = val };
                } else {
                    const new_variable_dict = try objutil.newDictWithCapacity(2);
                    defer new_variable_dict.decrRefCount();
                    try interp.setVariableTo(var_name, new_variable_dict);
                    break :blk .{ .original = (try interp.getVariable(var_name)).toHandle().? };
                }
            };
            defer dict.discardChanges();

            const unset_ctx = objutil.ShimmerableSliceContext{ .items = args[3..args.len] };
            _ = try interp.wrapError(&det, objutil.dictRemoveRecursively(&det, &dict, unset_ctx));
            if (dict.takeMutated().toHandle()) |new| {
                defer new.decrRefCount();
                try interp.setVariableToObject(var_name, new.reference());
            }
        },
        .exists => {
            const dict = &args[2];
            const exists_ctx = objutil.ShimmerableSliceContext{ .items = args[3..] };
            try interp.setResultBoolean((try interp.getDictValueRecursively(dict, exists_ctx)) != .none);
        },
        .keys, .values => {
            var new_dict: OptionalHandle = .none;
            errdefer new_dict.decrOptional();
            var kv_map: objutil.DictKvResult = try interp.wrapError(&det, objutil.dictGetKvPairs(&det, Heap.global_gpa, &args[2]));
            defer {
                var iter = kv_map.iterator();
                while (iter.next()) |val| {
                    val.key_ptr.decrRefCount();
                    val.value_ptr.decrRefCount();
                }
                kv_map.deinit(Heap.global_gpa);
            }

            if (args.len == 4) {
                const pattern = &args[3];
                var filtered = try objutil.newListWithCapacity(@intCast(kv_map.count()));
                errdefer filtered.decrRefCount();
                for (kv_map.keys(), kv_map.values()) |key, value| {
                    const used = if (subcommand == .keys) key else value;
                    if (try objutil.globMatch(pattern.current(), used, false)) {
                        objutil.listAppendAssumeCapacity(filtered, used.dupOrRef());
                    }
                }
                interp.setResultOwning(filtered);
            } else {
                interp.setResultOwning(try objutil.newList(if (subcommand == .keys) kv_map.keys() else kv_map.values()));
            }
        },
        .merge => {
            const dicts = args[2..];

            if (dicts.len == 0) {
                interp.setResultOwning(try objutil.newDictWithCapacity(0));
                return;
            }

            // Make sure everything is a dict.
            for (dicts) |*d| try interp.shimmerToDict(d);

            if (dicts.len == 1) {
                interp.setResult(dicts[0].current());
                return;
            }

            var result = try objutil.newDictWithCapacity(0);
            errdefer result.decrRefCount();

            for (dicts) |dict| {
                const pair_count = dict.peek().body.dict.len / 2;
                var pair_i: u32 = 0;
                while (pair_i < pair_count) : (pair_i += 1) {
                    const k = objutil.dictItem(dict.current(), pair_i * 2);
                    const v = objutil.dictItem(dict.current(), pair_i * 2 + 1);
                    _ = try interp.putDictValueInPlace(&result, k, v);
                }
            }

            interp.setResultOwning(result);
        },
        .link => {
            const link_to = &args[2];
            const dict = &args[3];

            var mutable_dict = try dict.duplicateForMutable();
            errdefer mutable_dict.decrRefCount();

            const hash_ref = try objutil.createHashReference(link_to.current());
            defer hash_ref.decrRefCount();
            _ = try interp.putDictValueInPlace(&mutable_dict, Heap.local_heap.getInternedString(.@"^parent"), hash_ref);
            interp.setResultOwning(mutable_dict);
        },
        else => std.debug.panic("unimplemented: {}", .{subcommand}),
    }
}

const std = @import("std");

const common = @import("common.zig");
const heap = common.heap;
const ErrorDetails = common.ErrorDetails;
const Value = common.Value;
const objects = common.objects;
const String = objects.String;
const List = objects.List;
const Interp = common.Interp;
const Shimmerable = common.Shimmerable;
const registerCommand = common.registerCommand;

pub fn refCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const ref = try objects.HashReference.new(try args[1].ensureBoxed());
    interp.setResultOwning(ref.asHead().asValue());
}

pub fn derefCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    interp.setResult((try interp.resolveHash(&args[1])).ref.asValue());
}

pub fn launderCmd(interp: *Interp, args: []Shimmerable) !void {
    const str = try args[1].getString();
    try interp.setResultString(str);
}

pub fn breakpointCmd(_: *Interp, _: []Shimmerable) Interp.Error!void {
    @breakpoint();
}

/// [errorinfo optsDict]
pub fn infoCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const Subcommands = enum {
        exists,
        source,
        frame,
        hostname,
        type,
    };
    const Parser = objects.SubcommandParser(Subcommands, &.{
        .{ .variant = .exists, .usage = "varName", .min_args = 1, .max_args = 1 },
        .{ .variant = .source, .usage = "script ?fileName lineNo?", .min_args = 1, .max_args = 3 },
        .{ .variant = .frame, .usage = "?level?", .min_args = 0, .max_args = 1 },
        .{ .variant = .hostname, .usage = "", .min_args = 0, .max_args = 0 },
        .{ .variant = .type, .usage = "object", .min_args = 1, .max_args = 1 },
    });

    var det: ErrorDetails = undefined;
    const subcommand: Subcommands = try interp.wrapError(&det, Parser.parse(&det, args));

    switch (subcommand) {
        .exists => {
            const val = try interp.getVariable(&args[2]);
            interp.setResultBoolean(val.isSome());
        },
        .source => {
            const script = &args[2];
            if (args.len == 3) {
                if (script.current().asType(objects.Source)) |info| {
                    const file_name = info.file_name.orEmpty();
                    const line_no = objects.Integer.new(info.line_no);
                    const list = try objects.List.new(&.{ file_name, line_no });
                    interp.setResultOwning(list.asHead().asValue());
                } else {
                    const list = try objects.List.new(&.{ heap.interned_empty_string, Value.newInt(1) });
                    interp.setResultOwning(list.asHead().asValue());
                }
            } else {
                const file_name = try String.newValue(try args[3].current().getString());
                errdefer file_name.release();
                const line_no = try interp.getInteger(&args[4]);
                const line_no_narrowed = std.math.cast(u32, line_no) orelse {
                    return interp.wrapError(&det, objects.Integer.overflowError(i64, &det, line_no));
                };
                const as_source = try script.prepareToShimmer(objects.Source);
                as_source.* = .{
                    .file_name = file_name.asOptional(),
                    .line_no = line_no_narrowed,
                    .hash = .init(null),
                };
            }
        },
        .frame => {
            const bad_level_err = heap.InternedString.newValue("bad level");
            const current = @as(i64, interp.callFrameIdx());

            if (args.len == 2) {
                try interp.setResultInteger(current + 1);
                return;
            }

            const level = try interp.getInteger(&args[2]);
            const target: u32 = blk: {
                if (level < 0) {
                    // Less than 0, so this is a relative frame index. Note this means that
                    // `current + level` is always less than `current`, so we don't need to
                    // check if it's higher than the current frame.
                    const abs_frame = current + level;
                    break :blk std.math.cast(u32, abs_frame) orelse return interp.setResultError(bad_level_err);
                } else {
                    if (level >= current + 1) return interp.setResultError(bad_level_err);
                    // Since `current` is a u32, it's impossible for `level` to be bigger than a u32,
                    // hence we can safely cast it.
                    break :blk @intCast(level);
                }
            };

            // Find the topmost eval frame for the target call frame. We start at
            // `eval_frames.items.len` since by design, the current eval frame is
            // always the top one.
            var target_eval_frame: ?*Interp.EvalFrame = null;
            var i = interp.eval_frames.items.len;
            while (i > 0) {
                i -= 1;
                const eval_frame = &interp.eval_frames.items[i];
                if (eval_frame.call_frame == target) {
                    target_eval_frame = eval_frame;
                    break;
                }
            }
            const eval_frame = target_eval_frame orelse return interp.setResultError(bad_level_err);

            const result_dict = try objects.Dictionary.newWithCapacity(&.{}, 10);
            errdefer result_dict.asHead().release();
            try result_dict.put(heap.InternedString.newValue("type"), heap.InternedString.newValue("source"));
            if (eval_frame.currently_evaluating.asType(objects.Source)) |source| {
                const line_no = objects.Integer.new(source.line_no);
                try result_dict.put(heap.InternedString.newValue("line"), line_no);
                try result_dict.put(heap.InternedString.newValue("file"), source.file_name.orEmpty());
            }

            const rel_level = objects.Integer.new(current - target);
            try result_dict.put(heap.InternedString.newValue("level"), rel_level);

            interp.setResultOwning(result_dict.asHead().asValue());
        },
        .hostname => {
            var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
            const name = std.posix.gethostname(&buf) catch |err| {
                try interp.setResultFormatted("could not get hostname: {s}", .{@errorName(err)});
                return error.EvalError;
            };
            try interp.setResultString(name);
        },
        .type => {
            if (args[1].current().asPtr()) |obj| {
                try interp.setResultString(obj.vtable.name);
            } else {
                try interp.setResultString(@tagName(args[1].current().raw.tag));
            }
        },
    }
}

pub fn errorinfoCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const message = args[1];
    const stack_trace = if (args.len == 3) args[2].current() else if (args.len == 2) interp.stack_trace.orEmpty() else unreachable;

    // The stack is a flat list: {name file line args ...} repeated.
    var stack_list: Shimmerable = .{ .original = stack_trace.borrow() };
    defer stack_list.deinit();
    const as_list = try interp.getList(&stack_list);

    const error_message = Interp.makeErrorMessage(message.current(), as_list) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WrongSize => return,
    };
    interp.setResultOwning(error_message);
}

pub fn registerCommands(interp: *Interp) !void {
    try registerCommand(interp, "breakpoint", breakpointCmd, "", 0, 0, null);
    try registerCommand(interp, "deref", derefCmd, "hash", 1, 1, null);
    try registerCommand(interp, "errorinfo", errorinfoCmd, "optsDict", 1, 1, null);
    try registerCommand(interp, "info", infoCmd, "subcommand ?arg ...?", 1, null, null);
    try registerCommand(interp, "launder", launderCmd, "string", 1, 1, null);
    try registerCommand(interp, "ref", refCmd, "string", 1, 1, null);
}

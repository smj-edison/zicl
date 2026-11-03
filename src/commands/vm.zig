const std = @import("std");

const Tokenizer = @import("../Tokenizer.zig");
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

pub fn vmCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const Subcommands = enum {
        exists,
        frame,
        hostname,
        level,
        parse,
        source,
        stacktrace,
        type,
    };
    const Parser = objects.SubcommandParser(Subcommands, &.{
        .{ .variant = .exists, .usage = "varName", .min_args = 1, .max_args = 1 },
        .{ .variant = .frame, .usage = "?level?", .min_args = 0, .max_args = 1 },
        .{ .variant = .hostname, .usage = "", .min_args = 0, .max_args = 0 },
        .{ .variant = .level, .usage = "?levelNum?", .min_args = 0, .max_args = 1 },
        .{ .variant = .parse, .usage = "parseType ?args...? -- buffer", .min_args = 3 },
        .{ .variant = .source, .usage = "script ?fileName lineNo?", .min_args = 1, .max_args = 3 },
        .{ .variant = .stacktrace, .usage = "", .min_args = 0, .max_args = 0 },
        .{ .variant = .type, .usage = "object", .min_args = 1, .max_args = 1 },
    });

    var det: ErrorDetails = undefined;
    const subcommand: Subcommands = try interp.wrapError(&det, Parser.parse(&det, args));

    switch (subcommand) {
        .exists => {
            const value = try interp.getVariableTakingRef(&args[2]);
            defer if (value) |val| val.dropReference();
            interp.setResultBoolean(value != null);
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
                const line_no = try interp.getInteger(&args[4]);
                const line_no_narrowed = std.math.cast(u32, line_no) orelse return interp.integerOverflowError(i64, line_no);
                const source = try objects.Source.new(
                    try args[2].current().getString(),
                    args[3].current().asOptional(),
                    line_no_narrowed,
                );
                interp.setResultOwning(source.asHead().asValue());
            }
        },
        .frame => {
            const bad_level_err = heap.InternedString.newValue("bad level");
            const current_frame = interp.callFrameIdx();
            const current_level: i64 = interp.call_frames.items[current_frame].level;

            if (args.len == 2) {
                interp.setResultInteger(current_level + 1);
                return;
            }

            const level = try interp.getInteger(&args[2]);
            // Less than 0 means `level` is a relative level.
            const target_level = if (level < 0) current_level + level else level;
            if (target_level < 0 or target_level > current_level) return interp.setError(bad_level_err);

            const levels_up: u32 = @intCast(current_level - target_level);
            const target_frame = interp.getRelativeCallFrame(current_frame, levels_up).?;

            // Find the topmost eval frame for the target call frame. We start at
            // `eval_frames.items.len` since by design, the current eval frame is
            // always the top one.
            var target_eval_frame: ?*Interp.EvalFrame = null;
            var i = interp.eval_frames.items.len;
            while (i > 0) {
                i -= 1;
                const eval_frame = &interp.eval_frames.items[i];
                if (eval_frame.call_frame == target_frame) {
                    target_eval_frame = eval_frame;
                    break;
                }
            }
            const eval_frame = target_eval_frame orelse return interp.setError(bad_level_err);

            const result_dict = try objects.Dictionary.newWithCapacity(&.{}, 10);
            errdefer result_dict.asHead().dropReference();
            try result_dict.put(heap.InternedString.newValue("type"), heap.InternedString.newValue("source"));
            if (eval_frame.currently_evaluating.asType(objects.Source)) |source| {
                try result_dict.put(heap.InternedString.newValue("line"), objects.Integer.new(source.line_no));
                try result_dict.put(heap.InternedString.newValue("file"), source.file_name.orEmpty());
            } else {
                try result_dict.put(heap.InternedString.newValue("line"), Value.newInt(-1));
                try result_dict.put(heap.InternedString.newValue("file"), heap.interned_empty_string);
            }

            const rel_level = objects.Integer.new(levels_up);
            try result_dict.put(heap.InternedString.newValue("level"), rel_level);

            interp.setResultOwning(result_dict.asHead().asValue());
        },
        .level => {
            const current_frame = interp.callFrameIdx();
            const current_level = @as(i64, interp.call_frames.items[current_frame].level);

            if (args.len == 2) {
                interp.setResultInteger(current_level);
                return;
            }

            const level = try interp.getInteger(&args[2]);
            const target_level = if (level == 0) current_level else if (level > 0) level else current_level + level;
            if (target_level < 1 or target_level > current_level) {
                return interp.setError(heap.InternedString.newValue("bad level"));
            }

            const levels_up: u32 = @intCast(current_level - target_level);
            const target_frame = interp.getRelativeCallFrame(current_frame, levels_up).?;

            const frame_args = interp.call_frames.items[target_frame].args;
            const list = try objects.List.newFromShimmerables(frame_args);
            interp.setResultOwning(list.asHead().asValue());
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
                try interp.setResultString(std.mem.span(obj.vtable.name));
            } else {
                try interp.setResultString(@tagName(args[1].current().raw.tag));
            }
        },
        .parse => {
            const ParseType = enum {
                command,
            };
            const EnumParser = objects.EnumConstructor(ParseType, false);
            const parse_type = try interp.wrapError(&det, EnumParser.get(&det, &args[2]));

            var index: usize = 3;
            var dash_dash_index: ?usize = 0;
            while (index < args.len) : (index += 1) {
                if (try args[index].equalsString("--")) {
                    dash_dash_index = index;
                    break;
                }
            }

            const sub_arg_count = dash_dash_index orelse return interp.setErrorInterned("-- missing");
            if (sub_arg_count + 1 >= args.len) return interp.setErrorInterned("parse buffer missing");
            const buffer = try args[sub_arg_count + 1].getString();
            if (buffer.len < 1) return interp.setErrorInterned("empty buffer");

            var tokenizer = Tokenizer.init(buffer, 1);
            switch (parse_type) {
                .command => {
                    if (buffer[0] != '[') return interp.setErrorInterned("must start with [");
                    const token = tokenizer.nextCommandToken() catch |err| {
                        return interp.setResultStringOwning(try Tokenizer.convertTokenizerError(heap.global_gpa, err));
                    };

                    const token_value = try String.newValue(buffer[token.loc.start..token.loc.end]);
                    defer token_value.dropReference();
                    const after_end_bracket = token.loc.end + 1;
                    const remaining = if (after_end_bracket < buffer.len)
                        try String.newValue(buffer[after_end_bracket..])
                    else
                        heap.interned_empty_string;
                    defer remaining.dropReference();

                    const return_list = try List.new(&.{ token_value, remaining });
                    interp.setResultOwning(return_list.asHead().asValue());
                },
            }
        },
        .stacktrace => {
            const trace = try interp.buildErrorStack();
            interp.setResultOwning(trace);
        },
    }
}

pub fn registerCommands(interp: *Interp) !void {
    try registerCommand(interp, "vm", vmCmd, "subcommand ?arg ...?", 1, null);
}

const testing = std.testing;
const memutil = common.memutil;

fn testInfoLevel(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("0", "vm level");
    try interp.testExpectScriptError(error.EvalError, "bad level", "vm level 0");
    try interp.testExpectScriptError(error.EvalError, "bad level", "vm level -1");
    try interp.testExpectScriptError(error.EvalError, "bad level", "vm level 1");

    try interp.testExpectScriptResult("f a b",
        \\ fn f {a b} { return [vm level 1] }
        \\ f a b
    );
    try interp.testExpectScriptResult("f a b",
        \\ fn f {a b} { return [vm level 0] }
        \\ f a b
    );

    // `g`'s frame (level 2) can see its own invocation (0 or 2), and its
    // caller `f`'s invocation via either an absolute (1) or relative (-1) level.
    try interp.testExpectScriptResult("g c/f a b/f a b",
        \\ fn g {x} { return "[vm level 2]/[vm level -1]/[vm level 1]" }
        \\ fn f {a b} { g c }
        \\ f a b
    );

    try interp.testExpectScriptError(error.EvalError, "bad level",
        \\ fn g {x} { vm level 3 }
        \\ fn f {a b} { g c }
        \\ f a b
    );
    try interp.testExpectScriptError(error.EvalError, "bad level",
        \\ fn g {x} { vm level -3 }
        \\ fn f {a b} { g c }
        \\ f a b
    );
}

test "vm level" {
    try memutil.checkAllocationFailures(.exhaustive, testInfoLevel, .{});
}

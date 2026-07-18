pub fn hashCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    interp.setResultOwning(try objutil.createHashReference(args[1].current()));
}

pub fn hashlookupCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    interp.setResult(try interp.resolveHash(&args[1]));
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
    const Parser = objutil.SubcommandParser(Subcommands, &.{
        .{ .variant = .exists, .usage = "varName", .min_args = 1, .max_args = 1 },
        .{ .variant = .source, .usage = "script ?fileName lineNo?", .min_args = 1, .max_args = 3 },
        .{ .variant = .frame, .usage = "?level?", .min_args = 0, .max_args = 1 },
        .{ .variant = .hostname, .usage = "", .min_args = 0, .max_args = 0 },
        .{ .variant = .type, .usage = "object", .min_args = 1, .max_args = 1 },
    });

    var det: objutil.ErrorDetails = undefined;
    const subcommand: Subcommands = try interp.wrapError(&det, Parser.parse(&det, args));

    switch (subcommand) {
        .exists => {
            const val = try interp.getVariable(&args[2]);
            try interp.setResultInteger(if (val.toHandle() != null) 1 else 0);
        },
        .source => {
            const script = &args[2];
            if (args.len == 3) {
                if (objutil.getSourceInfo(script.current())) |info| {
                    const file_name = info.file_name.orEmpty();
                    const line_no = try objutil.newInteger(info.line_no);
                    defer line_no.decrRefCount();
                    const list = try objutil.newList(&.{ file_name, line_no });
                    interp.setResultOwning(list);
                } else {
                    const line_no = try objutil.newInteger(1);
                    defer line_no.decrRefCount();
                    const list = try objutil.newList(&.{ Heap.local_heap.emptyHandle(), line_no });
                    interp.setResultOwning(list);
                }
            } else {
                const file_name = try objutil.newString(try args[3].getString());
                defer file_name.decrRefCount();
                const line_no = try interp.getInteger(&args[4]);
                try script.ensureShimmerable();
                try objutil.setSourceInfo(script.current(), .{ .file_name = file_name.toOptional(), .line_no = @intCast(line_no) });
            }
        },
        .frame => {
            const current = interp.callFrameIdx();

            if (args.len == 2) {
                try interp.setResultInteger(@intCast(current + 1));
                return;
            }

            const level = try interp.getInteger(&args[2]);
            const signed_current: i64 = @intCast(current);
            const signed_level: i64 = @intCast(level);
            const target: u32 = blk: {
                if (level < 0) {
                    const t = signed_current + signed_level;
                    if (t < 0) {
                        try interp.setResultString("bad level");
                        return error.EvalError;
                    }
                    break :blk @intCast(t);
                } else {
                    if (signed_level >= signed_current + 1) {
                        try interp.setResultString("bad level");
                        return error.EvalError;
                    }
                    break :blk @intCast(level);
                }
            };

            // Find the topmost eval frame for the target call frame.
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

            if (target_eval_frame == null) {
                try interp.setResultString("bad level");
                return error.EvalError;
            }

            const eval_frame = target_eval_frame.?;
            const body = eval_frame.currently_evaluating;
            const source_info = objutil.getSourceInfo(body);
            const file_name, const base_line = if (source_info) |info| blk: {
                break :blk .{ info.file_name.orEmpty(), info.line_no };
            } else blk: {
                break :blk .{ Heap.local_heap.emptyHandle(), 1 };
            };
            const abs_line = base_line + (eval_frame.current_line -| 1);

            const call_frame = &interp.call_frames.items[eval_frame.call_frame];
            const type_val = if (call_frame.signature.name.toHandle() != null) "fn" else "source";
            const type_handle = try objutil.newString(type_val);
            defer type_handle.decrRefCount();
            const file_name_str = if (file_name.tag() == .string) try file_name.getString() else "";
            const file_handle = try objutil.newString(file_name_str);
            defer file_handle.decrRefCount();
            const line_handle = try objutil.newInteger(@intCast(abs_line));
            defer line_handle.decrRefCount();

            var dict = try objutil.newDictWithCapacity(8);
            defer dict.decrRefCount();

            objutil.dictPutAssumeCapacity(dict, Heap.local_heap.getInternedString(.type), type_handle.steal());
            objutil.dictPutAssumeCapacity(dict, Heap.local_heap.getInternedString(.file), file_handle.steal());
            objutil.dictPutAssumeCapacity(dict, Heap.local_heap.getInternedString(.line), objutil.integerObject(@intCast(abs_line)));

            const rel_level = current - target;
            objutil.dictPutAssumeCapacity(dict, Heap.local_heap.getInternedString(.level), objutil.integerObject(@intCast(rel_level)));

            interp.setResult(dict.borrow());
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
            try interp.setResultString(@tagName(args[1].tag()));
        },
    }
}

pub fn errorinfoCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const message = args[1];
    const stack_trace = if (args.len == 3) args[2].current() else if (args.len == 2) interp.stack_trace.orEmpty() else unreachable;

    // The stack is a flat list: {name file line args ...} repeated.
    var stack_list = stack_trace.borrow();
    errdefer stack_list.decrRefCount();
    try interp.shimmerToListInPlace(&stack_list);

    const error_message = Interp.makeErrorMessage(message.current(), stack_list) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WrongSize => return,
    };
    interp.setResultOwning(error_message);
}

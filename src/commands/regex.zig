const std = @import("std");
const testing = std.testing;

const pcre2 = @import("pcre2");
const strutil = @import("../strutil.zig");

const common = @import("common.zig");
const heap = common.heap;
const Value = common.Value;
const objects = common.objects;
const ErrorDetails = common.ErrorDetails;
const Interp = common.Interp;
const Shimmerable = common.Shimmerable;
const registerCommand = common.registerCommand;
const memutil = common.memutil;

const regex = @import("../regex.zig");
const Regexp = regex.Regexp;
const String = objects.String;

pub fn createIndexPair(start: i64, end: i64) !Value {
    const indices_list = try objects.List.new(&.{ objects.Integer.new(start), objects.Integer.new(end) });
    return indices_list.asHead().asValue();
}

pub fn matchToList(
    subject: []const u8,
    ovector: []usize,
    opt_indices: bool,
) !*objects.List {
    const list = try objects.List.newWithCapacity(&.{}, ovector.len);
    errdefer list.asHead().release();

    var pair_idx: usize = 0;
    while (pair_idx < ovector.len) : (pair_idx += 2) {
        const start = ovector[pair_idx];
        const end = ovector[pair_idx + 1];

        if (start == std.math.maxInt(usize)) {
            if (opt_indices) {
                list.appendAssumeCapacityOwning(try createIndexPair(-1, -1));
            } else {
                list.appendAssumeCapacityOwning(heap.interned_empty_string);
            }
        } else {
            if (opt_indices) {
                // Tcl reports an inclusive end index, while pcre2's ovector end
                // is one past the match, so a zero-length match reports as
                // `start start-1`.
                list.appendAssumeCapacityOwning(try createIndexPair(@intCast(start), @as(i64, @intCast(end)) - 1));
            } else {
                const capture = subject[start..end];
                list.appendAssumeCapacityOwning(try objects.String.newValue(capture));
            }
        }
    }

    return list;
}

pub fn regexpCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    var opt_nocase = false;
    var opt_all = false;
    var opt_inline = false;
    var opt_indices = false;
    var opt_expanded = false;
    var opt_line = false;
    var opt_linestop = false;
    var opt_lineanchor = false;
    var opt_start: i64 = 0;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (try args[i].current().equalsString("-nocase")) {
            opt_nocase = true;
        } else if (try args[i].current().equalsString("-all")) {
            opt_all = true;
        } else if (try args[i].current().equalsString("-inline")) {
            opt_inline = true;
        } else if (try args[i].current().equalsString("-indices")) {
            opt_indices = true;
        } else if (try args[i].current().equalsString("-expanded")) {
            opt_expanded = true;
        } else if (try args[i].current().equalsString("-line")) {
            opt_line = true;
        } else if (try args[i].current().equalsString("-linestop")) {
            opt_linestop = true;
        } else if (try args[i].current().equalsString("-lineanchor")) {
            opt_lineanchor = true;
        } else if (try args[i].current().equalsString("-start")) {
            i += 1;
            if (i >= args.len) return error.WrongUsage;
            opt_start = try interp.getInteger(&args[i]);
        } else if (try args[i].current().equalsString("--")) {
            i += 1;
            break;
        } else {
            break;
        }
    }

    const remaining = args[i..];
    if (remaining.len < 2) return error.WrongUsage;
    if (opt_inline and remaining.len > 2) return error.WrongUsage;

    var compile_opts: u32 = pcre2.PCRE2_UTF | pcre2.PCRE2_UCP | pcre2.PCRE2_DOTALL;
    if (opt_nocase) compile_opts |= pcre2.PCRE2_CASELESS;
    if (opt_expanded) compile_opts |= pcre2.PCRE2_EXTENDED;
    if (opt_line or opt_lineanchor) compile_opts |= pcre2.PCRE2_MULTILINE;
    if (opt_line or opt_linestop) compile_opts &= ~@as(u32, pcre2.PCRE2_DOTALL);

    const regexp_arg = &remaining[0];
    var det: objects.ErrorDetails = undefined;
    const regexp = try interp.wrapError(&det, Regexp.shimmerFrom(&det, regexp_arg, compile_opts));

    const subject = try remaining[1].getString();
    const match_vars = remaining[2..];

    // Read through `regex` rather than aliasing, since these are set by
    // `initGlobals` and an alias would capture the pre-init value.
    const match_data = pcre2.pcre2_match_data_create_from_pattern_8(regexp.regexp, regex.pcre2_ctx) orelse return error.OutOfMemory;
    defer pcre2.pcre2_match_data_free_8(match_data);

    var start_offset: usize = 0;
    var skip_match = false;
    if (opt_start != 0) {
        const cp_len = try String.getCodepointLength(&remaining[1]);
        var start_cp_idx = opt_start;
        if (start_cp_idx < 0) {
            start_cp_idx += @as(i64, @intCast(cp_len)) + 1;
        }
        // `<=`, not `==`: a `-start` more negative than the string is still
        // negative after the wrap above, and `-start -10` on an 8 character
        // subject lands on -1. Letting that reach the `else` below would
        // `@intCast` a negative to `usize`.
        if (start_cp_idx <= 0) {
            start_offset = 0;
        } else if (start_cp_idx > cp_len) {
            skip_match = true;
        } else {
            start_offset = strutil.cpIndex(subject, @intCast(start_cp_idx)) orelse subject.len;
        }
    }

    var match_opts: u32 = 0;
    if (start_offset > 0) match_opts |= pcre2.PCRE2_NOTBOL;

    var result_list: ?*objects.List = null;
    if (opt_inline and opt_all) result_list = try objects.List.new(&.{});
    errdefer if (result_list) |val| val.asHead().release();

    var match_count: usize = 0;

    if (!skip_match) while (true) {
        if (start_offset > subject.len) break;
        const return_code = pcre2.pcre2_match_8(
            regexp.regexp,
            subject.ptr,
            subject.len,
            start_offset,
            match_opts,
            match_data,
            regex.pcre2_match_ctx,
        );
        if (return_code == pcre2.PCRE2_ERROR_NOMATCH) break;
        if (return_code == pcre2.PCRE2_ERROR_NOMEMORY) return error.OutOfMemory;
        if (return_code < 0) {
            var buf: [256]u8 = undefined;
            const msg_len = pcre2.pcre2_get_error_message_8(return_code, &buf, buf.len);
            const msg = buf[0..@intCast(msg_len)];
            try interp.setResultString(msg);
            return error.EvalError;
        }

        match_count += 1;

        const ovector_count = pcre2.pcre2_get_ovector_count_8(match_data) * 2;
        const ovector = pcre2.pcre2_get_ovector_pointer_8(match_data)[0..ovector_count];

        if (opt_inline) {
            if (opt_all) {
                const match_list = try matchToList(subject, ovector, opt_indices);
                defer match_list.asHead().release();
                // `append` borrows, so the items stay owned by `match_list`
                // until it is released above.
                for (match_list.items) |item| try result_list.?.append(item);
            } else {
                const list = try matchToList(subject, ovector, opt_indices);
                interp.setResultOwning(list.asHead().asValue());
                return;
            }
        } else {
            try setRegexpCaptureVars(interp, subject, match_data, match_vars, opt_indices);
        }

        if (!opt_all) break;

        const match_end = ovector[1];
        const match_start = ovector[0];
        if (match_end == match_start) {
            start_offset = match_start + 1;
        } else {
            start_offset = match_end;
        }
        match_opts |= pcre2.PCRE2_NOTBOL;
    };

    if (opt_inline) {
        if (opt_all) {
            interp.setResultOwning(result_list.?.asHead().asValue());
        } else {
            interp.setEmptyResult();
        }
    } else {
        if (opt_all) {
            interp.setResultInteger(@intCast(match_count));
        } else {
            interp.setResultBoolean(match_count > 0);
        }
    }
}

fn setRegexpCaptureVars(
    interp: *Interp,
    subject: []const u8,
    match_data: *pcre2.pcre2_match_data_8,
    match_vars: []Shimmerable,
    opt_indices: bool,
) Interp.Error!void {
    if (match_vars.len == 0) return;

    const ovector = pcre2.pcre2_get_ovector_pointer_8(match_data);
    const ovector_count = pcre2.pcre2_get_ovector_count_8(match_data);

    for (match_vars, 0..) |*var_name, idx| {
        if (idx < ovector_count) {
            const start = ovector[idx * 2];
            const end = ovector[idx * 2 + 1];
            if (start == std.math.maxInt(usize)) {
                if (opt_indices) {
                    const indices_list = try createIndexPair(-1, -1);
                    defer indices_list.release();
                    try interp.setVariable(var_name, indices_list);
                } else {
                    try interp.setVariable(var_name, heap.interned_empty_string);
                }
            } else {
                if (opt_indices) {
                    // Inclusive end, as in `matchToList`.
                    const indices_list = try createIndexPair(@intCast(start), @as(i64, @intCast(end)) - 1);
                    defer indices_list.release();
                    try interp.setVariable(var_name, indices_list);
                } else {
                    const capture = subject[start..end];
                    const capture_value = try objects.String.newValue(capture);
                    defer capture_value.release();
                    try interp.setVariable(var_name, capture_value);
                }
            }
        } else {
            if (opt_indices) {
                const pair = try createIndexPair(-1, -1);
                defer pair.release();
                try interp.setVariable(var_name, pair);
            } else {
                try interp.setVariable(var_name, heap.interned_empty_string);
            }
        }
    }
}

pub fn registerCommands(interp: *Interp) !void {
    try registerCommand(interp, "regexp", regexpCmd, "?options? exp string ?matchVar ...?", 2, null);
    try registerCommand(interp, "regsub", regsubCmd, "?options? exp string subSpec ?varName?", 3, null);
}

pub fn regsubCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    var opt_nocase = false;
    var opt_all = false;
    var opt_expanded = false;
    var opt_line = false;
    var opt_linestop = false;
    var opt_lineanchor = false;
    var opt_start: i64 = 0;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (try args[i].current().equalsString("-nocase")) {
            opt_nocase = true;
        } else if (try args[i].current().equalsString("-all")) {
            opt_all = true;
        } else if (try args[i].current().equalsString("-expanded")) {
            opt_expanded = true;
        } else if (try args[i].current().equalsString("-line")) {
            opt_line = true;
        } else if (try args[i].current().equalsString("-linestop")) {
            opt_linestop = true;
        } else if (try args[i].current().equalsString("-lineanchor")) {
            opt_lineanchor = true;
        } else if (try args[i].current().equalsString("-start")) {
            i += 1;
            if (i >= args.len) return error.WrongUsage;
            opt_start = try interp.getInteger(&args[i]);
        } else if (try args[i].current().equalsString("--")) {
            i += 1;
            break;
        } else {
            break;
        }
    }

    const remaining = args[i..];
    if (remaining.len != 3 and remaining.len != 4) return error.WrongUsage;

    var compile_opts: u32 = pcre2.PCRE2_UTF | pcre2.PCRE2_UCP | pcre2.PCRE2_DOTALL;
    if (opt_nocase) compile_opts |= pcre2.PCRE2_CASELESS;
    if (opt_expanded) compile_opts |= pcre2.PCRE2_EXTENDED;
    if (opt_line or opt_lineanchor) compile_opts |= pcre2.PCRE2_MULTILINE;
    if (opt_line or opt_linestop) compile_opts &= ~@as(u32, pcre2.PCRE2_DOTALL);

    const regexp_arg = &remaining[0];
    var det: objects.ErrorDetails = undefined;
    const regexp = try interp.wrapError(&det, Regexp.shimmerFrom(&det, regexp_arg, compile_opts));

    const pattern_str = try regexp_arg.current().getString();

    const subject = try remaining[1].current().getString();
    const sub_spec = try remaining[2].current().getString();

    const match_data = pcre2.pcre2_match_data_create_from_pattern_8(regexp.regexp, null) orelse return error.OutOfMemory;
    defer pcre2.pcre2_match_data_free_8(match_data);

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(heap.global_gpa);

    var src_pos: usize = 0;
    var start_offset: usize = 0;
    if (opt_start != 0) {
        const cp_len = try String.getCodepointLength(&remaining[1]);
        var start_char_idx = opt_start;
        if (start_char_idx < 0) {
            start_char_idx += @as(i64, @intCast(cp_len)) + 1;
        }
        if (start_char_idx <= 0) {
            start_offset = 0;
        } else if (start_char_idx > cp_len) {
            start_offset = subject.len;
        } else {
            start_offset = strutil.cpIndex(subject, @intCast(start_char_idx)) orelse subject.len;
        }
        try result.appendSlice(heap.global_gpa, subject[0..start_offset]);
        src_pos = start_offset;
    }

    var match_opts: u32 = 0;
    if (start_offset > 0) match_opts |= pcre2.PCRE2_NOTBOL;

    var match_count: usize = 0;

    while (true) {
        if (start_offset > subject.len) break;
        const rc = pcre2.pcre2_match_8(regexp.regexp, subject.ptr, subject.len, start_offset, match_opts, match_data, null);
        if (rc == pcre2.PCRE2_ERROR_NOMATCH) break;
        if (rc == pcre2.PCRE2_ERROR_NOMEMORY) return error.OutOfMemory;
        if (rc < 0) {
            var buf: [256]u8 = undefined;
            const msg_len = pcre2.pcre2_get_error_message_8(rc, &buf, buf.len);
            const msg = buf[0..@intCast(msg_len)];
            try interp.setResultString(msg);
            return error.EvalError;
        }

        match_count += 1;

        const ovector = pcre2.pcre2_get_ovector_pointer_8(match_data);
        const ovector_count = pcre2.pcre2_get_ovector_count_8(match_data);

        const match_start = ovector[0];
        const match_end = ovector[1];

        try result.appendSlice(heap.global_gpa, subject[src_pos..match_start]);
        try applySubstitution(&result, subject, ovector, ovector_count, sub_spec);

        src_pos = match_end;
        start_offset = match_end;

        if (!opt_all) break;

        if (match_end == match_start) {
            if (pattern_str.len > 0 and pattern_str[0] == '^') {
                match_opts |= pcre2.PCRE2_NOTBOL;
                // Don't advance; next iteration will try same position with NOTBOL.
            } else {
                const char_len = strutil.cpIndex(subject[src_pos..], 1) orelse 0;
                if (char_len == 0) break;
                try result.appendSlice(heap.global_gpa, subject[src_pos .. src_pos + char_len]);
                src_pos += char_len;
                start_offset = src_pos;
                match_opts |= pcre2.PCRE2_NOTBOL;
            }
        } else {
            if (start_offset >= subject.len) break;
            match_opts |= pcre2.PCRE2_NOTBOL;
        }
    }

    try result.appendSlice(heap.global_gpa, subject[src_pos..]);
    try result.append(heap.global_gpa, 0); // Null sentinel.
    const substituted = try result.toOwnedSlice(heap.global_gpa);
    const substituted_str = blk: {
        errdefer heap.global_gpa.free(substituted);
        // `NoFree`, since the errdefer above already frees `substituted`.
        break :blk try String.newOwningNoFree(substituted[0 .. substituted.len - 1 :0]);
    };
    defer substituted_str.asHead().release();

    if (remaining.len == 4) {
        try interp.setVariable(&remaining[3], substituted_str.asHead().asValue());
        interp.setResultInteger(@intCast(match_count));
    } else {
        interp.setResult(substituted_str.asHead().asValue());
    }
}

fn applySubstitution(
    result: *std.ArrayList(u8),
    subject: []const u8,
    ovector: [*]usize,
    ovector_count: u32,
    sub_spec: []const u8,
) !void {
    var j: usize = 0;
    while (j < sub_spec.len) : (j += 1) {
        const c = sub_spec[j];
        if (c == '&') {
            if (ovector_count > 0 and ovector[0] != std.math.maxInt(usize)) {
                try result.appendSlice(heap.global_gpa, subject[ovector[0]..ovector[1]]);
            }
        } else if (c == '\\') {
            if (j + 1 < sub_spec.len) {
                j += 1;
                const next_c = sub_spec[j];
                if (next_c >= '0' and next_c <= '9') {
                    const idx = next_c - '0';
                    if (idx < ovector_count and ovector[idx * 2] != std.math.maxInt(usize)) {
                        const start = ovector[idx * 2];
                        const end = ovector[idx * 2 + 1];
                        try result.appendSlice(heap.global_gpa, subject[start..end]);
                    }
                } else if (next_c == '\\' or next_c == '&') {
                    try result.append(heap.global_gpa, next_c);
                } else {
                    try result.append(heap.global_gpa, '\\');
                    try result.append(heap.global_gpa, next_c);
                }
            } else {
                try result.append(heap.global_gpa, '\\');
            }
        } else {
            try result.append(heap.global_gpa, c);
        }
    }
}

fn testRegexpBasicMatch(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("true",
        \\ regexp "hello" "hello world"
    );
    try interp.testExpectScriptResult("false",
        \\ regexp "foo" "hello world"
    );
}

test "regexp basic match" {
    try memutil.checkAllocationFailures(.exhaustive, testRegexpBasicMatch, .{});
}

fn testRegexpNocase(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("true",
        \\ regexp -nocase "HELLO" "hello world"
    );
    try interp.testExpectScriptResult("false",
        \\ regexp "HELLO" "hello world"
    );
}

test "regexp -nocase" {
    try memutil.checkAllocationFailures(.exhaustive, testRegexpNocase, .{});
}

fn testRegexpCaptureVariables(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("helloworld",
        \\ regexp {hello(\w+)} "helloworld" match group1
        \\ set match
    );
    try interp.testExpectScriptResult("world",
        \\ regexp {hello(\w+)} "helloworld" match group1
        \\ set group1
    );
}

test "regexp capture variables" {
    try memutil.checkAllocationFailures(.exhaustive, testRegexpCaptureVariables, .{});
}

fn testRegexpAll(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("2",
        \\ regexp -all "o" "hello world"
    );
    try interp.testExpectScriptResult("3",
        \\ regexp -all "l" "hello world"
    );
}

test "regexp -all" {
    try memutil.checkAllocationFailures(.exhaustive, testRegexpAll, .{});
}

fn testRegexpAllWithCaptureVariables(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Variables get the values from the last match.
    try interp.testExpectScriptResult("c",
        \\ regexp -all "(.)" "abc" match group1
        \\ set group1
    );
}

test "regexp -all with capture variables" {
    try memutil.checkAllocationFailures(.exhaustive, testRegexpAllWithCaptureVariables, .{});
}

fn testRegexpInline(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("helloworld world",
        \\ regexp -inline {hello(\w+)} "helloworld"
    );
    try interp.testExpectScriptResult("",
        \\ regexp -inline "foo" "hello world"
    );
}

test "regexp -inline" {
    try memutil.checkAllocationFailures(.exhaustive, testRegexpInline, .{});
}

fn testRegexpAllInline(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("o o",
        \\ regexp -all -inline "o" "hello world"
    );
}

test "regexp -all -inline" {
    try memutil.checkAllocationFailures(.exhaustive, testRegexpAllInline, .{});
}

fn testRegexpIndices(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("0 9",
        \\ regexp -indices {hello(\w+)} "helloworld" match group1
        \\ set match
    );
    try interp.testExpectScriptResult("5 9",
        \\ regexp -indices {hello(\w+)} "helloworld" match group1
        \\ set group1
    );
}

test "regexp -indices" {
    try memutil.checkAllocationFailures(.exhaustive, testRegexpIndices, .{});
}

fn testRegexpInlineIndices(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("{0 4}",
        \\ regexp -inline -indices "hello" "hello"
    );
}

test "regexp -inline -indices" {
    try memutil.checkAllocationFailures(.exhaustive, testRegexpInlineIndices, .{});
}

fn testRegexpStart(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("world",
        \\ regexp -start 5 {(\w+)} "helloworld" match
        \\ set match
    );
}

test "regexp -start" {
    try memutil.checkAllocationFailures(.exhaustive, testRegexpStart, .{});
}

fn testRegexpBasicOperation(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("true",
        \\ regexp ab*c abbbc
    );
    try interp.testExpectScriptResult("true",
        \\ regexp ab*c ac
    );
    try interp.testExpectScriptResult("false",
        \\ regexp ab*c ab
    );
    try interp.testExpectScriptResult("true",
        \\ regexp -- -gorp abc-gorpxxx
    );
    try interp.testExpectScriptResult("true",
        \\ regexp {^([^ ]*)[ ]*([^ ]*)} "" a
    );
}

test "regexp basic operation" {
    try memutil.checkAllocationFailures(.exhaustive, testRegexpBasicOperation, .{});
}

fn testRegexpCaptureVariablesBasic(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("true abbbbc",
        \\ set foo {}
        \\ list [regexp ab*c abbbbc foo] $foo
    );
    try interp.testExpectScriptResult("true abbbbc bbbb",
        \\ set foo {}
        \\ set f2 {}
        \\ list [regexp a(b*)c abbbbc foo f2] $foo $f2
    );
    try interp.testExpectScriptResult("true abbbbc bbbb",
        \\ set foo {}
        \\ set f2 {}
        \\ list [regexp a(b*)(c) abbbbc foo f2] $foo $f2
    );
    try interp.testExpectScriptResult("true abbbbc bbbb c",
        \\ set foo {}
        \\ set f2 {}
        \\ set f3 {}
        \\ list [regexp a(b*)(c) abbbbc foo f2 f3] $foo $f2 $f3
    );
}

test "regexp capture variables basic" {
    try memutil.checkAllocationFailures(.exhaustive, testRegexpCaptureVariablesBasic, .{});
}

fn testRegexpCaptureVariablesOptionalGroups(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("true a a {} {}",
        \\ set foo 2; set f2 2; set f3 2; set f4 2
        \\ list [regexp (a)(b)? xay foo f2 f3 f4] $foo $f2 $f3 $f4
    );
    try interp.testExpectScriptResult("true ac a {} c",
        \\ set foo 1; set f2 1; set f3 1; set f4 1
        \\ list [regexp (a)(b)?(c) xacy foo f2 f3 f4] $foo $f2 $f3 $f4
    );
}

test "regexp capture variables optional groups" {
    try memutil.checkAllocationFailures(.exhaustive, testRegexpCaptureVariablesOptionalGroups, .{});
}

fn testRegexpIndicesCaptureVariables(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("true {0 5}",
        \\ set foo {}
        \\ list [regexp -indices ab*c abbbbc foo] $foo
    );
    try interp.testExpectScriptResult("true {0 5} {1 4}",
        \\ set foo {}
        \\ set f2 {}
        \\ list [regexp -indices a(b*)c abbbbc foo f2] $foo $f2
    );
    try interp.testExpectScriptResult("true {0 5} {1 4} {5 5}",
        \\ set foo {}
        \\ set f2 {}
        \\ set f3 {}
        \\ list [regexp -indices a(b*)(c) abbbbc foo f2 f3] $foo $f2 $f3
    );
    try interp.testExpectScriptResult("true {1 1} {1 1} {-1 -1} {-1 -1}",
        \\ set foo 2; set f2 2; set f3 2; set f4 2
        \\ list [regexp -indices (a)(b)? xay foo f2 f3 f4] $foo $f2 $f3 $f4
    );
    try interp.testExpectScriptResult("true {1 2} {1 1} {-1 -1} {2 2}",
        \\ set foo 1; set f2 1; set f3 1; set f4 1
        \\ list [regexp -indices (a)(b)?(c) xacy foo f2 f3 f4] $foo $f2 $f3 $f4
    );
}

test "regexp -indices capture variables" {
    try memutil.checkAllocationFailures(.exhaustive, testRegexpIndicesCaptureVariables, .{});
}

fn testRegexpNocaseCapture(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("true aBbbxYXxxZ Bbb xYXxx",
        \\ set f1 22
        \\ set f2 33
        \\ set f3 44
        \\ list [regexp -nocase {a(b*)([xy]*)z} aBbbxYXxxZ22 f1 f2 f3] $f1 $f2 $f3
    );
}

test "regexp -nocase capture" {
    try memutil.checkAllocationFailures(.exhaustive, testRegexpNocaseCapture, .{});
}

fn testRegexpAllWithInline(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("b b b b b b",
        \\ regexp -all -inline b abababbabaaaaaaaaaab
    );
    try interp.testExpectScriptResult("10 20 30 40",
        \\ regexp -all -inline {\d+} "10:20:30:40"
    );
}

test "regexp -all with -inline" {
    try memutil.checkAllocationFailures(.exhaustive, testRegexpAllWithInline, .{});
}

fn testRegexpAllInlineIndices(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("{0 4} {1 3} {2 2} {-1 -1} {5 9} {6 8} {-1 -1} {7 7}",
        \\ regexp -all -inline -indices a(b(c)d|e(f)g)h abcdhaefgh
    );
}

test "regexp -all -inline -indices" {
    try memutil.checkAllocationFailures(.exhaustive, testRegexpAllInlineIndices, .{});
}

fn testRegexpAllWithCaptureVarsGetsLastMatch(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("aefgh efg {} f {}",
        \\ regexp -all a(b(c)d|e(f)g)h abcdhaefgh a b c d e
        \\ list $a $b $c $d $e
    );
}

test "regexp -all with capture vars gets last match" {
    try memutil.checkAllocationFailures(.exhaustive, testRegexpAllWithCaptureVarsGetsLastMatch, .{});
}

fn testRegexpStartEdgeCases(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("true 1",
        \\ list [regexp -start -10 {\d} 1abc2de3 x] $x
    );
    try interp.testExpectScriptResult("true 2",
        \\ list [regexp -start 2 {\d} 1abc2de3 x] $x
    );
    try interp.testExpectScriptResult("true 2",
        \\ list [regexp -start 4 {\d} 1abc2de3 x] $x
    );
    try interp.testExpectScriptResult("true 3",
        \\ list [regexp -start 5 {\d} 1abc2de3 x] $x
    );
    try interp.testExpectScriptResult("false",
        \\ regexp -start [string length 1abc2de3] {\d} 1abc2de3 x
    );
    try interp.testExpectScriptResult("false",
        \\ regexp -start 2 {^$} {}
    );
}

test "regexp -start edge cases" {
    try memutil.checkAllocationFailures(.exhaustive, testRegexpStartEdgeCases, .{});
}

fn testRegexpInlineNoMatches(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("",
        \\ regexp -inline {\w(\d+)\w} ""
    );
    try interp.testExpectScriptResult("",
        \\ regexp -inline hello goodbye
    );
}

test "regexp -inline no matches" {
    try memutil.checkAllocationFailures(.exhaustive, testRegexpInlineNoMatches, .{});
}

fn testRegexpInlineWithCaptures(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("b b",
        \\ regexp -inline (b) ababa
    );
    try interp.testExpectScriptResult("e456d 456",
        \\ regexp -inline {\w(\d+)\w} "   hello 23 there456def "
    );
}

test "regexp -inline with captures" {
    try memutil.checkAllocationFailures(.exhaustive, testRegexpInlineWithCaptures, .{});
}

fn testRegexpEmptyString(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("true",
        \\ regexp -- ^ {}
    );
    try interp.testExpectScriptResult("true",
        \\ regexp -start 0 -- ^ {}
    );
    try interp.testExpectScriptResult("false",
        \\ regexp -start 3 -- ^ {123}
    );
    try interp.testExpectScriptResult("true",
        \\ regexp -start 3 -- $ {123}
    );
}

test "regexp empty string" {
    try memutil.checkAllocationFailures(.exhaustive, testRegexpEmptyString, .{});
}

fn testRegsubBasicOperation(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("1 xax111aaa222xaa",
        \\ list [regsub aa+ xaxaaaxaa 111&222 foo] $foo
    );
    try interp.testExpectScriptResult("1 aaa111xaa",
        \\ list [regsub aa+ aaaxaa &111 foo] $foo
    );
    try interp.testExpectScriptResult("1 xax111aaa",
        \\ list [regsub aa+ xaxaaa 111& foo] $foo
    );
    try interp.testExpectScriptResult("1 11aaa2aaa333",
        \\ list [regsub aa+ aaa 11&2&333 foo] $foo
    );
    try interp.testExpectScriptResult("1 xaxaaa2aaa333xaa",
        \\ list [regsub aa+ xaxaaaxaa &2&333 foo] $foo
    );
    try interp.testExpectScriptResult("1 xax1aaa22aaaxaa",
        \\ list [regsub aa+ xaxaaaxaa 1&22& foo] $foo
    );
}

test "regsub basic operation" {
    try memutil.checkAllocationFailures(.exhaustive, testRegsubBasicOperation, .{});
}

fn testRegsubCaptureGroups(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("1 xax1aa22aaxaa",
        \\ list [regsub a(a+) xaxaaaxaa {1\122\1} foo] $foo
    );
    try interp.testExpectScriptResult("1 {xax1\\aa22aaxaa}",
        \\ list [regsub a(a+) xaxaaaxaa {1\\\122\1} foo] $foo
    );
    try interp.testExpectScriptResult("1 {xax1\\122aaxaa}",
        \\ list [regsub a(a+) xaxaaaxaa {1\\122\1} foo] $foo
    );
    try interp.testExpectScriptResult("1 {xax1\\aaaaaxaa}",
        \\ list [regsub a(a+) xaxaaaxaa {1\\&\1} foo] $foo
    );
    try interp.testExpectScriptResult("1 xax1&aaxaa",
        \\ list [regsub a(a+) xaxaaaxaa {1\&\1} foo] $foo
    );
    try interp.testExpectScriptResult("1 xaxaaaaaaaaaaaaaaxaa",
        \\ list [regsub a(a+) xaxaaaxaa {\1\1\1\1&&} foo] $foo
    );
}

test "regsub capture groups" {
    try memutil.checkAllocationFailures(.exhaustive, testRegsubCaptureGroups, .{});
}

fn testRegsubNoMatchAndAnchored(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("0 xyz",
        \\ set foo xxx; list [regsub abc xyz 111 foo] $foo
    );
    try interp.testExpectScriptResult("1 {111 xyz}",
        \\ set foo xxx; list [regsub ^ xyz "111 " foo] $foo
    );
    try interp.testExpectScriptResult("1 {abc111 def}",
        \\ set foo xxx; list [regsub -- -foo abc-foodef "111 " foo] $foo
    );
    try interp.testExpectScriptResult("0 {}",
        \\ set foo xxx; list [regsub x "" y foo] $foo
    );
}

test "regsub no match and anchored" {
    try memutil.checkAllocationFailures(.exhaustive, testRegsubNoMatchAndAnchored, .{});
}

fn testRegsubNocase(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("1 xaAAaAAay",
        \\ list [regsub -nocase a(a+) xaAAaAAay & foo] $foo
    );
    try interp.testExpectScriptResult("0 xaAAaAAay",
        \\ set foo 123; list [regsub a(a+) xaAAaAAay & foo] $foo
    );
    try interp.testExpectScriptResult("1 CbDE",
        \\ set foo 123; list [regsub -nocase a CaDE b foo] $foo
    );
    try interp.testExpectScriptResult("1 CbD",
        \\ set foo 123; list [regsub -nocase XYZ CxYzD b foo] $foo
    );
}

test "regsub -nocase" {
    try memutil.checkAllocationFailures(.exhaustive, testRegsubNocase, .{});
}

fn testRegsubAll(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("4 a|xxx|b|xx|c|x|d|x|",
        \\ set foo 86; list [regsub -all x+ axxxbxxcxdx |&| foo] $foo
    );
    try interp.testExpectScriptResult("1 a|xxx|bxxcxdx",
        \\ set foo 86; list [regsub x+ axxxbxxcxdx |&| foo] $foo
    );
    try interp.testExpectScriptResult("0 axxxbxxcxdx",
        \\ set foo 86; list [regsub -all bc axxxbxxcxdx |&| foo] $foo
    );
    try interp.testExpectScriptResult("2 {yy yy more}",
        \\ set foo xxx; list [regsub -all node "node node more" yy foo] $foo
    );
    try interp.testExpectScriptResult("1 123xxx",
        \\ set foo xxx; list [regsub -all ^ xxx 123 foo] $foo
    );
}

test "regsub -all" {
    try memutil.checkAllocationFailures(.exhaustive, testRegsubAll, .{});
}

fn testRegsubWithoutVarNameReturnsValue(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("aXaca",
        \\ regsub b abaca X
    );
    try interp.testExpectScriptResult("XbXcX",
        \\ regsub -all a abaca X
    );
    try interp.testExpectScriptResult("a,bcd,c,eabcfde",
        \\ regsub {b([^d]*)d} abcdeabcfde {,&,\1,}
    );
    try interp.testExpectScriptResult("a,bcd,c,ea,bcfd,cf,e",
        \\ regsub -all {b([^d]*)d} abcdeabcfde {,&,\1,}
    );
}

test "regsub without varName returns value" {
    try memutil.checkAllocationFailures(.exhaustive, testRegsubWithoutVarNameReturnsValue, .{});
}

fn testRegsubStart(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("4 a1b/2c/3d/4e/5",
        \\ set x {}; list [regsub -all -start 2 {\d} a1b2c3d4e5 {/&} x] $x
    );
    try interp.testExpectScriptResult("0 hello",
        \\ set x {}; list [regsub -all -start -25 {z} hello {/&} x] $x
    );
    try interp.testExpectScriptResult("0 hello",
        \\ set x {}; list [regsub -all -start 3 {z} hello {/&} x] $x
    );
    try interp.testExpectScriptResult("1 cbc",
        \\ list [regsub -start 2 -start 0 a abc c x] $x
    );
    try interp.testExpectScriptResult("0 abc",
        \\ list [regsub -start 0 -start 2 a abc c x] $x
    );
}

test "regsub -start" {
    try memutil.checkAllocationFailures(.exhaustive, testRegsubStart, .{});
}

const std = @import("std");
const mem = std.mem;
const math = std.math;
const assert = std.debug.assert;
const testing = std.testing;

const common = @import("common.zig");
const heap = common.heap;
const objects = common.objects;
const ErrorDetails = common.ErrorDetails;
const Value = common.Value;
const Interp = common.Interp;
const Shimmerable = common.Shimmerable;
const registerCommand = common.registerCommand;
const memutil = common.memutil;

fn codecEncodeBase64(interp: *Interp, opt_args: []Shimmerable, data_arg: *Shimmerable) Interp.Error!void {
    var max_len: ?usize = null;
    var wrap_char: []const u8 = "\n";
    var idx: usize = 0;
    while (idx < opt_args.len) {
        const opt = try opt_args[idx].current().getString();
        if (mem.eql(u8, opt, "-maxlen")) {
            if (idx + 1 >= opt_args.len) return error.WrongUsage;
            const len_int = try interp.getInteger(&opt_args[idx + 1]);
            if (len_int < 0) return interp.setErrorString("expected positive integer for -maxlen");
            max_len = if (len_int == 0) null else @intCast(len_int);
            idx += 2;
        } else if (mem.eql(u8, opt, "-wrapchar")) {
            if (idx + 1 >= opt_args.len) return error.WrongUsage;
            wrap_char = try opt_args[idx + 1].current().getString();
            idx += 2;
        } else {
            return interp.setErrorFormatted("bad option \"{s}\": must be -maxlen or -wrapchar", .{opt});
        }
    }

    const data = try data_arg.current().getString();
    const enc_len = std.base64.standard.Encoder.calcSize(data.len);
    const raw_b64 = try heap.local_arena.alloc(u8, enc_len);
    _ = std.base64.standard.Encoder.encode(raw_b64, data);

    if (max_len) |line_len| {
        var out_buf: std.ArrayList(u8) = .empty;
        var offset: usize = 0;
        while (offset < enc_len) {
            const chunk_len = @min(line_len, enc_len - offset);
            try out_buf.appendSlice(heap.local_arena, raw_b64[offset .. offset + chunk_len]);
            offset += chunk_len;
            if (offset < enc_len or wrap_char.len > 0) {
                try out_buf.appendSlice(heap.local_arena, wrap_char);
            }
        }
        return interp.setResultString(out_buf.items);
    } else {
        return interp.setResultString(raw_b64);
    }
}

fn codecEncodeHex(interp: *Interp, opt_args: []Shimmerable, data_arg: *Shimmerable) Interp.Error!void {
    if (opt_args.len != 0) {
        const opt = try opt_args[0].current().getString();
        return interp.setErrorFormatted("bad option \"{s}\": hex encode takes no options", .{opt});
    }

    const data = try data_arg.current().getString();
    const hex_chars = "0123456789abcdef";
    const hex_buf = try heap.local_arena.alloc(u8, data.len * 2);
    for (data, 0..) |b, hex_i| {
        hex_buf[hex_i * 2] = hex_chars[b >> 4];
        hex_buf[hex_i * 2 + 1] = hex_chars[b & 0xF];
    }
    return interp.setResultString(hex_buf);
}

fn codecDecodeBase64(interp: *Interp, opt_args: []Shimmerable, data_arg: *Shimmerable) Interp.Error!void {
    var strict = false;
    var idx: usize = 0;
    while (idx < opt_args.len) {
        const opt = try opt_args[idx].current().getString();
        if (mem.eql(u8, opt, "-strict")) {
            strict = true;
            idx += 1;
        } else {
            return interp.setErrorFormatted("bad option \"{s}\": must be -strict", .{opt});
        }
    }

    const input = try data_arg.current().getString();
    const clean_input = if (!strict) blk: {
        var filtered: std.ArrayList(u8) = .empty;
        for (input) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;
            try filtered.append(heap.local_arena, c);
        }
        break :blk filtered.items;
    } else input;

    if (clean_input.len == 0) {
        return interp.setResultString("");
    }

    const max_decoded_len = std.base64.standard.Decoder.calcSizeUpperBound(clean_input.len) catch {
        return interp.setErrorString("invalid base64 encoding");
    };
    const dest = try heap.local_arena.alloc(u8, max_decoded_len);
    std.base64.standard.Decoder.decode(dest, clean_input) catch {
        return interp.setErrorString("invalid base64 encoding");
    };
    var pad: usize = 0;
    if (clean_input.len > 0 and clean_input[clean_input.len - 1] == '=') pad += 1;
    if (clean_input.len > 1 and clean_input[clean_input.len - 2] == '=') pad += 1;
    const exact_len = max_decoded_len - pad;
    return interp.setResultString(dest[0..exact_len]);
}

fn codecDecodeHex(interp: *Interp, opt_args: []Shimmerable, data_arg: *Shimmerable) Interp.Error!void {
    if (opt_args.len != 0) {
        const opt = try opt_args[0].current().getString();
        return interp.setErrorFormatted("bad option \"{s}\": hex decode takes no options", .{opt});
    }

    const input = try data_arg.current().getString();
    if (input.len % 2 != 0) return interp.setErrorString("hex string must have an even number of digits");
    const dest = try heap.local_arena.alloc(u8, input.len / 2);
    _ = std.fmt.hexToBytes(dest, input) catch {
        return interp.setErrorString("invalid hex string");
    };
    return interp.setResultString(dest);
}

fn codecEncode(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const codec_name = try args[0].current().getString();
    const opt_args = args[1 .. args.len - 1];
    const data_arg = &args[args.len - 1];

    if (mem.eql(u8, codec_name, "base64")) {
        return codecEncodeBase64(interp, opt_args, data_arg);
    } else if (mem.eql(u8, codec_name, "hex")) {
        return codecEncodeHex(interp, opt_args, data_arg);
    } else {
        return interp.setErrorFormatted("unknown codec \"{s}\": must be base64 or hex", .{codec_name});
    }
}

fn codecDecode(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const codec_name = try args[0].current().getString();
    const opt_args = args[1 .. args.len - 1];
    const data_arg = &args[args.len - 1];

    if (mem.eql(u8, codec_name, "base64")) {
        return codecDecodeBase64(interp, opt_args, data_arg);
    } else if (mem.eql(u8, codec_name, "hex")) {
        return codecDecodeHex(interp, opt_args, data_arg);
    } else {
        return interp.setErrorFormatted("unknown codec \"{s}\": must be base64 or hex", .{codec_name});
    }
}

pub fn codecCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const Subcommands = enum {
        encode,
        decode,
        names,
    };
    const Parser = objects.SubcommandParser(Subcommands, &.{
        .{ .variant = .encode, .usage = "codecName ?options? data", .min_args = 2 },
        .{ .variant = .decode, .usage = "codecName ?options? data", .min_args = 2 },
        .{ .variant = .names, .usage = "", .min_args = 0, .max_args = 0 },
    });

    var det: ErrorDetails = undefined;
    const subcommand: Subcommands = try interp.wrapError(&det, Parser.parse(&det, args));

    switch (subcommand) {
        .names => {
            const b64 = try objects.String.newValue("base64");
            errdefer b64.dropReference();
            const hex = try objects.String.newValue("hex");
            errdefer hex.dropReference();
            const list = try objects.List.new(&.{ b64, hex });
            b64.dropReference();
            hex.dropReference();
            interp.setResultOwning(list.asHead().asValue());
        },
        .encode => try codecEncode(interp, args[2..]),
        .decode => try codecDecode(interp, args[2..]),
    }
}

pub fn registerCommands(interp: *Interp) !void {
    try registerCommand(interp, "codec", codecCmd, "subcommand ?arg ...?", 1, null);
}

fn testCodecBase64(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("aGVsbG8=", "codec encode base64 \"hello\"");
    try interp.testExpectScriptResult("hello", "codec decode base64 \"aGVsbG8=\"");
    try interp.testExpectScriptResult("hello", "codec decode base64 \"  aGVsbG8=  \\n\"");
    try interp.testExpectScriptResult("aGVs\nbG8=\n", "codec encode base64 -maxlen 4 \"hello\"");
    try interp.testExpectScriptResult("hello", "codec decode base64 -strict \"aGVsbG8=\"");
    try interp.testExpectScriptError(error.EvalError, "invalid base64 encoding", "codec decode base64 -strict \"  aGVsbG8=\"");
}

test "codec base64" {
    try memutil.checkAllocationFailures(.exhaustive, testCodecBase64, .{});
}

fn testCodecHex(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("68656c6c6f", "codec encode hex \"hello\"");
    try interp.testExpectScriptResult("hello", "codec decode hex \"68656c6c6f\"");
    try interp.testExpectScriptError(error.EvalError, "hex string must have an even number of digits", "codec decode hex \"abc\"");
}

test "codec hex" {
    try memutil.checkAllocationFailures(.exhaustive, testCodecHex, .{});
}

fn testCodecNames(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    try interp.testExpectScriptResult("base64 hex", "codec names");
}

test "codec names" {
    try memutil.checkAllocationFailures(.exhaustive, testCodecNames, .{});
}

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
        hash,
    };
    const Parser = objects.SubcommandParser(Subcommands, &.{
        .{ .variant = .encode, .usage = "format data", .min_args = 2, .max_args = 2 },
        .{ .variant = .decode, .usage = "format data", .min_args = 2, .max_args = 2 },
        .{ .variant = .hash, .usage = "algorithm data", .min_args = 2, .max_args = 2 },
    });

    var det: ErrorDetails = undefined;
    const subcommand: Subcommands = try interp.wrapError(&det, Parser.parse(&det, args));

    const data = try args[3].current().getString();

    switch (subcommand) {
        .encode => {
            if (try args[2].equalsString("base64")) {
                const encoder = std.base64.standard.Encoder;
                const out_len = encoder.calcSize(data.len);
                const out_buf = try heap.global_gpa.alloc(u8, out_len);
                defer heap.global_gpa.free(out_buf);
                _ = encoder.encode(out_buf, data);
                return interp.setResultString(out_buf);
            } else if (try args[2].equalsString("hex")) {
                const out_len = data.len * 2;
                const out_buf = try heap.global_gpa.alloc(u8, out_len);
                defer heap.global_gpa.free(out_buf);
                const hex_chars = "0123456789abcdef";
                for (data, 0..) |b, i| {
                    out_buf[i * 2] = hex_chars[b >> 4];
                    out_buf[i * 2 + 1] = hex_chars[b & 0x0f];
                }
                return interp.setResultString(out_buf);
            } else {
                return interp.setErrorFormatted("bad format \"{s}\": must be base64 or hex", .{try args[2].getString()});
            }
        },
        .decode => {
            if (try args[2].equalsString("base64")) {
                const decoder = comptime std.base64.standard.decoderWithIgnore(" \r\n\t");
                const upper = decoder.calcSizeUpperBound(data.len);
                const out_buf = try heap.global_gpa.alloc(u8, upper);
                defer heap.global_gpa.free(out_buf);
                const written = decoder.decode(out_buf, data) catch {
                    return interp.setErrorString("invalid base64 data");
                };
                return interp.setResultString(out_buf[0..written]);
            } else if (try args[2].equalsString("hex")) {
                if (data.len % 2 != 0) {
                    return interp.setErrorString("hex string has odd length");
                }
                const out_len = data.len / 2;
                const out_buf = try heap.global_gpa.alloc(u8, out_len);
                defer heap.global_gpa.free(out_buf);
                _ = std.fmt.hexToBytes(out_buf, data) catch {
                    return interp.setErrorString("invalid hex string");
                };
                return interp.setResultString(out_buf);
            } else {
                return interp.setErrorFormatted("bad format \"{s}\": must be base64 or hex", .{try args[2].getString()});
            }
        },
        .hash => {
            if (try args[2].equalsString("sha-1")) {
                var out: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
                std.crypto.hash.Sha1.hash(data, &out, .{});
                return interp.setResultString(&out);
            } else if (try args[2].equalsString("sha-256")) {
                var out: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(data, &out, .{});
                return interp.setResultString(&out);
            } else if (try args[2].equalsString("blake3")) {
                var out: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
                std.crypto.hash.Blake3.hash(data, &out, .{});
                return interp.setResultString(&out);
            } else {
                return interp.setErrorFormatted("bad algorithm \"{s}\": must be sha-1, sha-256, or blake3", .{try args[2].getString()});
            }
        },
    }
}

pub fn registerCommands(interp: *Interp) !void {
    try registerCommand(interp, "codec", codecCmd, "subcommand format/algorithm data", 3, 3);
}

test "codec base64 encode and decode" {
    const test_str = "hello world";
    const enc = std.base64.standard.Encoder;
    var out_buf: [32]u8 = undefined;
    const encoded = enc.encode(&out_buf, test_str);
    try testing.expectEqualStrings("aGVsbG8gd29ybGQ=", encoded);

    const decoder = std.base64.standard.decoderWithIgnore(" \r\n\t");
    var dec_buf: [32]u8 = undefined;
    const written = try decoder.decode(&dec_buf, encoded);
    try testing.expectEqualStrings(test_str, dec_buf[0..written]);
}

test "codec hashing" {
    // sha-1 of "hello": aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d
    var sha1_out: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash("hello", &sha1_out, .{});
    const expected_sha1 = "\xaa\xf4\xc6\x1d\xdc\xc5\xe8\xa2\xda\xbe\xde\x0f\x3b\x48\x2c\xd9\xae\xa9\x43\x4d";
    try testing.expectEqualStrings(expected_sha1, &sha1_out);

    // sha-256 of "hello": 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
    var sha256_out: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("hello", &sha256_out, .{});
    const expected_sha256 = "\x2c\xf2\x4d\xba\x5f\xb0\xa3\x0e\x26\xe8\x3b\x2a\xc5\xb9\xe2\x9e\x1b\x16\x1e\x5c\x1f\xa7\x42\x5e\x73\x04\x33\x62\x93\x8b\x98\x24";
    try testing.expectEqualStrings(expected_sha256, &sha256_out);

    // blake3 of "hello": ea8f163db38682925e4491c5e58d4bb3506ef8c14eb78a86e908c5624a67200f
    var blake3_out: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
    std.crypto.hash.Blake3.hash("hello", &blake3_out, .{});
    const expected_blake3 = "\xea\x8f\x16\x3d\xb3\x86\x82\x92\x5e\x44\x91\xc5\xe5\x8d\x4b\xb3\x50\x6e\xf8\xc1\x4e\xb7\x8a\x86\xe9\x08\xc5\x62\x4a\x67\x20\x0f";
    try testing.expectEqualStrings(expected_blake3, &blake3_out);
}

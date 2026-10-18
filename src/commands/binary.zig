const std = @import("std");
const math = std.math;
const mem = std.mem;
const assert = std.debug.assert;
const testing = std.testing;

const common = @import("common.zig");
const heap = common.heap;
const Value = common.Value;
const OptionalValue = heap.OptionalValue;
const Object = heap.Object;
const SpecialString = heap.SpecialString;
const objects = common.objects;
const String = objects.String;
const List = objects.List;
const Dictionary = objects.Dictionary;
const ErrorDetails = common.ErrorDetails;
const Shimmerable = common.Shimmerable;
const Interp = common.Interp;
const registerCommand = common.registerCommand;
const memutil = common.memutil;

const interned_cursor = heap.InternedString.newValue("cursor");
const interned_encode = heap.InternedString.newValue("encode");
const interned_decode = heap.InternedString.newValue("decode");
const interned_underscore = heap.InternedString.newValue("_");
const interned_underscore_buf = heap.InternedString.newValue("_buf");
const interned_underscore_cursor = heap.InternedString.newValue("_cursor");

pub const BitReader = struct {
    source: []const u8,
    bit_pos: usize = 0,
    last_bit_endian: ?std.builtin.Endian = null,

    pub fn checkBitBounds(self: *const BitReader, bit_count: usize) !void {
        const total_source_bits = math.mul(usize, self.source.len, 8) catch return error.EndOfStream;
        const end_bit = math.add(usize, self.bit_pos, bit_count) catch return error.EndOfStream;
        if (end_bit > total_source_bits) return error.EndOfStream;
    }

    pub fn checkEndianTransition(self: *BitReader, endian: std.builtin.Endian) !void {
        if (self.bit_pos % 8 == 0) {
            self.last_bit_endian = endian;
        } else if (self.last_bit_endian) |prev| {
            if (prev != endian) return error.MidByteEndianSwitch;
        } else {
            self.last_bit_endian = endian;
        }
    }

    pub fn skipBits(self: *BitReader, bit_count: usize) !void {
        try self.checkBitBounds(bit_count);
        self.bit_pos += bit_count;
        if (self.bit_pos % 8 == 0) {
            self.last_bit_endian = null;
        }
    }

    pub fn alignTo(self: *BitReader, align_bits: usize) !void {
        if (align_bits <= 1) return;
        const rem = self.bit_pos % align_bits;
        if (rem != 0) {
            const pad = align_bits - rem;
            try self.skipBits(pad);
        }
    }

    /// Reads `buffer.len` whole bytes (`buffer.len * 8` bits).
    /// - Aligned (`bit_pos % 8 == 0`): returns zero-copy slice into `source`.
    /// - Unaligned (`bit_pos % 8 != 0`): stitches bits into `buffer` using active bit endianness.
    pub fn readBytes(self: *BitReader, buffer: []u8) ![]const u8 {
        const total_bits = math.mul(usize, buffer.len, 8) catch return error.EndOfStream;
        try self.checkBitBounds(total_bits);

        const bit_rem: u3 = @intCast(self.bit_pos % 8);
        const byte_idx = self.bit_pos / 8;

        if (bit_rem == 0) {
            self.bit_pos += total_bits;
            self.last_bit_endian = null;
            return self.source[byte_idx .. byte_idx + buffer.len];
        }

        const endian = self.last_bit_endian orelse .big;
        for (buffer) |*out_byte| {
            out_byte.* = @intCast(try self.readBits(8, endian));
        }
        return buffer;
    }

    pub fn readBits(self: *BitReader, bit_count: u7, endian: std.builtin.Endian) !u64 {
        if (bit_count == 0) return 0;
        if (bit_count > 64) return error.InvalidBitWidth;
        try self.checkBitBounds(bit_count);
        try self.checkEndianTransition(endian);

        if (self.bit_pos % 8 == 0 and bit_count % 8 == 0) {
            const byte_idx = self.bit_pos / 8;
            const byte_len = bit_count / 8;
            self.bit_pos += bit_count;
            self.last_bit_endian = null;
            return mem.readVarInt(u64, self.source[byte_idx .. byte_idx + byte_len], endian);
        }

        var acc: u64 = 0;
        var bits_read: u7 = 0;
        var remaining: u7 = bit_count;

        while (remaining > 0) {
            const byte_idx = self.bit_pos / 8;
            const bit_rem: u3 = @intCast(self.bit_pos % 8);
            const avail: u4 = @as(u4, 8) - bit_rem;
            const take: u4 = @min(remaining, avail);

            var mask: u8 = 0xFF;
            if (take < 8) {
                mask = (@as(u8, 1) << @intCast(take)) - 1;
            }
            const byte = self.source[byte_idx];

            switch (endian) {
                .big => {
                    const shift: u3 = @intCast(avail - take);
                    const bits: u64 = (byte >> shift) & mask;
                    acc = (acc << @intCast(take)) | bits;
                },
                .little => {
                    const bits: u64 = (byte >> bit_rem) & mask;
                    acc |= bits << @intCast(bits_read);
                },
            }

            self.bit_pos += take;
            bits_read += take;
            remaining -= take;
        }

        if (self.bit_pos % 8 == 0) {
            self.last_bit_endian = null;
        }
        return acc;
    }
};

fn checkSliceEndianTransition(
    bit_pos: usize,
    last_bit_endian: *?std.builtin.Endian,
    endian: std.builtin.Endian,
) !void {
    if (bit_pos % 8 == 0) {
        last_bit_endian.* = endian;
    } else if (last_bit_endian.*) |prev| {
        if (prev != endian) return error.MidByteEndianSwitch;
    } else {
        last_bit_endian.* = endian;
    }
}

fn writeBitsIntoSlice(
    dest: []u8,
    bit_pos: *usize,
    last_bit_endian: *?std.builtin.Endian,
    value: u64,
    bit_count: u7,
    endian: std.builtin.Endian,
) !void {
    if (bit_count == 0) return;
    if (bit_count > 64) return error.InvalidBitWidth;
    try checkSliceEndianTransition(bit_pos.*, last_bit_endian, endian);

    if (bit_pos.* % 8 == 0 and bit_count % 8 == 0) {
        const byte_idx = bit_pos.* / 8;
        const byte_len = bit_count / 8;
        switch (endian) {
            .big => {
                var i: usize = 0;
                while (i < byte_len) : (i += 1) {
                    const shift: u6 = @intCast((byte_len - 1 - i) * 8);
                    dest[byte_idx + i] = @truncate(value >> shift);
                }
            },
            .little => {
                var i: usize = 0;
                while (i < byte_len) : (i += 1) {
                    const shift: u6 = @intCast(i * 8);
                    dest[byte_idx + i] = @truncate(value >> shift);
                }
            },
        }
        bit_pos.* += bit_count;
        last_bit_endian.* = null;
        return;
    }

    var bits_written: u7 = 0;
    var remaining: u7 = bit_count;

    while (remaining > 0) {
        const byte_idx = bit_pos.* / 8;
        const bit_rem: u3 = @intCast(bit_pos.* % 8);
        const avail: u4 = @as(u4, 8) - bit_rem;
        const take: u4 = @min(remaining, avail);

        var mask: u8 = 0xFF;
        if (take < 8) {
            mask = (@as(u8, 1) << @intCast(take)) - 1;
        }

        switch (endian) {
            .big => {
                const src_shift: u6 = @intCast(remaining - take);
                const chunk: u8 = @as(u8, @truncate(value >> src_shift)) & mask;
                const dst_shift: u3 = @intCast(avail - take);
                dest[byte_idx] &= ~(mask << dst_shift);
                dest[byte_idx] |= chunk << dst_shift;
            },
            .little => {
                const src_shift: u6 = @intCast(bits_written);
                const chunk: u8 = @as(u8, @truncate(value >> src_shift)) & mask;
                dest[byte_idx] &= ~(mask << bit_rem);
                dest[byte_idx] |= chunk << bit_rem;
            },
        }

        bit_pos.* += take;
        bits_written += take;
        remaining -= take;
    }

    if (bit_pos.* % 8 == 0) {
        last_bit_endian.* = null;
    }
}

fn writeBitStreamIntoSlice(
    dest: []u8,
    bit_pos: *usize,
    last_bit_endian: *?std.builtin.Endian,
    src_bytes: []const u8,
    bit_count: usize,
    endian: std.builtin.Endian,
) !void {
    if (bit_count == 0) return;

    if (bit_pos.* % 8 == 0 and bit_count % 8 == 0) {
        const byte_idx = bit_pos.* / 8;
        const byte_len = bit_count / 8;
        @memcpy(dest[byte_idx .. byte_idx + byte_len], src_bytes[0..byte_len]);
        bit_pos.* += bit_count;
        last_bit_endian.* = null;
        return;
    }

    var reader: BitReader = .{
        .source = src_bytes,
        .bit_pos = 0,
        .last_bit_endian = endian,
    };
    var remaining = bit_count;
    while (remaining > 0) {
        const take: u7 = @intCast(@min(remaining, 64));
        const val = try reader.readBits(take, endian);
        try writeBitsIntoSlice(dest, bit_pos, last_bit_endian, val, take, endian);
        remaining -= take;
    }
}

pub const BitWriter = struct {
    bytes: std.ArrayList(u8) = .empty,
    bit_pos: usize = 0,
    last_bit_endian: ?std.builtin.Endian = null,

    pub fn deinit(self: *BitWriter, gpa: std.mem.Allocator) void {
        self.bytes.deinit(gpa);
    }

    pub fn ensureBitCapacity(self: *BitWriter, gpa: std.mem.Allocator, end_bit: usize) !void {
        const needed_bytes = (math.add(usize, end_bit, 7) catch return error.OutOfMemory) / 8;
        if (needed_bytes > self.bytes.items.len) {
            const old_len = self.bytes.items.len;
            try self.bytes.resize(gpa, needed_bytes);
            @memset(self.bytes.items[old_len..needed_bytes], 0);
        }
    }

    pub fn writeBits(self: *BitWriter, gpa: std.mem.Allocator, value: u64, bit_count: u7, endian: std.builtin.Endian) !void {
        if (bit_count == 0) return;
        const end_bit = math.add(usize, self.bit_pos, bit_count) catch return error.OutOfMemory;
        try self.ensureBitCapacity(gpa, end_bit);
        try writeBitsIntoSlice(self.bytes.items, &self.bit_pos, &self.last_bit_endian, value, bit_count, endian);
    }

    pub fn writeBytes(self: *BitWriter, gpa: std.mem.Allocator, data: []const u8) !void {
        if (data.len == 0) return;
        const total_bits = math.mul(usize, data.len, 8) catch return error.OutOfMemory;
        const end_bit = math.add(usize, self.bit_pos, total_bits) catch return error.OutOfMemory;
        try self.ensureBitCapacity(gpa, end_bit);

        if (self.bit_pos % 8 == 0) {
            const byte_idx = self.bit_pos / 8;
            @memcpy(self.bytes.items[byte_idx .. byte_idx + data.len], data);
            self.bit_pos += total_bits;
            self.last_bit_endian = null;
            return;
        }

        const endian = self.last_bit_endian orelse .big;
        for (data) |b| {
            try self.writeBits(gpa, b, 8, endian);
        }
    }

    pub fn writeBitStream(
        self: *BitWriter,
        gpa: std.mem.Allocator,
        src_bytes: []const u8,
        bit_count: usize,
        endian: std.builtin.Endian,
    ) !void {
        if (bit_count == 0) return;
        const end_bit = math.add(usize, self.bit_pos, bit_count) catch return error.OutOfMemory;
        try self.ensureBitCapacity(gpa, end_bit);
        try writeBitStreamIntoSlice(self.bytes.items, &self.bit_pos, &self.last_bit_endian, src_bytes, bit_count, endian);
    }

    pub fn padZeroBits(self: *BitWriter, gpa: std.mem.Allocator, bit_count: usize) !void {
        if (bit_count == 0) return;
        const end_bit = math.add(usize, self.bit_pos, bit_count) catch return error.OutOfMemory;
        try self.ensureBitCapacity(gpa, end_bit);

        const endian = self.last_bit_endian orelse .big;
        var remaining = bit_count;
        while (remaining > 0) {
            const take: u7 = @intCast(@min(remaining, 64));
            try writeBitsIntoSlice(self.bytes.items, &self.bit_pos, &self.last_bit_endian, 0, take, endian);
            remaining -= take;
        }
        if (self.bit_pos % 8 == 0) {
            self.last_bit_endian = null;
        }
    }

    pub fn alignTo(self: *BitWriter, gpa: std.mem.Allocator, align_bits: usize) !void {
        if (align_bits <= 1) return;
        const rem = self.bit_pos % align_bits;
        if (rem != 0) {
            try self.padZeroBits(gpa, align_bits - rem);
        }
    }
};

const IntSpec = struct {
    signed: bool,
    bits: u7,
    /// `null` only for bare `u1`/`i1` or `u8`/`i8`.
    endian: ?std.builtin.Endian,
};

const FloatSpec = struct {
    bits: enum { f32, f64 },
    endian: std.builtin.Endian,
};

const BaseType = union(enum) {
    int: IntSpec,
    float: FloatSpec,
    str,
    bytes,
    mark,
    @"struct",
    custom,
    directive,
};

const DirectionalValue = struct {
    both: ?Value = null,
    encode: ?Value = null,
    decode: ?Value = null,

    pub fn get(self: DirectionalValue, dir: enum { encode, decode }) ?Value {
        switch (dir) {
            .encode => {
                if (self.encode) |v| return v;
                return self.both;
            },
            .decode => {
                if (self.decode) |v| return v;
                return self.both;
            },
        }
    }

    pub fn hasAny(self: DirectionalValue) bool {
        return self.both != null or self.encode != null or self.decode != null;
    }
};

const FieldSpec = struct {
    name: ?[]const u8 = null,
    name_val: ?Value = null,
    base_type: BaseType,

    cond: DirectionalValue = .{},
    align_to: DirectionalValue = .{},
    @"align": DirectionalValue = .{},
    pad: DirectionalValue = .{},
    count: DirectionalValue = .{},
    prefix: DirectionalValue = .{},
    len: DirectionalValue = .{},
    term: DirectionalValue = .{},
    schema: DirectionalValue = .{},
    call: DirectionalValue = .{},
    @"enum": DirectionalValue = .{},
    default: DirectionalValue = .{},
    val: DirectionalValue = .{},

    /// Statically parsed alignment values when constant.
    static_align_to_bits: ?usize = null,
    static_align_bits: ?usize = null,
    static_pad_bits: ?usize = null,
    static_len_bits: ?usize = null,
    static_count: ?usize = null,
    static_prefix: ?IntSpec = null,

    pub fn requiredAlignmentBits(self: FieldSpec) ?usize {
        if (self.static_align_bits) |explicit_align| return explicit_align;
        switch (self.base_type) {
            .int => |int_spec| {
                if (int_spec.bits >= 8 and int_spec.bits % 8 == 0) return 8;
                return 1;
            },
            .float => return 8,
            .str, .bytes => return 8,
            .mark, .custom, .@"struct", .directive => return 1,
        }
    }

    pub fn bitEndian(self: FieldSpec) ?std.builtin.Endian {
        switch (self.base_type) {
            .int => |int_spec| {
                if (int_spec.bits % 8 != 0) return int_spec.endian;
                return null;
            },
            else => return null,
        }
    }

    pub fn fixedBitWidth(self: FieldSpec) ?usize {
        var mult: usize = 1;
        if (self.count.hasAny()) {
            if (self.static_count) |c| {
                mult = c;
            } else {
                return null;
            }
        }

        if (self.base_type == .directive) {
            return self.static_pad_bits orelse 0;
        }

        const elem_bits: usize = switch (self.base_type) {
            .int => |int_spec| int_spec.bits,
            .float => |float_spec| switch (float_spec.bits) {
                .f32 => 32,
                .f64 => 64,
            },
            .mark => 0,
            .str, .bytes => self.static_len_bits orelse return null,
            .@"struct", .custom => return null,
            .directive => unreachable,
        };

        const total_elem = math.mul(usize, elem_bits, mult) catch return null;
        if (self.static_pad_bits) |pad_b| {
            return math.add(usize, total_elem, pad_b) catch return null;
        }
        return total_elem;
    }

    pub fn alwaysByteMultiple(self: FieldSpec) bool {
        if (self.fixedBitWidth()) |bits| {
            return bits % 8 == 0;
        }
        if (self.static_pad_bits) |pad_b| {
            if (pad_b % 8 != 0) return false;
        }
        switch (self.base_type) {
            .int => |int_spec| return int_spec.bits % 8 == 0,
            .float => return true,
            .mark => return true,
            .str => return true,
            .bytes => {
                if (self.len.hasAny() and self.static_len_bits == null) {
                    // Could be dynamic bytes; check if any static len is non-byte.
                    return true;
                }
                return true;
            },
            .@"struct", .custom => return false,
            .directive => return true,
        }
    }
};

fn parseByteOrBitSize(raw: []const u8) ?struct { bits: usize, is_bit_suffixed: bool } {
    if (raw.len == 0) return null;
    if (raw[raw.len - 1] == 'b') {
        const num_str = raw[0 .. raw.len - 1];
        if (num_str.len == 0) return null;
        const val = std.fmt.parseInt(usize, num_str, 10) catch return null;
        return .{ .bits = val, .is_bit_suffixed = true };
    } else {
        const val = std.fmt.parseInt(usize, raw, 10) catch return null;
        const bits = math.mul(usize, val, 8) catch return null;
        return .{ .bits = bits, .is_bit_suffixed = false };
    }
}

fn parseIntTypeToken(token: []const u8) ?IntSpec {
    if (token.len < 2) return null;
    const signed = switch (token[0]) {
        'u' => false,
        'i' => true,
        else => return null,
    };

    var digits_part = token[1..];
    var endian: ?std.builtin.Endian = null;
    if (mem.endsWith(u8, digits_part, "le")) {
        endian = .little;
        digits_part = digits_part[0 .. digits_part.len - 2];
    } else if (mem.endsWith(u8, digits_part, "be")) {
        endian = .big;
        digits_part = digits_part[0 .. digits_part.len - 2];
    }

    if (digits_part.len == 0) return null;
    const bits = std.fmt.parseInt(u7, digits_part, 10) catch return null;
    if (bits == 0 or bits > 64) return null;

    if (endian == null and bits != 1 and bits != 8) {
        return null;
    }

    return .{
        .signed = signed,
        .bits = bits,
        .endian = endian,
    };
}

fn parseBaseTypeToken(token: []const u8) ?BaseType {
    if (mem.eql(u8, token, "str")) return .str;
    if (mem.eql(u8, token, "bytes")) return .bytes;
    if (mem.eql(u8, token, "mark")) return .mark;
    if (mem.eql(u8, token, "struct")) return .@"struct";
    if (mem.eql(u8, token, "custom")) return .custom;
    if (mem.eql(u8, token, "f32le")) return .{ .float = .{ .bits = .f32, .endian = .little } };
    if (mem.eql(u8, token, "f32be")) return .{ .float = .{ .bits = .f32, .endian = .big } };
    if (mem.eql(u8, token, "f64le")) return .{ .float = .{ .bits = .f64, .endian = .little } };
    if (mem.eql(u8, token, "f64be")) return .{ .float = .{ .bits = .f64, .endian = .big } };

    if (parseIntTypeToken(token)) |int_spec| {
        return .{ .int = int_spec };
    }
    return null;
}

const OptionKind = enum {
    cond,
    align_to,
    @"align",
    pad,
    count,
    prefix,
    len,
    term,
    schema,
    call,
    @"enum",
    default,
    val,
};

const ParsedOptionKey = struct {
    kind: OptionKind,
    dir: enum { both, encode, decode },
};

fn parseOptionKey(raw: []const u8) ?ParsedOptionKey {
    var base = raw;
    var dir: @FieldType(ParsedOptionKey, "dir") = .both;
    if (mem.endsWith(u8, raw, "_encode")) {
        base = raw[0 .. raw.len - "_encode".len];
        dir = .encode;
    } else if (mem.endsWith(u8, raw, "_decode")) {
        base = raw[0 .. raw.len - "_decode".len];
        dir = .decode;
    }

    var kind: OptionKind = undefined;
    if (mem.eql(u8, base, "cond")) {
        kind = .cond;
    } else if (mem.eql(u8, base, "align_to")) {
        kind = .align_to;
    } else if (mem.eql(u8, base, "align")) {
        kind = .@"align";
    } else if (mem.eql(u8, base, "pad")) {
        kind = .pad;
    } else if (mem.eql(u8, base, "count")) {
        kind = .count;
    } else if (mem.eql(u8, base, "prefix")) {
        kind = .prefix;
    } else if (mem.eql(u8, base, "len")) {
        kind = .len;
    } else if (mem.eql(u8, base, "term")) {
        kind = .term;
    } else if (mem.eql(u8, base, "schema")) {
        kind = .schema;
    } else if (mem.eql(u8, base, "call")) {
        kind = .call;
    } else if (mem.eql(u8, base, "enum")) {
        kind = .@"enum";
    } else if (mem.eql(u8, base, "default")) {
        kind = .default;
    } else if (mem.eql(u8, base, "val")) {
        kind = .val;
    } else {
        return null;
    }

    return .{ .kind = kind, .dir = dir };
}

fn setDirectionalOption(slot: *DirectionalValue, dir: @FieldType(ParsedOptionKey, "dir"), val: Value) void {
    switch (dir) {
        .both => slot.both = val,
        .encode => slot.encode = val,
        .decode => slot.decode = val,
    }
}

fn parseSchemaFields(interp: *Interp, arena: std.mem.Allocator, schema_val: Value) !struct {
    fields: []FieldSpec,
    has_named: bool,
} {
    var schema_shim: Shimmerable = .{ .original = schema_val };
    defer schema_shim.discardChanges();
    const schema_list = try interp.getList(&schema_shim);

    var fields: std.ArrayList(FieldSpec) = .empty;
    errdefer freeSchemaFields(fields.items);
    var has_named = false;

    // Support single-field shorthand: e.g. `{bytes len 4}` or `{pad 2}` passed directly as the schema
    // instead of `{{bytes len 4}}`. If the first element is a single token and the second element
    // is a recognized option key, treat `schema_list` itself as a single field definition.
    var single_field_wrapper: [1]Value = .{schema_val};
    var field_item_slice: []const Value = schema_list.items;
    if (schema_list.items.len >= 2 and schema_list.items.len % 2 != 0) {
        var first_shim: Shimmerable = .{ .original = schema_list.items[0] };
        defer first_shim.discardChanges();
        if (List.shimmerFrom(null, &first_shim)) |first_as_list| {
            if (first_as_list.items.len == 1) {
                const second_str = try schema_list.items[1].getString();
                if (parseOptionKey(second_str) != null) {
                    field_item_slice = &single_field_wrapper;
                }
            }
        } else |_| {}
    } else if (schema_list.items.len == 2) {
        const first_str = try schema_list.items[0].getString();
        if (parseOptionKey(first_str)) |opt| {
            if (opt.kind == .pad or opt.kind == .@"align" or opt.kind == .align_to) {
                field_item_slice = &single_field_wrapper;
            }
        }
    }

    for (field_item_slice) |item_val| {
        var item_shim: Shimmerable = .{ .original = item_val };
        defer item_shim.discardChanges();
        const sub_list = try interp.getList(&item_shim);
        if (sub_list.items.len == 0) {
            return interp.setErrorString("empty field definition in binary schema");
        }

        const head_str = try sub_list.items[0].getString();

        // Check if the element starts with a stream directive (`pad`, `align`, `align_to`).
        if (parseOptionKey(head_str)) |directive_opt| {
            if (directive_opt.kind == .pad or directive_opt.kind == .@"align" or directive_opt.kind == .align_to) {
                if (sub_list.items.len % 2 != 0) {
                    return interp.setErrorFormatted("directive \"{s}\" requires a value", .{head_str});
                }
                var field: FieldSpec = .{ .base_type = .directive };
                try populateFieldOptions(interp, &field, sub_list.items);
                try fields.append(arena, field);
                continue;
            }
        }

        var field_name: ?[]const u8 = null;
        var field_name_val: ?Value = null;
        var type_str: []const u8 = head_str;
        if (mem.indexOfScalar(u8, head_str, '=')) |eq_idx| {
            if (eq_idx == 0) {
                return interp.setErrorFormatted("invalid empty field name in \"{s}\"", .{head_str});
            }
            const name_slice = try arena.dupe(u8, head_str[0..eq_idx]);
            field_name = name_slice;
            field_name_val = try String.newValue(name_slice);
            type_str = head_str[eq_idx + 1 ..];
            has_named = true;
        }
        errdefer if (field_name_val) |nv| nv.dropReference();

        const base_type = parseBaseTypeToken(type_str) orelse {
            return interp.setErrorFormatted("unknown binary type \"{s}\"", .{type_str});
        };

        const opt_items = sub_list.items[1..];
        if (opt_items.len % 2 != 0) {
            return interp.setErrorFormatted("field \"{s}\" options must be key-value pairs", .{head_str});
        }

        var field: FieldSpec = .{
            .name = field_name,
            .name_val = field_name_val,
            .base_type = base_type,
        };
        try populateFieldOptions(interp, &field, opt_items);

        // Validate required options for specific base types.
        switch (field.base_type) {
            .bytes => {
                if (!field.len.hasAny() and !field.prefix.hasAny() and !field.term.hasAny()) {
                    return interp.setErrorFormatted("bytes field requires len, prefix, or term modifier", .{});
                }
            },
            .@"struct" => {
                if (!field.schema.hasAny()) {
                    return interp.setErrorFormatted("struct field requires schema modifier", .{});
                }
                if (field.schema.both) |sub_schema_val| {
                    const sub_parsed = try parseSchemaFields(interp, arena, sub_schema_val);
                    defer freeSchemaFields(sub_parsed.fields);
                }
            },
            .custom => {
                if (!field.call.hasAny()) {
                    return interp.setErrorFormatted("custom field requires call, call_encode, or call_decode modifier", .{});
                }
            },
            else => {},
        }

        try fields.append(arena, field);
    }

    try validateSchemaAlignment(interp, fields.items);

    return .{
        .fields = try fields.toOwnedSlice(arena),
        .has_named = has_named,
    };
}

fn freeSchemaFields(fields: []const FieldSpec) void {
    for (fields) |f| {
        if (f.name_val) |nv| nv.dropReference();
    }
}

fn populateFieldOptions(interp: *Interp, field: *FieldSpec, opt_items: []const Value) !void {
    var i: usize = 0;
    while (i < opt_items.len) : (i += 2) {
        const key_str = try opt_items[i].getString();
        const val = opt_items[i + 1];

        const parsed_key = parseOptionKey(key_str) orelse {
            return interp.setErrorFormatted("unknown binary field modifier \"{s}\"", .{key_str});
        };

        switch (parsed_key.kind) {
            .cond => setDirectionalOption(&field.cond, parsed_key.dir, val),
            .align_to => {
                setDirectionalOption(&field.align_to, parsed_key.dir, val);
                const val_str = try val.getString();
                const parsed_sz = parseByteOrBitSize(val_str) orelse {
                    return interp.setErrorFormatted("invalid align_to value \"{s}\"", .{val_str});
                };
                if (parsed_sz.bits == 0) {
                    return interp.setErrorString("align_to must be greater than 0");
                }
                field.static_align_to_bits = parsed_sz.bits;
            },
            .@"align" => {
                setDirectionalOption(&field.@"align", parsed_key.dir, val);
                const val_str = try val.getString();
                const parsed_sz = parseByteOrBitSize(val_str) orelse {
                    return interp.setErrorFormatted("invalid align value \"{s}\"", .{val_str});
                };
                if (parsed_sz.bits == 0) {
                    return interp.setErrorString("align must be greater than 0");
                }
                field.static_align_bits = parsed_sz.bits;
            },
            .pad => {
                setDirectionalOption(&field.pad, parsed_key.dir, val);
                const val_str = try val.getString();
                const parsed_sz = parseByteOrBitSize(val_str) orelse {
                    return interp.setErrorFormatted("invalid pad value \"{s}\"", .{val_str});
                };
                field.static_pad_bits = parsed_sz.bits;
            },
            .count => {
                setDirectionalOption(&field.count, parsed_key.dir, val);
                const val_str = try val.getString();
                if (std.fmt.parseInt(usize, val_str, 10)) |c| {
                    field.static_count = c;
                } else |_| {}
            },
            .prefix => {
                setDirectionalOption(&field.prefix, parsed_key.dir, val);
                const val_str = try val.getString();
                const int_spec = parseIntTypeToken(val_str) orelse {
                    return interp.setErrorFormatted("invalid prefix integer type \"{s}\"", .{val_str});
                };
                if (int_spec.signed) {
                    return interp.setErrorFormatted("prefix integer type \"{s}\" must be unsigned", .{val_str});
                }
                field.static_prefix = int_spec;
            },
            .len => {
                setDirectionalOption(&field.len, parsed_key.dir, val);
                const val_str = try val.getString();
                if (parseByteOrBitSize(val_str)) |sz| {
                    if (field.base_type == .str and sz.is_bit_suffixed and sz.bits % 8 != 0) {
                        return interp.setErrorString("str length must be a multiple of 8 bits");
                    }
                    field.static_len_bits = sz.bits;
                }
            },
            .term => {
                const term_str = try val.getString();
                if (term_str.len == 0) {
                    return interp.setErrorString("term delimiter cannot be empty");
                }
                setDirectionalOption(&field.term, parsed_key.dir, val);
            },
            .schema => setDirectionalOption(&field.schema, parsed_key.dir, val),
            .call => setDirectionalOption(&field.call, parsed_key.dir, val),
            .@"enum" => {
                var enum_shim: Shimmerable = .{ .original = val };
                defer enum_shim.discardChanges();
                _ = try interp.getDict(&enum_shim);
                setDirectionalOption(&field.@"enum", parsed_key.dir, val);
            },
            .default => setDirectionalOption(&field.default, parsed_key.dir, val),
            .val => setDirectionalOption(&field.val, parsed_key.dir, val),
        }
    }
}

fn validateSchemaAlignment(interp: *Interp, fields: []const FieldSpec) !void {
    var known_bit_offset: ?usize = 0;
    var known_byte_aligned: ?bool = true;
    var active_byte_endian: ?std.builtin.Endian = null;

    for (fields) |field| {
        if (field.cond.hasAny()) {
            known_bit_offset = null;
            if (!field.alwaysByteMultiple()) {
                known_byte_aligned = null;
                active_byte_endian = null;
            }
            continue;
        }

        if (field.static_align_to_bits) |align_to| {
            if (known_bit_offset) |off| {
                const rem = off % align_to;
                if (rem != 0) known_bit_offset = off + (align_to - rem);
            }
            if (align_to % 8 == 0) {
                known_byte_aligned = true;
                active_byte_endian = null;
            }
        }

        if (field.requiredAlignmentBits()) |req_align| {
            if (req_align > 1) {
                if (known_bit_offset) |off| {
                    if (off % req_align != 0) {
                        return interp.setErrorFormatted(
                            "alignment error: field requires {d}-bit alignment, but static bit offset is {d}",
                            .{ req_align, off },
                        );
                    }
                } else if (req_align == 8) {
                    if (known_byte_aligned) |aligned| {
                        if (!aligned) {
                            return interp.setErrorString(
                                "alignment error: byte-aligned field follows non-byte-aligned bit fields without align_to",
                            );
                        }
                    }
                }
            }
        }

        if (field.bitEndian()) |endian| {
            if (known_byte_aligned) |aligned| {
                if (!aligned) {
                    if (active_byte_endian) |prev| {
                        if (prev != endian) {
                            return interp.setErrorString("cannot switch bit endianness mid-byte without byte alignment");
                        }
                    }
                }
            }
            active_byte_endian = endian;
        }

        if (field.fixedBitWidth()) |bits| {
            if (known_bit_offset) |off| {
                known_bit_offset = off + bits;
                known_byte_aligned = (known_bit_offset.? % 8 == 0);
            } else if (bits % 8 != 0) {
                known_byte_aligned = null;
            }
            if (known_byte_aligned == true) active_byte_endian = null;
        } else if (field.alwaysByteMultiple()) {
            known_bit_offset = null;
        } else {
            known_bit_offset = null;
            known_byte_aligned = null;
            active_byte_endian = null;
        }
    }
}

const vartypes = @import("../vartypes.zig");

const EvalScope = struct {
    const SavedEntry = struct {
        key: Value,
        old_slot: ?vartypes.VariableSlot,
    };

    interp: *Interp,
    initialized: bool = false,
    saved: std.ArrayList(SavedEntry) = .empty,
    last_val: Value = heap.interned_empty_string,

    pub fn deinit(self: *EvalScope) void {
        if (self.initialized) {
            const frame = self.interp.callFrame();
            var i: usize = self.saved.items.len;
            while (i > 0) {
                i -= 1;
                const entry = self.saved.items[i];
                if (entry.old_slot) |slot| {
                    const idx = frame.variables.map.getIndex(entry.key).?;
                    const slot_ptr = frame.variables.slotAt(idx);
                    slot_ptr.dropReference();
                    slot_ptr.* = slot;
                    entry.key.dropReference();
                } else {
                    const removed = frame.variables.map.fetchOrderedRemove(entry.key).?;
                    removed.key.dropReference();
                    removed.value.dropReference();
                    entry.key.dropReference();
                }
            }
            frame.call_epoch = self.interp.nextCallEpoch();
        }
        self.saved.deinit(heap.global_gpa);
    }

    fn hasSavedKey(self: *const EvalScope, name: Value) bool {
        for (self.saved.items) |entry| {
            if (entry.key.equals(name) catch unreachable) return true;
        }
        return false;
    }

    fn putSavingOld(self: *EvalScope, name: Value, val: Value) !void {
        try heap.hashutil.cacheQuickHash(name);
        try self.saved.ensureUnusedCapacity(heap.global_gpa, 1);

        const frame = self.interp.callFrame();
        if (!self.hasSavedKey(name)) {
            var old_slot: ?vartypes.VariableSlot = null;
            if (frame.variables.map.getIndex(name)) |idx| {
                old_slot = frame.variables.slotAt(idx).takeReference();
            }
            errdefer if (old_slot) |s| s.dropReference();

            _ = try frame.variables.put(name, .{ .normal = val });
            self.saved.appendAssumeCapacity(.{
                .key = name.takeReference(),
                .old_slot = old_slot,
            });
        } else {
            _ = try frame.variables.put(name, .{ .normal = val });
        }
    }

    pub fn ensureInitialized(self: *EvalScope, initial_dict: ?*Dictionary) !void {
        if (self.initialized) return;
        self.initialized = true;

        if (initial_dict) |dict| {
            var i: usize = 0;
            while (i < dict.items.len) : (i += 2) {
                const k = dict.items[i];
                const v = dict.items[i + 1];
                try self.putSavingOld(k, v);
            }
            self.interp.callFrame().call_epoch = self.interp.nextCallEpoch();
        }
    }

    pub fn bindField(self: *EvalScope, maybe_name_val: ?Value, val: Value) !void {
        self.last_val = val;
        if (self.initialized) {
            if (maybe_name_val) |name_val| {
                try self.putSavingOld(name_val, val);
            }
            try self.putSavingOld(interned_underscore, val);
            self.interp.callFrame().call_epoch = self.interp.nextCallEpoch();
        }
    }

    pub fn evalExpr(
        self: *EvalScope,
        expr_val: Value,
        initial_dict: ?*Dictionary,
        current_bit_pos: usize,
        buf_bytes: []const u8,
    ) !Value {
        try self.ensureInitialized(initial_dict);

        try self.putSavingOld(interned_underscore, self.last_val);
        const cursor_val = Value.newInt(math.cast(i64, current_bit_pos) orelse return self.interp.integerOverflowError(usize, current_bit_pos));
        try self.putSavingOld(interned_underscore_cursor, cursor_val);

        const expr_str = try expr_val.getString();
        if (mem.indexOf(u8, expr_str, "_buf") != null) {
            const buf_val = try String.newValue(buf_bytes);
            defer buf_val.dropReference();
            try self.putSavingOld(interned_underscore_buf, buf_val);
        }
        self.interp.callFrame().call_epoch = self.interp.nextCallEpoch();

        return try self.interp.evalExpression(expr_val);
    }
};

fn evalBoolModifier(
    scope: *EvalScope,
    expr_val: Value,
    initial_dict: ?*Dictionary,
    bit_pos: usize,
    buf_bytes: []const u8,
) !bool {
    var res = try scope.evalExpr(expr_val, initial_dict, bit_pos, buf_bytes);
    defer res.dropReference();
    var det: ErrorDetails = undefined;
    return try scope.interp.wrapError(&det, objects.Boolean.getFromValue(&det, res));
}

fn evalNonNegativeLengthBits(
    scope: *EvalScope,
    len_val: Value,
    is_str: bool,
    initial_dict: ?*Dictionary,
    bit_pos: usize,
    buf_bytes: []const u8,
) !usize {
    const raw_str = try len_val.getString();
    if (parseByteOrBitSize(raw_str)) |sz| {
        if (is_str and sz.is_bit_suffixed and sz.bits % 8 != 0) {
            return scope.interp.setErrorString("str length must be a multiple of 8 bits");
        }
        return sz.bits;
    }

    var is_bits = false;
    var eval_target = len_val;
    var stripped_temp: OptionalValue = .none;
    defer stripped_temp.dropReference();

    if (raw_str.len > 1 and raw_str[raw_str.len - 1] == 'b') {
        is_bits = true;
        const stripped = try String.newValue(raw_str[0 .. raw_str.len - 1]);
        stripped_temp = stripped.asOptional();
        eval_target = stripped;
    }

    var res = try scope.evalExpr(eval_target, initial_dict, bit_pos, buf_bytes);
    defer res.dropReference();

    const res_str = try res.getString();
    if (parseByteOrBitSize(res_str)) |sz| {
        if (is_bits) {
            const raw_num = std.fmt.parseInt(usize, res_str, 10) catch {
                return scope.interp.setErrorFormatted("invalid bit length \"{s}\"", .{res_str});
            };
            return raw_num;
        }
        if (is_str and sz.is_bit_suffixed and sz.bits % 8 != 0) {
            return scope.interp.setErrorString("str length must be a multiple of 8 bits");
        }
        return sz.bits;
    }

    var res_shim: Shimmerable = .{ .original = res };
    defer res_shim.discardChanges();
    const int_val = try scope.interp.getInteger(&res_shim);
    if (int_val < 0) {
        return scope.interp.setErrorFormatted("negative length {d} in binary schema", .{int_val});
    }
    const u_val: usize = math.cast(usize, int_val) orelse return scope.interp.integerOverflowError(i64, int_val);
    if (is_bits) return u_val;
    return math.mul(usize, u_val, 8) catch return error.OutOfMemory;
}

fn evalValueOrLiteral(
    scope: *EvalScope,
    val_opt: Value,
    initial_dict: ?*Dictionary,
    bit_pos: usize,
    buf_bytes: []const u8,
) !Value {
    const raw = try val_opt.getString();
    var looks_like_expr = false;
    for (raw) |c| {
        if (c == '$' or c == '[' or c == '+' or c == '*' or c == '/' or c == '(' or c == ')') {
            looks_like_expr = true;
            break;
        }
    }
    if (!looks_like_expr) {
        return val_opt.takeReference();
    }
    return scope.evalExpr(val_opt, initial_dict, bit_pos, buf_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return val_opt.takeReference(),
    };
}

fn readStateCursor(interp: *Interp, state_dict: *Dictionary) !usize {
    if (try interp.getDictValue(state_dict, interned_cursor)) |cursor_val| {
        var shim: Shimmerable = .{ .original = cursor_val };
        defer shim.discardChanges();
        const int_val = try interp.getInteger(&shim);
        if (int_val < 0) {
            return interp.setErrorFormatted("negative cursor bit offset {d}", .{int_val});
        }
        return math.cast(usize, int_val) orelse return interp.integerOverflowError(i64, int_val);
    }
    return 0;
}

fn writeStateCursor(interp: *Interp, state_dict: *Dictionary, bit_pos: usize) !void {
    const pos_i64 = math.cast(i64, bit_pos) orelse return interp.integerOverflowError(usize, bit_pos);
    try state_dict.put(interned_cursor, Value.newInt(pos_i64));
}

fn invokeCustomCodec(
    interp: *Interp,
    call_val: Value,
    dir: enum { encode, decode },
    state_dict: **Dictionary,
    arg1: Value,
    arg2: Value,
) !Value {
    var cmd_val: Value = call_val;
    var cmd_owned = false;

    // Check if `call_val` is a dictionary containing `encode`/`decode` methods, or a direct closure.
    var call_shim: Shimmerable = .{ .original = call_val };
    defer call_shim.discardChanges();
    if (Dictionary.shimmerFrom(null, &call_shim)) |_| {
        const key = if (dir == .encode) interned_encode else interned_decode;
        var det: ErrorDetails = undefined;
        if (try interp.wrapError(&det, Dictionary.shimGetFollowingLinks(&det, &call_shim, key))) |method_val| {
            cmd_val = method_val.takeReference();
            cmd_owned = true;
        }
    } else |_| {}
    defer if (cmd_owned) cmd_val.dropReference();

    var cmd_shim: Shimmerable = .{ .original = cmd_val };
    defer cmd_shim.discardChanges();

    var command = interp.getCommandFromValue(&cmd_shim, true) catch |err| switch (err) {
        error.CommandNotFound => return error.EvalError,
        else => return Interp.narrowError(err),
    };
    defer command.deinit();

    const is_method = switch (command) {
        .closure => |closure| closure.closure.content.is_method,
        .letrec => |letrec| letrec.closure.closure.content.is_method,
        .command => false,
    };

    var invoke_args: [4]Shimmerable = .{
        .{ .original = cmd_val },
        .{ .original = state_dict.*.asHead().asValue() },
        .{ .original = arg1 },
        .{ .original = arg2 },
    };
    defer invoke_args[1].discardChanges();

    try interp.invokeCommand(&command, &invoke_args);
    const result_val = interp.result.takeReference();
    errdefer result_val.dropReference();

    if (is_method) {
        if (invoke_args[1].shimmered.asValue()) |updated_self| {
            var self_shim: Shimmerable = .{ .original = updated_self };
            defer self_shim.discardChanges();
            var det: ErrorDetails = undefined;
            const new_dict = try interp.wrapError(&det, self_shim.getMutable(Dictionary, &det));
            state_dict.*.asHead().dropReference();
            state_dict.* = new_dict;
        }
    }

    return result_val;
}

fn translateEnumDecode(
    scope: *EvalScope,
    field: FieldSpec,
    raw_val: Value,
    initial_dict: ?*Dictionary,
    bit_pos: usize,
    buf_bytes: []const u8,
) !Value {
    const enum_val = field.@"enum".get(.decode) orelse return raw_val.takeReference();
    var enum_shim: Shimmerable = .{ .original = enum_val };
    defer enum_shim.discardChanges();
    const enum_dict = try scope.interp.getDict(&enum_shim);

    var raw_shim: Shimmerable = .{ .original = raw_val };
    defer raw_shim.discardChanges();
    const raw_int = try scope.interp.getInteger(&raw_shim);

    var i: usize = 0;
    var matched: ?Value = null;
    while (i < enum_dict.items.len) : (i += 2) {
        var key_shim: Shimmerable = .{ .original = enum_dict.items[i] };
        defer key_shim.discardChanges();
        const key_int = try scope.interp.getInteger(&key_shim);
        if (key_int == raw_int) {
            matched = enum_dict.items[i + 1];
        }
    }

    if (matched) |sym| {
        return sym.takeReference();
    }

    if (field.default.get(.decode)) |def_val| {
        return try evalValueOrLiteral(scope, def_val, initial_dict, bit_pos, buf_bytes);
    }

    return scope.interp.setErrorFormatted("unmapped enum wire value {d}", .{raw_int});
}

fn translateEnumEncode(
    scope: *EvalScope,
    field: FieldSpec,
    input_val: Value,
    initial_dict: ?*Dictionary,
    bit_pos: usize,
    buf_bytes: []const u8,
) !Value {
    const enum_val = field.@"enum".get(.encode) orelse return input_val.takeReference();
    var enum_shim: Shimmerable = .{ .original = enum_val };
    defer enum_shim.discardChanges();
    const enum_dict = try scope.interp.getDict(&enum_shim);

    var match_key: ?Value = null;
    var match_count: usize = 0;
    var i: usize = 0;
    while (i < enum_dict.items.len) : (i += 2) {
        const k = enum_dict.items[i];
        const sym = enum_dict.items[i + 1];
        if (try sym.equals(input_val)) {
            if (match_key) |prev_k| {
                if (!(try prev_k.equals(k))) {
                    match_count += 1;
                }
            } else {
                match_key = k;
                match_count = 1;
            }
        }
    }

    if (match_count > 1) {
        return scope.interp.setErrorFormatted(
            "ambiguous enum symbol \"{s}\" maps to multiple wire values",
            .{try input_val.getString()},
        );
    }
    if (match_key) |k| {
        return k.takeReference();
    }

    if (field.default.get(.encode)) |def_val| {
        return try evalValueOrLiteral(scope, def_val, initial_dict, bit_pos, buf_bytes);
    }

    return scope.interp.setErrorFormatted("unknown enum symbol \"{s}\"", .{try input_val.getString()});
}

fn decodeSingleInt(interp: *Interp, reader: *BitReader, int_spec: IntSpec) !Value {
    const endian = int_spec.endian orelse (reader.last_bit_endian orelse .big);
    const raw = reader.readBits(int_spec.bits, endian) catch |err| switch (err) {
        error.EndOfStream => return interp.setErrorString("unexpected end of stream while decoding integer"),
        error.MidByteEndianSwitch => return interp.setErrorString("cannot switch bit endianness mid-byte"),
        error.InvalidBitWidth => return interp.setErrorString("invalid integer bit width"),
    };

    if (!int_spec.signed) {
        if (raw <= @as(u64, @intCast(math.maxInt(i64)))) {
            return Value.newInt(@intCast(raw));
        }
        return (try String.newFormatted("{d}", .{raw})).asHead().asValue();
    } else {
        if (int_spec.bits == 64) {
            return Value.newInt(@bitCast(raw));
        }
        const sign_bit = @as(u64, 1) << @intCast(int_spec.bits - 1);
        const mask = (@as(u64, 1) << @intCast(int_spec.bits)) - 1;
        const raw_masked = raw & mask;
        var signed_val: i64 = 0;
        if ((raw_masked & sign_bit) != 0) {
            signed_val = @bitCast(raw_masked | ~mask);
        } else {
            signed_val = @intCast(raw_masked);
        }
        return Value.newInt(signed_val);
    }
}

fn parseEncodeIntBits(interp: *Interp, val: Value, int_spec: IntSpec) !u64 {
    if (!int_spec.signed) {
        if (int_spec.bits == 64) {
            if (val.asInlineInt()) |inline_i| {
                if (inline_i < 0) {
                    return interp.setErrorFormatted("value {d} out of range for u64", .{inline_i});
                }
                return @intCast(inline_i);
            }
            const str = mem.trim(u8, try val.getString(), " \t\r\n");
            if (str.len > 0 and str[0] == '-') {
                return interp.setErrorFormatted("value \"{s}\" out of range for u64", .{str});
            }
            if (std.fmt.parseInt(u64, str, 0)) |u_val| {
                return u_val;
            } else |_| {}
        }

        var shim: Shimmerable = .{ .original = val };
        defer shim.discardChanges();
        const i_val = try interp.getInteger(&shim);
        if (i_val < 0) {
            return interp.setErrorFormatted("value {d} out of range for u{d}", .{ i_val, int_spec.bits });
        }
        const u_val: u64 = @intCast(i_val);
        if (int_spec.bits < 64) {
            const max_u = (@as(u64, 1) << @intCast(int_spec.bits)) - 1;
            if (u_val > max_u) {
                return interp.setErrorFormatted("value {d} out of range for u{d}", .{ i_val, int_spec.bits });
            }
        }
        return u_val;
    } else {
        var shim: Shimmerable = .{ .original = val };
        defer shim.discardChanges();
        const i_val = try interp.getInteger(&shim);
        if (int_spec.bits < 64) {
            const min_i = -(@as(i64, 1) << @intCast(int_spec.bits - 1));
            const max_i = (@as(i64, 1) << @intCast(int_spec.bits - 1)) - 1;
            if (i_val < min_i or i_val > max_i) {
                return interp.setErrorFormatted("value {d} out of range for i{d}", .{ i_val, int_spec.bits });
            }
            const mask = (@as(u64, 1) << @intCast(int_spec.bits)) - 1;
            return @as(u64, @bitCast(i_val)) & mask;
        }
        return @bitCast(i_val);
    }
}

fn encodeSingleInt(interp: *Interp, writer: *BitWriter, gpa: std.mem.Allocator, val: Value, int_spec: IntSpec) !void {
    const raw_bits = try parseEncodeIntBits(interp, val, int_spec);
    const endian = int_spec.endian orelse (writer.last_bit_endian orelse .big);
    writer.writeBits(gpa, raw_bits, int_spec.bits, endian) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MidByteEndianSwitch => return interp.setErrorString("cannot switch bit endianness mid-byte"),
        error.InvalidBitWidth => return interp.setErrorString("invalid integer bit width"),
    };
}

fn decodeElement(
    interp: *Interp,
    arena: std.mem.Allocator,
    reader: *BitReader,
    field: FieldSpec,
    scope: *EvalScope,
    state_dict: **Dictionary,
    decoded_dict: *Dictionary,
    decoded_list: *List,
    is_named_mode: bool,
) Interp.Error!Value {
    var prefix_byte_len: ?usize = null;
    if (field.prefix.get(.decode)) |prefix_val| {
        const prefix_str = try prefix_val.getString();
        const prefix_spec = parseIntTypeToken(prefix_str).?;
        const len_val = try decodeSingleInt(interp, reader, prefix_spec);
        defer len_val.dropReference();
        var len_shim: Shimmerable = .{ .original = len_val };
        defer len_shim.discardChanges();
        const len_i64 = try interp.getInteger(&len_shim);
        prefix_byte_len = math.cast(usize, len_i64) orelse return interp.integerOverflowError(i64, len_i64);
    }

    switch (field.base_type) {
        .int => |int_spec| {
            return try decodeSingleInt(interp, reader, int_spec);
        },
        .float => |float_spec| {
            switch (float_spec.bits) {
                .f32 => {
                    const bits = reader.readBits(32, float_spec.endian) catch |err| switch (err) {
                        error.EndOfStream => return interp.setErrorString("unexpected end of stream while decoding float"),
                        error.MidByteEndianSwitch => return interp.setErrorString("cannot switch bit endianness mid-byte"),
                        error.InvalidBitWidth => unreachable,
                    };
                    const u32_bits: u32 = @truncate(bits);
                    const f32_val: f32 = @bitCast(u32_bits);
                    return Value.newFloat(@floatCast(f32_val));
                },
                .f64 => {
                    const bits = reader.readBits(64, float_spec.endian) catch |err| switch (err) {
                        error.EndOfStream => return interp.setErrorString("unexpected end of stream while decoding float"),
                        error.MidByteEndianSwitch => return interp.setErrorString("cannot switch bit endianness mid-byte"),
                        error.InvalidBitWidth => unreachable,
                    };
                    const f64_val: f64 = @bitCast(bits);
                    return Value.newFloat(f64_val);
                },
            }
        },
        .str => {
            var delim: []const u8 = "\x00";
            if (field.term.get(.decode)) |term_val| {
                delim = try term_val.getString();
            }

            if (prefix_byte_len) |byte_len| {
                const scratch = try arena.alloc(u8, byte_len);
                const slice = reader.readBytes(scratch) catch {
                    return interp.setErrorString("unexpected end of stream while decoding str");
                };
                if (mem.indexOfScalar(u8, slice, 0) != null) {
                    return interp.setErrorString("interior null byte in str field");
                }
                return try String.newValue(slice);
            }

            if (field.len.get(.decode)) |len_val| {
                const bit_len = try evalNonNegativeLengthBits(scope, len_val, true, decoded_dict, reader.bit_pos, reader.source);
                const byte_len = bit_len / 8;
                const scratch = try arena.alloc(u8, byte_len);
                const slice = reader.readBytes(scratch) catch {
                    return interp.setErrorString("unexpected end of stream while decoding str");
                };

                var content_end = slice.len;
                if (delim.len == 1 and delim[0] == 0) {
                    while (content_end > 0 and slice[content_end - 1] == 0) {
                        content_end -= 1;
                    }
                    if (mem.indexOfScalar(u8, slice[0..content_end], 0) != null) {
                        return interp.setErrorString("interior null byte in fixed-length str");
                    }
                } else {
                    if (mem.indexOf(u8, slice, delim)) |pos| {
                        content_end = pos;
                    }
                    if (mem.indexOfScalar(u8, slice[0..content_end], 0) != null) {
                        return interp.setErrorString("interior null byte in str field");
                    }
                }
                return try String.newValue(slice[0..content_end]);
            }

            // Delimiter-terminated str (default "\x00").
            if (reader.bit_pos % 8 == 0) {
                const start_byte = reader.bit_pos / 8;
                const rest = reader.source[start_byte..];
                const match_off = mem.indexOf(u8, rest, delim) orelse {
                    return interp.setErrorString("unexpected end of stream: missing str terminator");
                };
                const content = rest[0..match_off];
                if (mem.indexOfScalar(u8, content, 0) != null) {
                    return interp.setErrorString("interior null byte in str field");
                }
                reader.bit_pos += (match_off + delim.len) * 8;
                return try String.newValue(content);
            } else {
                var accum: std.ArrayList(u8) = .empty;
                const endian = reader.last_bit_endian orelse .big;
                while (true) {
                    const b: u8 = @intCast(reader.readBits(8, endian) catch {
                        return interp.setErrorString("unexpected end of stream: missing str terminator");
                    });
                    try accum.append(arena, b);
                    if (accum.items.len >= delim.len and mem.eql(u8, accum.items[accum.items.len - delim.len ..], delim)) {
                        const content = accum.items[0 .. accum.items.len - delim.len];
                        if (mem.indexOfScalar(u8, content, 0) != null) {
                            return interp.setErrorString("interior null byte in str field");
                        }
                        return try String.newValue(content);
                    }
                }
            }
        },
        .bytes => {
            if (prefix_byte_len) |byte_len| {
                const scratch = try arena.alloc(u8, byte_len);
                const slice = reader.readBytes(scratch) catch {
                    return interp.setErrorString("unexpected end of stream while decoding bytes");
                };
                return try String.newValue(slice);
            }

            if (field.len.get(.decode)) |len_val| {
                const bit_len = try evalNonNegativeLengthBits(scope, len_val, false, decoded_dict, reader.bit_pos, reader.source);
                if (bit_len % 8 == 0) {
                    const byte_len = bit_len / 8;
                    const scratch = try arena.alloc(u8, byte_len);
                    const slice = reader.readBytes(scratch) catch {
                        return interp.setErrorString("unexpected end of stream while decoding bytes");
                    };
                    return try String.newValue(slice);
                } else {
                    reader.checkBitBounds(bit_len) catch {
                        return interp.setErrorString("unexpected end of stream while decoding bit-length bytes");
                    };
                    const endian = reader.last_bit_endian orelse .big;
                    var writer: BitWriter = .{};
                    defer writer.deinit(arena);
                    var remaining = bit_len;
                    while (remaining > 0) {
                        const take: u7 = @intCast(@min(remaining, 64));
                        const chunk = reader.readBits(take, endian) catch {
                            return interp.setErrorString("unexpected end of stream while decoding bit-length bytes");
                        };
                        writer.writeBits(arena, chunk, take, endian) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.MidByteEndianSwitch, error.InvalidBitWidth => unreachable,
                        };
                        remaining -= take;
                    }
                    return try String.newValue(writer.bytes.items);
                }
            }

            if (field.term.get(.decode)) |term_val| {
                const delim = try term_val.getString();
                if (reader.bit_pos % 8 == 0) {
                    const start_byte = reader.bit_pos / 8;
                    const rest = reader.source[start_byte..];
                    const match_off = mem.indexOf(u8, rest, delim) orelse {
                        return interp.setErrorString("unexpected end of stream: missing bytes terminator");
                    };
                    const content = rest[0..match_off];
                    reader.bit_pos += (match_off + delim.len) * 8;
                    return try String.newValue(content);
                } else {
                    var accum: std.ArrayList(u8) = .empty;
                    const endian = reader.last_bit_endian orelse .big;
                    while (true) {
                        const b: u8 = @intCast(reader.readBits(8, endian) catch {
                            return interp.setErrorString("unexpected end of stream: missing bytes terminator");
                        });
                        try accum.append(arena, b);
                        if (accum.items.len >= delim.len and mem.eql(u8, accum.items[accum.items.len - delim.len ..], delim)) {
                            const content = accum.items[0 .. accum.items.len - delim.len];
                            return try String.newValue(content);
                        }
                    }
                }
            }

            return interp.setErrorString("bytes field requires len, prefix, or term modifier");
        },
        .mark => {
            const pos_i64 = math.cast(i64, reader.bit_pos) orelse return interp.integerOverflowError(usize, reader.bit_pos);
            return Value.newInt(pos_i64);
        },
        .@"struct" => {
            const sub_schema_val = field.schema.get(.decode) orelse {
                return interp.setErrorString("struct field missing schema modifier");
            };
            return try executeDecodeSchema(interp, arena, sub_schema_val, reader, state_dict, scope);
        },
        .custom => {
            const call_val = field.call.get(.decode) orelse {
                return interp.setErrorString("custom field missing call or call_decode modifier");
            };
            try writeStateCursor(interp, state_dict.*, reader.bit_pos);
            const buf_val = try String.newValue(reader.source);
            defer buf_val.dropReference();
            const parsed_so_far = if (is_named_mode) decoded_dict.asHead().asValue() else decoded_list.asHead().asValue();
            const res = try invokeCustomCodec(interp, call_val, .decode, state_dict, buf_val, parsed_so_far);
            errdefer res.dropReference();
            reader.bit_pos = try readStateCursor(interp, state_dict.*);
            if (reader.bit_pos % 8 == 0) {
                reader.last_bit_endian = null;
            }
            return res;
        },
        .directive => unreachable,
    }
}

fn executeDecodeSchema(
    interp: *Interp,
    arena: std.mem.Allocator,
    schema_val: Value,
    reader: *BitReader,
    state_dict: **Dictionary,
    parent_scope: ?*EvalScope,
) Interp.Error!Value {
    const parsed_schema = try parseSchemaFields(interp, arena, schema_val);
    defer freeSchemaFields(parsed_schema.fields);

    const decoded_dict = try Dictionary.new(&.{});
    defer decoded_dict.asHead().dropReference();
    const decoded_list = try List.new(&.{});
    defer decoded_list.asHead().dropReference();

    var local_scope: EvalScope = .{ .interp = interp };
    defer local_scope.deinit();
    const scope = parent_scope orelse &local_scope;

    for (parsed_schema.fields) |field| {
        if (field.cond.get(.decode)) |cond_val| {
            const active = try evalBoolModifier(scope, cond_val, decoded_dict, reader.bit_pos, reader.source);
            if (!active) {
                if (!parsed_schema.has_named and field.base_type != .directive) {
                    try decoded_list.append(heap.interned_empty_string);
                }
                continue;
            }
        }

        if (field.align_to.get(.decode)) |align_to_val| {
            const align_to_bits = try evalNonNegativeLengthBits(scope, align_to_val, false, decoded_dict, reader.bit_pos, reader.source);
            reader.alignTo(align_to_bits) catch {
                return interp.setErrorString("unexpected end of stream during align_to");
            };
        }

        const req_align = if (field.@"align".get(.decode)) |align_val|
            try evalNonNegativeLengthBits(scope, align_val, false, decoded_dict, reader.bit_pos, reader.source)
        else
            (field.requiredAlignmentBits() orelse 1);

        if (req_align > 1 and reader.bit_pos % req_align != 0) {
            return interp.setErrorFormatted(
                "alignment error: cursor at bit {d} is not aligned to {d} bits",
                .{ reader.bit_pos, req_align },
            );
        }

        if (field.base_type == .directive) {
            if (field.pad.get(.decode)) |pad_val| {
                const pad_bits = try evalNonNegativeLengthBits(scope, pad_val, false, decoded_dict, reader.bit_pos, reader.source);
                reader.skipBits(pad_bits) catch {
                    return interp.setErrorString("unexpected end of stream during pad");
                };
            }
            continue;
        }

        var final_val: Value = undefined;
        if (field.count.get(.decode)) |count_val| {
            var count_res = try scope.evalExpr(count_val, decoded_dict, reader.bit_pos, reader.source);
            defer count_res.dropReference();
            var count_shim: Shimmerable = .{ .original = count_res };
            defer count_shim.discardChanges();
            const count_i64 = try interp.getInteger(&count_shim);
            if (count_i64 < 0) {
                return interp.setErrorFormatted("negative count {d} in binary decode", .{count_i64});
            }
            const count_usize = math.cast(usize, count_i64) orelse return interp.integerOverflowError(i64, count_i64);

            const elem_list = try List.newWithCapacity(&.{}, count_usize);
            errdefer elem_list.asHead().dropReference();

            var idx: usize = 0;
            while (idx < count_usize) : (idx += 1) {
                const raw_elem = try decodeElement(interp, arena, reader, field, scope, state_dict, decoded_dict, decoded_list, parsed_schema.has_named);
                defer raw_elem.dropReference();
                const mapped_elem = try translateEnumDecode(scope, field, raw_elem, decoded_dict, reader.bit_pos, reader.source);
                defer mapped_elem.dropReference();
                elem_list.appendAssumeCapacity(mapped_elem);
            }
            final_val = elem_list.asHead().asValue();
        } else {
            const raw_elem = try decodeElement(interp, arena, reader, field, scope, state_dict, decoded_dict, decoded_list, parsed_schema.has_named);
            defer raw_elem.dropReference();
            final_val = try translateEnumDecode(scope, field, raw_elem, decoded_dict, reader.bit_pos, reader.source);
        }
        defer final_val.dropReference();

        if (field.val.get(.decode)) |expected_opt| {
            const expected_val = try evalValueOrLiteral(scope, expected_opt, decoded_dict, reader.bit_pos, reader.source);
            defer expected_val.dropReference();

            var matches = try final_val.equals(expected_val);
            if (!matches) {
                var a_shim: Shimmerable = .{ .original = final_val };
                defer a_shim.discardChanges();
                var b_shim: Shimmerable = .{ .original = expected_val };
                defer b_shim.discardChanges();
                if (interp.getInteger(&a_shim)) |a_int| {
                    if (interp.getInteger(&b_shim)) |b_int| {
                        matches = (a_int == b_int);
                    } else |_| {}
                } else |_| {}
            }
            if (!matches) {
                return interp.setErrorFormatted(
                    "validation failed: expected \"{s}\", got \"{s}\"",
                    .{ try expected_val.getString(), try final_val.getString() },
                );
            }
        }

        if (field.pad.get(.decode)) |pad_val| {
            const pad_bits = try evalNonNegativeLengthBits(scope, pad_val, false, decoded_dict, reader.bit_pos, reader.source);
            reader.skipBits(pad_bits) catch {
                return interp.setErrorString("unexpected end of stream during pad");
            };
        }

        if (field.base_type == .mark) {
            if (field.name_val) |nv| {
                try state_dict.*.put(nv, final_val);
            }
        }

        try scope.bindField(field.name_val, final_val);

        if (parsed_schema.has_named) {
            if (field.name_val) |nv| {
                try decoded_dict.put(nv, final_val);
            }
        } else {
            try decoded_list.append(final_val);
        }
    }

    if (parsed_schema.has_named) {
        return decoded_dict.asHead().takeReference().asValue();
    } else {
        return decoded_list.asHead().takeReference().asValue();
    }
}

fn encodeElement(
    interp: *Interp,
    arena: std.mem.Allocator,
    writer: *BitWriter,
    field: FieldSpec,
    elem_val: Value,
    scope: *EvalScope,
    state_dict: **Dictionary,
    encode_dict: *Dictionary,
    all_values_val: Value,
) Interp.Error!void {
    const wire_val = try translateEnumEncode(scope, field, elem_val, encode_dict, writer.bit_pos, writer.bytes.items);
    defer wire_val.dropReference();

    var prefix_spec_opt: ?IntSpec = null;
    if (field.prefix.get(.encode)) |prefix_val| {
        const prefix_str = try prefix_val.getString();
        prefix_spec_opt = parseIntTypeToken(prefix_str).?;
    }

    switch (field.base_type) {
        .int => |int_spec| {
            if (prefix_spec_opt) |prefix_spec| {
                const byte_len = (int_spec.bits + 7) / 8;
                const len_val = Value.newInt(@intCast(byte_len));
                try encodeSingleInt(interp, writer, arena, len_val, prefix_spec);
            }
            try encodeSingleInt(interp, writer, arena, wire_val, int_spec);
        },
        .float => |float_spec| {
            var shim: Shimmerable = .{ .original = wire_val };
            defer shim.discardChanges();
            const f64_val = try interp.getFloat(&shim);
            switch (float_spec.bits) {
                .f32 => {
                    if (prefix_spec_opt) |prefix_spec| {
                        try encodeSingleInt(interp, writer, arena, Value.newInt(4), prefix_spec);
                    }
                    const f32_val: f32 = @floatCast(f64_val);
                    const u32_bits: u32 = @bitCast(f32_val);
                    writer.writeBits(arena, u32_bits, 32, float_spec.endian) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.MidByteEndianSwitch => return interp.setErrorString("cannot switch bit endianness mid-byte"),
                        error.InvalidBitWidth => unreachable,
                    };
                },
                .f64 => {
                    if (prefix_spec_opt) |prefix_spec| {
                        try encodeSingleInt(interp, writer, arena, Value.newInt(8), prefix_spec);
                    }
                    const u64_bits: u64 = @bitCast(f64_val);
                    writer.writeBits(arena, u64_bits, 64, float_spec.endian) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.MidByteEndianSwitch => return interp.setErrorString("cannot switch bit endianness mid-byte"),
                        error.InvalidBitWidth => unreachable,
                    };
                },
            }
        },
        .str => {
            const str_bytes = try wire_val.getString();
            var delim: []const u8 = "\x00";
            if (field.term.get(.encode)) |term_val| {
                delim = try term_val.getString();
            }

            if (prefix_spec_opt) |prefix_spec| {
                const len_i64 = math.cast(i64, str_bytes.len) orelse return interp.integerOverflowError(usize, str_bytes.len);
                try encodeSingleInt(interp, writer, arena, Value.newInt(len_i64), prefix_spec);
                writer.writeBytes(arena, str_bytes) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.MidByteEndianSwitch => return interp.setErrorString("cannot switch bit endianness mid-byte"),
                    error.InvalidBitWidth => unreachable,
                };
                return;
            }

            if (field.len.get(.encode)) |len_val| {
                const bit_len = try evalNonNegativeLengthBits(scope, len_val, true, encode_dict, writer.bit_pos, writer.bytes.items);
                const byte_len = bit_len / 8;
                if (str_bytes.len > byte_len) {
                    return interp.setErrorFormatted(
                        "str length {d} exceeds fixed slot size {d}",
                        .{ str_bytes.len, byte_len },
                    );
                }
                if (mem.indexOfScalar(u8, str_bytes, 0) != null) {
                    return interp.setErrorString("interior null byte in str field");
                }
                writer.writeBytes(arena, str_bytes) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.MidByteEndianSwitch => return interp.setErrorString("cannot switch bit endianness mid-byte"),
                    error.InvalidBitWidth => unreachable,
                };
                const pad_bytes = byte_len - str_bytes.len;
                if (pad_bytes > 0) {
                    writer.padZeroBits(arena, pad_bytes * 8) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.MidByteEndianSwitch => return interp.setErrorString("cannot switch bit endianness mid-byte"),
                        error.InvalidBitWidth => unreachable,
                    };
                }
                return;
            }

            if (mem.indexOf(u8, str_bytes, delim) != null) {
                return interp.setErrorString("str value contains terminator sequence before end");
            }
            writer.writeBytes(arena, str_bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.MidByteEndianSwitch => return interp.setErrorString("cannot switch bit endianness mid-byte"),
                error.InvalidBitWidth => unreachable,
            };
            writer.writeBytes(arena, delim) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.MidByteEndianSwitch => return interp.setErrorString("cannot switch bit endianness mid-byte"),
                error.InvalidBitWidth => unreachable,
            };
        },
        .bytes => {
            const raw_bytes = try wire_val.getString();
            if (prefix_spec_opt) |prefix_spec| {
                const len_i64 = math.cast(i64, raw_bytes.len) orelse return interp.integerOverflowError(usize, raw_bytes.len);
                try encodeSingleInt(interp, writer, arena, Value.newInt(len_i64), prefix_spec);
                writer.writeBytes(arena, raw_bytes) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.MidByteEndianSwitch => return interp.setErrorString("cannot switch bit endianness mid-byte"),
                    error.InvalidBitWidth => unreachable,
                };
                return;
            }

            if (field.len.get(.encode)) |len_val| {
                const bit_len = try evalNonNegativeLengthBits(scope, len_val, false, encode_dict, writer.bit_pos, writer.bytes.items);
                if (bit_len % 8 == 0) {
                    const byte_len = bit_len / 8;
                    if (raw_bytes.len != byte_len) {
                        return interp.setErrorFormatted(
                            "bytes length {d} does not match expected length {d}",
                            .{ raw_bytes.len, byte_len },
                        );
                    }
                    writer.writeBytes(arena, raw_bytes) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.MidByteEndianSwitch => return interp.setErrorString("cannot switch bit endianness mid-byte"),
                        error.InvalidBitWidth => unreachable,
                    };
                } else {
                    const avail_bits = math.mul(usize, raw_bytes.len, 8) catch return error.OutOfMemory;
                    if (avail_bits < bit_len) {
                        return interp.setErrorFormatted(
                            "bytes buffer has {d} bits, fewer than required {d} bits",
                            .{ avail_bits, bit_len },
                        );
                    }
                    const endian = writer.last_bit_endian orelse .big;
                    writer.writeBitStream(arena, raw_bytes, bit_len, endian) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return interp.setErrorString("failed to write bit-length bytes"),
                    };
                }
                return;
            }

            if (field.term.get(.encode)) |term_val| {
                const delim = try term_val.getString();
                if (mem.indexOf(u8, raw_bytes, delim) != null) {
                    return interp.setErrorString("bytes value contains terminator sequence before end");
                }
                writer.writeBytes(arena, raw_bytes) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.MidByteEndianSwitch => return interp.setErrorString("cannot switch bit endianness mid-byte"),
                    error.InvalidBitWidth => unreachable,
                };
                writer.writeBytes(arena, delim) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.MidByteEndianSwitch => return interp.setErrorString("cannot switch bit endianness mid-byte"),
                    error.InvalidBitWidth => unreachable,
                };
                return;
            }

            return interp.setErrorString("bytes field requires len, prefix, or term modifier");
        },
        .mark => {},
        .@"struct" => {
            const sub_schema_val = field.schema.get(.encode) orelse {
                return interp.setErrorString("struct field missing schema modifier");
            };
            try executeEncodeSchema(interp, arena, sub_schema_val, wire_val, writer, state_dict, scope);
        },
        .custom => {
            const call_val = field.call.get(.encode) orelse {
                return interp.setErrorString("custom field missing call or call_encode modifier");
            };
            const old_cursor = writer.bit_pos;
            try writeStateCursor(interp, state_dict.*, old_cursor);

            const encoded_chunk = try invokeCustomCodec(interp, call_val, .encode, state_dict, wire_val, all_values_val);
            defer encoded_chunk.dropReference();

            const new_cursor = try readStateCursor(interp, state_dict.*);
            if (new_cursor < old_cursor) {
                return interp.setErrorString("custom encode codec moved cursor backward");
            }
            const bit_delta = new_cursor - old_cursor;
            const chunk_bytes = try encoded_chunk.getString();
            const avail_bits = math.mul(usize, chunk_bytes.len, 8) catch return error.OutOfMemory;
            if (bit_delta > avail_bits) {
                return interp.setErrorFormatted(
                    "custom encode codec advanced cursor by {d} bits but only returned {d} bytes",
                    .{ bit_delta, chunk_bytes.len },
                );
            }
            const endian = writer.last_bit_endian orelse .big;
            writer.writeBitStream(arena, chunk_bytes, bit_delta, endian) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return interp.setErrorString("failed to append custom codec bit stream"),
            };
        },
        .directive => unreachable,
    }
}

fn countAnonymousValueFields(fields: []const FieldSpec) usize {
    var total: usize = 0;
    for (fields) |field| {
        if (field.base_type == .directive or field.base_type == .mark) continue;
        if (field.val.get(.encode) != null) continue;
        total += 1;
    }
    return total;
}

fn executeEncodeSchema(
    interp: *Interp,
    arena: std.mem.Allocator,
    schema_val: Value,
    values_val: Value,
    writer: *BitWriter,
    state_dict: **Dictionary,
    parent_scope: ?*EvalScope,
) Interp.Error!void {
    const parsed_schema = try parseSchemaFields(interp, arena, schema_val);
    defer freeSchemaFields(parsed_schema.fields);

    const encode_dict = try Dictionary.new(&.{});
    defer encode_dict.asHead().dropReference();

    var anon_items: []const Value = &.{};
    var single_anon_buf: [1]Value = .{values_val};
    var values_shim: Shimmerable = .{ .original = values_val };
    defer values_shim.discardChanges();

    if (parsed_schema.has_named) {
        const input_dict = try interp.getDict(&values_shim);
        var i: usize = 0;
        while (i < input_dict.items.len) : (i += 2) {
            try encode_dict.put(input_dict.items[i], input_dict.items[i + 1]);
        }
    } else {
        const expected_anon = countAnonymousValueFields(parsed_schema.fields);
        if (expected_anon == 1) {
            if (List.shimmerFrom(null, &values_shim)) |as_list| {
                if (as_list.items.len == 1) {
                    anon_items = as_list.items;
                } else {
                    anon_items = &single_anon_buf;
                }
            } else |_| {
                anon_items = &single_anon_buf;
            }
        } else {
            const as_list = try interp.getList(&values_shim);
            anon_items = as_list.items;
        }
    }

    var local_scope: EvalScope = .{ .interp = interp };
    defer local_scope.deinit();
    const scope = parent_scope orelse &local_scope;

    var anon_idx: usize = 0;

    for (parsed_schema.fields) |field| {
        if (field.cond.get(.encode)) |cond_val| {
            const active = try evalBoolModifier(scope, cond_val, encode_dict, writer.bit_pos, writer.bytes.items);
            if (!active) {
                if (!parsed_schema.has_named and field.base_type != .directive and field.base_type != .mark and field.val.get(.encode) == null) {
                    if (anon_idx < anon_items.len) anon_idx += 1;
                }
                continue;
            }
        }

        if (field.align_to.get(.encode)) |align_to_val| {
            const align_to_bits = try evalNonNegativeLengthBits(scope, align_to_val, false, encode_dict, writer.bit_pos, writer.bytes.items);
            writer.alignTo(arena, align_to_bits) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.MidByteEndianSwitch => return interp.setErrorString("cannot switch bit endianness mid-byte"),
                error.InvalidBitWidth => unreachable,
            };
        }

        const req_align = if (field.@"align".get(.encode)) |align_val|
            try evalNonNegativeLengthBits(scope, align_val, false, encode_dict, writer.bit_pos, writer.bytes.items)
        else
            (field.requiredAlignmentBits() orelse 1);

        if (req_align > 1 and writer.bit_pos % req_align != 0) {
            return interp.setErrorFormatted(
                "alignment error: cursor at bit {d} is not aligned to {d} bits",
                .{ writer.bit_pos, req_align },
            );
        }

        if (field.base_type == .directive) {
            if (field.pad.get(.encode)) |pad_val| {
                const pad_bits = try evalNonNegativeLengthBits(scope, pad_val, false, encode_dict, writer.bit_pos, writer.bytes.items);
                writer.padZeroBits(arena, pad_bits) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.MidByteEndianSwitch => return interp.setErrorString("cannot switch bit endianness mid-byte"),
                    error.InvalidBitWidth => unreachable,
                };
            }
            continue;
        }

        if (field.base_type == .mark) {
            const pos_i64 = math.cast(i64, writer.bit_pos) orelse return interp.integerOverflowError(usize, writer.bit_pos);
            const mark_val = Value.newInt(pos_i64);
            if (field.name_val) |nv| {
                try state_dict.*.put(nv, mark_val);
                try encode_dict.put(nv, mark_val);
            }
            try scope.bindField(field.name_val, mark_val);
            continue;
        }

        var field_val: Value = undefined;
        var field_val_owned = false;
        if (field.val.get(.encode)) |val_opt| {
            field_val = try evalValueOrLiteral(scope, val_opt, encode_dict, writer.bit_pos, writer.bytes.items);
            field_val_owned = true;
        } else if (parsed_schema.has_named) {
            if (field.name_val) |nv| {
                if (try interp.getDictValue(encode_dict, nv)) |found| {
                    field_val = found;
                } else if (field.default.get(.encode)) |def_opt| {
                    field_val = try evalValueOrLiteral(scope, def_opt, encode_dict, writer.bit_pos, writer.bytes.items);
                    field_val_owned = true;
                } else {
                    return interp.setErrorFormatted("missing required field \"{s}\" in binary encode", .{field.name.?});
                }
            } else if (field.default.get(.encode)) |def_opt| {
                field_val = try evalValueOrLiteral(scope, def_opt, encode_dict, writer.bit_pos, writer.bytes.items);
                field_val_owned = true;
            } else {
                return interp.setErrorString("unnamed field in named schema requires val or default modifier for encode");
            }
        } else {
            if (anon_idx < anon_items.len) {
                field_val = anon_items[anon_idx];
                anon_idx += 1;
            } else if (field.default.get(.encode)) |def_opt| {
                field_val = try evalValueOrLiteral(scope, def_opt, encode_dict, writer.bit_pos, writer.bytes.items);
                field_val_owned = true;
            } else {
                return interp.setErrorString("not enough values provided for anonymous binary encode schema");
            }
        }
        defer if (field_val_owned) field_val.dropReference();

        if (field.count.get(.encode)) |count_val| {
            var count_res = try scope.evalExpr(count_val, encode_dict, writer.bit_pos, writer.bytes.items);
            defer count_res.dropReference();
            var count_shim: Shimmerable = .{ .original = count_res };
            defer count_shim.discardChanges();
            const count_i64 = try interp.getInteger(&count_shim);
            if (count_i64 < 0) {
                return interp.setErrorFormatted("negative count {d} in binary encode", .{count_i64});
            }
            const count_usize = math.cast(usize, count_i64) orelse return interp.integerOverflowError(i64, count_i64);

            var list_shim: Shimmerable = .{ .original = field_val };
            defer list_shim.discardChanges();
            const elem_list = try interp.getList(&list_shim);
            if (elem_list.items.len != count_usize) {
                return interp.setErrorFormatted(
                    "array field expected {d} elements, got {d}",
                    .{ count_usize, elem_list.items.len },
                );
            }

            for (elem_list.items) |elem| {
                try encodeElement(interp, arena, writer, field, elem, scope, state_dict, encode_dict, values_val);
            }
        } else {
            try encodeElement(interp, arena, writer, field, field_val, scope, state_dict, encode_dict, values_val);
        }

        if (field.pad.get(.encode)) |pad_val| {
            const pad_bits = try evalNonNegativeLengthBits(scope, pad_val, false, encode_dict, writer.bit_pos, writer.bytes.items);
            writer.padZeroBits(arena, pad_bits) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.MidByteEndianSwitch => return interp.setErrorString("cannot switch bit endianness mid-byte"),
                error.InvalidBitWidth => unreachable,
            };
        }

        if (field.name_val) |nv| {
            try encode_dict.put(nv, field_val);
        }
        try scope.bindField(field.name_val, field_val);
    }
}

fn initStateDict(interp: *Interp, state_var_opt: ?*Shimmerable, at_bit_opt: ?usize) !struct {
    dict: *Dictionary,
    initial_cursor: usize,
} {
    var dict: *Dictionary = undefined;
    if (state_var_opt) |state_var| {
        if (try interp.getVariableTakingRef(state_var)) |existing| {
            defer existing.dropReference();
            const existing_str = try existing.getString();
            if (existing_str.len == 0) {
                dict = try Dictionary.new(&.{});
            } else {
                var shim: Shimmerable = .{ .original = existing };
                defer shim.discardChanges();
                var det: ErrorDetails = undefined;
                dict = try interp.wrapError(&det, shim.getMutable(Dictionary, &det));
            }
        } else {
            dict = try Dictionary.new(&.{});
        }
    } else {
        dict = try Dictionary.new(&.{});
    }
    errdefer dict.asHead().dropReference();

    var cursor: usize = 0;
    if (at_bit_opt) |at_bit| {
        cursor = at_bit;
    } else {
        cursor = try readStateCursor(interp, dict);
    }
    try writeStateCursor(interp, dict, cursor);
    return .{ .dict = dict, .initial_cursor = cursor };
}

fn parseNonNegativeBitArg(interp: *Interp, arg: *Shimmerable, flag_name: []const u8) !usize {
    const val = try interp.getInteger(arg);
    if (val < 0) {
        return interp.setErrorFormatted("{s} bit count cannot be negative: {d}", .{ flag_name, val });
    }
    return math.cast(usize, val) orelse return interp.integerOverflowError(i64, val);
}

fn binaryDecodeCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    // binary decode ?-at bit_offset? ?-state stateVar? schema data
    if (args.len < 4) return error.WrongUsage;

    var at_bit_opt: ?usize = null;
    var state_var_opt: ?*Shimmerable = null;

    const flag_limit = args.len - 2;
    var i: usize = 2;
    while (i < flag_limit) {
        const flag = try args[i].current().getString();
        if (mem.eql(u8, flag, "-at")) {
            if (i + 1 >= flag_limit) return error.WrongUsage;
            at_bit_opt = try parseNonNegativeBitArg(interp, &args[i + 1], "-at");
            i += 2;
        } else if (mem.eql(u8, flag, "-state")) {
            if (i + 1 >= flag_limit) return error.WrongUsage;
            state_var_opt = &args[i + 1];
            i += 2;
        } else {
            return interp.setErrorFormatted("bad option \"{s}\": must be -at or -state", .{flag});
        }
    }

    const schema_val = args[args.len - 2].current();
    const data_val = args[args.len - 1].current();
    const data_bytes = try data_val.getString();

    var state_info = try initStateDict(interp, state_var_opt, at_bit_opt);
    defer state_info.dict.asHead().dropReference();

    var reader: BitReader = .{
        .source = data_bytes,
        .bit_pos = state_info.initial_cursor,
    };
    reader.checkBitBounds(0) catch {
        return interp.setErrorString("initial cursor bit offset exceeds data length");
    };

    const result_val = try executeDecodeSchema(interp, heap.local_arena, schema_val, &reader, &state_info.dict, null);
    errdefer result_val.dropReference();

    if (state_var_opt) |state_var| {
        try writeStateCursor(interp, state_info.dict, reader.bit_pos);
        try interp.setVariable(state_var, state_info.dict.asHead().asValue());
    }

    interp.setResultOwning(result_val);
}

fn binaryEncodeCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    // binary encode ?-state stateVar? ?-bitlength? schema values
    if (args.len < 4) return error.WrongUsage;

    var state_var_opt: ?*Shimmerable = null;
    var want_bitlength = false;

    const flag_limit = args.len - 2;
    var i: usize = 2;
    while (i < flag_limit) {
        const flag = try args[i].current().getString();
        if (mem.eql(u8, flag, "-state")) {
            if (i + 1 >= flag_limit) return error.WrongUsage;
            state_var_opt = &args[i + 1];
            i += 2;
        } else if (mem.eql(u8, flag, "-bitlength")) {
            want_bitlength = true;
            i += 1;
        } else {
            return interp.setErrorFormatted("bad option \"{s}\": must be -state or -bitlength", .{flag});
        }
    }

    const schema_val = args[args.len - 2].current();
    const values_val = args[args.len - 1].current();

    var state_info = try initStateDict(interp, state_var_opt, 0);
    defer state_info.dict.asHead().dropReference();

    var writer: BitWriter = .{};
    defer writer.deinit(heap.local_arena);

    try executeEncodeSchema(interp, heap.local_arena, schema_val, values_val, &writer, &state_info.dict, null);

    if (!want_bitlength and writer.bit_pos % 8 != 0) {
        return interp.setErrorFormatted(
            "encoded bit length ({d}) is not a multiple of 8; use -bitlength for non-byte-aligned output",
            .{writer.bit_pos},
        );
    }

    if (state_var_opt) |state_var| {
        try writeStateCursor(interp, state_info.dict, writer.bit_pos);
        try interp.setVariable(state_var, state_info.dict.asHead().asValue());
    }

    const bytes_val = try String.newValue(writer.bytes.items);
    defer bytes_val.dropReference();

    if (want_bitlength) {
        const bits_i64 = math.cast(i64, writer.bit_pos) orelse return interp.integerOverflowError(usize, writer.bit_pos);
        const list_res = try List.new(&.{ bytes_val, Value.newInt(bits_i64) });
        interp.setResultOwning(list_res.asHead().asValue());
    } else {
        interp.setResult(bytes_val);
    }
}

/// Applies a bit-stream write (`patch_bytes`, `patch_bits` bits) at `start_bit` onto `target_var`,
/// mutating its `SpecialString` in-place when exclusively owned, or performing copy-on-write otherwise.
fn applyBitSpliceToVariable(
    interp: *Interp,
    target_var: *Shimmerable,
    maybe_var: ?Value,
    start_bit: usize,
    patch_bytes: []const u8,
    patch_bits: usize,
    endian: std.builtin.Endian,
) Interp.Error!Value {
    const end_bit = math.add(usize, start_bit, patch_bits) catch return error.OutOfMemory;
    const needed_byte_len = (math.add(usize, end_bit, 7) catch return error.OutOfMemory) / 8;

    if (maybe_var) |var_value| {
        if (try var_value.asMutableStringInPlace()) |special| {
            if (patch_bits == 0 and needed_byte_len <= special.getString().len) {
                return var_value;
            }

            // Byte-aligned fast path.
            if (start_bit % 8 == 0 and patch_bits % 8 == 0) {
                const byte_offset = start_bit / 8;
                const byte_count = patch_bits / 8;
                if (byte_offset == special.getString().len) {
                    try special.appendInPlace(patch_bytes[0..byte_count]);
                } else {
                    try special.patchBytesInPlace(byte_offset, patch_bytes[0..byte_count]);
                }
                return var_value;
            }

            const old_len = special.getString().len;
            const new_len = @max(old_len, needed_byte_len);
            try special.ensureTotalCapacity(new_len);

            const ptr = special.getMutableString().ptr;
            if (new_len > old_len) {
                @memset(ptr[old_len..new_len], 0);
            }
            ptr[new_len] = 0;
            errdefer ptr[old_len] = 0;

            var bit_pos = start_bit;
            var last_endian: ?std.builtin.Endian = endian;
            writeBitStreamIntoSlice(ptr[0..new_len], &bit_pos, &last_endian, patch_bytes, patch_bits, endian) catch |err| switch (err) {
                error.MidByteEndianSwitch => return interp.setErrorString("cannot switch bit endianness mid-byte"),
                error.EndOfStream, error.InvalidBitWidth => unreachable,
            };

            const mod_start_byte = @min(old_len, start_bit / 8);
            const mod_end_byte = needed_byte_len;
            try special.updateHashesAfterModification(ptr[0..new_len], mod_start_byte, mod_end_byte);

            special.setLengthWithinCapacity(new_len);
            special.invalidateCachedHashAndUtf8Len();
            return var_value;
        }
    }

    var base_buf: [350]u8 = undefined;
    var base_bytes: [:0]const u8 = "";
    if (maybe_var) |var_value| {
        base_bytes = try var_value.getStringWithBuffer(&base_buf);
    }

    const new_len = @max(base_bytes.len, needed_byte_len);
    const out_buf = try heap.global_gpa.allocSentinel(u8, new_len, 0);
    errdefer heap.global_gpa.free(out_buf);

    if (base_bytes.len > 0) {
        @memcpy(out_buf[0..base_bytes.len], base_bytes);
    }
    if (new_len > base_bytes.len) {
        @memset(out_buf[base_bytes.len..new_len], 0);
    }
    out_buf[new_len] = 0;

    if (patch_bits > 0) {
        var bit_pos = start_bit;
        var last_endian: ?std.builtin.Endian = endian;
        writeBitStreamIntoSlice(out_buf[0..new_len], &bit_pos, &last_endian, patch_bytes, patch_bits, endian) catch |err| switch (err) {
            error.MidByteEndianSwitch => return interp.setErrorString("cannot switch bit endianness mid-byte"),
            error.EndOfStream, error.InvalidBitWidth => unreachable,
        };
    }

    const new_str = try String.newOwningNoFree(out_buf);
    defer new_str.asHead().dropReference();
    const new_val = new_str.asHead().asValue();
    try interp.setVariable(target_var, new_val);
    return new_val;
}

fn binaryPatchCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    // binary patch ?-at bit_offset? ?-state stateVar? ?-extend? ?-bitlength bit_len? targetVar ?-at bit_offset? schema value
    if (args.len < 5) return error.WrongUsage;

    var at_bit_opt: ?usize = null;
    var state_var_opt: ?*Shimmerable = null;
    var allow_extend = false;
    var explicit_bitlen_opt: ?usize = null;
    var target_var_opt: ?*Shimmerable = null;

    const opt_limit = args.len - 2;
    var i: usize = 2;
    while (i < opt_limit) {
        const token = try args[i].current().getString();
        if (mem.eql(u8, token, "-at")) {
            if (i + 1 >= opt_limit) return error.WrongUsage;
            at_bit_opt = try parseNonNegativeBitArg(interp, &args[i + 1], "-at");
            i += 2;
        } else if (mem.eql(u8, token, "-state")) {
            if (i + 1 >= opt_limit) return error.WrongUsage;
            state_var_opt = &args[i + 1];
            i += 2;
        } else if (mem.eql(u8, token, "-extend")) {
            allow_extend = true;
            i += 1;
        } else if (mem.eql(u8, token, "-bitlength")) {
            if (i + 1 >= opt_limit) return error.WrongUsage;
            explicit_bitlen_opt = try parseNonNegativeBitArg(interp, &args[i + 1], "-bitlength");
            i += 2;
        } else if (target_var_opt == null) {
            target_var_opt = &args[i];
            i += 1;
        } else {
            return interp.setErrorFormatted("unexpected argument \"{s}\" in binary patch", .{token});
        }
    }

    const target_var = target_var_opt orelse return error.WrongUsage;
    const schema_val = args[args.len - 2].current();
    const value_val = args[args.len - 1].current();

    var state_info = try initStateDict(interp, state_var_opt, at_bit_opt);
    defer state_info.dict.asHead().dropReference();
    const start_bit = state_info.initial_cursor;

    if (!allow_extend) {
        if (try interp.getVariableForMutation(target_var) == null) {
            return interp.setErrorFormatted(
                "can't read \"{s}\": no such variable (use -extend to create)",
                .{try target_var.current().getString()},
            );
        }
    }

    var writer: BitWriter = .{};
    defer writer.deinit(heap.local_arena);

    var patch_state = try Dictionary.new(&.{});
    defer patch_state.asHead().dropReference();
    try writeStateCursor(interp, patch_state, 0);

    try executeEncodeSchema(interp, heap.local_arena, schema_val, value_val, &writer, &patch_state, null);

    var patch_bits = writer.bit_pos;
    if (explicit_bitlen_opt) |exp_bits| {
        if (exp_bits > writer.bit_pos) {
            return interp.setErrorFormatted(
                "-bitlength {d} exceeds encoded patch width {d}",
                .{ exp_bits, writer.bit_pos },
            );
        }
        patch_bits = exp_bits;
    }

    const maybe_var = try interp.getVariableForMutation(target_var);
    var base_buf: [350]u8 = undefined;
    var existing_byte_len: usize = 0;
    if (maybe_var) |var_value| {
        const s = try var_value.getStringWithBuffer(&base_buf);
        existing_byte_len = s.len;
    } else if (!allow_extend) {
        return interp.setErrorFormatted(
            "can't read \"{s}\": no such variable (use -extend to create)",
            .{try target_var.current().getString()},
        );
    }

    const end_bit = math.add(usize, start_bit, patch_bits) catch return error.OutOfMemory;
    const existing_bits = math.mul(usize, existing_byte_len, 8) catch return error.OutOfMemory;
    if (!allow_extend and end_bit > existing_bits) {
        return interp.setErrorFormatted(
            "patch range [{d}..{d}) exceeds buffer length ({d} bits); use -extend to grow buffer",
            .{ start_bit, end_bit, existing_bits },
        );
    }

    // Determine bit endianness from schema if unaligned.
    var patch_endian: std.builtin.Endian = .big;
    const parsed_schema = try parseSchemaFields(interp, heap.local_arena, schema_val);
    defer freeSchemaFields(parsed_schema.fields);
    if (parsed_schema.fields.len > 0) {
        if (parsed_schema.fields[0].bitEndian()) |e| {
            patch_endian = e;
        } else switch (parsed_schema.fields[0].base_type) {
            .int => |int_spec| if (int_spec.endian) |e| {
                patch_endian = e;
            },
            .float => |float_spec| patch_endian = float_spec.endian,
            else => {},
        }
    }

    const final_val = try applyBitSpliceToVariable(
        interp,
        target_var,
        maybe_var,
        start_bit,
        writer.bytes.items,
        patch_bits,
        patch_endian,
    );

    if (state_var_opt) |state_var| {
        try writeStateCursor(interp, state_info.dict, end_bit);
        try interp.setVariable(state_var, state_info.dict.asHead().asValue());
    }

    interp.setResult(final_val);
}

fn binaryAppendCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    // binary append ?-at bit_offset? ?-state stateVar? ?-bitlength bit_len? ?-endian le|be? targetVar ?chunk ...?
    if (args.len < 3) return error.WrongUsage;

    var at_bit_opt: ?usize = null;
    var state_var_opt: ?*Shimmerable = null;
    var explicit_bitlen_opt: ?usize = null;
    var endian: std.builtin.Endian = .big;

    var i: usize = 2;
    while (i < args.len) {
        const token = try args[i].current().getString();
        if (token.len > 0 and token[0] == '-') {
            if (mem.eql(u8, token, "-at")) {
                if (i + 1 >= args.len) return error.WrongUsage;
                at_bit_opt = try parseNonNegativeBitArg(interp, &args[i + 1], "-at");
                i += 2;
            } else if (mem.eql(u8, token, "-state")) {
                if (i + 1 >= args.len) return error.WrongUsage;
                state_var_opt = &args[i + 1];
                i += 2;
            } else if (mem.eql(u8, token, "-bitlength")) {
                if (i + 1 >= args.len) return error.WrongUsage;
                explicit_bitlen_opt = try parseNonNegativeBitArg(interp, &args[i + 1], "-bitlength");
                i += 2;
            } else if (mem.eql(u8, token, "-endian")) {
                if (i + 1 >= args.len) return error.WrongUsage;
                const end_str = try args[i + 1].current().getString();
                if (mem.eql(u8, end_str, "le")) {
                    endian = .little;
                } else if (mem.eql(u8, end_str, "be")) {
                    endian = .big;
                } else {
                    return interp.setErrorFormatted("bad endianness \"{s}\": must be le or be", .{end_str});
                }
                i += 2;
            } else {
                return interp.setErrorFormatted(
                    "bad option \"{s}\": must be -at, -state, -bitlength, or -endian",
                    .{token},
                );
            }
        } else {
            break;
        }
    }

    if (i >= args.len) return error.WrongUsage;
    const target_var = &args[i];
    const chunks = args[i + 1 ..];

    var maybe_var = try interp.getVariableForMutation(target_var);
    var base_buf: [350]u8 = undefined;
    var existing_byte_len: usize = 0;
    if (maybe_var) |var_value| {
        const s = try var_value.getStringWithBuffer(&base_buf);
        existing_byte_len = s.len;
    }

    var state_dict: ?*Dictionary = null;
    defer if (state_dict) |d| d.asHead().dropReference();

    var bit_pos: usize = math.mul(usize, existing_byte_len, 8) catch return error.OutOfMemory;
    if (state_var_opt != null or at_bit_opt != null) {
        var has_cursor_in_state = false;
        if (state_var_opt) |sv| {
            if (try interp.getVariableTakingRef(sv)) |existing_sv| {
                defer existing_sv.dropReference();
                var sv_shim: Shimmerable = .{ .original = existing_sv };
                defer sv_shim.discardChanges();
                if (Dictionary.shimmerFrom(null, &sv_shim)) |_| {
                    var det: ErrorDetails = undefined;
                    if (try interp.wrapError(&det, Dictionary.shimGetFollowingLinks(&det, &sv_shim, interned_cursor)) != null) {
                        has_cursor_in_state = true;
                    }
                } else |_| {}
            }
        }
        const effective_at = if (at_bit_opt) |at| at else if (has_cursor_in_state) null else bit_pos;
        const info = try initStateDict(interp, state_var_opt, effective_at);
        state_dict = info.dict;
        bit_pos = info.initial_cursor;
    }

    if (chunks.len == 0) {
        if (maybe_var) |var_value| {
            interp.setResult(var_value);
        } else {
            try interp.setVariable(target_var, heap.interned_empty_string);
            interp.setEmptyResult();
        }
        if (state_var_opt) |sv| {
            try writeStateCursor(interp, state_dict.?, bit_pos);
            try interp.setVariable(sv, state_dict.?.asHead().asValue());
        }
        return;
    }

    // Pre-validate all chunks and compute total bits when byte-aligned appending at the end.
    var total_extra_bytes: usize = 0;
    var all_whole_bytes = (bit_pos % 8 == 0 and explicit_bitlen_opt == null);
    for (chunks) |chunk_shim| {
        var c_buf: [350]u8 = undefined;
        const c_bytes = try chunk_shim.current().getStringWithBuffer(&c_buf);
        const avail_bits = math.mul(usize, c_bytes.len, 8) catch return error.OutOfMemory;
        if (explicit_bitlen_opt) |req_bits| {
            if (req_bits > avail_bits) {
                return interp.setErrorFormatted(
                    "-bitlength {d} exceeds chunk size ({d} bits)",
                    .{ req_bits, avail_bits },
                );
            }
            if (req_bits % 8 != 0) all_whole_bytes = false;
        } else {
            total_extra_bytes = math.add(usize, total_extra_bytes, c_bytes.len) catch return error.OutOfMemory;
        }
    }

    // Fast in-place reserve when appending whole bytes at the end of an exclusively owned SpecialString.
    if (all_whole_bytes and bit_pos == existing_byte_len * 8) {
        if (maybe_var) |var_value| {
            if (try var_value.asMutableStringInPlace()) |special| {
                const target_cap = math.add(usize, existing_byte_len, total_extra_bytes) catch return error.OutOfMemory;
                try special.ensureTotalCapacity(target_cap);
                for (chunks) |chunk_shim| {
                    var c_buf: [350]u8 = undefined;
                    const c_bytes = chunk_shim.current().getStringWithBuffer(&c_buf) catch unreachable;
                    try special.appendInPlace(c_bytes);
                    bit_pos += c_bytes.len * 8;
                }
                if (state_var_opt) |sv| {
                    try writeStateCursor(interp, state_dict.?, bit_pos);
                    try interp.setVariable(sv, state_dict.?.asHead().asValue());
                }
                interp.setResult(var_value);
                return;
            }
        }
    }

    var current_val: Value = heap.interned_empty_string;
    for (chunks) |chunk_shim| {
        var c_buf: [350]u8 = undefined;
        const c_bytes = try chunk_shim.current().getStringWithBuffer(&c_buf);
        const chunk_bits = explicit_bitlen_opt orelse (c_bytes.len * 8);

        current_val = try applyBitSpliceToVariable(
            interp,
            target_var,
            maybe_var,
            bit_pos,
            c_bytes,
            chunk_bits,
            endian,
        );
        maybe_var = current_val;
        bit_pos += chunk_bits;
    }

    if (state_var_opt) |sv| {
        try writeStateCursor(interp, state_dict.?, bit_pos);
        try interp.setVariable(sv, state_dict.?.asHead().asValue());
    }

    interp.setResult(current_val);
}

const BinarySubcommand = enum {
    encode,
    decode,
    patch,
    append,
};

pub fn binaryCmd(interp: *Interp, args: []Shimmerable) Interp.Error!void {
    const Parser = objects.SubcommandParser(BinarySubcommand, &.{
        .{ .variant = .encode, .usage = "?-state stateVar? ?-bitlength? schema values", .min_args = 2 },
        .{ .variant = .decode, .usage = "?-at bit_offset? ?-state stateVar? schema data", .min_args = 2 },
        .{ .variant = .patch, .usage = "?-at bit_offset? ?-state stateVar? ?-extend? ?-bitlength bit_len? targetVar schema value", .min_args = 3 },
        .{ .variant = .append, .usage = "?-at bit_offset? ?-state stateVar? ?-bitlength bit_len? ?-endian le|be? targetVar ?chunk ...?", .min_args = 1 },
    });

    var det: ErrorDetails = undefined;
    const subcommand: BinarySubcommand = try interp.wrapError(&det, Parser.parse(&det, args));

    switch (subcommand) {
        .encode => try binaryEncodeCmd(interp, args),
        .decode => try binaryDecodeCmd(interp, args),
        .patch => try binaryPatchCmd(interp, args),
        .append => try binaryAppendCmd(interp, args),
    }
}

pub fn registerCommands(interp: *Interp) !void {
    try registerCommand(interp, "binary", binaryCmd, "subcommand ?arg ...?", 1, null);
}

fn testBinaryBasicEncodeDecode(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Exact wire-byte checks for big-endian and little-endian integers (16, 24, 32, 64-bit, signed/unsigned).
    // 0x12345678 = 305419896:
    //   u32be -> "\x12\x34\x56\x78"
    //   u32le -> "\x78\x56\x34\x12"
    try interp.testExpectScriptResult("\x12\x34\x56\x78", "binary encode u32be 0x12345678");
    try interp.testExpectScriptResult("\x78\x56\x34\x12", "binary encode u32le 0x12345678");
    try interp.testExpectScriptResult("305419896", "binary decode u32be \"\\x12\\x34\\x56\\x78\"");
    try interp.testExpectScriptResult("305419896", "binary decode u32le \"\\x78\\x56\\x34\\x12\"");

    // Signed 32-bit (-2 = 0xFFFFFFFE) and 24-bit (0x010203 = 66051) in big and little endian:
    try interp.testExpectScriptResult("\xff\xff\xff\xfe", "binary encode i32be -2");
    try interp.testExpectScriptResult("\xfe\xff\xff\xff", "binary encode i32le -2");
    try interp.testExpectScriptResult("-2", "binary decode i32be \"\\xff\\xff\\xff\\xfe\"");
    try interp.testExpectScriptResult("-2", "binary decode i32le \"\\xfe\\xff\\xff\\xff\"");
    try interp.testExpectScriptResult("\x01\x02\x03\x03\x02\x01", "binary encode {u24be u24le} {0x010203 0x010203}");

    // Named mode encode + exact wire bytes + decode with integers, strings, bytes, and bitfields:
    //   ver=4 (0100b), ihl=5 (0101b) -> 0x45
    //   len=20 (u16be) -> 0x00 0x14
    //   flag=1 (1b), rest=0x1234 (001001000110100b) -> 0x92 0x34
    //   name="hello\x00"
    //   tail="xy"
    try interp.testExpectScriptResult("\x45\x00\x14\x92\x34hello\x00xy|4 5 20 1 4660 hello xy",
        \\ set schema {
        \\     ver=u4be
        \\     ihl=u4be
        \\     len=u16be
        \\     flag=u1be
        \\     rest=u15be
        \\     name=str
        \\     {tail=bytes len 2}
        \\ }
        \\ set bin [binary encode $schema {ver 4 ihl 5 len 20 flag 1 rest 4660 name hello tail xy}]
        \\ set d [binary decode $schema $bin]
        \\ string cat $bin | [list $d::ver $d::ihl $d::len $d::flag $d::rest $d::name $d::tail]
    );

    // Anonymous mode encode + exact wire bytes ("\xff\xfe\x00\x04") + decode.
    try interp.testExpectScriptResult("\xff\xfe\x00\x04|255 -2 1024",
        \\ set bin [binary encode {u8 i8 u16le} {255 -2 1024}]
        \\ string cat $bin | [binary decode {u8 i8 u16le} $bin]
    );
}

test "binary basic encode and decode" {
    try memutil.checkAllocationFailures(.exhaustive, testBinaryBasicEncodeDecode, .{});
}

fn testBinaryBitEndianAndAlignment(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Little-endian bitfields match Zig packed struct layout (LSB-first):
    //   3-bit value 5 (101b) followed by 5-bit value 9 (01001b) -> (9 << 3) | 5 = 0x4D = 77 ('M').
    // Big-endian bitfields pack MSB-first:
    //   3-bit value 5 (101b) followed by 5-bit value 9 (01001b) -> (5 << 5) | 9 = 0xA9 = 169.
    // Multi-byte unaligned u12le(0xABC) + u4le(0xD) -> 0xDABC in little-endian = "\xbc\xda",
    // whereas u12be(0xABC) + u4be(0xD) -> "\xab\xcd".
    try interp.testExpectScriptResult("\x4d|\xa9|\xbc\xda|\xab\xcd|5 9",
        \\ set le_bin [binary encode {a=u3le b=u5le} {a 5 b 9}]
        \\ set be_bin [binary encode {a=u3be b=u5be} {a 5 b 9}]
        \\ set le16 [binary encode {u12le u4le} {0xabc 0xd}]
        \\ set be16 [binary encode {u12be u4be} {0xabc 0xd}]
        \\ set fields [binary decode {u3le u5le} $le_bin]
        \\ string cat $le_bin | $be_bin | $le16 | $be16 | $fields
    );

    // Static alignment error when a byte-aligned u16be follows 7 bits.
    try interp.testExpectScriptError(
        error.EvalError,
        "alignment error: field requires 8-bit alignment, but static bit offset is 7",
        "binary decode {u7be u16be} \"\\x00\\x00\\x00\"",
    );

    // Mid-byte endian switch between le and be is rejected statically.
    try interp.testExpectScriptError(
        error.EvalError,
        "cannot switch bit endianness mid-byte without byte alignment",
        "binary decode {u4le u4be} \"\\x00\"",
    );
}

test "binary bit endianness and alignment validation" {
    try memutil.checkAllocationFailures(.exhaustive, testBinaryBitEndianAndAlignment, .{});
}

fn testBinaryModifiersAndExpressions(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Dynamic len expression, enum + default, val assertion, prefix, count, cond + exact wire check:
    //   magic=0xCAFE -> "\xca\xfe"
    //   kind=ping(1) -> "\x01"
    //   has_arr=1    -> "\x01"
    //   arr={10 20 30} -> "\x0a\x14\x1e"
    //   body="abcd" prefixed with u8(4) -> "\x04abcd"
    try interp.testExpectScriptResult("\xca\xfe\x01\x01\x0a\x14\x1e\x04abcd|ping {10 20 30} abcd",
        \\ set schema {
        \\     {magic=u16be val 0xCAFE}
        \\     {kind=u8 enum {1 ping 2 pong} default unknown}
        \\     has_arr=u8
        \\     {arr=u8 count 3 cond {$has_arr != 0}}
        \\     {body=bytes prefix u8}
        \\ }
        \\ set bin [binary encode $schema {kind ping has_arr 1 arr {10 20 30} body abcd}]
        \\ set d [binary decode $schema $bin]
        \\ string cat $bin | [list $d::kind $d::arr $d::body]
    );

    // Overwritten local variables and upvar links in the caller's frame are restored after encode/decode.
    try interp.testExpectScriptResult("outer_len 99|5 abcde|outer_len 99 false",
        \\ set outer_var "outer_len"
        \\ fn run_decode {} {
        \\     upvar 1 outer_var n
        \\     set _ 99
        \\     set before "$n $_"
        \\     set bin [binary encode {n=u8 {payload=bytes len {$n}}} {n 5 payload abcde}]
        \\     set d [binary decode {n=u8 {payload=bytes len {$n}}} $bin]
        \\     set after "$n $_ [info exists _cursor]"
        \\     string cat $before | "$d::n $d::payload" | $after
        \\ }
        \\ run_decode
    );
}

test "binary modifiers and expressions" {
    try memutil.checkAllocationFailures(.exhaustive, testBinaryModifiersAndExpressions, .{});
}

fn testBinaryAppendAndPatchInPlace(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Multi-pass header with mark + in-place binary append + in-place binary patch,
    // verifying the exact wire bytes ("\x12\x34\x56\x78\x00\x00\x00\x0dhello").
    try interp.testExpectScriptResult("\x12\x34\x56\x78\x00\x00\x00\x0dhello|305419896 13 hello",
        \\ set hdr_schema {
        \\     {magic=u32be val 0x12345678}
        \\     len_pos=mark
        \\     {total_len=u32be val_encode 0}
        \\ }
        \\ set state {}
        \\ set pkt [binary encode -state state $hdr_schema {}]
        \\ binary append pkt "hello"
        \\ binary patch -at $state::len_pos pkt u32be [string bytelength $pkt]
        \\ set dec [binary decode {magic=u32be total_len=u32be {msg=bytes len {$total_len - 8}}} $pkt]
        \\ string cat $pkt | [list $dec::magic $dec::total_len $dec::msg]
    );

    // Bit-level append and bit-level patch with -bitlength:
    //   5 (0101b), patched to 6 (0110b), 7 (0111b) -> "\x56\x70".
    try interp.testExpectScriptResult("\x56\x70|5 6 7",
        \\ lassign [binary encode -bitlength u4be 5] c1 bits1
        \\ lassign [binary encode -bitlength u4be 2] c2 bits2
        \\ lassign [binary encode -bitlength u4be 7] c3 bits3
        \\ set buf ""
        \\ set st {}
        \\ binary append -state st -bitlength $bits1 buf $c1
        \\ binary append -state st -bitlength $bits2 buf $c2
        \\ binary append -state st -bitlength $bits3 buf $c3
        \\ lassign [binary encode -bitlength u4be 6] patch_val patch_bits
        \\ binary patch -at 4 -bitlength $patch_bits buf u4be 6
        \\ string cat $buf | [binary decode {u4be u4be u4be} $buf]
    );
}

test "binary append and patch in place" {
    try memutil.checkAllocationFailures(.exhaustive, testBinaryAppendAndPatchInPlace, .{});
}

fn testBinaryCustomCodec(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // 300 in LEB128 varint is 0xAC 0x02, followed by "ok\x00".
    try interp.testExpectScriptResult("\xac\x02ok\x00|300 ok",
        \\ set varint {}
        \\ method varint::decode {self buf parsed} {
        \\     set result 0
        \\     set shift 0
        \\     while true {
        \\         lassign [binary decode -state self u8 $buf] byte
        \\         set result [expr {$result | (($byte & 0x7f) << $shift)}]
        \\         if {($byte & 0x80) == 0} {
        \\             return $result
        \\         }
        \\         incr shift 7
        \\     }
        \\ }
        \\ method varint::encode {self val all} {
        \\     set out ""
        \\     while true {
        \\         set byte [expr {$val & 0x7f}]
        \\         set val [expr {$val >> 7}]
        \\         if {$val != 0} { set byte [expr {$byte | 0x80}] }
        \\         append out [binary encode u8 $byte]
        \\         incr self::cursor 8
        \\         if {$val == 0} { return $out }
        \\     }
        \\ }
        \\ set schema [list [list id=custom call $varint] msg=str]
        \\ set bin [binary encode $schema {id 300 msg ok}]
        \\ set d [binary decode $schema $bin]
        \\ string cat $bin | [list $d::id $d::msg]
    );
}

test "binary custom codec" {
    try memutil.checkAllocationFailures(.exhaustive, testBinaryCustomCodec, .{});
}

fn testBinaryStructFloatPadAndHashRefs(ta: std.mem.Allocator) !void {
    var interp = try common.testStart(ta);
    defer common.testFinish(&interp);

    // Nested structs, f32be/f64le, pad, align_to, fixed-len str, and custom terminator + exact wire bytes:
    //   a=1.5 (f32be) -> 0x3FC00000 -> "\x3f\xc0\x00\x00"
    //   b=-2.25 (f64le) -> 0xC002000000000000 -> "\x00\x00\x00\x00\x00\x00\x02\xc0"
    //   flags=5 (u3be = 101b) + align_to 1 byte (5 zero bits) -> 0xA0 -> "\xa0"
    //   pt={x 10 y 20} -> "\x0a\x14"
    //   pad 2 bytes -> "\x00\x00"
    //   tag="hi" (str len 4) -> "hi\x00\x00"
    //   msg="world" (str term "\r\n") -> "world\r\n"
    try interp.testExpectScriptResult("\x3f\xc0\x00\x00\x00\x00\x00\x00\x00\x00\x02\xc0\xa0\x0a\x14\x00\x00hi\x00\x00world\r\n|1.5 -2.25 10 20 hi world",
        \\ set point_schema {x=u8 y=u8}
        \\ set outer_schema [list \
        \\     a=f32be \
        \\     b=f64le \
        \\     {flags=u3be} \
        \\     {align_to 1} \
        \\     [list pt=struct schema $point_schema] \
        \\     {pad 2} \
        \\     {tag=str len 4} \
        \\     {msg=str term "\r\n"} \
        \\ ]
        \\ set bin [binary encode $outer_schema {a 1.5 b -2.25 flags 5 pt {x 10 y 20} tag hi msg world}]
        \\ set d [binary decode $outer_schema $bin]
        \\ string cat $bin | [list $d::a $d::b $d::pt::x $d::pt::y $d::tag $d::msg]
    );

    // Copy-on-write when shared vs in-place when exclusively owned, plus blake3~ hash-ref preservation.
    const k_val = try String.newValue("k");
    defer k_val.dropReference();
    const v_val = try String.newValue("v");
    defer v_val.dropReference();
    const dict_obj = try Dictionary.new(&.{ k_val, v_val });
    defer dict_obj.asHead().dropReference();
    const ref_obj = try objects.HashReference.new(dict_obj.asHead());
    defer ref_obj.asHead().dropReference();

    const var_name = try String.newValue("shared_ref");
    defer var_name.dropReference();
    var var_shim: Shimmerable = .{ .original = var_name };
    defer var_shim.discardChanges();
    try interp.setVariable(&var_shim, ref_obj.asHead().asValue());

    try interp.testExpectScriptResult("0000ABCD|true",
        \\ set buf "0000"
        \\ binary append buf $shared_ref
        \\ set copy $buf
        \\ binary patch -at 0 buf {bytes len 4} "ABCD"
        \\ set extracted [string range $buf 4 end]
        \\ string cat [string range $copy 0 3] [string range $buf 0 3] | [string equal $extracted $shared_ref]
    );

    const extracted_name = try String.newValue("extracted");
    defer extracted_name.dropReference();
    var extracted_var_shim: Shimmerable = .{ .original = extracted_name };
    defer extracted_var_shim.discardChanges();
    const extracted_val = (try interp.getVariableTakingRef(&extracted_var_shim)).?;
    defer extracted_val.dropReference();

    var ref_shim: Shimmerable = .{ .original = extracted_val };
    defer ref_shim.discardChanges();
    const resolved_ref = try objects.HashReference.shimmerFrom(null, &ref_shim);
    try std.testing.expectEqual(dict_obj.asHead(), resolved_ref.ref);
}

test "binary struct float pad and hash refs" {
    try memutil.checkAllocationFailures(.exhaustive, testBinaryStructFloatPadAndHashRefs, .{});
}

const BinaryFuzzContext = struct {
    interp: *Interp,
    counting: *memutil.CountingAllocator,
    baseline_allocs: memutil.CountingAllocator.Snapshot,
    baseline_arena: memutil.ScopedArena.Snapshot,
    initial_var_count: usize,
};

const interned_fuzz_cmd = heap.InternedString.newValue("binary");
const interned_fuzz_decode = heap.InternedString.newValue("decode");
const interned_fuzz_encode = heap.InternedString.newValue("encode");
const interned_fuzz_patch = heap.InternedString.newValue("patch");
const interned_fuzz_append = heap.InternedString.newValue("append");
const interned_fuzz_extend = heap.InternedString.newValue("-extend");
const interned_fuzz_buf = heap.InternedString.newValue("fuzz_buf");

fn resetFuzzIterationState(ctx: *BinaryFuzzContext) void {
    var target_shim: Shimmerable = .{ .original = interned_fuzz_buf };
    defer target_shim.discardChanges();
    ctx.interp.setVariable(&target_shim, heap.interned_empty_string) catch unreachable;

    const vars = ctx.interp.callFrame().variables;
    while (vars.map.count() > ctx.initial_var_count) {
        const popped = vars.map.pop().?;
        popped.key.dropReference();
        popped.value.dropReference();
    }

    ctx.interp.setEmptyResult();
    ctx.interp.stack_trace.swapWithNone();
    ctx.interp.pending_error_code.swapWithNone();
    ctx.interp.pending_error_during.swapWithNone();

    if (ctx.interp.parsed_scripts.first != null) {
        var scripts = ctx.interp.parsed_scripts.valueIterator();
        while (scripts.next()) |script| script.*.asHead().dropReference();
        ctx.interp.parsed_scripts.clearRetainingCapacity();
    }
    if (ctx.interp.parsed_exprs.first != null) {
        var exprs = ctx.interp.parsed_exprs.valueIterator();
        while (exprs.next()) |expr| expr.*.asHead().dropReference();
        ctx.interp.parsed_exprs.clearRetainingCapacity();
    }
    if (ctx.interp.parsed_closures.first != null) {
        var closures = ctx.interp.parsed_closures.valueIterator();
        while (closures.next()) |closure| closure.*.asHead().deinit();
        ctx.interp.parsed_closures.clearRetainingCapacity();
    }
    if (ctx.interp.parsed_substs.first != null) {
        var substs = ctx.interp.parsed_substs.valueIterator();
        while (substs.next()) |subst| subst.*.asHead().dropReference();
        ctx.interp.parsed_substs.clearRetainingCapacity();
    }

    heap.local_arena_instance.restore(ctx.baseline_arena);
    if (@import("options").trace_mem) @import("../leak_check.zig").deinit();
}

fn testBinaryFuzzOne(ctx: *BinaryFuzzContext, smith: *testing.Smith) !void {
    {
        defer resetFuzzIterationState(ctx);

        var schema_buf: [128]u8 = undefined;
        var data_buf: [128]u8 = undefined;
        var values_buf: [128]u8 = undefined;

        const schema_len = smith.slice(&schema_buf);
        const data_len = smith.slice(&data_buf);
        const values_len = smith.slice(&values_buf);

        const schema_slice = schema_buf[0..schema_len];
        const data_slice = data_buf[0..data_len];
        const values_slice = values_buf[0..values_len];

        const interp = ctx.interp;

        // 1. Fuzz arbitrary raw schema strings and binary payloads through decode, encode, patch, and append.
        const schema_val = try String.newValue(schema_slice);
        defer schema_val.dropReference();
        const data_val = try String.newValue(data_slice);
        defer data_val.dropReference();
        const values_val = try String.newValue(values_slice);
        defer values_val.dropReference();

        {
            var target_shim: Shimmerable = .{ .original = interned_fuzz_buf };
            defer target_shim.discardChanges();
            try interp.setVariable(&target_shim, data_val);
        }

        // `binary decode <random_schema> <random_data>`
        {
            var call_args: [4]Shimmerable = .{
                .{ .original = interned_fuzz_cmd },
                .{ .original = interned_fuzz_decode },
                .{ .original = schema_val },
                .{ .original = data_val },
            };
            defer for (&call_args) |*a| a.discardChanges();
            _ = binaryCmd(interp, &call_args) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
        }

        // `binary encode <random_schema> <random_values>`
        {
            var call_args: [4]Shimmerable = .{
                .{ .original = interned_fuzz_cmd },
                .{ .original = interned_fuzz_encode },
                .{ .original = schema_val },
                .{ .original = values_val },
            };
            defer for (&call_args) |*a| a.discardChanges();
            _ = binaryCmd(interp, &call_args) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
        }

        // `binary patch -extend fuzz_buf <random_schema> <random_values>`
        {
            var call_args: [6]Shimmerable = .{
                .{ .original = interned_fuzz_cmd },
                .{ .original = interned_fuzz_patch },
                .{ .original = interned_fuzz_extend },
                .{ .original = interned_fuzz_buf },
                .{ .original = schema_val },
                .{ .original = values_val },
            };
            defer for (&call_args) |*a| a.discardChanges();
            _ = binaryCmd(interp, &call_args) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
        }

        // `binary append fuzz_buf <random_data> <random_values>`
        {
            var call_args: [5]Shimmerable = .{
                .{ .original = interned_fuzz_cmd },
                .{ .original = interned_fuzz_append },
                .{ .original = interned_fuzz_buf },
                .{ .original = data_val },
                .{ .original = values_val },
            };
            defer for (&call_args) |*a| a.discardChanges();
            _ = binaryCmd(interp, &call_args) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
        }

        // 2. Also synthesize a structured random schema from Smith tokens so deep decode/encode/patch paths get exercised.
        const token_pool = [_][]const u8{
            "u1be",
            "u3be",
            "u4be",
            "u5be",
            "u1le",
            "u3le",
            "u4le",
            "u5le",
            "u8",
            "i8",
            "u16be",
            "u16le",
            "i16be",
            "i16le",
            "u24be",
            "u24le",
            "u32be",
            "u32le",
            "i32be",
            "i32le",
            "u64be",
            "u64le",
            "f32be",
            "f32le",
            "f64be",
            "f64le",
            "str",
            "mark",
            "{align_to 1}",
            "{pad 1}",
            "{bytes len 2}",
            "{str len 3}",
            "{u8 count 2}",
            "{u8 enum {0 zero 1 one} default other}",
        };

        const field_count = smith.valueRangeAtMost(u8, 1, 6);
        var synth_schema_buf: [256]u8 = undefined;
        var synth_schema_len: usize = 0;
        var synth_vals_buf: [64]u8 = undefined;
        var synth_vals_len: usize = 0;

        var f_idx: u8 = 0;
        while (f_idx < field_count) : (f_idx += 1) {
            if (f_idx > 0) {
                synth_schema_buf[synth_schema_len] = ' ';
                synth_schema_len += 1;
                synth_vals_buf[synth_vals_len] = ' ';
                synth_vals_len += 1;
            }
            const tok = token_pool[smith.index(token_pool.len)];
            @memcpy(synth_schema_buf[synth_schema_len..][0..tok.len], tok);
            synth_schema_len += tok.len;
            synth_vals_buf[synth_vals_len] = '1';
            synth_vals_len += 1;
        }

        const synth_schema_val = try String.newValue(synth_schema_buf[0..synth_schema_len]);
        defer synth_schema_val.dropReference();
        const synth_vals_val = try String.newValue(synth_vals_buf[0..synth_vals_len]);
        defer synth_vals_val.dropReference();

        {
            var call_args: [4]Shimmerable = .{
                .{ .original = interned_fuzz_cmd },
                .{ .original = interned_fuzz_decode },
                .{ .original = synth_schema_val },
                .{ .original = data_val },
            };
            defer for (&call_args) |*a| a.discardChanges();
            _ = binaryCmd(interp, &call_args) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
        }

        {
            var call_args: [4]Shimmerable = .{
                .{ .original = interned_fuzz_cmd },
                .{ .original = interned_fuzz_encode },
                .{ .original = synth_schema_val },
                .{ .original = synth_vals_val },
            };
            defer for (&call_args) |*a| a.discardChanges();
            _ = binaryCmd(interp, &call_args) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
        }
    }

    try ctx.counting.expectMatchesSnapshot(ctx.baseline_allocs);
}

test "binary fuzz random schemas and data" {
    const backing_gpa = if (@import("builtin").fuzz) std.heap.c_allocator else testing.allocator;
    var counting = memutil.CountingAllocator.init(backing_gpa);

    var interp = try common.testStart(counting.allocator());
    defer common.testFinish(&interp);

    // Pre-warm arena and frame capacities before snapshotting live allocations.
    _ = try heap.local_arena.alloc(u8, 1);
    try interp.callFrame().variables.map.ensureTotalCapacity(heap.global_gpa, 128);
    try interp.eval_frames.ensureTotalCapacity(heap.global_gpa, 16);
    try interp.call_frames.ensureTotalCapacity(heap.global_gpa, 16);
    {
        var target_shim: Shimmerable = .{ .original = interned_fuzz_buf };
        defer target_shim.discardChanges();
        try interp.setVariable(&target_shim, heap.interned_empty_string);
    }

    var ctx: BinaryFuzzContext = .{
        .interp = &interp,
        .counting = &counting,
        .baseline_allocs = counting.takeSnapshot(),
        .baseline_arena = heap.local_arena_instance.takeSnapshot(),
        .initial_var_count = interp.callFrame().variables.count(),
    };

    try testing.fuzz(&ctx, testBinaryFuzzOne, .{
        .corpus = &.{
            "",
            "\x04u8\x00\x00\x01\xff\x011",
            "\x0cu4be u4be u8\x02\xab\xcd\x051 2 3",
            "\x0du3le u5le u16le\x03\x4d\x01\x02\x055 9 7",
            "\x14{bytes len 3} u32be\x07abcdefg\x06xyz 42",
        },
    });
}

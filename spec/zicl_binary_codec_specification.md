# Zicl Binary Codec Specification (`binary encode`, `binary decode`, `binary patch`, `binary append`)

This document specifies the design, grammar, semantics, and implementation blueprint for Zicl's binary codec subsystem, replacing traditional Tcl `binary format` and `binary scan` with a modern, bidirectional, bit-addressed codec engine.

---

## 1. Core Architecture & Philosophy

1. **First-Class Schemas as Native Lists:** Schemas are plain Zicl lists. Each field is exactly one list element (a bare word for defaults or a braced sublist for options).
2. **First-Class Return Values:** `binary decode` returns an immutable Zicl dictionary (or a list in anonymous mode) directly rather than mutating arbitrary variables in the caller's frame via side effects.
3. **Explicit Bit-Stream Addressing with Byte-Friendly Defaults:** All cursor movement internally tracks bit positions (`self::cursor`). Schema length and alignment modifiers (`pad`, `align`, `align_to`, `len`) default to **bytes**, using a `b` suffix for **bits** (`4` = 32 bits, `4b` = 4 bits). Cursor coordinates (`-at`, `-bitlength`, `mark`, `self::cursor`, `$_cursor`) are always in **bits**.
4. **Unified Bit & Byte Endianness:** Bit numbering within a byte and byte ordering across bytes follow a single unified endianness rule (`be` = MSB-first network order; `le` = LSB-first hardware/`packed struct` order). Switching between `le` and `be` requires byte alignment (`cursor % 8 == 0`).
5. **Compile-Time Static Alignment Safety:** Byte-oriented primitives (`u8`, `u16le`, `u32be`, `str`, `bytes`, etc.) require byte alignment by default. Layout errors (e.g. 7 bits preceding a multi-byte integer, or switching `le` $\leftrightarrow$ `be` mid-byte) are rejected during schema validation before execution.
6. **Universal Directional Postfixes:** Any modifier `foo` can be customized for directionality with `foo_encode` or `foo_decode` (e.g. `val_encode`, `call_decode`, `default_decode`).
7. **Stateful Monadic Codecs:** Custom codecs are invoked via `call` (`call_encode` / `call_decode`). The bit cursor lives at `self::cursor` in the state dictionary and threads linearly through the pass.

---

## 2. Command API

All cursor offsets and bit counts (`-at`, `-bitlength`, `mark`, `self::cursor`) are measured in **bits**. Binary buffers are always represented as raw byte strings.

```tcl
# Decode to a dictionary (named mode) or positional list (anonymous mode)
set result [binary decode ?-at bit_offset? ?-state stateVar? $schema $data]

# Encode to a byte buffer from a dictionary or positional list
# Errors if total bits emitted is not a multiple of 8, unless -bitlength is specified
# (which returns [list $bytes $total_bits]).
set bin [binary encode ?-state stateVar? ?-bitlength? $schema $values]

# Overwrite bits/bytes in-place (COW) at an exact bit coordinate without manual buffer slicing
# Errors if patch exceeds buffer bounds, unless -extend is specified.
binary patch ?-at bit_offset? ?-state stateVar? ?-extend? ?-bitlength $bit_len? targetVar $type_or_schema $value

# Concatenate byte or non-byte-aligned bit buffers in-place (COW) at a bit coordinate
binary append ?-at bit_offset? ?-state stateVar? ?-bitlength $bit_len? ?-endian le|be? targetVar $chunk ?$chunk ...?
```

### State Threading (`-state stateVar`)
* If `-state stateVar` is supplied, the engine reads/initializes `stateVar` (defaulting `cursor` to `0` if not present, or to `bit_offset` if `-at` is also provided) and writes updated state (including `cursor` and any `mark` coordinates) back to `stateVar` in the caller's scope upon completion.
* If `-state` is omitted, a temporary `{cursor 0}` dictionary is used for the duration of the call and discarded at the end.

### Return & Input Modes
* **Named Mode:** If any field's type token in `$schema` has a `name=` prefix, `binary decode` returns a Zicl dictionary, and `binary encode` accepts a dictionary.
  * If named and unnamed fields are mixed (e.g., `{ {u16be val 0xCAFE} payload=bytes }`), unnamed fields are dropped from the decoded dictionary and do not require entries in the encode dictionary.
* **Anonymous Mode:** If all fields omit `name=` (e.g., `{u8 u16be str}`), `binary decode` returns a flat Zicl list, and `binary encode` accepts a positional list of values.
  * Stream directives (`pad`, `align`, `align_to`) neither consume nor produce positional elements.
  * If a conditional field (`cond`) evaluates to false in anonymous mode, `binary decode` emits `""` at that index to preserve positional alignment; in named mode, the key is simply omitted from the dictionary.

---

## 3. Schema Syntax & Grammar

Every element in the `$schema` list is one of:
1. **Bare word:** `[name=]base_type` (parsed on the first `=` in the type token)
2. **Braced sublist:** `{[name=]base_type opt1 val1 opt2 val2 ...}`
3. **Stream Directive:** `{align 4}`, `{align_to 4}`, `{pad 16b}`

```tcl
set ipv4_schema [list \
    version=u4be \
    ihl=u4be \
    tos=u8 \
    total_len=u16be \
    id=u16be \
    flags=u3be \
    frag_offset=u13be \
    ttl=u8 \
    proto=u8 \
    {checksum=u16be val_encode 0} \
    src_ip=u32be \
    dst_ip=u32be \
    {options=bytes len {($ihl - 5) * 4}} \
    {payload=bytes len {$total_len - ($ihl * 4)}} \
]
```

---

## 4. Base Primitives & Endianness

### Unified Bit & Byte Endianness
Byte endianness and bit endianness follow one unified rule:
* **Big-Endian (`be`):** Within each byte, bits are numbered from **MSB (`bit 7`) down to LSB (`bit 0`)**. Across bytes, earlier bits in the stream are placed into the **more-significant** bits of the integer (`acc = (acc << take) | bits`).
* **Little-Endian (`le`):** Within each byte, bits are numbered from **LSB (`bit 0`) up to MSB (`bit 7`)**. Across bytes, earlier bits in the stream are placed into the **less-significant** bits of the integer (`acc |= bits << bits_read_so_far`).
* **Mid-Byte Endianness Rule:** Switching between `le` and `be` is only valid on a byte boundary (`cursor % 8 == 0`). Attempting to switch between `le` and `be` while `cursor % 8 != 0` is rejected statically (and at runtime after dynamic bit-length fields).

### Primitive Table

| Type | Default Alignment | Description |
| :--- | :--- | :--- |
| **`u1`**, **`i1`**, **`u1le`**, **`u1be`**, **`i1le`**, **`i1be`** | `1b` (1 bit) | Single-bit unsigned (`0`..`1`) or signed (`-1`..`0`) integer. Bare `u1`/`i1` inherit the active bit-endianness of the current byte (defaulting to `be` at byte boundaries). |
| **`u2le`..`u64le`**, **`u2be`..`u64be`**, **`i2le`..`i64le`**, **`i2be`..`i64be`** (non-multiples of 8) | `1b` (1 bit) | Unaligned bit-stream integers. Sequential bit-packing without implicit padding. Signed `iN` values are two's-complement sign-extended from $N$ bits. |
| **`u8`**, **`i8`**, **`u8le`**, **`u8be`**, **`i8le`**, **`i8be`** | `1` (1 byte / `8b`) | Single-byte integers. |
| **`u16le`**, **`u16be`**, **`u24le`**, **`u24be`**, **`u32le`**, **`u32be`**, **`u64le`**, **`u64be`**, **`i16le`**, **`i16be`**, etc. | `1` (1 byte / `8b`) | Byte-aligned multi-byte integers (can be relaxed to bit-aligned via `align 1b`). Integers exceeding `i64` range (`>= 2^63` or bit widths `> 64`) are represented as decimal strings (or big ints). |
| **`f32le`**, **`f32be`**, **`f64le`**, **`f64be`** | `1` (1 byte / `8b`) | IEEE-754 floating-point numbers. |
| **`str`** | `1` (1 byte / `8b`) | Null-terminated string (`term "\x00"` default). Fixed slots (`len N`) are zero-padded on encode and stripped of trailing terminators on decode. Interior null bytes before the terminator raise an error. |
| **`bytes`** | `1` (1 byte / `8b`) | Raw byte string. Requires explicit `len`, `prefix`, or `term`. |
| **`mark`** | `1b` (1 bit) | Zero-width coordinate snapshot. Binds the current `self::cursor` (bit offset) to `name` in the `-state` dict (and decoded result dict). Consumes/emits 0 bits. |
| **`struct`** | Matches sub-schema | Runs a nested sub-schema specified via `schema <list>`. Returns/takes a dictionary (or list). |
| **`custom`** | `1b` (1 bit) | Invokes a custom codec via `call`, `call_encode`, or `call_decode`. |

---

## 5. Sublist Modifiers & Options

All options support directional overrides: `foo_encode` and `foo_decode`.

| Modifier | Argument | Description |
| :--- | :--- | :--- |
| **`cond`** | `<expr>` | Conditional field presence. Evaluated first; if falsy, the entire field (including `align`/`align_to`) is skipped and reads/writes 0 bits. |
| **`align_to`** | `<N>[b]` | Pads cursor forward (zero-filling on encode, skipping on decode) to the next multiple of $N$ bytes (or bits with `b`). |
| **`align`** | `<N>[b]` | Pure assertion (and override for a primitive's default alignment). Verifies `self::cursor % align == 0`. Errors on mismatch. |
| **`pad`** | `<N>[b]` | Skips (decode) or zero-fills (encode) a fixed count of bytes (or bits with `b`). |
| **`count`** | `<expr>` | Element repetition factor for arrays/lists. Loops the element (including any `prefix`) `count` times. |
| **`prefix`** | `<int_type>` | Fused byte-length framing (`prefix u8`, `prefix u16be`). Reads/writes the byte length of the following element immediately preceding its content. |
| **`len`** | `<expr>` | Dynamic length in bytes (or bits if suffixed with `b`). Evaluated via `expr`. |
| **`term`** | `<string>` | Single or multi-byte delimiter (e.g. `term "\r\n\r\n"`). |
| **`schema`** | `<list>` | Nested schema list for `struct` fields. |
| **`call`** | `<cmd_or_dict>` | Custom codec handler. `call $codec` invokes `$codec::decode` on decode and `$codec::encode` on encode. Directional `call_decode` and `call_encode` take a command/closure directly. |
| **`enum`** | `<dict>` | Bi-directional mapping `{wire_int symbol ...}`. Non-injective duplicates are allowed in the dict and only error if `encode` attempts to encode an ambiguous symbol. |
| **`default`** | `<literal\|expr>` | Fallback value when `enum` lookup fails (without `default`, unmapped `enum` values raise an error), or when a field is omitted from `$values` during `encode`. |
| **`val`** | `<literal\|expr>` | On encode: value to emit (need not be passed in `$values`). On decode: asserts decoded value (after `enum` translation, if any) equals this value. |

### Modifier Evaluation Order
When multiple modifiers are present on a single field, they execute in this order:
1. **`cond`**: If false, stop immediately (0 bits read/written; no alignment checked).
2. **`align_to`**, then **`align`**: Pad and/or verify cursor alignment.
3. **`count`**: Repeat steps 4–7 `count` times, collecting elements into a Zicl list.
4. **`prefix` / `len` / `term`**: Determine framing for the individual element.
5. **Primitive / `schema` / `call`**: Read or write the raw value.
6. **`enum` & `default`**: Translate between wire integer and symbolic string, applying `default` if unmapped.
7. **`val`**: Assert (decode) or supply (encode) the post-`enum` value.

---

## 6. Expression Environment Scope

Expressions inside modifiers (`len`, `val`, `cond`, `count`, `default`) are evaluated against a scope containing:
* All previously decoded field names (in `decode`).
* All user-supplied input values and previously encoded fields (in `encode`).
* **`$_`**: The immediately preceding decoded/encoded field value.
* **`$_buf`**: The raw input buffer string (in `decode`) or the bytes encoded so far (lazily materialized in `encode` if referenced).
* **`$_cursor`**: The current bit offset (`self::cursor`).

---

## 7. Custom Codec Contract (`call` / `call_encode` / `call_decode`)

Custom codecs can be provided as a dictionary with `encode` and `decode` methods via `call $varint`, or as separate functions via `call_decode` / `call_encode`:

```tcl
set varint {}

method varint::decode {self buf parsed} {
    set result 0
    set shift 0
    while 1 {
        lassign [binary decode -state self u8 $buf] byte
        set result [| $result [<< [& $byte 0x7f] $shift]]
        if {![& $byte 0x80]} {
            return $result
        }
        incr shift 7
    }
}

method varint::encode {self val all} {
    set out ""
    while 1 {
        set byte [& $val 0x7f]
        set val [>> $val 7]
        if {$val != 0} { set byte [| $byte 0x80] }
        append out [binary encode u8 $byte]
        incr self::cursor 8
        if {$val == 0} { return $out }
    }
}

# Usage in a schema:
set schema [list {id=custom call $varint} payload=bytes]
```

* The state dictionary (from `-state stateVar`, or a temporary `{cursor 0}` dictionary if omitted) is passed as `self`.
* `decode` reads from `buf`, advances `self::cursor` (either via `binary decode -state self` or `incr self::cursor <bits>`), and returns the decoded value.
* `encode` advances `self::cursor` by the exact number of bits emitted and returns the encoded byte string. If `self::cursor` advances by a non-multiple of 8 bits, the engine truncates the returned byte string to the exact bit delta.

---

## 8. Multi-Pass Protocols & `binary patch`

For container formats like ELF, Mach-O, or forward CRCs:
1. **Pass 1:** Serialize header with placeholder constants and snapshot bit coordinates into `-state` with `mark`:
   ```tcl
   set elf_header [list \
       {ident=u32be val 0x7f454c46} \
       shoff_loc=mark \
       {shoff=u32le val_encode 0} \
   ]
   set state {}
   set bin [binary encode -state state $elf_header $metadata]
   ```
2. **Pass 2:** Append payload sections, compute real offsets/checksums, and stamp in-place via `binary patch` using the recorded bit offset `$state::shoff_loc`:
   ```tcl
   binary patch -at $state::shoff_loc bin u32le $actual_shoff
   ```

---

## 9. Zig Engine Architecture (`src/binary.zig`)

### Zero-Copy / Scratch-Buffered `BitReader`
```zig
pub const BitReader = struct {
    source: []const u8,
    bit_pos: usize = 0,
    last_bit_endian: ?std.builtin.Endian = null,

    fn checkBitBounds(self: *const BitReader, bit_count: usize) !void {
        const total_source_bits = std.math.mul(usize, self.source.len, 8) catch return error.EndOfStream;
        const end_bit = std.math.add(usize, self.bit_pos, bit_count) catch return error.EndOfStream;
        if (end_bit > total_source_bits) return error.EndOfStream;
    }

    fn checkEndianTransition(self: *BitReader, endian: std.builtin.Endian) !void {
        if (self.bit_pos % 8 == 0) {
            self.last_bit_endian = endian;
        } else if (self.last_bit_endian) |prev| {
            if (prev != endian) return error.MidByteEndianSwitch;
        } else {
            self.last_bit_endian = endian;
        }
    }

    /// Reads `buffer.len` whole bytes (`buffer.len * 8` bits).
    /// - Aligned (`bit_pos % 8 == 0`): returns zero-copy slice into `source`.
    /// - Unaligned (`bit_pos % 8 != 0`): stitches bits into `buffer` using active bit endianness.
    pub fn readBytes(self: *BitReader, buffer: []u8) ![]const u8 {
        const total_bits = std.math.mul(usize, buffer.len, 8) catch return error.EndOfStream;
        try self.checkBitBounds(total_bits);

        const bit_rem: u3 = @intCast(self.bit_pos % 8);
        const byte_idx = self.bit_pos / 8;

        if (bit_rem == 0) {
            self.bit_pos += total_bits;
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

        // Fast path for byte-aligned whole-byte reads.
        if (self.bit_pos % 8 == 0 and bit_count % 8 == 0) {
            const byte_idx = self.bit_pos / 8;
            const byte_len = bit_count / 8;
            self.bit_pos += bit_count;
            return std.mem.readVarInt(u64, self.source[byte_idx .. byte_idx + byte_len], endian);
        }

        var acc: u64 = 0;
        var bits_read: u7 = 0;
        var remaining: u7 = bit_count;

        while (remaining > 0) {
            const byte_idx = self.bit_pos / 8;
            const bit_rem: u3 = @intCast(self.bit_pos % 8);
            const avail: u4 = @as(u4, 8) - bit_rem;
            const take: u4 = @min(remaining, avail);

            const mask: u8 = if (take == 8) 0xFF else (@as(u8, 1) << @intCast(take)) - 1;
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
        return acc;
    }
};
```

### Static Alignment & Endianness Validator
```zig
pub fn validateSchemaAlignment(fields: []const FieldSpec) !void {
    // Known static bit offset from the start of the schema (null when dynamic).
    var known_bit_offset: ?usize = 0;
    // Even when exact offset is unknown, we may still know that the cursor is byte-aligned (mod 8 == 0).
    var is_byte_aligned: bool = true;
    var active_byte_endian: ?std.builtin.Endian = null;

    for (fields) |field| {
        if (field.has_cond) {
            // A conditional field may or may not execute at runtime; after it runs,
            // static alignment is only preserved if the conditional field's width is a byte multiple.
            if (!field.alwaysByteMultiple()) {
                known_bit_offset = null;
                is_byte_aligned = false;
                active_byte_endian = null;
            }
            continue;
        }

        if (field.align_to_bits) |align_to| {
            if (known_bit_offset) |off| {
                const rem = off % align_to;
                if (rem != 0) known_bit_offset = off + (align_to - rem);
            }
            if (align_to % 8 == 0) {
                is_byte_aligned = true;
                active_byte_endian = null;
            }
        }

        if (field.requiredAlignmentBits()) |req_align| {
            if (known_bit_offset) |off| {
                if (off % req_align != 0) return error.StaticAlignmentError;
            } else if (req_align == 8 and !is_byte_aligned) {
                return error.UnalignedByteType;
            }
        }

        if (field.bitEndian()) |endian| {
            if (!is_byte_aligned) {
                if (active_byte_endian) |prev| {
                    if (prev != endian) return error.MidByteEndianSwitch;
                }
            }
            active_byte_endian = endian;
        }

        if (field.fixedBitWidth()) |bits| {
            if (known_bit_offset) |off| {
                known_bit_offset = off + bits;
                is_byte_aligned = (known_bit_offset.? % 8 == 0);
            } else if (bits % 8 != 0) {
                is_byte_aligned = false;
            }
            if (is_byte_aligned) active_byte_endian = null;
        } else if (field.alwaysByteMultiple()) {
            known_bit_offset = null;
            // Preserves existing `is_byte_aligned` state.
        } else {
            known_bit_offset = null;
            is_byte_aligned = false;
            active_byte_endian = null;
        }
    }
}
```
# `Object.extra` & Future Rope / Zero-Copy Slice Design

This document captures:
1. **Near-Term Refactor:** Replacing `SpecialString` indirection with a direct `Object.string` pointer (`u64` length for future `mmap` support) plus a nullable ref-counted `Object.extra` pointer.
2. **Shelved Future Optimization (Pending Benchmarks):** Extending `Extra` with zero-copy slices and lock-free ropes using `Capability`-style in-flight reference tracking.

---

## Part 1: Replacing `SpecialString` with `Object.extra` and `u64` Length

### Motivation
Currently, `Object.string` is a tagged `*anyopaque` that points to either a raw `[*:0]u8` (with a `u16` length in `StringMetadata`) or a `*SpecialString` (when `len > 1024` or `blake3~` hashes are present). This has three drawbacks:
1. **Double pointer indirection on large strings:** Reading a `SpecialString` requires chasing `Object.string -> SpecialString -> slice.ptr`.
2. **Duplicated metadata across types:**
   * `SpecialString` tracks `utf8_length` and `hash: ?*u256`.
   * `objects.String` separately tracks `codepoint_length` in its body.
   * `objects.Source` separately tracks `hash: ?*u256` in its body.
3. **`u16` length ceiling on direct strings:** Supporting large `mmap`-backed files requires 64-bit byte lengths (`u64`).

### Design

#### 1. `Object` Header Fields
* **`string`**: `std.atomic.Value(?[*]u8)` — Always points directly to the contiguous byte buffer once materialized, regardless of whether `extra` is present.
* **`string_metadata` / `string_len`**: Tracks `has_value` and a full `u64` byte length so multi-gigabyte `mmap` regions work natively without a separate length lookup in `extra`.
* **`extra`**: `std.atomic.Value(?*Extra)` — Nullable pointer to a ref-counted `Extra` struct when the string has extended properties or cached metadata.

#### 2. `Extra` Responsibilities
`Extra` is ref-counted (`std.atomic.Value(u32)`) so `Object.duplicateHeadOnto` can share it in $O(1)$ while `dest.string` aliases `src.string` directly:

```zig
pub const Extra = struct {
    pub const Backing = union(enum) {
        /// Standard heap allocation (`string[0..len :0]`).
        heap: [:0]u8,
        /// Overallocated heap buffer for amortized O(1) in-place `[append]`.
        different_capacity: struct {
            string: [:0]u8,
            original_capacity: u64,
        },
        /// Future: Memory-mapped file backing (`munmap` on deinit).
        mmap: []align(std.heap.page_size_min) const u8,
    };

    backing: Backing,
    utf8_length: std.atomic.Value(u64) = .init(std.math.maxInt(u64)),
    tracked_hashes: []HashAndInfo = &.{},
    hash: std.atomic.Value(?*u256) = .init(null),
    ref_count: std.atomic.Value(u32) = .init(1),
};
```

#### 3. Ownership, Duplication, and Deinitialization
* **Fast-path `getString(obj)`:**
  Once `has_value` is true, `getString()` simply reads `obj.string` and the `u64` length directly from `Object`—zero indirection through `extra`.
* **Deinitialization / `invalidateString(obj)`:**
  If `obj.extra` is non-null, `extra` owns the underlying buffer (`obj.string` merely aliases it):
  ```zig
  if (obj.extra.load(.acquire)) |extra| {
      extra.decrRefCount();
  } else if (obj.getStringSlice()) |slice| {
      heap.global_gpa.free(slice);
  }
  ```
* **`duplicateHeadOnto(src, dest)`:**
  * If `src.extra` is non-null: `extra.incrRefCount()`, `dest.extra = extra`, and `dest.string = src.string` (zero-copy aliasing).
  * If `src.extra` is null and `src.string` is non-null: duplicate the small string slice (or promote to `Extra` if zero-copy sharing is desired).

---

## Part 2: Shelved Future Design — Ropes & Zero-Copy Slices in `Extra`

> **Status:** Shelved until benchmarks demonstrate a bottleneck with flat/overallocated buffers.

### Overview
Because `Object.extra` survives type shimmering (unlike `Object.vtable`), `Extra.Backing` can represent unflattened ropes and zero-copy slices while `Object.string` remains `null` (`has_value = false`) until a caller invokes `getString()`.

```zig
pub const Backing = union(enum) {
    heap: [:0]u8,
    different_capacity: struct {
        string: [:0]u8,
        original_capacity: u64,
    },
    mmap: []align(std.heap.page_size_min) const u8,

    /// Zero-copy byte slice into another `Extra`'s buffer.
    slice: struct {
        parent: *Extra,
        offset: u64,
        len: u64,
    },

    /// Concatenation tree node.
    rope: struct {
        left: *Extra,
        right: *Extra,
        total_len: u64,
        depth: u8,
        state: std.atomic.Value(RopeState) = .init(.{}),
    },
};
```

### Key Mechanics

1. **Seam-Only `blake3~` Scanning on Concatenation:**
   When concatenating `left` and `right` into a `.rope`, neither child needs to be rescanned for `blake3~<43-char-hash>` references—each child already tracks its own references. Only the 49-byte boundary window (`left[left.len -| 49 ..] ++ right[0 .. @min(49, right.len)]`) needs to be checked for a hash reference split across the seam.

2. **Sharing Across Multiple `Object`s:**
   If `obj1` (`string = null, extra = E`) is duplicated into `obj2` before flattening, both point to `E`. When `obj1.getString()` flattens `E`, `E.backing` transitions from `.rope` to `.heap` and sets `obj1.string`. When `obj2.getString()` is later called, it sees `E.backing` is already `.heap` and simply aliases `obj2.string = E.backing.heap.ptr`.

3. **Lock-Free Concurrent Flattening via `in_flight` Counter:**
   Following the pattern in [`src/Capability.zig`](file:///home/mason/dev/zig/zicl/src/Capability.zig#L161-L231):
   ```zig
   const RopeState = packed struct(u32) {
       in_flight: u31 = 0,
       flattened: bool = false,
   };
   ```
   * Before walking a `.rope` node to copy its leaf bytes, a thread calls `markInFlight()` (incrementing `in_flight` via CAS if `flattened == false`).
   * If `flattened == true`, another thread already flattened this node, so the caller copies directly from the node's flattened buffer instead of recursing into `left`/`right`.
   * As the flattener descends into any child `.rope` nodes, it also scopes `child.markInFlight()` / `defer child.dropInFlight()` on each child node so concurrent flatteners of subtrees cannot free `left`/`right` out from under the root flattener.
   * The thread that wins the CAS to install the flattened buffer sets `flattened = true`.
   * In `dropInFlight()`, the last thread to decrement `in_flight` to `0` when `flattened == true` (using `.acq_rel` ordering) calls `left.decrRefCount()` and `right.decrRefCount()` to reclaim the intermediate tree nodes.

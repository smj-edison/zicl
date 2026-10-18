# `SpecialString` Extensions (`mmap`, Slices, and Ropes)

> **Status:** Shelved for future work / benchmarking.

## Why Keep `SpecialString` Multiplexed in `Object.string`

`Object` is carefully sized at **80 bytes** (`32`-byte header + `48`-byte `body_backing`).
Moving `SpecialString` to a separate `Object.extra` pointer and widening `Object`'s inline string length to `u64` would add 16 bytes to **every** `Object` in the heap (96 bytes total, +20% memory overhead).

Keeping `SpecialString` multiplexed inside `Object.string` via `string_metadata.is_special` avoids that overhead completely:
1. **Short strings ($\le 1024$ bytes, no `blake3~` refs):** Stored directly in `Object.string` with `StringMetadata.len` (`u16`)—zero indirection and zero extra header bytes.
2. **Large strings ($> 1024$ bytes), `blake3~`-bearing strings, `mmap` files, and ropes:** Stored in `*SpecialString`, which already carries full 64-bit (`usize` / `u64`) lengths and atomic ref-counting for $O(1)$ sharing across `Object.duplicateHeadOnto`.

---

## Future `SpecialString.Type` Extensions

```zig
pub const Type = union(enum) {
    /// Standard heap allocation (`> 1024` bytes or containing `blake3~` hashes).
    normal: [:0]u8,

    /// Overallocated heap buffer for amortized O(1) in-place `[append]`.
    different_capacity: struct {
        string: [:0]u8,
        original_capacity: u64,
    },

    /// Memory-mapped file backing (`munmap` on deinit).
    /// Supports 64-bit file lengths without growing `Object`.
    mmap: []align(std.heap.page_size_min) const u8,

    /// Zero-copy byte slice into another `SpecialString`.
    slice: struct {
        parent: *SpecialString,
        offset: u64,
        len: u64,
    },

    /// Concatenation tree node (lazily flattened on `getString()`).
    rope: struct {
        left: *SpecialString,
        right: *SpecialString,
        total_len: u64,
        depth: u8,
        state: std.atomic.Value(RopeState) = .init(.{}),
    },
};
```

---

## Shelved Rope & Slice Mechanics

1. **In-Place `[append]` via `.different_capacity` (First Step Before Ropes):**
   Before introducing `.rope`, wiring `[append]` and `binary append` to mutate `.different_capacity` in place when `obj.canMutate()` and `special.ref_count == 1` provides amortized $O(1)$ appends with flat buffers.

2. **Seam-Only `blake3~` Scanning on Concatenation:**
   When concatenating `left` and `right`, neither child needs to be rescanned for `blake3~<43-char-hash>` references—each child already tracks its own references. Only the 49-byte boundary window (`left[left.len -| 49 ..] ++ right[0 .. @min(49, right.len)]`) needs to be checked for a hash reference split across the seam.

3. **Lock-Free Concurrent Rope Flattening via `in_flight` Counter:**
   Following the pattern in [`src/Capability.zig`](file:///home/mason/dev/zig/zicl/src/Capability.zig#L161-L231):
   ```zig
   const RopeState = packed struct(u32) {
       in_flight: u31 = 0,
       flattened: bool = false,
   };
   ```
   * Before walking a `.rope` node to copy its leaf bytes, a thread calls `markInFlight()` (incrementing `in_flight` via CAS if `flattened == false`).
   * If `flattened == true`, another thread already flattened this node, so the caller reads directly from the node's flattened buffer instead of recursing into `left`/`right`.
   * As the flattener descends into any child `.rope` nodes, it also scopes `child.markInFlight()` / `defer child.dropInFlight()` on each child node so concurrent flatteners of subtrees cannot free `left`/`right` out from under the root flattener.
   * The thread that wins the CAS to install the flattened buffer sets `flattened = true`.
   * In `dropInFlight()`, the last thread to decrement `in_flight` to `0` when `flattened == true` (using `.acq_rel` ordering) calls `left.decrRefCount()` and `right.decrRefCount()` to reclaim the intermediate tree nodes.

# Zicl: Dictionary Shapes and Parent-Lookup Caching

Implementation spec for adding hidden-class "shapes" to Zicl dictionaries, plus an id-validated cache for parent-chain (`~parent`) lookups.

## Before you write code

1. **Survey first.** Find and read:
   - the dictionary object type and its body struct
   - the object header (refcount, `cross_thread` flag, vtable)
   - `HashRegistry` and `makeCrossthread()`
   - `canShimmer`
   - the parent-chain (`~parent`) lookup path
   - the existing variable caches (`CachedLocalVar` / `CachedLexicalVar` and their epoch)
   - how per-thread / worker state is represented
2. **Report back before implementing** with:
   - a short map of where each piece of this spec lands
   - anything in this spec that contradicts the existing code
   - the exact current semantics for duplicate keys in a dict string rep (see "Semantics to preserve")

   Do not guess at an API that already exists. Use the codebase's existing names and conventions, including its refcount method names.
3. Work in the phases below. Each phase ends with its tests passing, including under TSan where noted, before you start the next.

## Non-negotiable invariants

- **EIAS.** Shapes are an internal-representation optimization only. A dict's string rep, iteration order, and every observable behavior must be identical with and without shapes. Never let a shape id, mutation id, or internal hash appear in any string rep.
- **Recoverable OOM.** Every allocation is fallible and propagates `error.OutOfMemory`.
  - A failed `dict set` / `dict unset` / transition leaves the dict semantically unchanged.
  - Do all fallible work (shape lookup or creation, value-array growth) before mutating the dict.
  - No `catch unreachable` on allocation paths.
- **Insertion order.** Zicl guarantees dict insertion order, and shapes must preserve it exactly.
- **Crossthread objects are frozen.** They never shimmer or mutate in place. This is what makes the design below safe.
- **No deep recursion on teardown.** Shape chains can be long. Freeing a shape chain must be iterative, because MCU stacks are small and NRE is on the roadmap.

## Semantics to preserve

- **Updating an existing key** keeps its position and does not change the shape.
- **Unset, then re-set:** the key moves to the end.
- **Duplicate keys in a string rep** (for example `a 1 b 2 a 3`): match Zicl's current behavior exactly. The Tcl convention is that the key keeps its first position and takes the last value (`a 3 b 2`). Verify what Zicl does now and keep it. Shape construction from parsing must agree with the string order.

## Design overview

There are two shape types:

- **`CrossthreadShape`** is canonical and globally interned (hash-consed). There is exactly one per distinct key sequence process-wide. It is immutable after creation and has an atomic refcount.
- **`ThreadlocalShape`** is a per-thread proxy for one `CrossthreadShape`. It has a non-atomic local refcount, holds one atomic reference on its global shape, and owns the thread-local transition edges.

Thread-local dicts point at a `ThreadlocalShape`, and crossthread (frozen) dicts point at a `CrossthreadShape`. The object's existing `cross_thread` flag says which one.

Identity uses **u64 ids that are never reused**:
- Every `CrossthreadShape` gets a unique `id`, and its `ThreadlocalShape`s copy it. So the same layout has the same id on every thread.
- Caches compare ids and never hold shape references. A stale cache entry can only miss, never falsely hit, so there is no ABA problem.

### Why interning instead of a cryptographic Merkle hash

Shapes are hash-consed on `(parent, key)`. The parent is already canonical, so verifying an intern-table hit is O(1): compare `entry.parent_id == parent.id` and the key bytes.

The table hash is therefore only for finding entries, never for deciding identity, and can be a fast non-cryptographic mix:

```
mix(parent.id, key.hash)
```

Reuse the key's existing string hash. **Do not use Blake3 here.**

## Data structures

Put `id: u64` at offset 0 in both shape structs, so an inline-cache check reads `dict.shape.id` without branching on local vs. crossthread.

```zig
const CrossthreadShape = struct {
    id: u64,                       // offset 0, unique, never reused
    rc: std.atomic.Value(u32),     // match existing refcount width/conventions
    parent: ?*CrossthreadShape,    // owns one reference; null for the empty shape
    key: <existing string/object ref type>,  // owns a reference
    depth: u32,                    // number of keys; this shape's key is slot depth-1
    // Lazily built, published with CAS (the loser frees its copy):
    flat_keys: std.atomic.Value(?*KeyArray),     // insertion-ordered keys
    lookup: std.atomic.Value(?*KeyIndexTable),   // only built when depth > 8
};

const ThreadlocalShape = struct {
    id: u64,                       // offset 0, copy of global.id
    local_rc: u32,                 // non-atomic
    global: *CrossthreadShape,     // holds one atomic reference while this exists
    transitions: <small map key -> *ThreadlocalShape>,  // thread-local edges
    lru_node: <intrusive node for the parking LRU>,
};
```

- **Slot index equals insertion position.** The key added at depth `d` lives at slot `d`. So the dict's values array is already in insertion order, and iteration zips `flat_keys` with values.
- **`flat_keys`** is built on first need by walking the parent chain. It is immutable once published. Sharing prefix arrays across a chain (V8 descriptor-array style) is a possible later optimization. Do not do it in v1.
- **`lookup`** maps key to slot. It is built lazily for shapes with more than 8 keys. Below that, scan `flat_keys` linearly.
- The empty shape is a single immortal `CrossthreadShape` with id 1. Each thread has one `ThreadlocalShape` for it.

### Dictionary body

The body holds:
- a shape pointer (`*ThreadlocalShape` or `*CrossthreadShape`, chosen by the `cross_thread` flag)
- a values array whose length equals the shape's depth (with spare capacity)

Keep the existing hash-table representation as **dictionary mode** (see below).

## Id allocation

- A single global `std.atomic.Value(u64)` counter.
- Each thread reserves blocks with `fetch_add(4096)` and hands out ids locally. Ids only need uniqueness, not ordering.
- 0 means "unassigned" and is never handed out.
- Shape ids and object mutation ids may share the counter or use separate ones. Separate counters are preferred for readable dumps.

## Global intern table

- Maps `(parent_id, key bytes)` to `*CrossthreadShape`.
- Lock-striped buckets. The only write operation is insert-if-absent.
- **Lookup must use increment-if-nonzero:** a CAS loop on `rc` that fails when `rc == 0`. If it fails, treat the entry as absent: the shape is dying and will unregister itself. Create a new shape with a **new id**.
- **Release:**
  1. On the final release (rc reaches 0), lock the bucket.
  2. Remove the entry **only if it still points to this shape**, since a replacement may already be registered.
  3. Unlock.
  4. Release `key`.
  5. Release `parent` iteratively: loop up the chain while each release hits zero.
  6. Free `flat_keys`, `lookup`, and the shape itself.
- **The intern key must use the parent's id, never its pointer.** A freed parent's address can be reused, which would create a false match.

## Per-thread shape context

Each worker thread owns a context with:

- **`by_global`**: a map from `*CrossthreadShape` to `*ThreadlocalShape`. It is used when a thread copies a crossthread dict and needs its local proxy.
- **A parking LRU** of fixed capacity (start at 64; make it a build option). When a `ThreadlocalShape`'s `local_rc` reaches 0, park it instead of freeing it. It keeps its global reference, so its id stays stable and inline caches keep hitting. Evicting from the LRU frees it: release the global reference, remove it from `by_global`, and unlink it from its parent's `transitions`.
- **Its id block.**

On thread exit, release every `ThreadlocalShape` the context owns.

### Transition (local dict, adding a new key `k`)

1. Look up `k` in `shape.transitions`. On a hit, the result is the child.
2. On a miss:
   1. Intern `(shape.global.id, k)` in the global table, creating it if absent. This returns a `CrossthreadShape` with a reference held.
   2. Look up `by_global` in case this thread already has a proxy, for example one created via copy-on-write.
   3. Otherwise create a new `ThreadlocalShape`.
   4. Record the edge in `shape.transitions`.
3. Grow the values array if needed. **All of steps 1–3 happen before the dict changes.**
4. Commit: swap the dict's shape (local refcount +1 on the child, −1 on the old shape) and store the value at slot `depth - 1`.

### Going crossthread (`makeCrossthread` on a dict)

The order of these steps is **required**:

1. Read `tl = dict.shape`, and follow it to `g = tl.global`.
2. **Take an atomic reference on `g` first.**
3. Point the dict at `g`. It is now a crossthread dict.
4. **Then drop the local reference on `tl`.**

If step 4 happened before step 2, it could free `tl`, which releases its global reference and could free `g` before it is pinned.

### Copy-on-write of a crossthread dict

Resolve the copy's shape through `by_global[g]`, creating a `ThreadlocalShape` on a miss. The copy then points at the local proxy. Do not leave thread-local dicts pointing at global shapes.

## Dictionary mode (fallback)

Switch a dict permanently to the existing hash-table representation when any of these happens:
- **`dict unset`**. Delete transitions would fragment the tree.
- **More than 32 keys.** Make the threshold a build option. Data-keyed dicts (IDs, filenames) would otherwise explode the tree.

Converting to dictionary mode is fallible and must leave the dict unchanged on OOM. Dictionary-mode dicts have no shape id, so inline caches always miss on them. That is correct, just slow.

## Object mutation ids (for parent-lookup caching)

Add `mutation_id: u64` to the object header, or wherever the survey shows space; the object backing is planned to shrink to 32 bytes with shapes, so report the layout impact.

- **Stamp lazily.** The value is 0 until the object is first used as a parent in a cached lookup or first frozen. Stamp from the thread's id block. For crossthread objects, install the id with a CAS so racing threads agree on one id.
- **Reset on in-place mutation.** When a refcount-1 object is mutated in place, set `mutation_id = 0` (or take a fresh id). It is no longer the same value.
- Parents are deeply frozen, so any change anywhere up the chain produces new objects with new ids. **One id compare validates the whole chain.**

## Parent-lookup cache (`~parent`)

The inline cache entry is attached to the call site or the name object's internal rep, following the existing `CachedLexicalVar` pattern:

```zig
const ParentLookupCache = struct {
    child_shape_id: u64,  // proves the child still doesn't shadow the key
    parent_mid: u64,      // proves the frozen parent chain is the same
    owner: *Object,       // object on the chain that holds the key (NOT a counted reference)
    slot: u32,
};
```

**Hit** when both of these hold:
- `child.shape.id == child_shape_id`
- `child.parent.mutation_id == parent_mid`, and `parent_mid != 0`

Then return `owner`'s value at `slot`. This is safe without owning `owner`, because `owner` is reachable from the live, validated parent.

**Miss:**
1. Do the full walk.
2. Stamp the parent's `mutation_id` if it is 0. A 0 must never be recorded.
3. Overwrite the entry. This re-learns new ids if a shape was freed and recreated.

**Never** dereference `owner` before both id checks pass.

### Caching "not found"

- **"Key absent from the whole chain"** is a pure function of the chain. Cache it, for example with `owner = null`.
- **"Some hash on the chain could not be resolved locally"** is a fact about this machine at this moment. Do not cache it, because content may arrive later and healing must work.

## Phases and tests

1. **Id allocator and mutation-id stamping.**
   - Unit tests: uniqueness across threads, 0 never issued, lazy stamping, reset on in-place mutation.
2. **`CrossthreadShape` and the intern table.**
   - Test that identical key sequences built on different threads produce the same shape and id.
   - Test increment-if-nonzero against a concurrent final release.
   - Test that a recreated shape gets a new id.
   - Test iterative teardown of a 100k-deep chain with no stack overflow.
   - Multithreaded stress under **TSan**.
3. **`ThreadlocalShape` and the per-thread context.**
   - Test transitions, the parking LRU (a build-and-drop loop must keep a stable id), eviction, and thread-exit cleanup.
   - Run the leak detector clean.
4. **Dict representation on shapes.**
   - Run the full existing dict test suite unchanged.
   - Add round-trip tests: string rep to dict to string rep, including duplicate keys.
   - Test that order is preserved through set, update, and unset-then-set.
   - Test dictionary-mode fallback on unset and past the threshold.
   - **OOM injection:** fail every allocation index in set, unset, and transition, and assert the dict is unchanged each time.
5. **`makeCrossthread` and copy-on-write paths.**
   - Test that the reference order is correct (TSan, plus a test that drops the last local reference concurrently).
   - Test that a dict made crossthread and then copied back on another thread gets that thread's proxy with the same id.
6. **Parent-lookup cache.**
   - Hit and miss tests.
   - Rebinding the parent must miss.
   - Shadowing in the child must miss.
   - A freed-and-recreated shape must miss, then re-learn.
   - "Not found" is cached, but "unresolvable hash" is not.
7. **Benchmarks** against the current implementation:
   - record-style dict build and access
   - data-keyed dicts (should match the current speed via dictionary mode)
   - deep `~parent` chains

## Out of scope for this change

- Sharing prefix arrays across descriptor chains (V8 style)
- Using shape ids for dict-equality fast paths
- Persisting shapes or syncing them across machines (only Blake3 content addressing crosses machines)
- Bytecode inline-cache integration, beyond leaving the cache struct reusable
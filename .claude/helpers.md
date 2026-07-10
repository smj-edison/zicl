# Helper function index

Public helper functions in the foundation files. Consult this before implementing
anything that might already exist. The interpreter (`src/Interp.zig`) is mid-port
and still mixes in old `objutil`/`Heap`/`Handle` names; the functions below are the
new API that call sites should converge on.

---

## src/heap.zig

### Global lifecycle
- `heap.initGlobals(gpa, io)` -- Initialize global heap state (`global_gpa`, `global_io`, registries, leak check). Call once per process (or test).
- `heap.deinitGlobals()` -- Tear down global state. After this, `initGlobals` may be called again.
- `heap.initThread(arena_gpa)` -- Initialize the calling thread's `local_arena` (a `std.heap.ArenaAllocator`).
- `heap.deinitThread()` -- Tear down the calling thread's arena.
- `heap.testStart(gpa, io)` -- Test helper: `initGlobals` + `initThread`. Does not return a heap (single global heap).
- `heap.testFinish()` -- Test helper: dump leaks (if `trace_mem`), `deinitThread`, `deinitGlobals`. Use with `defer`.
- `heap.dumpLastTouchedTrace(fd)` -- Exported: dump the operation history of the last-touched object to a file descriptor (used by panic handlers).

### Registries
- `heap.NativeInitFn` -- Signature for a lazy native command initializer: `*const fn (interp: *anyopaque) callconv(.c) void`.
- `heap.nativefn_registry.register(gpa, name, init_fn)` -- Register a lazy C command initializer; `error.DuplicateNativeFn` on duplicates.
- `heap.nativefn_registry.get(name)` -- Look up a lazy initializer by name, or null.
- `heap.registered_hashes.getAndBorrow(hash)` -- Look up a `u256` hash and return a borrowed `*Object` (or null). Thread-safe via shared lock.
- `heap.registered_hashes.register(key, obj)` -- Idempotently register `obj` under `key`; marks it cross-thread and bumps the instance count.
- `heap.registered_hashes.unregister(key, obj)` -- Decrement the instance count for `key`; frees the representative when the last instance goes away.

### Value (64-bit NaN-boxed)
- `Value.newInt(i32)` -- Build an inline integer `Value`.
- `Value.newFloat(f64)` -- Build an inline float `Value` (canonicalizes NaN).
- `Value.newBool(bool)` -- Build an inline boolean `Value`.
- `Value.fromRep(rep)` -- Build a `Value` from a raw `ValueRep` (asserts not `.none`).
- `Value.asOptional(value)` -- Convert to `OptionalValue`.
- `Value.asRep(value)` -- Reinterpret as the raw `ValueRep` bit layout.
- `Value.isFloat(value)` -- True if the value is a float (including canonical NaN).
- `Value.expandedValue(value)` -- Return the `Expanded` union (`ptr`, `int`, `false`, `true`, `interned`, `float`).
- `Value.asPtr(value)` -- Return `?*Object` (non-null only for the `.ptr` tag).
- `Value.asInt(value)` -- Return `?i32` (non-null only for inline ints).
- `Value.asFloat(value)` -- Return `?f64` (non-null only for floats).
- `Value.asType(value, T)` -- Return `?*T` if the value points at an `Object` whose vtable is `T.vtable`.
- `Value.canShimmer(value)` -- True if the value points at a non-cross-thread object.
- `Value.canMutate(value)` -- True if the value points at an exclusively-owned, non-cross-thread, non-hash-registered object.
- `Value.incrRefCount(value)` -- Increment the ref count if the value is a pointer (no-op for primitives).
- `Value.borrow(value)` -- Increment ref count and return the same `Value`.
- `Value.release(value)` -- Decrement ref count and free if zero (no-op for primitives).
- `Value.duplicate(value)` -- Shallow copy (deep for the string rep); primitives return themselves.
- `Value.duplicateAsBoxed(value)` -- Like `duplicate` but always returns a heap `*Object` (boxes primitives).
- `Value.box(value)` -- Box a primitive into a heap `*Object` (`Integer`, `Boolean`, `Float`, or `String`). Asserts the value is a primitive.
- `Value.duplicateBoxed(value)` -- `duplicate` for pointers, `box` for primitives; always returns a `*Object`.
- `Value.swap(ref, new)` -- Set `ref.* = new` and release the old value.
- `Value.makeCrossthread(value)` -- Recursively mark a pointer value cross-thread (no-op for primitives).
- `Value.getString(value)` -- Return the string rep, generating it if needed (may allocate for objects; primitives use `local_arena`).
- `Value.getStringWithBuffer(value, buf)` -- Like `getString` but takes a 350-byte stack buffer to avoid allocating for primitives.
- `Value.equals(a, b)` -- Deep string equality (compares hashes for special strings; may allocate).
- `Value.equalsString(value, str)` -- Compare a value's string rep to a byte slice.
- `Value.getHashNoRegister(value)` -- Return the `u256` Blake3 content hash without registering in the hash registry.
- `Value.trace(value, fmt, args)` -- Append a trace entry (only when `trace_mem` is enabled).

### OptionalValue
- `OptionalValue.asValue(optional)` -- Return `?Value` (null if `.none`).
- `OptionalValue.fromValue(value)` -- Convert `?Value` to `OptionalValue`.
- `OptionalValue.borrow(optional)` -- Borrow the contained value (nop if none).
- `OptionalValue.makeCrossthread(optional)` -- Mark the contained value cross-thread (nop if none).
- `OptionalValue.release(optional)` -- Release the contained value (nop if none).
- `OptionalValue.orElse(optional, otherwise)` -- Return the contained value or `otherwise`.
- `OptionalValue.swap(ref, new)` -- Overwrite `ref.*` with `new`, releasing the old value.
- `OptionalValue.swapWithNone(ref)` -- Release the contained value and set to `.none` (use in `errdefer`).

### Interned strings
- `heap.createInternedString(comptime bytes)` -- Returns a type with `.get()` (the `[*:0]const u8` pointer) and `.value()` (a `Value`). The string is length-prefixed and NUL-terminated in rodata.

### SpecialString (large / hash-bearing strings)
- `SpecialString.deinit(self)` -- Free the string bytes, tracked hashes, cached hash, and the struct itself.
- `SpecialString.getHash(self)` -- Return the `u256` hash, computing and caching it on first call.
- `SpecialString.getCodepointLength(self)` -- Return cached UTF-8 length, or null if not yet computed.
- `SpecialString.setCodepointLength(self, value)` -- Cache the UTF-8 length.
- `SpecialString.getString(self)` -- Return the string bytes.
- `SpecialString.incrRefCount(self)` / `SpecialString.decrRefCount(self)` -- Atomic ref counting (frees at zero).

### Object (80-byte heap header)
- `Object.from(T, ptr)` -- Get the `*Object` header for a typed body pointer `*T`.
- `Object.fromConst(T, ptr)` -- Const variant of `from`.
- `Object.castTo(obj, T)` -- Cast a `*Object` to `*T` (asserts `obj.vtable == &T.vtable`).
- `Object.constCastTo(obj, T)` -- Const variant of `castTo`.
- `Object.castToInner(obj)` -- Get the typed body as `*align(@alignOf(Object)) anyopaque`.
- `Object.asValue(obj)` -- Build a `.ptr` `Value` from this object.
- `Object.canMutate(obj)` -- True if ref count is 1, not cross-thread, and not hash-registered.
- `Object.canShimmer(obj)` -- True if not cross-thread.
- `Object.newObjectUninitialized(T)` -- Allocate an 80-byte slot, set vtable/ref_count/metadata, return `{ head: *Object, body: *T }`. Does not zero the string fields.
- `Object.newObject(T)` -- Like `newObjectUninitialized` but also initializes `string`/`string_metadata` to "no string".
- `Object.duplicate(obj)` -- Dispatch to the vtable's `duplicate` (panics if none).
- `Object.makeCrossthread(obj)` -- Dispatch to the vtable's `make_crossthread` and set `metadata.cross_thread`.
- `Object.enumerateStruct(ctx, info)` -- Walk the object for leak diagnostics (string, metadata, ref count, then the vtable's `enumerate_struct`).
- `Object.freeBacking(obj)` -- Free the 80-byte slot.
- `Object.deinit(obj)` -- Invalidate the internal rep, free the string, free the backing.
- `Object.getStringDetails(obj)` -- Return `StringDetails` (`.none`, `.normal`, `.special`) without generating a string.
- `Object.getString(obj)` -- Return the string rep, generating it via `update_string` if missing (may OOM).
- `Object.setStringIgnoreRace(obj, bytes)` -- Take ownership of `bytes`; on `OtherThreadSet` or OOM, free `bytes` and return.
- `Object.setStringDuplicatingIgnoreRace(obj, bytes)` -- Copy `bytes` and set; tolerates races.
- `Object.setStringDuplicating(obj, bytes)` -- Copy `bytes` and set; propagates `OtherThreadSet` and OOM.
- `Object.setStringOwning(obj, bytes)` -- Take ownership of `bytes`; scans for hash refs and promotes to `SpecialString` when needed; `error.OtherThreadSet` if another thread set the string first.
- `Object.setStringLocalObject(obj, bytes)` -- Non-atomic set for a known thread-local object (asserts not cross-thread).
- `Object.getRefCount(obj)` -- Atomic load for cross-thread objects, plain read otherwise.
- `Object.incrRefCount(obj)` -- Increment (atomic for cross-thread).
- `Object.borrow(obj)` -- Increment and return the same `*Object`.
- `Object.release(obj)` -- Decrement and free at zero; unregisters from the hash registry when a representative or registered object reaches the threshold.
- `Object.invalidateString(obj)` -- Free the string rep (asserts `canShimmer`).
- `Object.invalidateInternalRep(obj)` -- Dispatch to the vtable's `free_internal_rep`.
- `Object.getHashNoRegister(obj)` -- Return the `u256` hash from the cached string/special/source hash, computing if needed.
- `Object.getHashRegistering(obj)` -- `getHashNoRegister` plus idempotent `HashRegistry.register`.
- `Object.duplicateHeadOnto(src, dest)` -- Copy the vtable, metadata, and string rep from `src` onto an uninitialized `dest` header.
- `Object.duplicateStringOnly(src)` -- Allocate a fresh `None` object duplicating only the string rep of `src`.

### hashutil
- `hashutil.hashBytes(bytes)` -- Blake3 hash of a byte slice, returning `u256`.
- `hashutil.scanStringForHashRefs(arena, bytes)` -- Find all `blake3~<hash>` occurrences; returns an `ArrayList(HashInstance)`.
- `hashutil.parseHashReference(bytes)` -- Parse a string that is exactly one `blake3~<hash>` reference; return the `u256` or null.
- `hashutil.scanAndResolveHashRefs(arena, bytes)` -- Scan for hash refs and resolve each against `registered_hashes`, borrowing representatives; returns `[]SpecialString.HashAndInfo`.

### Refcount primitives
- `heap.incrRefCountOf(T, ref, is_atomic)` -- Generic ref count increment; returns the new count.
- `heap.decrRefCountOf(T, ref, is_atomic)` -- Generic ref count decrement; returns the new count (with acquire fence at zero for atomic).

---

## src/objects.zig

### Shimmerable (working buffer for shimmer and mutation)
- `Shimmerable.deinit(self)` -- Release original and shimmered, zero the struct.
- `Shimmerable.current(self)` -- Return the effective `Value` (`shimmered` if set, else `original`).
- `Shimmerable.consume(self)` -- Take ownership: release the original, return the effective value, zero the struct.
- `Shimmerable.discardChanges(self)` -- Release any shimmered duplicate and roll back to `original`.
- `Shimmerable.takeShimmered(self)` -- Steal the `shimmered` slot without releasing it.
- `Shimmerable.ensureShimmerable(self)` -- Duplicate into `shimmered` if the current value cannot shimmer (shared, cross-thread, or a primitive that needs boxing).
- `Shimmerable.prepareToShimmer(self)` -- `ensureShimmerable`, then cache the string rep and invalidate the internal rep; returns the `*Object` ready for a new vtable/body.
- `Shimmerable.getMutable(self, T, det)` -- Shimmer to `T`, then return a `*T` safe to mutate (duplicates if the current value cannot mutate).

### AlwaysType (read-only typed view)
- `objects.AlwaysType(T)` -- Comptime: returns a wrapper around `*Object` that can shimmer but never mutate.
  - `.init(value)` -- Wrap a `*T`.
  - `.deinit(self)` -- Release the borrowed object.
  - `.duplicate(self)` -- Copy the wrapper (bumps ref count).
  - `.get(self)` -- Shimmer to `T` if needed and return `*const T`; may OOM.

### IterHelper (leak-graph field walking)
- `IterHelper.follow(helper, T, field_name, ptr)` -- Follow a child struct (rejects object bodies; follow their `*Object` instead).
- `IterHelper.followOptional(helper, T, field_name, ptr)` -- Follow a nullable child struct.
- `IterHelper.followValue(helper, field_name, value)` -- Follow a `Value` (object or primitive leaf).
- `IterHelper.followValueSlice(helper, field_name, values)` -- Follow a `[]Value` slice.
- `IterHelper.followOptionalValue(helper, field_name, optional)` -- Follow an `OptionalValue`.
- `IterHelper.addField(helper, T, edge_name, fmt, val)` -- Add a scalar field leaf to the graph.

### None (untyped, string-only object)
- `None.new(bytes)` -- Allocate a `None` whose value is just its string rep.
- `None.asHead(self)` -- Get the `*Object` header.

### String
- `String.new(bytes)` -- Allocate a `String` copying `bytes`.
- `String.newOwning(bytes)` -- Allocate a `String` taking ownership of `bytes` (frees on error).
- `String.newObject(bytes)` -- Like `new` but returns `*Object`.
- `String.newValue(bytes)` -- Like `new` but returns a `Value`.
- `String.newFormatted(comptime fmt, args)` -- Allocate a formatted string.
- `String.newFromEscaped(escaped)` -- Parse backslash escapes and store the unescaped bytes.
- `String.newWithCodepointLength(bytes, codepoint_len)` -- Allocate with a pre-computed UTF-8 length.
- `String.getCodepointLength(shim)` -- Shimmer to `String` and return the UTF-8 codepoint count (computes and caches if needed).
- `String.shimmerFrom(det, shim)` -- Shimmer `shim` to a `String`; returns `*const String`.
- `String.asHead(self)` -- Get the `*Object` header.

### ParsedScript
- `ParsedScript.printTokens(script)` -- Debug: print the token/object table.
- `ParsedScript.deinit(parsed)` -- Free a parsed script's tokens and backing value list.

### Source (file/line metadata)
- `Source.new(file_name, line)` -- Allocate a `Source` carrying an optional file name and line number.
- `Source` caches its content hash in an atomic `?*u256` for cheap re-hashing.

### HashReference (a `blake3~<hash>` pointer to a registered object)
- `HashReference.new(referent)` -- Allocate a `HashReference` borrowing `referent`.
- `HashReference.shimmerFrom(det, shim)` -- Parse `shim`'s string as a hash ref and resolve it via `registered_hashes`; returns `*const HashReference`.
- `HashReference.resolveAsDictionary(det, shim)` -- Resolve a hash ref and shimmer the target to a `Dictionary`; returns `*const Dictionary`.
- `HashReference.asHead(self)` -- Get the `*Object` header.

### Regexp
- `Regexp` wraps a `*pcre2.pcre2_code_8`. Its `duplicate` is `Object.duplicateStringOnly` (recompiles on shimmer).

### Index (list index: int or `end?[+-]int`)
- `Index.asAbsoluteIndex(self, len)` -- Resolve a possibly-relative index against a list length.
- `Index.Range.fromIndexes(len, start_index, end_index)` -- Resolve two indexes to an absolute `[start, end)` byte range (Tcl's inclusive end is adjusted).
- `Index.shimmerFrom(det, shim)` -- Parse `shim`'s string into an `Index`.
- `Index.get(det, shim)` -- Fast path: return an inline int directly, else `shimmerFrom`.
- `Index.getRange(det, len, start, end)` -- Resolve a start/end pair of `Shimmerable` values to a `Range`.

### Float
- `Float.new(value)` -- Return an inline float `Value` (canonicalizes NaN).
- `Float.renderFloat(float, buf)` -- Format a float into a 350-byte buffer (appends `.0` for whole numbers).
- `Float.newBoxed(value)` -- Allocate a heap `Float`.
- `Float.parse(det, bytes)` -- Parse a float from bytes.
- `Float.shimmer(det, shim)` -- Shimmer `shim` to a float (inline if it round-trips, else boxed).
- `Float.get(det, shim)` -- Shimmer and return the `f64`.

### Integer
- `Integer.new(value)` -- Return an inline `Value` for `i32` range, else a boxed `Integer`.
- `Integer.newBoxed(value)` -- Allocate a heap `Integer` holding an `i64`.
- `Integer.integerOverflowError(det, rendered_int)` -- Populate `det` and return `error.IntegerOverflow`.
- `Integer.parse(det, bytes)` -- Parse an `i64` from bytes.
- `Integer.shimmerFrom(det, shim)` -- Shimmer to an integer (inline if it fits `i32`, else boxed); returns the `i64`.

### Boolean
- `Boolean.new(value)` -- Return an inline boolean `Value`.
- `Boolean.newBoxed(value)` -- Allocate a heap `Boolean`.

### List
- `List.new(items)` -- Allocate a `List` from a slice of `Value`s (borrows each).
- `List.newWithCapacity(items, capacity)` -- Allocate with a pre-reserved backing capacity.
- `List.append(list, value)` -- Append a value (borrows it); grows backing if needed.
- `List.set(list, index, value)` -- Replace a slot (releases the old value, borrows the new).
- `List.shimmerFrom(det, shim)` -- Shimmer to a list (dict -> list reuses the items; string -> tokenized list). Returns `*const List`.
- `List.asHead(self)` -- Get the `*Object` header.

### ValueSliceContext (key-path carrier for recursive dict ops)
- `ValueSliceContext.len(self)` / `.get(self, index)` / `.sliceAfter(self, index)` -- Interface used by the recursive dict functions.

### Dictionary
- `Dictionary.new(items)` -- Allocate a `Dictionary` from alternating key/value `Value`s; builds the lookup table.
- `Dictionary.asHead(self)` -- Get the `*Object` header.
- `Dictionary.shimmerFrom(det, shim)` -- Shimmer to a dict (list -> dict, requires an even count). Returns `*const Dictionary`.
- `Dictionary.getNoFollow(self, key)` -- Look up a key returning `OptionalValue` (no parent-link following).
- `Dictionary.getPtrNoFollow(self, key)` -- Look up a key returning `?*Value` into the items slice.
- `Dictionary.put(dict, key, value)` -- Insert/update a key (borrows value), invalidate the string. Asserts `canMutate`. Returns the value's index.
- `Dictionary.putInner(dict, key, value, remove_duplicates)` -- Like `put` but optionally skips string invalidation and duplicate removal.
- `Dictionary.resolveParentDict(dict, det)` -- Follow the `~parent` link to the parent `Dictionary` (or null).
- `Dictionary.remove(dict, det, key)` -- Remove all pairs with `key`; flattens parent links first if the key shadows a parent. Returns true if any were removed.
- `Dictionary.flatten(dict, det)` -- Collapse a `~parent` chain into a single flat dict (mutates in place).
- `Dictionary.flattenInner(dict, det)` -- Recursive helper; returns a new flat `Dictionary` or null if there is no parent.
- `Dictionary.getFollowingLinks(det, shim, key)` -- Look up `key`, following `~parent` links recursively; returns `OptionalValue`.
- `Dictionary.getRecursively(det, shim, context)` -- Nested lookup along a key path (`context` is a `ValueSliceContext`).
- `Dictionary.putRecursively(dict, det, context, value)` -- Nested insert/update along a key path (creates child dicts as needed).
- `Dictionary.removeRecursively(dict, det, context)` -- Nested remove along a key path.
- `Dictionary.getKvPairs(det, arena, shim)` -- Flatten a linked-dict chain into a `KvResult` map. (TODO: not yet ported to the new heap.)

### Enums and subcommands (comptime)
- `objects.enumNames(E, joiner)` -- Comptime: join enum variant names with `joiner`.
- `objects.EnumMapping(E, include_numbers)` -- Comptime: build a string-to-enum lookup table type.
- `objects.EnumConstructor(E, include_numbers)` -- Comptime: build a Tcl-facing enum constructor.
- `objects.SubcommandParser(Enum, subcommands)` -- Comptime: build a subcommand dispatcher with arity validation and usage strings.

### Misc
- `objects.allocPrintZ(comptime fmt, args)` -- Allocate a `[:0]u8` with `global_gpa` from a format string.
- `objects.interned_empty_string` -- The interned empty-string type (use `.value()`).
- `objects.interned_tilde_parent` -- The interned `"~parent"` string type (use `.value()`).
- `objects.ErrorDetails` -- `{ message: [:0]u8 }`; populated by object-level functions on user-facing errors. Owned by the caller when `det != null` and the error is not OOM.

---

## src/memutil.zig

### RingBufferAllocator
- `RingBufferAllocator.init(buffer)` -- Initialize a ring buffer allocator over a fixed buffer.
- `RingBufferAllocator.allocator(self)` -- Return a standard `Allocator` backed by this ring buffer. `free` is a no-op; `resize`/`remap` unsupported.

### RewindableArena
- `RewindableArena.init(child_allocator)` -- Create an empty rewindable arena.
- `RewindableArena.deinit(arena)` -- Free all chunks.
- `RewindableArena.allocator(self)` -- Return a standard `Allocator` backed by this arena.
- `RewindableArena.queryCapacity(arena)` -- Total usable bytes across all chunks (stable across `rewind`).
- `RewindableArena.snapshot(arena)` -- Take a point-in-time watermark.
- `RewindableArena.rewind(arena, snap)` -- Restore the arena to `snap`; chunks after `snap` are retained and overwritten as later allocations reach them.

### IndexedMemoryPool
- `memutil.IndexedMemoryPool(Item)` -- Comptime: a pool returning `usize` indices instead of pointers.
  - `.initWithCapacity(gpa, capacity)`, `.create(gpa)`, `.createAssumeCapacity()`, `.clearRetainingCapacity()`, `.destroy(index)`, `.deinit(gpa)`, `.dumpLeaked(scratch, fmt)`.

### LruCache
- `memutil.LruCache(K, V, Context)` -- Comptime: an LRU cache.
  - `.initWithCapacity(gpa, max_size)`, `.deinit(gpa)`, `.get(key)`, `.put(key, value)` (returns evicted value if at capacity), `.valueIterator()`, `.clearRetainingCapacity()`.

### StructIterator / GraphWalker (leak diagnostics)
- `memutil.StructIterator` -- Drives a typed walk over the heap graph for leak reporting.
  - `.followUnparentedNode(ctx, T, ptr)` -- Walk a root node with no parent.
  - `.followNode(ctx, T, info, field_name, ptr)` -- Walk a child node.
  - `.addFieldString(ctx, T, info, field_name, str)` / `.addField(ctx, T, info, field_name, fmt, val)` -- Add a scalar leaf.
- `memutil.GraphWalker` -- Collects nodes and edges discovered by a `StructIterator`.
  - `.empty` -- Empty walker.
  - `.promote(self, arena)` -- Return a `StructIterator` that feeds this walker.

### Testing
- `memutil.expectErrorOrOom(expected_error, actual_error_union)` -- Assert an error matches `expected_error` (passes through OOM).

### Hash context
- `memutil` string hash context: `.hash(self, s)` (Wyhash), `.eql(self, a, b)` (byte equality).

---

## src/strutil.zig

- `strutil.checkAllAscii(bytes, check)` -- True if every byte passes the predicate.
- `strutil.isGraph(c)` / `strutil.isPunct(c)` -- ASCII character class checks.
- `strutil.toTitle` / `strutil.toUpper` / `strutil.toLower` -- Case conversion functions (UTF-8 or ASCII depending on config).
- `strutil.compare(a, b, up_to_cp, case_insensitive)` -- Lexicographic codepoint-order comparison.
- `strutil.cpIndexUtf8(str, index)` / `strutil.cpIndexAscii(str, index)` / `strutil.cpIndex` -- Convert a codepoint index to a byte offset.
- `strutil.codepointLength(str)` / `strutil.strlenUtf8(str)` / `strutil.strlenAscii(str)` -- Count codepoints.
- `strutil.findCodepoint(str, cp)` -- Byte offset of the first occurrence of codepoint `cp`.
- `strutil.trimLeft(str, trim_chars)` / `strutil.trimRight(str, trim_chars)` -- Return the offset/length after trimming.
- `strutil.charsetMatch(pattern, cp, flags)` -- Match a Tcl charset pattern (e.g. `[a-z]`) against a codepoint.
- `strutil.globMatch(pattern, str, case_insensitive)` -- Glob-style pattern match on byte slices.
- `strutil.findFirstOccurrence(needle, haystack, cp_index)` / `strutil.findLastOccurrence(needle, haystack)` -- Substring search by codepoint offset.
- `strutil.hexDigitValue(c)` / `strutil.isHexDigit(c)` -- Hex digit helpers.
- `strutil.removeEscaping(source, dest)` -- Process backslash escapes in-place; return the resulting length.
- `strutil.QuotingType` -- `enum { bare, brace, escape }`.
- `strutil.calculateNeededQuotingType(str)` -- Determine how a string must be quoted.
- `strutil.quoteSize(quoting_type, str_len)` -- Output buffer size needed to quote a string.
- `strutil.quoteString(quoting_type, src, dest, escape_first_pound)` -- Write a quoted string into `dest`; return bytes written.
- `strutil.quoteStrings(gpa, items)` -- Quote and join a slice of strings into one `[:0]u8`.
- `strutil.Iterator.init(bytes)` / `.next()` / `.peek()` -- Codepoint iterator (UTF-8 or ASCII).

---

## src/leak_check.zig

- `leak_check.init()` -- Initialize the trace log and debug allocator (only when `trace_mem` is on).
- `leak_check.deinit()` -- Reset the trace log and counts.
- `leak_check.globalTrace(category, value, fmt, args)` -- Append a trace entry (alloc/free/other) with a stack trace. Inlined; no-op when `trace_mem` is off.
- `leak_check.captureLeaks()` -- Walk every leaked object via `GraphWalker`/`StructIterator`; returns a `LeakResult` (dot graph + per-object logs).
- `leak_check.dumpLeaks()` -- Capture leaks and dump the dot graph + details to stderr. Quiet when there are no leaks. Called from `heap.testFinish`.
- `leak_check.dumpLastTouchedTrace(fd)` -- Dump the operation history of the most recently touched object (hooked into the panic path). Re-entrancy guarded.
- `LeakResult.dumpDot(writer)` -- Render the leak graph as a Graphviz dot digraph.
- `LeakResult.dumpDetails(writer)` -- Print each leaked object's operation history with stack traces.
- `LeakResult.deinit(result)` -- Free the result's external arena.
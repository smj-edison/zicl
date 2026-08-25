# Helper function index

Public helper functions in the foundation files and the interpreter layer. Consult
this before implementing anything that might already exist.

---

## src/heap.zig

### Global lifecycle
- `heap.initGlobals(gpa, io)` -- Initialize global heap state (`global_gpa`, `global_io`, registries, leak check, regex globals). Idempotent; call once per process (or test).
- `heap.deinitGlobals()` -- Tear down global state. After this, `initGlobals` may be called again.
- `heap.initThread()` -- Initialize the calling thread's `local_arena` (a `memutil.ScopedArena` over `global_gpa`).
- `heap.deinitThread()` -- Tear down the calling thread's arena.
- `heap.testStart(gpa, io)` -- Test helper: `initGlobals` + `initThread`.
- `heap.testFinish()` -- Test helper: dump leaks (if `trace_mem`), `deinitThread`, `deinitGlobals`. Use with `defer`.
- `heap.dumpLastTouchedTrace(fd)` -- Exported: dump the operation history of the last-touched object to a file descriptor (used by panic handlers).
- `heap.initialized`, `heap.init_mutex`, `heap.running_leak_check` -- Global state flags. Lock `init_mutex` when adding or removing global registrations, not when reading them.

### Registries
- `heap.LazyRegisterFn` -- Signature for a lazy native command initializer: `*const fn (interp: *anyopaque) callconv(.c) void`.
- `heap.nativefn_registry.register(gpa, name, init_fn)` -- Register a lazy C command initializer; `error.DuplicateLazyFn` on duplicates.
- `heap.nativefn_registry.get(name)` -- Look up a lazy initializer by name, or null.
- `heap.registered_hashes.getAndTakeReference(hash)` -- Look up a `u256` hash and return a referenced `*Object` (or null). Thread-safe via shared lock.
- `heap.registered_hashes.register(key, obj)` -- Idempotently register `obj` under `key`; marks it cross-thread and bumps the instance count.
- `heap.registered_hashes.unregister(key, obj)` -- Decrement the instance count for `key`; frees the representative when the last instance goes away.

### Value (16-byte tagged union)
`Value` wraps a `ValueRep`: an `extern union` payload plus `interned_string_len: u16`
and `tag: Tag`, where `Tag` is `none`, `pointer`, `boolean`, `integer`, `float`, or
`interned`. Integers are full-width `i64` inline.

- `Value.newInt(i64)` -- Build an inline integer `Value`.
- `Value.newFloat(f64)` -- Build an inline float `Value`.
- `Value.newBool(bool)` -- Build an inline boolean `Value`.
- `Value.fromRep(rep)` -- Build a `Value` from a raw `ValueRep` (asserts the tag is not `none`).
- `Value.asOptional(value)` -- Convert to `OptionalValue`.
- `Value.asPtr(value)` -- Return `?*Object` (non-null only for the `pointer` tag).
- `Value.asInlineInt(value)` -- Return `?i64` (non-null only for the `integer` tag; use `objects.Integer.asInt` to also catch boxed integers).
- `Value.asInlineFloat(value)` -- Return `?f64` (non-null only for the `float` tag; use `objects.Float.asFloat` to also catch boxed floats).
- `Value.asInlineBool(value)` -- Return `?bool` (non-null only for the `boolean` tag).
- `Value.asType(value, T)` -- Return `?*T` if the value points at an `Object` whose vtable is `T.vtable`.
- `Value.canShimmer(value)` -- True if the value points at a non-cross-thread object (false for primitives).
- `Value.canMutate(value)` -- True if the value points at an exclusively-owned, non-cross-thread, non-hash-registered object (false for primitives).
- `Value.asMutableInPlace(value, T, det)` -- Return `?*T` when the value can be shimmered to `T` _and_ mutated without duplicating; null when the caller has to duplicate instead (`duplicateAsBoxed`, mutate the copy, store it back). The preferred entry point for mutation; see the copy-on-write recipe in the cookbook.
- `Value.incrRefCount(value)` -- Increment the ref count if the value is a pointer (no-op for primitives).
- `Value.takeReference(value)` -- Increment ref count and return the same `Value`.
- `Value.dropReference(value)` -- Decrement ref count and free if zero (no-op for primitives).
- `Value.duplicate(value)` -- Shallow copy (deep for the string rep); primitives return themselves.
- `Value.duplicateAsBoxed(value)` -- Like `duplicate` but always returns a heap `*Object` (boxes primitives).
- `Value.swap(ref, new)` -- Set `ref.* = new` and drop the old value.
- `Value.makeCrossthread(value)` -- Recursively mark a pointer value cross-thread (no-op for primitives).
- `Value.getString(value)` -- Return the string rep, generating it if needed (may allocate for objects; primitives render into `local_arena`).
- `Value.getStringWithBuffer(value, buf)` -- Like `getString` but takes a `*[350]u8` stack buffer so primitives never allocate. Only OOMs when the value is an object that OOMs generating its string.
- `Value.equals(a, b)` -- Deep string equality, with fast paths per tag pair (compares hashes when both sides are special strings).
- `Value.equalsString(value, str)` -- Compare a value's string rep to a byte slice.
- `Value.getHashNoRegister(value)` -- Return the `u256` Blake3 content hash without registering in the hash registry. This is the hash that travels between machines; for a hash table's index use `hashutil.quickHash` instead.
- `Value.trace(value, fmt, args)` -- Append a trace entry (only when `trace_mem` is enabled).

### OptionalValue
- `OptionalValue.none` -- The empty representation.
- `OptionalValue.isNone(optional)` / `.isSome(optional)` -- Tag checks.
- `OptionalValue.asValue(optional)` -- Return `?Value` (null if none).
- `OptionalValue.fromValue(value)` -- Convert `?Value` to `OptionalValue`.
- `OptionalValue.takeReference(optional)` -- Take the contained value (nop if none).
- `OptionalValue.makeCrossthread(optional)` -- Mark the contained value cross-thread (nop if none).
- `OptionalValue.dropReference(optional)` -- Drop the contained value (nop if none).
- `OptionalValue.orElse(optional, otherwise)` -- Return the contained value or `otherwise`.
- `OptionalValue.orEmpty(optional)` -- Return the contained value or the interned empty string.
- `OptionalValue.swap(ref, new)` -- Overwrite `ref.*` with `new`, releasing the old value.
- `OptionalValue.swapWithNone(ref)` -- Drop the contained value and set to none (use in `errdefer`).

### Interned strings
- `heap.InternedString.new(comptime bytes)` -- Build an `InternedString` from a comptime `[:0]const u8` in rodata.
- `heap.InternedString.newValue(comptime bytes)` -- Same, returning a `Value` directly. This is the usual entry point.
- `heap.InternedString.asSlice(interned)` -- Return the `[:0]const u8` bytes.
- `heap.interned_empty_string` -- The empty-string `Value` (note: lives in `heap`, not `objects`).

### SpecialString (large / hash-bearing strings)
- `SpecialString.deinit(self)` -- Free the string bytes, tracked hashes, cached hash, and the struct itself.
- `SpecialString.getHash(self)` -- Return the `u256` hash, computing and caching it on first call.
- `SpecialString.getCodepointLength(self)` -- Return cached UTF-8 length, or null if not yet computed.
- `SpecialString.setCodepointLength(self, value)` -- Cache the UTF-8 length.
- `SpecialString.getString(self)` -- Return the string bytes.
- `SpecialString.incrRefCount(self)` / `SpecialString.decrRefCount(self)` -- Atomic ref counting (frees at zero).

### Object (80-byte header plus inline body)
- `Object.body_max_size` (48) / `Object.body_align` (8) -- The size and alignment budget for a type's body.
- `Object.assertValidType(T)` -- Comptime check that `T` fits the body budget and declares a `vtable`.
- `Object.from(T, ptr)` -- Get the `*Object` header for a typed body pointer `*T`.
- `Object.fromConst(T, ptr)` -- Const variant of `from`.
- `Object.asType(obj, T)` -- Return `?*T`, non-null only when `obj.vtable == &T.vtable`.
- `Object.asTypeConst(obj, T)` -- Const variant of `asType`.
- `Object.asValue(obj)` -- Build a `pointer` `Value` from this object.
- `Object.canMutate(obj)` -- True if ref count is 1, not cross-thread, and not hash-registered.
- `Object.canShimmer(obj)` -- True if not cross-thread.
- `Object.newObjectUninitialized(T)` -- Allocate a slot, set vtable/ref_count/metadata, return `{ head: *Object, body: *T }`. Does not zero the string fields.
- `Object.newObject(T)` -- Like `newObjectUninitialized` but also initializes `string`/`string_metadata` to "no string".
- `Object.duplicate(obj)` -- Dispatch to the vtable's `duplicate` (panics if none).
- `Object.makeCrossthread(obj)` -- Dispatch to the vtable's `make_crossthread` and set `metadata.cross_thread`.
- `Object.enumerateStruct(ctx, info)` -- Walk the object for leak diagnostics (string, metadata, ref count, then the vtable's `enumerate_struct`).
- `Object.freeBacking(obj)` -- Free the slot (use in `errdefer` between `newObjectUninitialized` and full initialization).
- `Object.deinit(obj)` -- Invalidate the internal rep, free the string, free the backing.
- `Object.getStringDetails(obj)` -- Return `StringDetails` (`.none`, `.normal`, `.special`) without generating a string. `.asSpecial()` narrows to `?*SpecialString`.
- `Object.getString(obj)` -- Return the string rep, generating it via `update_string` if missing (may OOM).
- `Object.maybeGetString(obj)` -- Return the cached string rep, or null if none has been generated. Never allocates.
- `Object.setStringIgnoreRace(obj, bytes)` -- Take ownership of `bytes`; on `OtherThreadSet` or OOM, free `bytes` and return.
- `Object.setStringDuplicatingIgnoreRace(obj, bytes)` -- Copy `bytes` and set; tolerates races.
- `Object.setStringDuplicating(obj, bytes)` -- Copy `bytes` and set; propagates `OtherThreadSet` and OOM.
- `Object.setStringOwning(obj, bytes)` -- Take ownership of `bytes`; scans for hash refs and stores them as a `SpecialString` when needed; `error.OtherThreadSet` if another thread set the string first.
- `Object.setStringLocalObject(obj, bytes)` -- Non-atomic set for a known thread-local object (asserts not cross-thread).
- `Object.getRefCount(obj)` -- Atomic load for cross-thread objects, plain read otherwise.
- `Object.incrRefCount(obj)` -- Increment (atomic for cross-thread).
- `Object.takeReference(obj)` -- Increment and return the same `*Object`.
- `Object.dropReference(obj)` -- Decrement and free at zero; unregisters from the hash registry when a representative or registered object reaches the threshold.
- `Object.swap(ref, new)` -- Set `ref.* = new` and drop the old object.
- `Object.commitMutation(obj)` -- Free the string rep (asserts `canShimmer`).
- `Object.invalidateInternalRep(obj)` -- Dispatch to the vtable's `free_internal_rep`.
- `Object.getHashNoRegister(obj)` -- Return the `u256` hash from the cached string/special/source hash, computing if needed.
- `Object.getHashRegistering(obj)` -- `getHashNoRegister` plus idempotent `HashRegistry.register`.
- `Object.duplicateHeadOnto(src, dest)` -- Copy the vtable, metadata, and string rep from `src` onto an uninitialized `dest` header.
- `Object.duplicateStringOnly(src)` -- Allocate a fresh `None` object duplicating only the string rep of `src`.

### hashutil
- `hashutil.hash_prepend` (`"blake3~"`), `hashutil.hash_len`, `hashutil.hash_and_prepend_len` -- Layout constants for rendered hash references.
- `hashutil.hash_encoder` / `hashutil.hash_decoder` -- base64url codecs for the 32-byte hash.
- `hashutil.hashBytes(bytes)` -- Blake3 hash of a byte slice, returning `u256`.
- `hashutil.scanStringForHashRefs(arena, bytes)` -- Find all `blake3~<hash>` occurrences; returns an `ArrayList(HashInstance)`.
- `hashutil.parseHashReference(bytes)` -- Parse a string that is exactly one `blake3~<hash>` reference; return the `u256` or null.
- `hashutil.scanAndResolveHashRefs(arena, bytes)` -- Scan for hash refs and resolve each against `registered_hashes`, taking representatives; returns `[]SpecialString.HashAndInfo`.

### Quick hashing (for hash tables, not for content addressing)
- `hashutil.quick_hash_cutoff` (1024) -- The switch point between Wyhash and the cached Blake3 hash.
- `hashutil.quickHash(value)` -- Hash a value for a table's index (dictionary keys, variable tables). Wyhash below `quick_hash_cutoff`, the truncated cached Blake3 hash at or above it. Not cryptographically secure; only for hash tables paired with equality, not content addressing.
- `hashutil.cacheQuickHash(value)` -- Force the object's content hash to be cached ahead of time, for a key at or above `quick_hash_cutoff`, so a later `quickHash` on it cannot OOM.

### Refcount primitives
- `heap.incrRefCountOf(T, ref, is_atomic)` -- Generic ref count increment; returns the new count.
- `heap.decrRefCountOf(T, ref, is_atomic)` -- Generic ref count decrement; returns the new count (with acquire fence at zero for atomic).

---

## src/objects.zig

### Shimmerable (working buffer for shimmer and mutation)
- `Shimmerable.deinit(self)` -- Drop original and shimmered, poison the struct.
- `Shimmerable.current(self)` -- Return the effective `Value` (`shimmered` if set, else `original`).
- `Shimmerable.consume(self)` -- Take ownership: drop the original, return the effective value, poison the struct.
- `Shimmerable.discardChanges(self)` -- Drop any shimmered duplicate and roll back to `original`.
- `Shimmerable.takeShimmered(self)` -- Steal the `shimmered` slot without releasing it.
- `Shimmerable.getString(self)` -- Shorthand for `.current().getString()`.
- `Shimmerable.ensureBoxed(self)` -- Box a primitive into a heap object if needed; returns the `*Object`.
- `Shimmerable.ensureShimmerable(self)` -- `ensureBoxed`, then duplicate into `shimmered` if the object cannot shimmer.
- `Shimmerable.prepareToShimmer(self, T)` -- `ensureShimmerable`, cache the string rep, free the old body, install `T`'s vtable, and return the `*T` body to fill in. Call this from inside a `shimmerFrom`.
- `Shimmerable.prepareToShimmerVTable(self, vtable)` -- The vtable-typed counterpart to `prepareToShimmer`, for callers such as the C API that only have a `*const Object.VTable`, not a Zig type. Returns the raw `*anyopaque` body storage.
- `Shimmerable.getMutable(self, T, det)` -- Shimmer to `T`, then return an owned `*T` to mutate. Essentially always duplicates, and the result is detached from the shim: drop it yourself and write it back explicitly. Prefer `Value.asMutableInPlace` unless a shim is already in hand.

### IterHelper (leak-graph field walking)
- `IterHelper.follow(helper, T, field_name, ptr)` -- Follow a child struct (rejects object bodies; follow their `*Object` instead).
- `IterHelper.followOptional(helper, T, field_name, ptr)` -- Follow a nullable child struct.
- `IterHelper.followValue(helper, field_name, value)` -- Follow a `Value` (object or primitive leaf).
- `IterHelper.followValueSlice(helper, field_name, values)` -- Follow a `[]const Value` slice.
- `IterHelper.followOptionalValue(helper, field_name, optional)` -- Follow an `OptionalValue`.
- `IterHelper.followFieldSlice(helper, T, field_name, fmt, values)` -- Follow a slice of scalars, rendering each with `fmt`.
- `IterHelper.addField(helper, T, edge_name, fmt, val)` -- Add a scalar field leaf to the graph.

### None (untyped, string-only object)
- `None.new(bytes)` -- Allocate a `None` whose value is just its string rep.
- `None.asHead(self)` -- Get the `*Object` header.

### String
- `String.new(bytes)` -- Allocate a `String` copying `bytes`.
- `String.newOwning(bytes)` -- Allocate a `String` taking ownership of `bytes` (frees them on error).
- `String.newOwningNoFree(bytes)` -- Like `newOwning` but leaves `bytes` to the caller on error.
- `String.newObject(bytes)` -- Like `new` but returns `*Object`.
- `String.newValue(bytes)` -- Like `new` but returns a `Value`; returns the interned empty string for `""`.
- `String.newFormatted(comptime fmt, args)` -- Allocate a formatted string.
- `String.newFromEscaped(escaped)` -- Parse backslash escapes and store the unescaped bytes.
- `String.newWithCodepointLength(bytes, codepoint_len)` -- Allocate with a pre-computed UTF-8 length.
- `String.getCodepointLength(shim)` -- Shimmer `shim` to a `String` and return the UTF-8 codepoint count (computes and caches if needed).
- `String.shimmerFrom(det, shim)` -- Shimmer `shim` to a `String`; returns `*const String`.
- `String.asHead(self)` -- Get the `*Object` header.

### Source (file/line metadata)
- `Source.new(bytes, file_name, line)` -- Allocate a `Source` carrying its bytes plus an optional file name (`OptionalValue`) and line number.
- `Source.newFromEscaped(escaped, file_name, line)` -- Same, unescaping `escaped` first.
- `Source.asHead(self)` -- Get the `*Object` header.
- `Source` caches its content hash so re-hashing a script is cheap.

### HashReference (a `blake3~<hash>` pointer to a registered object)
- `HashReference.new(referent)` -- Allocate a `HashReference` taking `referent`.
- `HashReference.newFromValue(value)` -- Same, boxing `value` first if it is a primitive.
- `HashReference.shimmerFrom(det, shim)` -- Parse `shim`'s string as a hash ref and resolve it via `registered_hashes`; returns `*const HashReference`.
- `HashReference.resolveAsDictionary(det, shim)` -- Resolve a hash ref and shimmer the target to a `Dictionary`; returns `*const Dictionary`.
- `HashReference.asHead(self)` -- Get the `*Object` header.
- `HashReference.render(hash)` -- Render a `u256` hash as a `blake3~<hash>` reference string (fixed-size, no allocation).

### Index (list index: int or `end?[+-]int`)
- `Index.as_end` -- The bare `end` index.
- `Index.asAbsoluteIndex(self, len)` -- Resolve a possibly-relative index against a list length (returns `i65`, so out-of-range stays representable).
- `Index.Range.fromIndexes(len, start_index, end_index)` -- Resolve two indexes to an absolute `[start, end)` range (Tcl's inclusive end is adjusted).
- `Index.shimmerFrom(det, shim)` -- Parse `shim`'s string into an `Index`.
- `Index.get(det, shim)` -- Fast path: return an inline integer directly without shimmering, else `shimmerFrom`. Returns an `Index` by value.
- `Index.getRange(det, len, start, end)` -- Resolve a start/end pair of `Shimmerable` values to a `Range`.

### Float
- `Float.new(value)` -- Return an inline float `Value`.
- `Float.newBoxed(value)` -- Allocate a heap `Float`.
- `Float.asFloat(value)` -- Return `?f64` for an inline or boxed float, without shimmering.
- `Float.renderFloat(float, buf)` -- Format a float into a `*[350]u8` buffer (appends `.0` for whole numbers).
- `Float.parse(det, bytes)` -- Parse a float from bytes.
- `Float.shimmer(det, shim)` -- Shimmer `shim` to a float.
- `Float.get(det, shim)` -- Shimmer and return the `f64`.
- `Float.asHead(self)` -- Get the `*Object` header.

### Integer
- `Integer.new(value)` -- Return an inline integer `Value`. Never allocates, so it is not fallible.
- `Integer.newBoxed(value)` -- Allocate a heap `Integer` holding an `i64`.
- `Integer.asInt(value)` -- Return `?i64` for an inline or boxed integer, without shimmering.
- `Integer.parse(det, bytes)` -- Parse an `i64` from bytes.
- `Integer.shimmerFrom(det, shim)` -- Shimmer to an integer and return the `i64`.
- `Integer.overflowErrorString(det, rendered_int)` -- Populate `det` from an already-rendered integer and return `error.IntegerOverflow`.
- `Integer.overflowError(IntType, det, rendered_int)` -- Same, rendering `rendered_int` for you.
- `Integer.asHead(self)` -- Get the `*Object` header.

### Number (int-or-float, not an object type)
- `Number.getAsIntOrFloat(det, shim)` -- Resolve `shim` to `.integer` or `.float`, preferring integer.
- `Number.asInt(number)` -- Return `?i64` (null when the number is a float).
- `Number.asFloat(number)` -- Return the value as `f64`, converting integers.
- `Number.division_by_zero_message` / `Number.negative_denom_message` -- Interned error message values.

### Boolean
- `Boolean.new(value)` -- Return an inline boolean `Value`.
- `Boolean.fromString(det, bytes)` -- Parse a Tcl boolean literal from bytes.
- `Boolean.getFromValue(det, value)` -- Coerce a `Value` to `bool` without a `Shimmerable`.
- `Boolean.shimmerFrom(det, shim)` -- Shimmer `shim` to a boolean and return the `bool`.

### List
- `List.new(items)` -- Allocate a `List` from a slice of `Value`s (references each).
- `List.newWithCapacity(items, capacity)` -- Allocate with a pre-reserved backing capacity.
- `List.newFromShimmerables(shims)` -- Allocate a `List` from `[]const Shimmerable`, taking each `.current()`. Use this instead of collecting `.current()` by hand.
- `List.append(list, value)` -- Append a value (references it); grows backing if needed.
- `List.appendAssumeCapacity(list, value)` -- Append without growing (references `value`).
- `List.appendAssumeCapacityOwning(list, value)` -- Append without growing, taking the caller's reference.
- `List.set(list, index, value)` -- Replace a slot, releasing the old value and _taking ownership_ of `value` (it does not take).
- `List.resolveIndex(list, index)` -- Resolve an `Index` against this list's length; null when out of range.
- `List.shimmerWriteback(list, index, value)` -- Replace the item at `index` in place without invalidating the string rep, since string parsing isn't injective.
- `List.getRecursively(det, shim, indexes)` -- Nested lookup along a chain of `Index`-shimmerable positions; returns `OptionalValue`.
- `List.setRecursively(list, det, indexes, value)` -- Nested insert/update along a chain of positions. `list` must already be mutable.
- `List.shimmerFrom(det, shim)` -- Shimmer to a list (dict -> list reuses the items; string -> tokenized list). Returns `*const List`.
- `List.asHead(self)` -- Get the `*Object` header.
- `objects.valuesToShimmerables(gpa, values)` -- Wrap a `[]Value` as `[]Shimmerable` (non-owning; each `Shimmerable` points at the existing value).

### Key-path carriers for recursive dict ops
- `ValueSliceContext` -- `{ items: []const Value }` with `.len`, `.get(index)`, `.sliceAfter(index)`.
- `ShimmerableSliceContext` -- The same interface over `[]Shimmerable`, for command arguments.

### Dictionary
- `Dictionary.new(items)` -- Allocate a `Dictionary` from alternating key/value `Value`s; builds the lookup table.
- `Dictionary.newWithCapacity(items, capacity)` -- Allocate with a pre-reserved backing capacity.
- `Dictionary.asHead(self)` -- Get the `*Object` header.
- `Dictionary.shimmerFrom(det, shim)` -- Shimmer to a dict (list -> dict, requires an even count). Returns `*const Dictionary`.
- `Dictionary.keyNotFoundError(det, key)` -- Populate `det` with a "could not find value for key" message and return `error.KeyNotFound`.
- `Dictionary.getNoFollow(self, key)` -- Look up a key returning `OptionalValue` (no parent-link following).
- `Dictionary.getFollowingLinksMut(self, det, key)` -- Like `getFollowingLinks`, but called directly on an already-mutable `Dictionary`; asserts `canMutate` rather than going through a `Shimmerable`.
- `Dictionary.getPtrNoFollow(self, key)` -- Look up a key returning `?*Value` into the items slice.
- `Dictionary.put(dict, key, value)` -- Insert/update a key (references both), invalidating the string. Asserts `canMutate`.
- `Dictionary.putInner(dict, key, value)` -- Like `put` but returns the value's index in `items`.
- `Dictionary.shimmerWriteback(dict, key, value)` -- Replace an existing key's value in place without invalidating the string; for writing back a shimmered form of the same value.
- `Dictionary.resolveParentDict(dict, det)` -- Follow the `~parent` link to the parent `Dictionary` (or null).
- `Dictionary.remove(dict, det, key)` -- Remove all pairs with `key`; flattens parent links first if the key shadows a parent. Returns true if any were removed.
- `Dictionary.flattenForKey(dict, det, key)` -- Collapse only as much of the `~parent` chain as shadows `key`: an ancestor that doesn't hold `key` stays a link, preserving its sharing across threads. Mutates in place; a no-op when nothing needs collapsing.
- `Dictionary.flattenForKeyInner(dict, det, key)` -- Recursive helper; returns a new flat `Dictionary` combining every ancestor that holds `key`, or null when no ancestor holds it and the chain can stay as-is.
- `Dictionary.getFollowingLinks(det, shim, key)` -- Look up `key`, following `~parent` links recursively; returns `OptionalValue`.
- `Dictionary.getRecursively(det, shim, context)` -- Nested lookup along a key path (`context` is a `ValueSliceContext` or `ShimmerableSliceContext`).
- `Dictionary.putRecursively(dict, det, context, value)` -- Nested insert/update along a key path (creates child dicts as needed).
- `Dictionary.removeRecursively(dict, det, context)` -- Nested remove along a key path.
- `Dictionary.getKvPairs(det, arena, shim)` -- Flatten a linked-dict chain into a `KvResult` (an array hash map with parent keys inserted before child keys). Call `KvResult.deinit(arena)` when done.

### Enums and subcommands (comptime)
- `objects.enumNames(E, joiner)` -- Comptime: join enum variant names with `joiner`.
- `objects.EnumMapping(E, include_numbers)` -- Comptime: build a string-to-enum lookup table type.
- `objects.EnumConstructor(E, include_numbers)` -- Comptime: build a Tcl-facing enum object type, with `.shimmerFrom(det, shim)` and `.get(det, shim)`.
- `objects.SubcommandParser(Enum, subcommands)` -- Comptime: build a subcommand dispatcher with arity validation and usage strings; `.parse(det, args)` returns the variant.

### Misc
- `objects.allocPrintZ(comptime fmt, args)` -- Allocate a `[:0]u8` with `global_gpa` from a format string. This is a zicl helper, distinct from (and not deprecated like) the stdlib function of the same name; prefer it over spelling out `std.fmt.allocPrintSentinel(heap.global_gpa, ..., 0)`.
- `objects.quoteValues(gpa, items)` -- Quote and join a slice of `Value`s into one `[:0]u8`, the `Value` counterpart to `strutil.quoteStrings`.
- `objects.interned_tilde_parent` -- The interned `"~parent"` dict-link key `Value`.
- `objects.ErrorDetails` -- `{ message: [:0]u8, index: ?u32 = null }`; populated by object-level functions on user-facing errors. `message` is owned by the caller when `det != null` and the error is not OOM. `index` reports which argument was at fault, when the function knows.

---

## src/evaltypes.zig

The interpreter's object types and error plumbing. `Interp` re-exports `Error`,
`ReturnCode`, and `ReturnCodeEnum`, so command code usually imports only `Interp`.

- `EvalError` / `Error` -- The interpreter error sets. `Error` adds `WrongUsage` and `Tailcall` on top of `EvalError`.
- `ReturnCode` -- Tcl return codes (`ok`, `error`, `return`, `break`, `continue`, `signal`, `exit`, `oom`, `usage`, `tailcall`).
  - `.fromError(err)` / `.fromErrorUnion(value)` -- Map a Zig error (union) onto a return code.
  - `.toError(self)` -- Map a return code back to a Zig error (or return normally for `ok`).
- `ReturnCodeEnum` -- The `EnumConstructor` view of `ReturnCode`, for parsing `-code` options.
- `CommandFn` / `CCommandFn` -- The Zig and C command signatures.
- `Script.parse(det, value)` -- Tokenize and preprocess a script value. `Script.printTokens(script)` dumps the token table for debugging; `Script.asHead(self)` gets the header.
- `Substitution.parse(det, value, flags)` -- Parse a `[subst]` body with the given `Tokenizer.SubstFlags`.
- `Expression.parse(det, value)` -- Parse an expression into nodes; `Expression.evalNode(interp, nodes, node_index)` evaluates one.
- `Closure.parse(det, bytes)` -- Parse a closure literal. `Closure.Content` holds the parsed body, arg list, and scope:
  - `Content.duplicate` / `Content.deinit` / `Content.getUsage(gpa, command_name)`.
  - `Closure.parseArgList(det, args)` -- Parse an argument-spec list into a `ParsedArgList` (`.deinit()` when done).
  - `Closure.interned_name` / `interned_impl` / `interned_scope` -- The interned dict keys a closure serializes to.
- `NativeCommand` -- The command-table entry. `.getUsageInfo(gpa, command_name)`, `.minArity()`, `.maxArity()`, `.multipleOf()`.
- `CachedNativeCommand` -- Caches a resolved `*const NativeCommand` plus the command-table epoch it was resolved at, stashed onto a `Shimmerable` by `Interp.getCommandFromValue` so a repeated call by the same literal name skips re-resolution.
- `Letrec` -- Wraps a live `scope: *objects.Dictionary` plus a `selected: Value` key, so resolving it as a command re-reads `scope[selected]` on every call instead of freezing a value at wrap time (see the "letrec" section of CLAUDE.md for why). `Letrec.new(det, scope, selected)` builds one (`scope` must already be cross-thread). `Letrec.shimmerFrom(det, shim)` parses the `letrec <hash>` string form. `Letrec.asHead(self)` gets the header; `Letrec.interned_select` is the interned `"select"` key `[letrec select]` dispatches on; `Letrec.prefix` (`"letrec "`) is the string-form prefix.

---

## src/Tokenizer.zig

The shared tokenizer for both scripts and expressions ("cobbled together from Molt,
Zig's tokenizer, and Jimtcl" per the file's own header). `evaltypes.Script.parse` and
`evaltypes.Expression.parse` drive it; most command code never touches it directly.

- `Tokenizer.init(buffer, line_no)` -- Start tokenizing `buffer` from `line_no`.
- `Tokenizer.Error` -- `ScriptError || ExpressionError`, the union of every tokenizing failure.
- `Token` / `Token.Tag` / `Token.Location` -- One token: its tag, and its `{start, end, line_no}` span in the source.
- `tokenizer.nextScriptToken()` -- Next token in script grammar (words, command/variable substitution, braces, quotes).
- `Tokenizer.SubstFlags` -- `packed struct(u3) { command_subst, variable_subst, escape_subst }`, which kinds of substitution `[subst]` should perform; all default true.
- `tokenizer.nextSubstToken(flags)` -- Next token for a `[subst]` body, honoring `flags`.
- `tokenizer.nextStringToken()` -- Next plain/escaped string token within a word.
- `tokenizer.nextVariableToken()` -- Next `$name`/`$name(key)`/`${brace name}` token; `error.NotVariable` for a bare `$` that isn't one.
- `tokenizer.nextCommandToken()` -- Next `[...]` command-substitution token.
- `tokenizer.nextBracedStringToken()` -- Next `{...}` literal token.
- `tokenizer.nextEolToken()` / `tokenizer.nextSeparatorToken()` -- Next end-of-line / word-separator token.
- `tokenizer.nextCommentToken()` -- Consume a `#`-prefixed comment; produces no token.
- `tokenizer.nextListToken()` / `tokenizer.nextListStringToken()` -- Tokenize one element of Tcl list syntax (used by `List.shimmerFrom` on the string -> list path).
- `tokenizer.nextExpressionToken()` -- Next token in expression grammar (operators, numbers, function names, parens).
- `Tokenizer.function_names` -- The recognized `expr` function names (`abs`, `sin`, ...), matched by `nextExpressionToken`.
- `tokenizer.nextOperatorToken()` / `tokenizer.nextIrrationalFloatToken()` / `tokenizer.nextBooleanToken()` / `tokenizer.nextNumberToken()` -- Sub-parsers `nextExpressionToken` and `nextScriptToken` dispatch into.
- `Tokenizer.boolean_mapping` -- The literal-to-`bool` table (`"1"`/`"true"`/`"yes"`/`"on"` and their false counterparts) `nextBooleanToken` and `objects.Boolean.fromString` both key off.
- `Tokenizer.convertTokenizerError(gpa, err)` -- Render a `Tokenizer.Error` as a user-facing `[:0]u8` message.

---

## src/expr_parse.zig

Builds the `expr` AST that `evaltypes.Expression.parse`/`evalNode` walk. Operates on
tokens already produced by `Tokenizer.nextExpressionToken`.

- `Node` / `Node.Tag` / `Node.Data` / `Node.Index` -- One AST node: its operator/operand tag, its `unary`/`binary`/`ternary` child indexes or literal `value`, addressed by an opaque `Index` rather than a pointer (stable across the backing slice's reallocation).
- `Parser.init(gpa, source_file_name, source, tokens)` -- Build a parser over an already-tokenized expression.
- `parser.parseExpr()` -- Parse the full expression by precedence climbing; returns a `Parsed` or `error.ParseError` (details in `parser.err`).
- `parser.deinit()` -- Drop any `Value`s held by parsed nodes and free the node list.
- `Parser.Error` / `Parser.Error.Tag` -- The parse failure recorded in `parser.err`, one variant per grammar mistake (`missing_operand`, `too_many_r_parens`, `comma_outside_function`, ...). `.sourceIndex(err, p)` maps it back to a byte offset.
- `parser.renderError(parse_error, w)` -- Render a `rustc`-style single-line-context error (line number gutter, source line, `^` caret under the offending token).
- `parser.dump(node)` -- Debug: print a node's rendered form to stderr.
- `Parsed` -- `{ nodes: []Node, root_node: Node.Index }`, the parse result. `.render(writer)` writes it back out as expression syntax (round-trips `expr_parse` -> text); `.renderInner(writer, node_index)` renders a specific subtree. `.enumerateStruct(ctx, info)` is the leak-graph walker hook.

---

## src/vartypes.zig

Variable resolution and the cache object types behind it.

- `vartypes.setVariable(interp, det, call_frame_idx, name, value)` -- Set a variable in the given call frame, following dict sugar and upvar links.
- `vartypes.setVariableUpvar(interp, det, ...)` -- Create an upvar link into another frame.
- `vartypes.getVariable(interp, det, call_frame_idx, name)` -- Look up a variable, returning `OptionalValue`.
- `vartypes.getVariableOrError(interp, det, call_frame_idx, name)` -- Like `getVariable` but reports "no such variable".
- `vartypes.unsetVariable(interp, det, call_frame_idx, name)` -- Remove a variable.
- `vartypes.ensureValidVariableType(...)` -- Validate/normalize the object stored in a variable slot.
- `vartypes.badVariableNameError(det, name)` -- Populate `det` with a "not a valid variable name" message and return `error.BadVariableName`.
- `vartypes.expectErrorOrOom(expected_error, actual_error_union)` -- Test helper mirroring `memutil.expectErrorOrOom`.
- `VariableSlot` -- `union(enum) { normal: Value, upvar: Upvar }`, what one call frame slot holds; an upvar is a variant here rather than its own object type since a slot is never handed to Tcl as a value. `.takeReference(slot)` / `.dropReference(slot)` take/drop the contained value.
- `VarTable` -- The variables of one call frame: an insertion-ordered `Value`-to-`VariableSlot` map, deliberately not an `Object` (no string rep to keep in sync, cannot be referenced, cannot shimmer). `.create()` / `.destroy(table)` allocate and free. `.count(table)`, `.getIndex(table, name)`, `.slotAt(table, index)` -- lookups by name or stable index. `.put(table, name, slot)` -- insert or overwrite, taking both. `.remove(table, name)` -- remove by name, returning whether it was present.
- `CachedLocalVar` / `CachedLexicalVar` -- Cached variable-name objects carrying a resolved slot plus the epoch it was resolved at. `CachedLocalVar.getCurrentValue(self)` reads through the cache.
- `UpvarLink` -- A variable name that resolves into another call frame.
- `DictSugar` -- `var(key)` names. `.isValidDictSugar(name)`, `.parseDictSugar(name)`, `.shimmerAssumeValid(name)`.
- `VariableValue` -- The tagged union of what a variable slot can hold.

---

## src/regex.zig

The pcre2 foundation. Kept out of `src/commands/` because `heap.zig` drives the
context lifecycle, and the foundation must not import from the command layer.

- `regex.initGlobals()` / `regex.deinitGlobals()` -- Set up and tear down the pcre2 general context (wired into `heap.initGlobals`/`deinitGlobals`).
- `regex.pcre2_ctx` / `regex.pcre2_match_ctx` -- The global contexts. Read them through `regex.` at the point of use; aliasing one at container scope captures the pre-`initGlobals` value.
- `Regexp.shimmerFrom(det, shim, compile_opts)` -- Compile `shim`'s string into a pcre2 pattern. `Regexp`'s `duplicate` is `Object.duplicateStringOnly`, so a duplicate recompiles on next use.
- `regex.doesStringMatch(det, re, bytes)` -- Boolean match against a compiled pattern. Used by [switch] `-regexp` as well as by the regex commands.

---

## src/commands/regex.zig

- `regexpCmd` / `regsubCmd` -- The [regexp] and [regsub] implementations, registered by `registerCommands`.
- `matchToList(...)` -- Run a match and build the result list.
- `createIndexPair(start, end)` -- Build the two-element `{start end}` list used by `-indices`. Both indices are inclusive, unlike pcre2's ovector end.

---

## src/Capability.zig

Capabilities are the object type for handles that can't be automatically tracked the
way content-addressed hash references are (an open file, a running process, a raw C
pointer) -- unforgeable URLs like `<zicl://host/file-handle/sVye-a...>`, manually
opened and closed rather than ref-count-freed on last use. See the file's own header
comment for the full design rationale.

- `Capability.new(head)` -- Wrap an already-constructed `Head` (with its vtable set, `id` left uninitialized) as a `*Capability` object, registering it.
- `capability.asHead(self)` -- Get the `*Object` header (name collision with `Capability.Head` below is intentional: this is the object-system `asHead`, not the capability's own head).
- `capability.getBacking(self, Backing, det)` -- Recover the typed `*Backing` behind a capability, checking its vtable matches `Backing.vtable` and that it isn't closed.
- `capability.close(self)` -- Close the underlying `Head` (idempotent).
- `Capability.shimmerFrom(det, shim)` -- Parse a capability URL string and resolve it against the registry; rejects a capability from a different host and a stale (deregistered) id.
- `Capability.Head` -- The generic, atomically ref-counted part of a capability; `extern` so a C program can embed `Zicl_Head` as its backing struct's first field. `.takeReference(head)` / `.dropReference(head)`, `.close(head)` (runs `deinitBody` once, then deregisters), `.isClosed(head)`.
- `Capability.Head.VTable` -- `extern struct { name: [*:0]const u8, deinitBody: *const fn(*Head) callconv(.c) void, destroyBacking: *const fn(*Head) callconv(.c) void }`, one per capability kind (`"file-handle"`, `"process"`, `"pointer"`, ...).
- `Capability.Registry` -- Maps `Id` (`i128`) to `Head`, holding a strong reference to each. `.register(self, head)` assigns a CSPRNG id and inserts; `.deregister(self, head)` removes; `.resolve(self, id)` looks up, taking.
- `Capability.registry` -- The global `Registry` instance.
- `Capability.initGlobals(options)` / `Capability.deinitGlobals()` -- Set up the registry's CSPRNG and host name (or `deinitGlobals`: close and drop whatever capabilities are still open, e.g. at process shutdown). Wired into `heap.initGlobals`/`deinitGlobals`.
- `Capability.ParsedName` -- `{ host, type_name, id }`, the parsed form of a capability URL string.
- `Capability.parseName(det, bytes)` -- Parse a `<zicl://host/type/id>` string into a `ParsedName`, without resolving it against the registry.

---

## src/capabilities.zig

The concrete capability kinds built on `Capability.Head`. Each is a `Backing = struct
{ head: Capability.Head, body: <Kind> }` with its own `deinitBody`/`destroyBacking`.

- `capabilities.File` -- An open file. `.open(path, mode)` (`Mode` is `r`/`r+`/`w`/`w+`) creates a `"file-handle"` capability; `.openDescriptor(handle)` wraps an already-open fd without closing it when the capability closes. `.writeAll(file, bytes)` / `.readAll(file)` (whole-file slurp only; no partial/character-counted read yet).
- `capabilities.Process` -- A running pipeline, held as one capability regardless of stage count, since nothing else reaps its children. `.new(stages)` takes ownership of an already-spawned `[]Stage`. `.wait(self)` blocks until every stage exits and returns the pipeline's overall `Term` (an earlier failure is not masked by a later success); safe to call from two threads or call again after any outcome. `.pids(self, out)` reports each stage's pid, or null once reaped. `.pipelineTerm(stages)` / `.isNormalExit(term)` compute the overall result from already-waited stages. `Process.Stage.wait(self)` / `.kill(self)` operate on one stage.
- `capabilities.Pointer` -- A raw C pointer whose lifetime Zicl now owns, for FFI wrappers that want to hand a script an opaque handle without a bespoke capability type per pointed-to C type. `.new(ptr, type_name, destructor)` creates a `"pointer"` capability; `destructor` runs once at close (never for a null `ptr`). `.getTyped(cap, expected_type_name, det)` is `Capability.getBacking` plus a `type_name` check, since every `Pointer` shares one vtable and so gets no vtable-identity type safety for free.

---

## src/Interp.zig

Beyond `evalObject`/`callClosure`, `Interp` carries the helpers command code leans on
most.

### Results
- `interp.setResult(value)` / `setResultOwning(value)` -- Set the result, taking or taking ownership.
- `interp.setResultInteger` / `setResultFloat` / `setResultBoolean` / `setResultString` / `setResultStringOwning` / `setResultFormatted` / `setEmptyResult`.
- `interp.setError(value)` -- Set the result and return `error.EvalError`.
- `interp.setErrorString(bytes)` -- `setResultString` plus `error.EvalError`.
- `interp.setErrorFormatted(comptime fmt, args)` -- `setResultFormatted` plus `error.EvalError`.
- `interp.nextRandomFloat()` -- Draw the next `f64` in `[0, 1)` from the interpreter's PRNG.

### Coercions (these wrap the `objects` shimmer functions with interpreter error reporting)
- `interp.getInteger(shim)` / `getIntegerInPlace(ref)`
- `interp.getFloat(shim)`
- `interp.getBoolean(shim)` / `getBooleanInPlace(ref)`
- `interp.getIntOrFloatInPlace(ref)` -- Returns an `objects.Number`.
- `interp.getIndex(shim)`, `interp.getList(shim)` / `getListInPlace(ref)`, `interp.getDict(shim)` / `getDictInPlace(ref)`, `interp.resolveHash(shim)`
- `interp.wrapShimmerFn(...)` / `wrapShimmerInPlaceFn(...)` -- Build the above wrappers for a new type.
- `interp.integerOverflowError(IntType, rendered_int)` -- Interpreter-level counterpart to `Integer.overflowError`.
- `interp.wrapError(det, result)` / `Interp.narrowError(err)` / `Interp.narrowToEvalError(result)` -- Convert an object-level error plus `ErrorDetails` into an interpreter error with a message set.

### Variables and dict/list access (interp-level wrappers)
Thin wrappers over `vartypes`/`objects.Dictionary`/`objects.List` that default to the
interp's current call frame (`interp.callFrameIdx()`) and report failures into the
interpreter result via `wrapError`, instead of taking an explicit `call_frame_idx` and
`*ErrorDetails` the way the `vartypes`/`objects` free functions do.

- `interp.setVariable(name, value)` / `setVariableInFrame(call_frame_idx, name, value)` -- Set a variable, in the current or a given frame.
- `interp.setVariableSilent(name, value)` -- Like `setVariable` but propagates the raw error instead of writing a result message.
- `interp.setVariableUpvar(name, target_call_frame_idx, target_name)` -- Create an upvar link from the current frame into `target_call_frame_idx`.
- `interp.getVariable(name)` / `getVariableInFrame(call_frame_idx, name)` -- Look up a variable, returning `OptionalValue`.
- `interp.getVariableOrError(name)` -- Like `getVariable` but reports "no such variable".
- `interp.unsetVariable(name)` / `unsetVariableSilent(name)` -- Remove a variable, with or without setting a result message on failure.
- `interp.getDictValue(dict, key)` -- `Dictionary.getFollowingLinks` through a `Shimmerable`, reporting into the interp result.
- `interp.getMutDictValue(dict, key)` -- Same, but through `Dictionary.getFollowingLinksMut` on an already-mutable dict.
- `interp.getDictValueOrError(dict, key)` -- Like `getDictValue` but sets a "could not find value for key" result on a miss.
- `interp.getDictValueInPlace(dict, key)` -- Like `getDictValue` but uses `*Value` directly, wrapping it in a throwaway `Shimmerable` and writing back any shimmer.
- `interp.getDictValueRecursively(shim, context)` / `getDictValueRecursivelyOrError(shim, context)` -- Nested key-path lookup (`context` is a `ValueSliceContext` or `ShimmerableSliceContext`); the `OrError` variant renders all path keys into the error message.
- `interp.putDictValueRecursively(dict, context, value)` -- Nested key-path insert/update.
- `interp.removeDictValue(dict, key)` -- Remove a key; returns whether anything was removed.
- `interp.removeDictValueRecursively(dict, context)` -- Nested key-path remove.
- `interp.getListValueRecursively(shim, keys)` / `setListValueRecursively(list, indexes, value)` -- Nested list-index lookup/update.

### Evaluation and scope
- `interp.evalValue(script)` -- Evaluate a script value in the current call frame, resetting the stack trace for this top-level invocation. `evalValueInner(call_frame, script, cache_key)` is the shared inner loop both this and looping constructs call per iteration, so an iterating script doesn't accumulate arena usage.
- `interp.evalTopLevel(script)` -- `evalValue` for scripts entered from outside the interpreter (a file, an embedder call): a `[return]` reaching this boundary ends the script and keeps its result rather than escaping as an error, and a stray `[tailcall]` is rejected since there is no closure left to call from C.
- `interp.evalFile(filename)` -- Read and evaluate a file.
- `interp.evalExpression(value)` / `getBoolFromExpression(value)` / `evalSubstitution(value, flags)`.
- `interp.getScript` / `getExpression` / `getClosure` / `getSubstitution` -- Cache-aware parse entry points.
- `interp.getCommand(call_frame_idx, name, can_be_method)` -- Resolve a variable name to a `CommandVariant`, referenced; plumbs a letrec's scope through inner closure calls automatically. Use `CommandVariant.deinit()` for cleanup.
- `interp.getCommandFromValue(shim, can_be_method)` -- The value-level half of `getCommand`, for a value already in hand rather than a variable name; also caches native-command lookups onto `shim` as a `CachedNativeCommand`.
- `interp.invokeCommand(command_variant, args)` -- Dispatch a resolved `CommandVariant` (enforces `max_eval_depth`).
- `interp.invokeCommandMaybeMethod(args_raw)` -- Resolve `args_raw[0]` and invoke it, populating the `self` parameter when the name is a method-style dict-sugar path. `args_raw` must have room at `[0]` beyond `args_raw[1..]` for the method rewrite.
- `interp.registerCommand(name, command)` -- Register a `NativeCommand`.
- `interp.callFrame()` / `callFrameIdx()` / `evalFrame()` / `evalFrameIdx()` / `nextCallEpoch()`.
- `interp.getRelativeCallFrame(from, levels_up)` -- Walk `levels_up` parent links starting at `from`; null if the chain runs out first.
- `interp.captureScope(call_frame_idx)` / `captureCurrentScope()` -- Snapshot a frame's variables as a `Dictionary`.
- `interp.setErrorStack()` -- Populate `errorInfo` from the current eval frames, if not already set.
- `interp.buildErrorStack()` -- Build the stack trace as a flat `{name file line args}` list, one group per call frame, innermost first. Called by `setErrorStack`; use directly to build a trace outside the normal error path.
- `Interp.init(cfg)` / `interp.deinit()` -- Create and destroy an interpreter. `cfg` currently carries only `cache_capacity` (default 512).

### Test helpers
- `Interp.testRunScript(interp, script)` -- Evaluate a script and return the result value.
- `Interp.testExpectScriptResult(interp, expected, script)` -- Assert the result string matches.
- `Interp.testExpectScriptError(interp, expected_error, expected_str, script)` -- Assert the script fails with a specific error and message.

---

## src/commands/common.zig

Shared imports and registration glue for the command modules. Command modules import
this as `common` and re-use its `heap`/`objects`/`Interp` aliases.

- `common.registerCommand(interp, name, to_call, description, min_arity, max_arity)` -- Register a Zig command with its arity contract.
- `common.registerCoreCommands(interp)` -- Register every ported command module.
- `common.testStart(ta)` -- `heap.testStart` + `Interp.init` + `registerCoreCommands`; returns the `Interp` by value.
- `common.testFinish(&interp)` -- `interp.deinit()` + `heap.testFinish()`.

---

## src/memutil.zig

### Allocators
- `memutil.null_allocator` -- An allocator that fails every request; use it to assert a path does not allocate.
- `RingBufferAllocator.init(buffer)` -- Initialize a ring buffer allocator over a fixed buffer.
- `RingBufferAllocator.allocator(self)` -- Return a standard `Allocator` backed by this ring buffer. `free` is a no-op; `resize`/`remap` unsupported.
- `ScopedArena.init(child_allocator)` -- Create an empty scoped arena (bump allocator over a linked list of segments, modeled on std's `ArenaAllocator`).
- `ScopedArena.deinit(arena)` -- Free all segments.
- `ScopedArena.allocator(self)` -- Return a standard `Allocator` backed by this arena. `free` and shrink `resize` only affect the most recent allocation; growing in place works only for the last allocation with segment slack.
- `ScopedArena.queryCapacity(arena)` -- Total buffer bytes across all segments (excluding segment headers).
- `ScopedArena.takeSnapshot(arena)` -- Take a point-in-time `Snapshot` (`extern struct { current: ?*Segment, end_index: usize }`, safe to pass by value across the C ABI; null `current` marks a snapshot from before any segment existed).
- `ScopedArena.restore(arena, snapshot)` -- Restore the arena to `snapshot`: segments after the snapshot point are freed and reclaimed bytes are poisoned in safety builds.
- `ScopedArena.cascadeFreeSegments(arena, start)` -- Free `start` and every segment linked after it.
- `ScopedArena.Segment.min_size` / `.max_default_size` -- 8 KiB / 32 KiB growth bounds; larger allocations get their own oversized segment.

### IndexedMemoryPool
- `memutil.IndexedMemoryPool(Item)` -- Comptime: a pool returning `usize` indices instead of pointers.
  - `.initWithCapacity(gpa, capacity)`, `.create(gpa)`, `.createAssumeCapacity()`, `.clearRetainingCapacity()`, `.destroy(index)`, `.deinit(gpa)`, `.dumpLeaked(scratch, fmt)`.

### LruCache
- `memutil.LruCache(K, V, Context)` -- Comptime: an LRU cache.
  - `.initWithCapacity(gpa, max_size)`, `.deinit(gpa)`, `.get(key)`, `.getPtr(key)`, `.put(key, value)` (returns the evicted value if at capacity), `.valueIterator()`, `.clearRetainingCapacity()`.

### StructIterator / GraphWalker (leak diagnostics)
- `memutil.StructIterator` -- Drives a typed walk over the heap graph for leak reporting.
  - `.followUnparentedNode(ctx, T, ptr)` -- Walk a root node with no parent.
  - `.followNode(ctx, T, info, field_name, ptr)` / `.followNodeInner(...)` -- Walk a child node.
  - `.addFieldString(ctx, T, info, field_name, str)` / `.addField(ctx, T, info, field_name, fmt, val)` -- Add a scalar leaf.
- `memutil.GraphWalker` -- Collects nodes and edges discovered by a `StructIterator`.
  - `.empty` -- Empty walker.
  - `.promote(self, arena)` -- Return a `StructIterator` that feeds this walker.

### Testing
- `memutil.expectErrorOrOom(expected_error, actual_error_union)` -- Assert an error matches `expected_error` (passes through OOM).
- `memutil.OomTesting` -- `union(enum) { exhaustive, unsupported: []const u8 }`, the per-test declaration of whether it takes part in the full OOM sweep.
- `memutil.checkAllocationFailures(comptime mode, comptime func, args)` -- Runs `func` once against `testing.allocator` normally, and only performs the full `checkAllAllocationFailures` sweep when `mode == .exhaustive` and `-Dfull-oom-testing` is enabled. Use `testing.checkAllAllocationFailures` directly instead when a test is cheap enough to always sweep.

### Hash context
- `memutil` string hash context: `.hash(self, s)` (Wyhash), `.eql(self, a, b)` (byte equality).

---

## src/strutil.zig

- `strutil.checkAllAscii(bytes, check)` -- True if every byte passes the predicate.
- `strutil.isGraph(c)` / `strutil.isPunct(c)` -- ASCII character class checks.
- `strutil.encodeCodepoint(cp, buf)` -- Encode one codepoint into a `*[4]u8` (UTF-8) or 1 byte (ASCII build); can fail like `std.unicode.utf8Encode` on a surrogate half or an out-of-range codepoint, though every in-tree caller sources `cp` from decoding valid UTF-8 or remapping a valid codepoint, so that path never actually fires here.
- `strutil.toTitle` / `strutil.toUpper` / `strutil.toLower` -- Case conversion functions (UTF-8 or ASCII depending on `-Duse-utf8`).
- `strutil.compare(a, b, up_to_cp, case_insensitive)` -- Lexicographic codepoint-order comparison.
- `strutil.cpIndexUtf8(str, index)` / `strutil.cpIndexAscii(str, index)` / `strutil.cpIndex` -- Convert a codepoint index to a byte offset.
- `strutil.codepointLength(str)` / `strutil.strlenUtf8(str)` / `strutil.strlenAscii(str)` -- Count codepoints.
- `strutil.findCodepoint(str, cp)` -- Byte offset of the first occurrence of codepoint `cp`.
- `strutil.trimLeft(str, trim_chars)` / `strutil.trimRight(str, trim_chars)` -- Return the offset/length after trimming.
- `strutil.charsetMatch(pattern, cp, flags)` -- Match a Tcl charset pattern (e.g. `[a-z]`) against a codepoint.
- `strutil.globMatch(pattern, str, case_insensitive)` -- Glob-style pattern match on byte slices.
- `strutil.findFirstOccurrence(needle, haystack, cp_index)` / `strutil.findLastOccurrence(needle, haystack)` -- Substring search by codepoint offset.
- `strutil.findLastOccurrenceBounded(needle, haystack, max_start_byte)` -- Like `findLastOccurrence`, but only considers matches starting at or before `max_start_byte` (the match itself may extend past it). What `[string last]` uses for its optional `lastIndex` argument.
- `strutil.hexDigitValue(c)` / `strutil.isHexDigit(c)` -- Hex digit helpers.
- `strutil.parseInt(bytes)` -- Parse a Tcl integer literal into `i64`. Currently just `std.fmt.parseInt`, kept as its own entry point in case Tcl-specific parsing is needed later.
- `strutil.removeEscaping(source, dest)` -- Process backslash escapes; return the resulting length.
- `strutil.QuotingType` -- `enum { bare, brace, escape }`.
- `strutil.calculateNeededQuotingType(str)` -- Determine how a string must be quoted.
- `strutil.quoteSize(quoting_type, str_len)` -- Output buffer size needed to quote a string.
- `strutil.quoteString(quoting_type, src, dest, escape_first_pound)` -- Write a quoted string into `dest`; return bytes written.
- `strutil.quoteStrings(gpa, items)` -- Quote and join a slice of strings into one `[:0]u8`.
- `strutil.Iterator.init(bytes)` / `.next()` / `.peek()` / `.prev()` -- Codepoint iterator (UTF-8 or ASCII depending on `-Duse-utf8`); `prev` scans backwards by one codepoint, symmetric with `next`.

---

## src/ioutil.zig

Stdout and stderr are threadlocal fd overrides, not a process-wide lock, so
redirecting one thread's output never affects another thread's.

- `ioutil.local_stdout_fd` / `ioutil.local_stderr_fd` -- Threadlocal fd overrides (default to the real stdout/stderr fds), for redirecting output in tests and embedders.
- `ioutil.getStdout()` / `ioutil.getStderr()` -- Return the current thread's stdout/stderr as a `std.Io.File`.
- `ioutil.debug(comptime fmt, args)` -- Print to stderr via `getStderr()`.

---

## src/leak_check.zig

- `leak_check.initThread()` -- Set up this thread's ring-buffer allocator for trace-log string copies (only when `trace_mem` is on; idempotent).
- `leak_check.deinitThread()` -- Free this thread's ring-buffer allocator.
- `leak_check.deinit()` -- Reset the (process-wide) trace log and counts.
- `leak_check.dupeForTrace(bytes)` -- Copy `bytes` into this thread's ring buffer so a log entry can hold string content that outlives the object it came from. Old copies can be overwritten by later traces on the same thread; only for debugging output, never load-bearing.
- `leak_check.globalTrace(ptr, info)` -- Append a trace entry for `ptr` with a stack trace; `info` is the `LogInfo` union (`.alloc`, `.incr_ref_count`, `.decr_ref_count`, `.invalidate_rep`, `.invalidate_string`, `.set_string`, `.free`). Inlined; no-op when `trace_mem` is off.
- `leak_check.captureLeaks()` -- Walk every leaked object via `GraphWalker`/`StructIterator`; returns a `LeakResult` (dot graph + per-object logs).
- `leak_check.dumpLeaks()` -- Capture leaks and dump the dot graph + details to stderr. Quiet when there are no leaks. Called from `heap.testFinish`.
- `leak_check.dumpLastTouchedTrace(fd)` -- Dump the operation history of the most recently touched object (hooked into the panic path). Re-entrancy guarded.
- `LeakResult.dumpDot(writer)` -- Render the leak graph as a Graphviz dot digraph.
- `LeakResult.dumpDetails(terminal)` -- Print each leaked object's operation history with stack traces, to a `std.Io.Terminal`.
- `LeakResult.deinit(result)` -- Free the result's arena.
- `leak_check.checkCrossthreadInvariant()` -- Walk every currently-live object (from the trace log's net alloc-minus-free count, not a particular container) looking for an edge from a crossthread object into a non-crossthread one, the invariant `Object.makeCrossthread` is supposed to establish for its whole subgraph. Returns a `CrossthreadCheckResult`; only meaningful when `trace_mem` is on.
- `leak_check.dumpCrossthreadCheck()` -- `checkCrossthreadInvariant` plus dump the result to stderr. Callable from gdb.
- `CrossthreadViolation` -- `{ parent: *const Object, child: *const Object, field_name: []const u8 }`, one crossthread-into-non-crossthread edge found by `checkCrossthreadInvariant`.
- `CrossthreadCheckResult.deinit(result)` -- Free the result's arena.
- `CrossthreadCheckResult.dump(result, writer)` -- Print each violation, or "No crossthread violations found." when clean.

---

## src/libzicl.zig

The C API surface: almost entirely `export fn Zicl_*` bindings (C ABI, `callconv(.c)`)
over the Zig types documented elsewhere in this file, not `pub fn` helpers meant to be
called from other Zig code. Out of scope for a "what already exists in Zig" index;
consult the file directly (or `.claude/cookbook.md`'s C API recipes) when working on
the C boundary itself. The handful of genuinely internal `pub` declarations:

- `ziclLog(level, scope, format, args)` -- The `std.log` implementation this binary installs (`std_options.logFn`), writing through `ioutil.getStderr()`.
- `ziclPanic(msg, first_trace_addr)` -- The `panic` implementation (`std.debug.FullPanic(ziclPanic)`): dumps the last-touched-object trace, prints the panic message and stack trace to stderr, then aborts. Guards against recursive panics with a threadlocal stage counter.

---

## src/test_runner.zig

The project's custom unit-test runner (`build.zig` points `zig build test` at this
instead of Zig's default), so it can hook `dumpLastTouchedTrace` into both the panic
and segfault paths.

- `panicFn(msg, first_trace_addr)` -- The `panic` implementation: dumps the last-touched-object trace to fd 2, then defers to `std.debug.defaultPanic`.
- `debug.handleSegfault(addr, name, opt_ctx)` -- Overrides Zig's segfault handler the same way: a segfault does not route through `panicFn` (Zig's signal handler calls this directly), so without this override a use-after-free that faults rather than panics would skip the trace dump entirely.
- `panicFmt(comptime format, args)` -- `std.debug.panicExtra` wrapper used by the runner's own assertions.
- `main(init)` / `log(...)` / `mainSimple(...)` / `fuzz(...)` -- The test-running entry points (normal run, simple/no-server mode, fuzz mode); not meant to be called directly, only referenced by `zig build test`'s generated root.

---

## src/root.zig

The standalone `zicl` binary's entry point (as opposed to the library surface in
`libzicl.zig`). Also re-exports every module under `test {}` so `zig build test`
sees them.

- `main(init)` -- Sets up the heap/thread/interpreter, registers core commands, then runs a REPL loop over stdin/stdout (`> ` prompt, evaluate each line with `interp.evalValue`, print the result).
- `panic` / `panicAndPrintTraces(msg, first_trace_addr)` -- Dumps the last-touched-object trace via `heap.dumpLastTouchedTrace(-1)` before deferring to `std.debug.defaultPanic`.

---

## src/repl.zig

Not part of the build graph reachable from `main` or the test root; a standalone
scratch file exploring `uucode`'s case-mapping API (`uucode.get(.uppercase_mapping,
...)`). It references `ioutil` without importing it, so it does not currently compile.
Nothing here is a reusable helper; flagging its existence only so it isn't mistaken
for the REPL (that's `root.zig`'s `main`).

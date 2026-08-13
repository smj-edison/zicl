# Helper function index

Public helper functions in the foundation files and the interpreter layer. Consult
this before implementing anything that might already exist.

---

## src/heap.zig

### Global lifecycle
- `heap.initGlobals(gpa, io)` -- Initialize global heap state (`global_gpa`, `global_io`, registries, leak check, regex globals). Idempotent; call once per process (or test).
- `heap.deinitGlobals()` -- Tear down global state. After this, `initGlobals` may be called again.
- `heap.initThread()` -- Initialize the calling thread's `local_arena` (a `memutil.RewindableArena` over `global_gpa`).
- `heap.deinitThread()` -- Tear down the calling thread's arena.
- `heap.testStart(gpa, io)` -- Test helper: `initGlobals` + `initThread`.
- `heap.testFinish()` -- Test helper: dump leaks (if `trace_mem`), `deinitThread`, `deinitGlobals`. Use with `defer`.
- `heap.dumpLastTouchedTrace(fd)` -- Exported: dump the operation history of the last-touched object to a file descriptor (used by panic handlers).
- `heap.initialized`, `heap.init_mutex`, `heap.running_leak_check` -- Global state flags. Lock `init_mutex` when adding or removing global registrations, not when reading them.

### Registries
- `heap.LazyRegisterFn` -- Signature for a lazy native command initializer: `*const fn (interp: *anyopaque) callconv(.c) void`.
- `heap.nativefn_registry.register(gpa, name, init_fn)` -- Register a lazy C command initializer; `error.DuplicateLazyFn` on duplicates.
- `heap.nativefn_registry.get(name)` -- Look up a lazy initializer by name, or null.
- `heap.registered_hashes.getAndBorrow(hash)` -- Look up a `u256` hash and return a borrowed `*Object` (or null). Thread-safe via shared lock.
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
- `Value.borrow(value)` -- Increment ref count and return the same `Value`.
- `Value.release(value)` -- Decrement ref count and free if zero (no-op for primitives).
- `Value.duplicate(value)` -- Shallow copy (deep for the string rep); primitives return themselves.
- `Value.duplicateAsBoxed(value)` -- Like `duplicate` but always returns a heap `*Object` (boxes primitives).
- `Value.swap(ref, new)` -- Set `ref.* = new` and release the old value.
- `Value.makeCrossthread(value)` -- Recursively mark a pointer value cross-thread (no-op for primitives).
- `Value.getString(value)` -- Return the string rep, generating it if needed (may allocate for objects; primitives render into `local_arena`).
- `Value.getStringWithBuffer(value, buf)` -- Like `getString` but takes a `*[350]u8` stack buffer so primitives never allocate. Only OOMs when the value is an object that OOMs generating its string.
- `Value.equals(a, b)` -- Deep string equality, with fast paths per tag pair (compares hashes when both sides are special strings).
- `Value.equalsString(value, str)` -- Compare a value's string rep to a byte slice.
- `Value.getHashNoRegister(value)` -- Return the `u256` Blake3 content hash without registering in the hash registry. This is the hash that travels between machines; for a hash table's index use `heap.indexHash` instead.
- `Value.trace(value, fmt, args)` -- Append a trace entry (only when `trace_mem` is enabled).

### OptionalValue
- `OptionalValue.none` -- The empty representation.
- `OptionalValue.isNone(optional)` / `.isSome(optional)` -- Tag checks.
- `OptionalValue.asValue(optional)` -- Return `?Value` (null if none).
- `OptionalValue.fromValue(value)` -- Convert `?Value` to `OptionalValue`.
- `OptionalValue.borrow(optional)` -- Borrow the contained value (nop if none).
- `OptionalValue.makeCrossthread(optional)` -- Mark the contained value cross-thread (nop if none).
- `OptionalValue.release(optional)` -- Release the contained value (nop if none).
- `OptionalValue.orElse(optional, otherwise)` -- Return the contained value or `otherwise`.
- `OptionalValue.orEmpty(optional)` -- Return the contained value or the interned empty string.
- `OptionalValue.swap(ref, new)` -- Overwrite `ref.*` with `new`, releasing the old value.
- `OptionalValue.swapWithNone(ref)` -- Release the contained value and set to none (use in `errdefer`).

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
- `Object.borrow(obj)` -- Increment and return the same `*Object`.
- `Object.release(obj)` -- Decrement and free at zero; unregisters from the hash registry when a representative or registered object reaches the threshold.
- `Object.swap(ref, new)` -- Set `ref.* = new` and release the old object.
- `Object.invalidateString(obj)` -- Free the string rep (asserts `canShimmer`).
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
- `hashutil.scanAndResolveHashRefs(arena, bytes)` -- Scan for hash refs and resolve each against `registered_hashes`, borrowing representatives; returns `[]SpecialString.HashAndInfo`.

### Index hashing (for hash tables, not for content addressing)
- `heap.indexHash(value)` -- Hash a value for a table's index. Wyhash below `index_hash_cutoff`, the cached Blake3 at or above it. Infallible, so it can be called from a hash context; run `ensureIndexHashable` first.
- `heap.ensureIndexHashable(value)` -- Prepare a key so `indexHash` and `Value.equals` cannot allocate. Primitives need nothing; an object needs its string rep, and a long one also needs its content hash forced.
- `heap.hasIndexHash(value)` -- Whether the above has been done. For asserting the precondition where it is relied on.
- `heap.index_hash_cutoff` (1024) -- The switch point. Chosen on length, not object type, because a `SpecialString` will not imply a large string once mmapped strings exist.

### Refcount primitives
- `heap.incrRefCountOf(T, ref, is_atomic)` -- Generic ref count increment; returns the new count.
- `heap.decrRefCountOf(T, ref, is_atomic)` -- Generic ref count decrement; returns the new count (with acquire fence at zero for atomic).

---

## src/objects.zig

### Shimmerable (working buffer for shimmer and mutation)
- `Shimmerable.deinit(self)` -- Release original and shimmered, poison the struct.
- `Shimmerable.current(self)` -- Return the effective `Value` (`shimmered` if set, else `original`).
- `Shimmerable.consume(self)` -- Take ownership: release the original, return the effective value, poison the struct.
- `Shimmerable.discardChanges(self)` -- Release any shimmered duplicate and roll back to `original`.
- `Shimmerable.takeShimmered(self)` -- Steal the `shimmered` slot without releasing it.
- `Shimmerable.getString(self)` -- Shorthand for `.current().getString()`.
- `Shimmerable.ensureBoxed(self)` -- Box a primitive into a heap object if needed; returns the `*Object`.
- `Shimmerable.ensureShimmerable(self)` -- `ensureBoxed`, then duplicate into `shimmered` if the object cannot shimmer.
- `Shimmerable.prepareToShimmer(self, T)` -- `ensureShimmerable`, cache the string rep, free the old body, install `T`'s vtable, and return the `*T` body to fill in. Call this from inside a `shimmerFrom`.
- `Shimmerable.getMutable(self, T, det)` -- Shimmer to `T`, then return an owned `*T` to mutate. Essentially always duplicates, and the result is detached from the shim: release it yourself and write it back explicitly. Prefer `Value.asMutableInPlace` unless a shim is already in hand.

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
- `HashReference.new(referent)` -- Allocate a `HashReference` borrowing `referent`.
- `HashReference.newFromValue(value)` -- Same, boxing `value` first if it is a primitive.
- `HashReference.shimmerFrom(det, shim)` -- Parse `shim`'s string as a hash ref and resolve it via `registered_hashes`; returns `*const HashReference`.
- `HashReference.resolveAsDictionary(det, shim)` -- Resolve a hash ref and shimmer the target to a `Dictionary`; returns `*const Dictionary`.
- `HashReference.asHead(self)` -- Get the `*Object` header.

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
- `List.new(items)` -- Allocate a `List` from a slice of `Value`s (borrows each).
- `List.newWithCapacity(items, capacity)` -- Allocate with a pre-reserved backing capacity.
- `List.newFromShimmerables(shims)` -- Allocate a `List` from `[]const Shimmerable`, borrowing each `.current()`. Use this instead of collecting `.current()` by hand.
- `List.append(list, value)` -- Append a value (borrows it); grows backing if needed.
- `List.appendAssumeCapacity(list, value)` -- Append without growing (borrows `value`).
- `List.appendAssumeCapacityOwning(list, value)` -- Append without growing, taking the caller's reference.
- `List.set(list, index, value)` -- Replace a slot, releasing the old value and _taking ownership_ of `value` (it does not borrow).
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
- `Dictionary.getNoFollow(self, key)` -- Look up a key returning `OptionalValue` (no parent-link following).
- `Dictionary.getPtrNoFollow(self, key)` -- Look up a key returning `?*Value` into the items slice.
- `Dictionary.put(dict, key, value)` -- Insert/update a key (borrows both), invalidating the string. Asserts `canMutate`.
- `Dictionary.putInner(dict, key, value)` -- Like `put` but returns the value's index in `items`.
- `Dictionary.shimmerWriteback(dict, key, value)` -- Replace an existing key's value in place without invalidating the string; for writing back a shimmered form of the same value.
- `Dictionary.resolveParentDict(dict, det)` -- Follow the `~parent` link to the parent `Dictionary` (or null).
- `Dictionary.remove(dict, det, key)` -- Remove all pairs with `key`; flattens parent links first if the key shadows a parent. Returns true if any were removed.
- `Dictionary.flatten(dict, det)` -- Collapse a `~parent` chain into a single flat dict (mutates in place).
- `Dictionary.flattenInner(dict, det)` -- Recursive helper; returns a new flat `Dictionary` or null if there is no parent.
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

---

## src/vartypes.zig

Variable resolution and the cache object types behind it.

- `vartypes.setVariable(interp, det, call_frame_idx, name, value)` -- Set a variable in the given call frame, following dict sugar and upvar links.
- `vartypes.setVariableUpvar(interp, det, ...)` -- Create an upvar link into another frame.
- `vartypes.getVariable(interp, det, call_frame_idx, name)` -- Look up a variable, returning `OptionalValue`.
- `vartypes.getVariableOrError(interp, det, call_frame_idx, name)` -- Like `getVariable` but reports "no such variable".
- `vartypes.unsetVariable(interp, det, call_frame_idx, name)` -- Remove a variable.
- `vartypes.ensureValidVariableType(...)` -- Validate/normalize the object stored in a variable slot.
- `vartypes.expectErrorOrOom(expected_error, actual_error_union)` -- Test helper mirroring `memutil.expectErrorOrOom`.
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

## src/Interp.zig

Beyond `evalObject`/`callClosure`, `Interp` carries the helpers command code leans on
most.

### Results
- `interp.setResult(value)` / `setResultOwning(value)` -- Set the result, borrowing or taking ownership.
- `interp.setResultInteger` / `setResultFloat` / `setResultBoolean` / `setResultString` / `setResultStringOwning` / `setResultFormatted` / `setEmptyResult`.
- `interp.setResultError(value)` -- Set the result and return `error.EvalError`.

### Coercions (these wrap the `objects` shimmer functions with interpreter error reporting)
- `interp.getInteger(shim)` / `getIntegerInPlace(ref)`
- `interp.getFloat(shim)`
- `interp.getBoolean(shim)` / `getBooleanInPlace(ref)`
- `interp.getIntOrFloatInPlace(ref)` -- Returns an `objects.Number`.
- `interp.getIndex(shim)`, `interp.getList(shim)` / `getListInPlace(ref)`, `interp.resolveHash(shim)`
- `interp.wrapShimmerFn(...)` / `wrapShimmerInPlaceFn(...)` -- Build the above wrappers for a new type.
- `interp.integerOverflowError(IntType, rendered_int)` -- Interpreter-level counterpart to `Integer.overflowError`.
- `interp.wrapError(det, result)` / `Interp.narrowError(err)` / `Interp.narrowToEvalError(result)` -- Convert an object-level error plus `ErrorDetails` into an interpreter error with a message set.

### Evaluation and scope
- `interp.evalObject(script)` / `evalObjectInner(call_frame, script, cache_key)` / `evalFile(filename)`.
- `interp.evalExpression(value)` / `getBoolFromExpression(value)` / `evalSubstitution(value, flags)`.
- `interp.getScript` / `getExpression` / `getClosure` / `getSubstitution` -- Cache-aware parse entry points.
- `interp.getCommand(call_frame_idx, name, can_be_method)` -- Resolve a command or closure.
- `interp.registerCommand(name, command)` -- Register a `NativeCommand`.
- `interp.callFrame()` / `callFrameIdx()` / `evalFrame()` / `evalFrameIdx()` / `nextCallEpoch()`.
- `interp.captureScope(call_frame_idx)` / `captureCurrentScope()` -- Snapshot a frame's variables as a `Dictionary`.
- `interp.setErrorStack()` -- Populate `errorInfo` from the current eval frames.
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

### Hash context
- `memutil` string hash context: `.hash(self, s)` (Wyhash), `.eql(self, a, b)` (byte equality).

---

## src/strutil.zig

- `strutil.checkAllAscii(bytes, check)` -- True if every byte passes the predicate.
- `strutil.isGraph(c)` / `strutil.isPunct(c)` -- ASCII character class checks.
- `strutil.toTitle` / `strutil.toUpper` / `strutil.toLower` -- Case conversion functions (UTF-8 or ASCII depending on `-Duse-utf8`).
- `strutil.compare(a, b, up_to_cp, case_insensitive)` -- Lexicographic codepoint-order comparison.
- `strutil.cpIndexUtf8(str, index)` / `strutil.cpIndexAscii(str, index)` / `strutil.cpIndex` -- Convert a codepoint index to a byte offset.
- `strutil.codepointLength(str)` / `strutil.strlenUtf8(str)` / `strutil.strlenAscii(str)` -- Count codepoints.
- `strutil.findCodepoint(str, cp)` -- Byte offset of the first occurrence of codepoint `cp`.
- `strutil.trimLeft(str, trim_chars)` / `strutil.trimRight(str, trim_chars)` -- Return the offset/length after trimming.
- `strutil.charsetMatch(pattern, cp, flags)` -- Match a Tcl charset pattern (e.g. `[a-z]`) against a codepoint.
- `strutil.globMatch(pattern, str, case_insensitive)` -- Glob-style pattern match on byte slices.
- `strutil.findFirstOccurrence(needle, haystack, cp_index)` / `strutil.findLastOccurrence(needle, haystack)` -- Substring search by codepoint offset.
- `strutil.hexDigitValue(c)` / `strutil.isHexDigit(c)` -- Hex digit helpers.
- `strutil.removeEscaping(source, dest)` -- Process backslash escapes; return the resulting length.
- `strutil.QuotingType` -- `enum { bare, brace, escape }`.
- `strutil.calculateNeededQuotingType(str)` -- Determine how a string must be quoted.
- `strutil.quoteSize(quoting_type, str_len)` -- Output buffer size needed to quote a string.
- `strutil.quoteString(quoting_type, src, dest, escape_first_pound)` -- Write a quoted string into `dest`; return bytes written.
- `strutil.quoteStrings(gpa, items)` -- Quote and join a slice of strings into one `[:0]u8`.
- `strutil.Iterator.init(bytes)` / `.next()` / `.peek()` -- Codepoint iterator (UTF-8 or ASCII).

---

## src/ioutil.zig

Stdout and stderr are mutex-protected and redirectable, so never write to them
directly.

- `ioutil.lockStdout()` / `ioutil.unlockStdout()` -- Lock and return the current stdout `std.Io.File`.
- `ioutil.lockStderr()` / `ioutil.unlockStderr()` -- Same for stderr.
- `ioutil.global_stdout_fd` / `ioutil.global_stderr_fd` -- Atomic fd overrides, for redirecting output in tests and embedders.
- `ioutil.debug(comptime fmt, args)` -- Print to stderr, taking the lock for you.

---

## src/leak_check.zig

- `leak_check.init()` -- Initialize the trace log and debug allocator (only when `trace_mem` is on).
- `leak_check.deinit()` -- Reset the trace log and counts.
- `leak_check.globalTrace(category, value, fmt, args)` -- Append a trace entry (alloc/free/other) with a stack trace. Inlined; no-op when `trace_mem` is off.
- `leak_check.captureLeaks()` -- Walk every leaked object via `GraphWalker`/`StructIterator`; returns a `LeakResult` (dot graph + per-object logs).
- `leak_check.dumpLeaks()` -- Capture leaks and dump the dot graph + details to stderr. Quiet when there are no leaks. Called from `heap.testFinish`.
- `leak_check.dumpLastTouchedTrace(fd)` -- Dump the operation history of the most recently touched object (hooked into the panic path). Re-entrancy guarded.
- `LeakResult.dumpDot(writer)` -- Render the leak graph as a Graphviz dot digraph.
- `LeakResult.dumpDetails(terminal)` -- Print each leaked object's operation history with stack traces, to a `std.Io.Terminal`.
- `LeakResult.deinit(result)` -- Free the result's arena.

---

## src/tripwire.zig

Vendored failure injection, for exercising `errdefer` paths that
`checkAllAllocationFailures` cannot reach.

- `tripwire.module(FailPoints, func)` -- Comptime: build a fail-point module for one function, where `FailPoints` is a hand-curated enum and the error set comes from `func`.
  - `tw.check(.point)` -- A failure point; `try` it where you want a testable error.
  - `tw.errorAlways(.point)` and friends -- Arm a failure point from a test.
  - `tw.end(.reset)` -- Verify the armed expectations fired and reset for the next test.

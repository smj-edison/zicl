# Helper function index

Public helper functions in the utility files. Consult this before implementing
anything that might already exist.

---

## src/objutil.zig

### Strings
- `shimmerToString(provided_handle, new_handle)` -- Shimmer any object to `.string` tag; `new_handle` set if object moved.
- `getCodepointLength(provided_handle, new_handle)` -- Return the codepoint length of a string handle.
- `newString(heap, bytes)` -- Allocate a new string object copying `bytes`.
- `newStringFmt(heap, fmt, args)` -- Allocate a new string object from a format string.
- `newStringToFill(heap, len)` -- Allocate a string of `len` bytes for the caller to fill in.
- `newStringWithCodepointLen(heap, bytes, cp_length)` -- Allocate a string with a pre-computed codepoint length.
- `setStringFromEscaped(handle, escaped)` -- Parse escape sequences and store the unescaped bytes as the string rep.
- `globMatch(pattern, to_check, case_insensitive)` -- Tcl glob-style match between two Handle strings.
- `compare(a, b, case_insensitive)` -- Lexicographic codepoint comparison of two Handle strings.
- `stringRange(det, str, start, end, new_handle)` -- Create a substring (used by `[string range]`).
- `stringReplace(det, str, start, end, to_insert, new_handle)` -- Replace a range, optionally inserting new content.
- `stringCaseConversion(str, mode)` -- Return a new string in upper/lower/title case.
- `stringTrimLeft(str, trim_chars)` -- Trim codepoints from the left; new string only if something was trimmed.
- `stringTrimRight(str, trim_chars)` -- Trim codepoints from the right; new string only if something was trimmed.
- `stringTrim(str, trim_chars)` -- Trim both sides; new string only if something was trimmed.
- `stringIs(det, str, class, strict, new_handle)` -- Check if a string belongs to a named character class (`[string is]`).

### Integers
- `newInteger(heap, value)` -- Allocate a new integer object.
- `integerOverflowError(det, value)` -- Populate `det` and return `error.IntegerOverflow`.
- `integerOverflowErrorWithWide(det, value)` -- Same but formats the `i128` value for the error message.
- `integerGetNoShimmer(det, handle)` -- Extract `i64` without shimmering; error if not already integer-typed.
- `shimmerToInteger(det, provided_handle, new_handle)` -- Shimmer to `.integer`; `new_handle` set if object moved.
- `integerGet(det, provided_handle, new_handle)` -- Shimmer + return the `i64` value.

### Floats
- `newFloat(heap, value)` -- Allocate a new float object.
- `floatGetNoShimmer(det, handle)` -- Extract `f64` without shimmering; error if not already float-typed.
- `shimmerToFloat(det, provided_handle, new_handle)` -- Shimmer to `.float`; `new_handle` set if object moved.
- `floatGet(det, provided_handle, new_handle)` -- Shimmer + return the `f64` (note: return type is `i64` due to a bug, check source).

### Booleans
- `shimmerToBoolean(det, provided_handle, new_handle)` -- Shimmer to `.bool`; `new_handle` set if object moved.
- `getBoolean(det, provided_handle, new_handle)` -- Shimmer + return the `bool` value.

### Indices
- `shimmerToIndex(det, provided_handle, new_handle)` -- Shimmer to `.index` (list index) representation.
- `getIndex(det, handle, new_handle)` -- Shimmer + return the `Heap.ListIndex` value.
- `Range.fromIndexes(list_len, start_index, end_index)` -- Resolve two `ListIndex` values to an absolute byte range.

### Lists
- `newListWithCapacity(capacity)` -- Allocate a list with pre-reserved slots.
- `newList(handles)` -- Allocate a list from a slice of handles.
- `shimmerToList(det, provided_handle, new_handle)` -- Shimmer to `.list`; `new_handle` set if object moved.
- `listLengthRaw(list)` -- Return item count without shimmering (asserts already a list).
- `listLength(det, provided_list, new_list)` -- Shimmer + return the item count.
- `listItem(handle, index)` -- Get item handle by index (non-owning; asserts already a list).
- `listItemFollowRefs(handle, index)` -- Same as `listItem` but dereferences `.reference` objects.
- `listItems(handle)` -- Slice over all item objects in a list.
- `collectionItems(handle, len)` -- Slice of raw objects for a list or dict (lower-level than `listItems`/`dictItems`).
- `listSetObject(det, provided_list, new_list, index, value)` -- Set a list slot; takes ownership of `value`.
- `listAppendObject(det, provided_list, new_list, item)` -- Append a raw `Heap.Object`; takes ownership.
- `listAppend(det, provided_list, new_list, item)` -- Append a handle, duplicating/referencing as needed.
- `listAppendAssumeCapacity(list, item)` -- Infallible append; caller pre-allocated capacity and did ref-counting.

### Dicts
- `newDictWithCapacity(len)` -- Allocate a dict with pre-reserved key/value pair slots (`len` must be even).
- `newDict(heap, handles)` -- Allocate a dict from a slice of alternating key/value handles.
- `shimmerToDict(det, provided_handle, new_dict)` -- Shimmer to `.dict`; `new_dict` set if object moved.
- `dictItems(handle)` -- Slice over all key/value objects in a dict.
- `dictItem(dict, index)` -- Get a raw slot handle by flat index.
- `dictItemFollowRefs(dict, index)` -- Same as `dictItem` but dereferences `.reference` objects.
- `dictItemLength(handle)` -- Total number of slots (keys + values).
- `dictPairLengthRaw(handle)` -- Number of key/value pairs (total/2) without shimmering.
- `dictPairLength(det, provided_handle, new_dict)` -- Shimmer + return the pair count.
- `dictGetTable(dict)` -- Get (or lazily build) the hash-map lookup table for a dict.
- `dictMaybeGetTable(dict)` -- Return the hash-map table if already built, else null.
- `dictInvalidateTable(dict)` -- Destroy the cached hash-map table (call after mutation).
- `dictLookupInner(dict, key)` -- Look up a key returning the raw slot handle (no ref-follow).
- `dictLookupFollowRefs(dict, key)` -- Look up a key and follow `.reference` objects.
- `dictLookupFollowLinks(dict, key)` -- Look up a key and follow upvar links.
- `dictPut(dict, key, value)` -- Insert/update a key-value pair; returns `DictAndValueResult`.
- `dictPutInner(provided_dict, key, value)` -- Like `dictPut` but takes ownership of a raw `Heap.Object`.
- `dictPutRecursively(det, provided_dict, keys, value)` -- Nested dict insert/update along a key path.
- `dictRemove(provided_dict, key)` -- Remove a key; returns `DictAndRemovedResult`.
- `dictRemoveRecursively(det, provided_dict, keys)` -- Nested dict remove along a key path.
- `dictLookupRecursively(det, provided_dict, keys)` -- Nested dict lookup along a key path.

### References & misc
- `followIfRef(handle)` -- If handle is a `.reference`, return the target; otherwise return as-is.
- `getSourceInfo(handle)` -- Return `SourceInfo` if the handle has `.source` tag, else null.
- `setSourceInfo(handle, source_info)` -- Attach source location metadata to an object.
- `convertTokenizerError(heap, err)` -- Convert a `Tokenizer.Error` into a heap-allocated `ErrorDetails`.

### Enums
- `enumNames(T)` -- Comptime: return enum variant names joined by `", "`.
- `EnumMapping(T)` -- Comptime: build a string-to-enum lookup table type.
- `TclEnum(T, enum_name)` -- Comptime: generate a Tcl-facing enum type with a `.get` shimmer function.

### Scripts & expressions
- `parseScript(det, handle)` -- Parse a Tcl script from a string handle (not cached).
- `getScript(det, handle, cache_key)` -- Parse (or retrieve from LRU cache) a Tcl script.
- `parseExpression(det, handle)` -- Parse an expression from a string handle (not cached).
- `getExpression(det, handle, cache_key)` -- Parse (or retrieve from LRU cache) an expression.

---

## src/Heap.zig

### Handle operations
- `handle.peek()` -- Get a `*Object` pointer (does not increase ref count).
- `handle.tag()` -- Return the `Tag` of this handle.
- `handle.getHeap()` -- Return the `*Heap` this handle belongs to.
- `handle.toOptional()` -- Convert to `OptionalHandle`.
- `handle.toOptionalRef()` -- Cast `*Handle` to `*OptionalHandle` (zero-copy; same memory layout).
- `handle.prepareToShimmer()` -- Ensure string rep exists and clear the body for re-use.
- `handle.canShimmer()` -- True if the handle can change type (not shared, not special).
- `handle.canMutate()` -- True if the object can be modified in-place (exclusive ownership).
- `handle.isShared()` -- True if ref count > 1 or cross-thread.
- `handle.hasString()` -- True if a string representation is cached.
- `handle.getMetadata()` -- Return the `ObjectAndMetadata.Metadata` pointer.
- `handle.borrow()` -- Increment ref count and return the handle.
- `handle.incrRefCount()` -- Increment ref count (rarely needed; prefer `borrow`).
- `handle.decrRefCount()` -- Decrement ref count, freeing if it reaches zero.
- `handle.debugRefCount()` -- Return current ref count (debugging only).
- `handle.swap(new)` -- Always swap the handle and release the old one.
- `handle.swapIfNew(new_handle)` -- Swap only if `new_handle` is non-null, releasing the old.
- `handle.swapAndClear(optional)` -- Transfer ownership from an `OptionalHandle` and clear it.
- `handle.reference()` -- Create a `.reference` object (increments ref count).
- `handle.referenceTakeOwnership()` -- Create a `.reference` object without incrementing ref count.
- `handle.invalidateBody()` -- Clear the body field.
- `handle.invalidateString()` -- Clear the string representation.
- `handle.invalidateBoth()` -- Clear both body and string.
- `handle.isAllocHead()` -- True if this is the allocation head of a multi-object block.
- `handle.getString()` -- Return the string rep, generating it if needed (may allocate).
- `handle.getStringIfExists()` -- Return the string rep if already cached, else null.
- `handle.getStringDetails()` -- Return detailed string metadata.
- `handle.getHash()` -- Return a `u256` content hash.
- `handle.getSourceExtraData()` -- Access the `.source` extra data pointer.
- `handle.getDictExtraData()` -- Access the `.dict` extra data pointer.
- `handle.getClosureExtraData()` -- Access the `.closure` extra data pointer.
- `handle.trace(fmt, args)` -- Append a trace entry (only when `trace_mem` is enabled).
- `handle.assert(ok)` -- Assert with automatic trace dump on failure.

### OptionalHandle operations
- `optional.toHandle()` -- Convert to `?Handle`.
- `optional.getIndex()` -- Return the underlying index as `OptionalIndex`.
- `optional.toHandleRef()` -- Return `?*Handle`.
- `optional.swapRef(new_handle)` -- Swap and decrement the old value's ref count.
- `optional.swapRefIfNew(new_handle)` -- Swap only if `new_handle` is non-null.
- `optional.swapWithNone()` -- Decrement ref count and set to `.none` (use in `errdefer`).
- `optional.orElse(other)` -- Return contained handle if non-null, else `other`.
- `optional.orEmpty()` -- Return contained handle if non-null, else the empty handle.
- `optional.borrowOptional()` -- Borrow the contained handle (nop if none).
- `optional.decrOptional()` -- Decrement ref count if non-null.

### Heap-level operations
- `Heap.ensureMutableOrDup(handle, new_handle)` -- Duplicate if the handle cannot be mutated in-place.
- `Heap.ensureShimmerableOrDup(handle, new_handle)` -- Duplicate if the handle cannot shimmer.
- `Heap.ensureSameHeapOrDup(handle, new_handle)` -- Duplicate if the handle belongs to a different heap.
- `Heap.getString(handle)` -- Get string rep (may allocate) for a handle on any heap.
- `Heap.setString(handle, bytes)` -- Set the string representation.
- `Heap.checkIfEqual(a, b)` -- Deep equality check between two handles.
- `Heap.duplicate(dest_heap, src_handle)` -- Deep copy to a (possibly different) heap.
- `heap.duplicateObjString(handle)` -- Duplicate only the string portion of an object.
- `heap.dupSingleOrReference(handle)` -- Dup or create a `.reference` for a single object.
- `heap.dupOrReference(handle)` -- Dup or create a `.reference` (handles multi-object blocks).
- `heap.duplicateSingle(handle)` -- Deep copy a single object; error if it is a multi-object head.
- `heap.steal(handle)` -- Transfer ownership of a handle from another heap to the local heap.
- `heap.nullObject()` -- Return the null object handle.
- `heap.emptyHandle()` -- Return the empty/zero-length string handle.
- `heap.tempObject()` -- Return the scratch/temporary object handle.
- `heap.createObject()` -- Allocate one new object.
- `heap.createObjects(count)` -- Allocate a contiguous block of `count` objects; returns start index.
- `heap.freeObject(handle)` -- Free a single object (bypasses ref-counting).
- `heap.freeObjectBacking(handle)` -- Free the backing storage only (not the object header).
- `heap.getHandle(index)` -- Reconstruct a `Handle` from a raw heap index.
- `heap.getLocalObject(index)` -- Return `*Object` for a local heap index.
- `heap.objectSlice(start, end)` -- Slice of objects by index range.
- `heap.getLocalMetadata(index)` -- Return `*Metadata` for a local heap index.
- `heap.stringEquals(handle, value)` -- Compare a handle's string rep to a byte slice.
- `heap.getStringMut(handle)` -- Return a mutable slice of the string rep.
- `heap.getHeapString(start, end)` -- Get a string by byte range in the string heap.
- `heap.getHeapStringZ(index)` -- Get a null-terminated string by start index.
- `heap.createString(len)` -- Allocate `len` bytes in the string heap; returns start index.
- `heap.freeString(index, len)` -- Free string heap bytes.
- `heap.setNormalString(index, bytes)` -- Write a normal (in-heap) string to an object.
- `heap.setLongString(index, string_type)` -- Write a long (external) string to an object.
- `heap.setStringOwning(handle, bytes)` -- Set a sentinel-terminated string; takes ownership.
- `heap.exchangeString(index, expected, to_set_to)` -- Atomic CAS on the string field.
- `heap.splitAlloc(index, new_order)` -- Split a buddy block to a smaller order.
- `heap.createExtraData()` -- Allocate an `ExtraData` slot.
- `heap.getExtraData(index)` -- Return `*ExtraDataValue` for an `ExtraData` index.
- `heap.destroyExtraData(index)` -- Free an `ExtraData` slot.
- `heap.getInternedString(string)` -- Return the handle for a compile-time-interned string.

### Lifecycle
- `Heap.init(heap)` -- Initialize a heap (called by `initLocalHeap`).
- `Heap.deinit(heap)` -- Tear down a heap.
- `Heap.initGlobals(gpa)` -- Initialize global state (call once at program start).
- `Heap.initLocalHeap()` -- Create and register the calling thread's local heap.
- `Heap.deinitAll()` -- Tear down all heaps and global state.
- `Heap.createCustomType(custom_type)` -- Register a new custom object type.

### Reference counting helpers
- `Heap.atomicIncr(T, ptr)` -- Atomic fetch-and-increment for any integer type.
- `Heap.incrRefCountOf(T, ref, is_atomic)` -- Generic ref count increment.
- `Heap.decrRefCountOf(T, ref, is_atomic)` -- Generic ref count decrement; returns true if hit zero.

### Closures
- `Closure.borrow(closure)` -- Increment the closure's ref count and return it.
- `Closure.deinit(closure)` -- Decrement the closure's ref count, freeing if zero.

### Misc
- `Heap.nextCacheId()` -- Generate a monotonically increasing cache ID.
- `Heap.emptyObject()` -- Return a zero-initialized `Object` value (not a handle).
- `Heap.ListIndex.asAbsoluteIndex(list_len)` -- Resolve a possibly-negative list index to an absolute offset.

### Testing helpers
- `Heap.testStart(gpa)` -- Create a test heap (use with `defer Heap.testFinish()`).
- `Heap.testFinish()` -- Assert no leaks and destroy the test heap.
- `Heap.leakCheck(heap)` -- Return true if any objects are still live.
- `Heap.leakCheckWithMode(heap, mode)` -- Leak check with optional dot-graph output.
- `Heap.leakCheckAll()` -- Leak-check all heaps.

---

## src/memutil.zig

### Hashing
- `hashBytes(bytes)` -- Blake3 hash of a byte slice, returning `u256`.

### Buddy allocator math
- `getOrder(count)` -- Return the buddy order needed to hold `count` items.
- `getOrderSize(order)` -- Return the number of slots in a block of the given order (`2^order`).
- `buddyOfOrder(index, order)` -- Return the buddy index for a block at `index` with `order`.

### BuddyUnmanaged (comptime type)
- `BuddyUnmanaged(cfg)` -- Returns a buddy allocator type parameterized by `max_order` and pool config.
  - `.init(gpa, initial_capacity)` -- Initialize with given capacity.
  - `.deinit()` -- Tear down; returns `.leaked` if blocks were still allocated.
  - `.splitBlock(current_order, new_order)` -- Split an already-allocated block to a smaller order.
  - `.allocFromAnyThread(requested_order)` -- Thread-safe allocate (mutex-locked).
  - `.freeFromAnyThread(index, order)` -- Thread-safe free (mutex-locked).
  - `.allocFromOwningThread(requested_order)` -- Fast-path allocate from pool (owning thread only).
  - `.freeFromOwningThread(index, order)` -- Fast-path free to pool (owning thread only).

### Virtual memory
- `vmemMap(byte_count)` -- Map anonymous virtual memory pages.
- `vmemUnmap(memory)` -- Unmap previously mapped pages.
- `vmemMapItems(T, count)` -- Map virtual memory sized for `count` items of type `T`.
- `vmemUnmapItems(T, items)` -- Unmap pages mapped by `vmemMapItems`.

### IndexedMemoryPool (comptime type)
- `IndexedMemoryPool(Item, use_vmem)` -- Pool that returns `usize` indices instead of pointers.
  - `.initWithCapacity(gpa, capacity)` -- Initialize with initial capacity.
  - `.create(gpa)` -- Allocate one item (may grow).
  - `.createAssumeCapacity()` -- Allocate one item without growing.
  - `.clearRetainingCapacity()` -- Reset to empty, keeping backing memory.
  - `.destroy(index)` -- Free one item by index.
  - `.deinit(gpa)` -- Tear down the pool.
  - `.dumpLeaked(scratch, fmt)` -- Debug: print all live (non-freed) items.

### LRU cache (comptime type)
- `LruCache(K, V, Context)` -- LRU cache parameterized by key/value/context types.
  - `.initWithCapacity(gpa, max_size)` -- Initialize with a fixed capacity.
  - `.deinit(gpa)` -- Tear down.
  - `.get(key)` -- Look up a key, promoting it to MRU position.
  - `.put(key, value)` -- Insert or update; returns evicted value if at capacity.
  - `.valueIterator()` -- Iterate all values in MRU order.
  - `.clearRetainingCapacity()` -- Reset to empty, keeping backing memory.

### Testing
- `expectErrorOrOom(expected_error, actual_error_union)` -- Assert an error matches `expected_error` (passes through OOM).

---

## src/stringutil.zig

- `checkAllAscii(bytes, check)` -- Return true if every byte passes the given predicate.
- `isGraph(c)` -- True if `c` is a printable non-space ASCII character.
- `isPunct(c)` -- True if `c` is an ASCII punctuation character.
- `compare(a, b, case_insensitive)` -- Lexicographic codepoint-order comparison of two byte slices.
- `cpIndexUtf8(str, index)` -- Convert a codepoint index to a byte offset (UTF-8 mode).
- `cpIndexAscii(str, index)` -- Convert a codepoint index to a byte offset (ASCII mode, identity).
- `strlenUtf8(str)` -- Count codepoints in a UTF-8 string.
- `strlenAscii(str)` -- Return byte length (codepoint count equals byte count for ASCII).
- `findCodepoint(str, cp)` -- Return the byte offset of the first occurrence of codepoint `cp`.
- `trimLeft(str, trim_chars)` -- Return the byte offset after leading trim-char codepoints.
- `trimRight(str, trim_chars)` -- Return the byte length after removing trailing trim-char codepoints.
- `charsetMatch(pattern, cp, flags)` -- Match a Tcl charset pattern (e.g. `[a-z]`) against a codepoint.
- `globMatch(pattern, str, case_insensitive)` -- Glob-style pattern match on raw byte slices.
- `findFirstOccurrence(needle, haystack, cp_index)` -- Find `needle` in `haystack` starting at codepoint offset `cp_index`.
- `findLastOccurrence(needle, haystack)` -- Find the last occurrence of `needle` in `haystack`.
- `hexDigitValue(c)` -- Return the numeric value of a hex digit, or null.
- `isHexDigit(c)` -- True if `c` is a valid hex digit.
- `removeEscaping(source, dest)` -- Process backslash escapes in-place; return the resulting length.
- `calculateNeededQuotingType(str)` -- Determine whether a string needs brace, escape, or bare quoting.
- `quoteSize(quoting_type, str_len)` -- Return the output buffer size needed to quote a string.
- `quoteString(quoting_type, src, dest, escape_first_pound)` -- Write a quoted string into `dest`; return bytes written.
- `Iterator.init(bytes)` -- Create a codepoint iterator over a byte slice.
- `Iterator.next()` -- Advance and return the next codepoint as a `u8` (or `u21` in UTF-8 mode).
- `Iterator.peek()` -- Peek at the next codepoint without advancing.

---

## src/Interp.zig

### Lifecycle
- `init()` -- Create and initialize a new `Interp`; registers all built-in commands.
- `deinit(interp)` -- Tear down an interpreter, freeing all owned resources.

### Evaluation
- `evalObject(interp, script)` -- Evaluate a script handle; sets `interp.result` on success.
- `evalObjectInner(interp, script, cache_key)` -- Like `evalObject` but accepts an explicit cache key (used when the script handle was already looked up).
- `evalExpression(interp, handle, new_handle)` -- Parse and evaluate an expression; returns `ExprResult`.
- `evalExpressionInPlace(interp, handle)` -- Evaluate an expression, shimmering `handle` in-place; returns `ExprResult`.
- `getBoolFromExpression(interp, handle)` -- Evaluate an expression and return its boolean value; updates `handle` if shimmered.

### Setting the result
- `setResult(interp, handle)` -- Set `interp.result`, borrowing the handle (caller still owns original).
- `setResultOwning(interp, handle)` -- Set `interp.result`, taking ownership (no borrow).
- `setResultInteger(interp, value)` -- Allocate an integer object and set it as the result.
- `setResultFloat(interp, value)` -- Allocate a float object and set it as the result.
- `setResultString(interp, bytes)` -- Allocate a string object and set it as the result.
- `setResultInterned(interp, interned)` -- Set the result to a compile-time-interned string handle.
- `setResultFormatted(interp, fmt, args)` -- Allocate a formatted string and set it as the result.
- `setEmptyResult(interp)` -- Set the result to the heap's empty string handle.

### Commands
- `registerCommand(interp, name, call_info)` -- Register a native Zig function as a Tcl command.
- `getCommand(interp, name, ...)` -- Look up a registered command by name; returns null if not found.

### Variables
- `setVariableTo(interp, name, handle)` -- Set a variable by name to a handle, handling upvar links.
- `setVariableToObject(interp, name, obj)` -- Set a variable to a raw `Heap.Object` (lower-level than `setVariableTo`).
- `getVariable(interp, provided_name)` -- Look up a variable; returns `OptionalHandle` (.none if unset).
- `getVariableOrError(interp, name)` -- Look up a variable; returns `EvalError` if unset.

### Dict helpers (interp-aware wrappers)
- `getDictValue(interp, dict, key)` -- Look up `key` in `dict`; returns struct with value and shimmer handle.
- `getDictValueOrError(interp, dict, key)` -- Same as `getDictValue` but errors if the key is absent.
- `getDictValueRecursively(interp, dict, keys)` -- Recursive dict lookup along a key path; returns `OptionalHandle`.
- `getDictValueRecursivelyOrError(interp, dict, keys)` -- Recursive lookup; errors if any key is absent.
- `putDictValue(interp, dict, new_dict, key, value)` -- Insert/update `key` in `dict`; returns new value handle.
- `putDictValueRecursively(interp, dict, keys, value)` -- Recursive insert/update along a key path.
- `removeDictValue(interp, dict, new_dict, key)` -- Remove `key`; returns true if the key existed.
- `removeDictValueRecursively(interp, dict, keys)` -- Recursive remove along a key path.

### Shimmer wrappers (interp error context)
- `wrapError(interp, det, result)` -- Translate an `ErrorDetails`-tagged error into an interp-level `EvalError`.
- `wrapShimmerFn(fn)` -- Comptime: adapt a shimmer function to use `interp` instead of a `det` pointer.
- `getInteger(interp, handle)` -- Shimmer `*handle` to integer and return the `i64` value.
- `getIntegerNoShimmer(interp, handle)` -- Return the `i64` value without shimmering; error if not already integer.
- `getFloat(interp, handle)` -- Shimmer `*handle` to float and return the `f64` value.
- `getFloatNoShimmer(interp, handle)` -- Return the `f64` value without shimmering; error if not already float.
- `shimmerToList(interp, handle)` -- Shimmer `*handle` to a list in-place.
- `getListLength(interp, handle)` -- Shimmer `*handle` to list and return the item count.
- `listAppend(interp, list, item)` -- Append `item` to `*list`, duplicating if needed.
- `ensureShimmerable(interp, handle)` -- Duplicate `*handle` if it cannot be shimmered.
- `integerOverflowError(interp, value)` -- Report an integer overflow error on the interpreter.

### Closures
- `parseClosure(det, bytes)` -- Parse a closure definition from raw bytes; returns `Heap.Closure`.
- `parseClosureArgList(det, args)` -- Parse a closure argument-list handle into a `ParsedArgList`.
- `createClosureObject(closure)` -- Wrap a `Heap.Closure` in a heap handle.
- `getClosure(interp, handle)` -- Extract a `Closure` and its cache key from a handle.
- `callClosure(interp, closure, cache_key, args)` -- Invoke a closure with the given argument handles.

### Scopes
- `captureScope(interp, det, call_frame_idx)` -- Capture the variables at a given call frame as a dict.
- `captureCurrentScope(interp)` -- Capture the current scope's variables as a dict.

### ExprResult
- `ExprResult.release(result)` -- Release an expression result (decrements ref count if it holds a handle).
- `ExprResult.toObject(result)` -- Convert an expression result to a heap handle (may allocate).

### Testing helpers
- `testExpectScriptResult(interp, expected, script)` -- Assert `script` evaluates to `expected` string.
- `testExpectScriptError(interp, expected_error, expected_str, script)` -- Assert `script` yields a specific error and message.

### Misc
- `nextRandomFloat(interp)` -- Advance the interpreter's PRNG and return the next `f64` in [0, 1).

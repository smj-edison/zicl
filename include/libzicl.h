#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

/* ===== Values, types, and conventions =====
 * The foundational representations every other section builds on: the value
 * and optional-value types, the shimmerable working buffer, the status codes
 * and ownership convention, and the opaque interpreter and object handles. */

/* The payload of a value. Small primitives (integers, floats, booleans, and
 * interned strings) live inline; everything else is a pointer to a ref-counted
 * heap object. Mirrors `heap.ValueRep` on the Zig side, so the two must be
 * kept in step. */

typedef enum : uint8_t {
    ZICL_TAG_NONE = 0,
    ZICL_TAG_POINTER,
    ZICL_TAG_BOOLEAN,
    ZICL_TAG_INTEGER,
    ZICL_TAG_FLOAT,
    ZICL_TAG_INTERNED,
} Zicl_Tag;
typedef struct Zicl_ValueRep {
    union {
        void *pointer;
        double float_value;
        int64_t integer;
        bool boolean;
        const char *interned;
    } as;
    /* Only meaningful when `tag` is ZICL_TAG_INTERNED. */
    uint16_t interned_string_len;
    Zicl_Tag tag;
} Zicl_ValueRep;

/* A value that is always present. Pass it by value. */
typedef struct Zicl_Value {
    Zicl_ValueRep raw;
} Zicl_Value;

/* A value that may legitimately be absent, such as an out-of-range list index.
 * This is not how failure is reported: anything that can fail returns a status
 * code and writes its result through an out-parameter. The two are distinct
 * struct types, so an absent value cannot be passed onward by accident. Check
 * with Zicl_IsNone, then narrow with Zicl_Unwrap. */
typedef struct Zicl_OptionalValue {
    Zicl_ValueRep raw;
} Zicl_OptionalValue;

#define ZICL_NONE ((Zicl_OptionalValue){{{0}, 0, ZICL_TAG_NONE}})

static inline bool Zicl_IsNone(Zicl_OptionalValue value) {
    return value.raw.tag == ZICL_TAG_NONE;
}
static inline bool Zicl_IsSome(Zicl_OptionalValue value) {
    return value.raw.tag != ZICL_TAG_NONE;
}

/* Narrow an optional. Only valid once Zicl_IsNone has ruled out the empty
 * case; unwrapping an absent value and handing it back is undefined. */
static inline Zicl_Value Zicl_Unwrap(Zicl_OptionalValue value) {
    Zicl_Value narrowed;
    narrowed.raw = value.raw;
    return narrowed;
}

static inline Zicl_OptionalValue Zicl_Wrap(Zicl_Value value) {
    Zicl_OptionalValue widened;
    widened.raw = value.raw;
    return widened;
}

/* The working buffer for shimmering. `original` is the value the caller handed
 * in; `shimmered` holds a duplicated object when the original could not be
 * converted in place. `Zicl_Current` returns whichever is effective. Mirrors
 * `objects.Shimmerable` on the Zig side, so the two must be kept in step. */
typedef struct Zicl_Shimmerable {
    Zicl_Value original;
    Zicl_OptionalValue shimmered;
} Zicl_Shimmerable;

/* Build a shimmerable around a single value, with no shimmered duplicate. The
 * caller owns `value` for the lifetime of the shimmerable. */
static inline Zicl_Shimmerable Zicl_NewShimmerable(Zicl_Value value) {
    Zicl_Shimmerable shim;
    shim.original = value;
    shim.shimmered = ZICL_NONE;
    return shim;
}

/* Recover the containing struct from one of its members. A C program embeds a
 * Zicl type (such as a `Zicl_Head`) as a field in its own struct and uses this
 * to get back to the outer struct from the pointer Zicl hands it. Lets C code
 * manage its own objects the way the Zig side uses `@fieldParentPtr`. Mirrors
 * the Linux kernel's `container_of`. */
#define Zicl_ContainerOf(ptr, type, member) ({ \
    const typeof(((type *)0)->member) *__mptr = (ptr); \
    (type *)((char *)__mptr - offsetof(type, member)); })

#define ZICL_OK 0
#define ZICL_ERR 1
#define ZICL_OOM 2
#define ZICL_PROPAGATE 3
#define ZICL_BREAK 4
#define ZICL_CONTINUE 5
#define ZICL_EXIT 6
#define ZICL_USAGE 7
#define ZICL_TAILCALL 8

/* Ownership and error propagation.
 *
 * Zicl treats running out of memory as recoverable, which in C means every
 * allocating call has a status to check and everything acquired before a
 * failure has to be released. Anything that can fail returns one of the status
 * codes below and writes its result through an out-parameter, so the two
 * concerns stay separable:
 *
 *     int rc = 0;
 *     Zicl_Value script;
 *     ZICL_TRY(Zicl_NewString(&script, "puts hi", -1), rc);
 *     defer { Zicl_Release(script); }
 *     return Zicl_EvalValue(interp, script);
 *
 * `defer` here is whatever scope-exit mechanism the consumer has; nothing here
 * requires it, and a consumer without one releases by hand as usual. Registering
 * the release after the constructor has succeeded is what keeps a Zicl_Value
 * from ever needing to represent "not filled in yet".
 *
 * When ownership transfers to the caller on success, the release belongs only
 * on the failing paths. The status ZICL_TRY writes is an ordinary variable, so
 * that is a plain guarded defer rather than anything special:
 *
 *     int rc = 0;
 *     Zicl_List *list = Zicl_NewList(NULL, 0);
 *     if (!list) return ZICL_OOM;
 *     defer { if (rc) Zicl_ReleaseList(list); }
 *     ZICL_TRY(Zicl_ListAppend(list, item), rc);
 *     *out = Zicl_BoxList(list);
 *     return ZICL_OK;
 *
 * Such a guard only sees failures that ZICL_TRY recorded, so every fallible
 * call in the function has to go through it, the last one included. A bare
 * `return mightFail();` leaves the status at ZICL_OK and the cleanup will not
 * run. */
#define ZICL_TRY(call, status)                  \
    do {                                        \
        (status) = (call);                      \
        if ((status) != ZICL_OK)                \
            return (status);                    \
    } while (0)

/* Release the value held in `slot` and store `new_value` in its place. `slot`
 * is a pointer to a `Zicl_Value` or `Zicl_OptionalValue`; the macro works for
 * either because it copies through `.raw`, the common `ValueRep` they share.
 * `Zicl_Release` is a no-op for primitives and the `none` optional, so the
 * macro is safe to use on any slot. Use it to commit a copy-on-write duplicate
 * back into the slot it replaces:
 *
 *     Zicl_List *ml = NULL;
 *     if (Zicl_DupAsList(interp, slot, &ml)) ...
 *     ZICL_TRY(Zicl_ListAppend(ml, item), rc);
 *     ZICL_SWAP(&slot, Zicl_BoxList(ml));
 *
 * The in-place COW branch needs no writeback: it mutated `slot`'s own object.
 * `Zicl_ListShimmerWriteback` / `Zicl_DictShimmerWriteback` are a different
 * operation: they write a shimmered child back into a list/dict slot in place,
 * preserving the parent's string rep. Don't confuse them with this commit. */
#define ZICL_SWAP(slot, new_value)                              \
    do {                                                        \
        Zicl_ValueRep zicl_swap_old = (slot)->raw;              \
        (slot)->raw = (new_value).raw;                          \
        if (zicl_swap_old.tag != ZICL_TAG_NONE) {               \
            Zicl_Release((Zicl_Value){ zicl_swap_old });   \
        }                                                       \
    } while (0)

/* A ref-counted heap object. Opaque because its layout carries atomic fields
 * and a type-erased body that C cannot usefully touch directly; reach its state
 * through the accessors below (`Zicl_AsPtr`, `Zicl_RefCount`, ...). */
typedef struct Zicl_Object Zicl_Object;

typedef struct Zicl_Interp Zicl_Interp;

typedef int (*Zicl_CCommandFn)(Zicl_Interp *interp, int argc, Zicl_Shimmerable *argv);

/* A lazy native command initializer, called the first time a registered command
 * name is looked up. It is expected to install the real command (via
 * `Zicl_CreateCommand`) and then return. Mirrors `heap.LazyRegisterFn`. */
typedef void (*Zicl_LazyRegisterFn)(void *interp);

/* ===== Lifecycle =====
 * Process and thread setup, interpreter creation, and teardown. The global
 * state is per-process; each thread that touches the interpreter calls
 * `Zicl_InitThread` once. */

void Zicl_SetLocalStdout(int fd);
void Zicl_SetLocalStderr(int fd);

/* `host_name` is the name this machine goes by in the capabilities it hands
 * out. Pass NULL to ask the system for it. */
int Zicl_InitGlobals(const char *host_name);
/* Per-thread setup. Call once on every thread that touches the interpreter. */
int Zicl_InitThread(void);
void Zicl_DeinitThread(void);
void Zicl_DeinitAll(void);
/* Shutdown-only: dumps anything still live. Do not evaluate afterwards, as this
 * releases state the interpreter's out-of-memory path depends on. */
void Zicl_LeakCheckAll(void);

Zicl_Interp *Zicl_CreateInterp(void);
void Zicl_InterpDestroy(Zicl_Interp *interp);

/* A watermark into the calling thread's local arena, layout-equivalent to
 * `memutil.RewindableArena.Snapshot`. Treat the fields as opaque: hold the
 * value and pass it back to `Zicl_LocalArenaRewind`. A snapshot is only valid
 * on the thread that took it. */
typedef struct Zicl_ArenaSnapshot {
    void *current;
    size_t end_index;
} Zicl_ArenaSnapshot;

/* Take a watermark of the calling thread's local arena. Cheap (no allocation);
 * pairs with `Zicl_LocalArenaRewind`. Anything the interpreter still references
 * out of the arena becomes invalid after a rewind, so rewind only transient
 * work the caller keeps no live references to. */
Zicl_ArenaSnapshot Zicl_LocalArenaSnapshot(void);
/* Drop everything allocated from the local arena since `snap`, retaining the
 * chunks for reuse. `snap` must come from the same thread's `Zicl_LocalArenaSnapshot`. */
void Zicl_LocalArenaRewind(Zicl_ArenaSnapshot snap);

/* ===== Strings =====
 * The string representation is the source of truth for every value, so these
 * are the most general accessors. `Zicl_String` and `Zicl_GetString` generate
 * the string rep on demand, which can allocate (and so return NULL on OOM). */

int Zicl_NewString(Zicl_Value *out, const char *ptr, int len);
/* Wrap a static, NUL-terminated string as an interned value with no copy and no
 * allocation (so it cannot fail and returns by value). The string must live for
 * as long as the value is read and must be NUL-terminated. This is a header
 * inline so that strlen of a string literal folds to a compile-time constant,
 * making the common case (a short rodata literal such as a command name or dict
 * key) a constant Zicl_Value with no call. Interned strings are limited to
 * 65535 bytes; a longer one is a programmer error and aborts via
 * Zicl_InternStrTooLong rather than truncating. Unlike Zicl_NewString,
 * this does not take ownership and does not copy, so it must not be used for
 * buffers that will be freed or mutated. */
_Noreturn void Zicl_InternStrTooLong(void);
static inline Zicl_Value Zicl_InternStr(const char *ptr) {
    size_t len = strlen(ptr);
    if (len > 0xffff) Zicl_InternStrTooLong();
    Zicl_Value v;
    v.raw.as.interned = ptr;
    v.raw.interned_string_len = (uint16_t)len;
    v.raw.tag = ZICL_TAG_INTERNED;
    return v;
}
const char *Zicl_String(Zicl_Value object);
const char *Zicl_GetString(Zicl_Value object, int *len);

/* ===== Reference counting and object introspection =====
 * Reaching and accounting for the heap object behind a pointer-tagged value.
 * The primitives (`integer`, `float`, `boolean`, `interned`) carry no object,
 * so `Zicl_AsPtr` returns NULL and the refcount accessors report zero. */

void Zicl_Release(Zicl_Value value);
Zicl_Value Zicl_Borrow(Zicl_Value value);
/* A shallow copy of `value` as a fresh owned value with its own refcount. For a
 * pointer value this duplicates the underlying object (deep for the string rep;
 * collection items are borrowed) and can OOM; primitives (integer, float,
 * boolean, interned) return themselves, so it never fails for those. On success
 * stores the owned result in *out; the caller must release it or commit it via
 * ZICL_SWAP. Returns ZICL_OOM if the duplicate cannot be allocated. */
int Zicl_Duplicate(Zicl_Value value, Zicl_Value *out);
/* Release every value in `argv[0..argc]`. A convenience for cleaning up an
 * array of values (such as an argv built for a command call): it loops and
 * calls Zicl_Release on each, which is a no-op for primitives, so the
 * array can hold a mix of heap objects and inline values. `argc` must not be
 * negative. */
void Zicl_ReleaseArrayItems(Zicl_Value *argv, int argc);
/* The heap object a pointer-tagged value refers to, or NULL for primitives. */
Zicl_Object *Zicl_AsPtr(Zicl_Value value);
/* Wrap a heap object as a pointer-tagged value. The inverse of Zicl_AsPtr: no
 * refcount change, so the caller still owns the reference it had. */
Zicl_Value Zicl_BoxObject(Zicl_Object *obj);

/* Object debugging. `tag` is a plain field read, so there is no accessor for
 * it. Both of these are only meaningful for ZICL_TAG_POINTER values. */
uint32_t Zicl_RefCount(Zicl_Value value);
uint32_t *Zicl_RefCountPtr(Zicl_Value value);

/* ===== Cross-thread sharing =====
 * Objects opt into cross-thread access by marking themselves (and their
 * children) cross-thread. Marking is one-way: a marked object can never
 * shimmer or mutate again, even at ref count 1, because another thread may be
 * traversing a collection that reaches it. Ref counting switches to atomic
 * operations, so any thread can borrow, release, or free a marked object
 * without cooperating with its owning thread. Primitives are inline, so this
 * is a no-op for them.
 *
 * `Zicl_MakeCrossthread` only makes the object safe to ref-count and free from
 * another thread. It does not synchronize the transfer: the caller must
 * establish a happens-before relationship when handing the value to another
 * thread (e.g. through a mutex-protected channel). */

void Zicl_MakeCrossthread(Zicl_Value value);

/* ===== Value equality =====
 * Zicl compares values by their string representation, so values of different
 * runtime types compare equal when their string reps match (the integer 5 and
 * the string "5" are equal). Generating a string rep can allocate, so this can
 * return ZICL_OOM; on success it writes 1 or 0 to *out. */

int Zicl_Equals(Zicl_Value a, Zicl_Value b, int *out);

/* Fast equality that never allocates and never returns a false positive, but
 * may report two equal values as unequal when their string reps would need to
 * be generated to confirm it (for example, two distinct interned strings with
 * the same content, or a pointer-tagged object against a primitive). Use it as a
 * cheap short-circuit before falling back to Zicl_Equals. Returns 1 or 0. */
bool Zicl_QuickEquals(Zicl_Value a, Zicl_Value b);

/* ===== Numbers =====
 * Integer, float, and boolean values are stored inline, so the constructors
 * cannot fail. The coercions shimmer a value into the requested type through a
 * shimmerable, so they can fail (ZICL_OOM) or report a parse error (ZICL_ERR). */

Zicl_Value Zicl_NewLong(int64_t value);
Zicl_Value Zicl_NewDouble(double value);
Zicl_Value Zicl_NewBool(bool value);
int Zicl_GetLong(Zicl_Interp *interp, Zicl_Shimmerable *shim, long *out);
int Zicl_GetDouble(Zicl_Interp *interp, Zicl_Shimmerable *shim, double *out);
int Zicl_GetBoolean(Zicl_Interp *interp, Zicl_Shimmerable *shim, int *out);

/* ===== Shimmerables =====
 * Operations on the shimmerable working buffer itself, independent of any
 * specific target type. `Zicl_Current` returns the effective value (the
 * shimmered duplicate when one exists, otherwise the original). */

Zicl_Value Zicl_Current(const Zicl_Shimmerable *shim);
/* The string representation of the shimmerable's effective value, NUL-terminated.
 * Returns NULL if generating the string ran out of memory. */
const char *Zicl_ShimString(Zicl_Shimmerable *shim);
/* Same, writing the byte length to `*len` when non-NULL. */
const char *Zicl_ShimGetString(Zicl_Shimmerable *shim, int *len);
/* Release any shimmered duplicate and roll the shimmerable back to its original
 * value. The caller still owns `original`. */
void Zicl_ShimDiscardChanges(Zicl_Shimmerable *shim);

/* ===== Lists =====
 * The typed mutable body `*List` is the opaque handle `Zicl_List`; the export
 * functions take it directly, so no wrapper struct is needed. The copy-on-write
 * decision is exposed to the caller (`Zicl_AsListMut` for the no-copy fast path,
 * `Zicl_DupAsList` for the copy path) rather than hidden inside
 * `Zicl_ListAppend`, mirroring `lappendCmd` in src/commands/list.zig. */
typedef struct Zicl_List Zicl_List;

/* Build a list from `n_values` values (NULL/0 for an empty list). Each input
 * value is borrowed, so the caller keeps its reference. Result is NULL on OOM;
 * the caller owns the returned handle. */
Zicl_List *Zicl_NewList(const Zicl_Value *values, int n_values);
/* Build a list from `n_shims` shimmerables, borrowing each one's current value
 * (the effective value after any in-place shimmer). NULL/0 for an empty list.
 * Result is NULL on OOM; the caller owns the returned handle. */
Zicl_List *Zicl_NewListFromShimmerables(const Zicl_Shimmerable *shims, int n_shims);
/* Wrap an owned list handle as a value, transferring ownership. Do not touch
 * `list` afterwards. */
Zicl_Value Zicl_BoxList(Zicl_List *list);
/* Release an owned list handle. */
void Zicl_ReleaseList(Zicl_List *list);
/* Borrow a list handle: the same handle with its refcount incremented. The
 * caller owns the returned handle and must release it with Zicl_ReleaseList. */
Zicl_List *Zicl_BorrowList(Zicl_List *list);

/* Copy-on-write entry points. If `value` is uniquely owned, `*out` is a
 * borrowed mutable view of the same object (no copy). If it is shared,
 * cross-thread, or a primitive, `*out` is NULL and the caller must
 * Zicl_DupAsList. Returns ZICL_OOM if shimmering allocates and fails, ZICL_ERR
 * for a malformed list string. A borrowed view is not owned: do not pass it to
 * Zicl_ReleaseList. Commit a duplicate back to its slot with
 * ZICL_SWAP(&slot, Zicl_BoxList(*out)). */
int Zicl_AsListMut(Zicl_Interp *interp, Zicl_Value value, Zicl_List **out);
/* An owned mutable copy of `value` shimmered to a list. Returns ZICL_OOM on OOM
 * (out is set to NULL), ZICL_ERR for a malformed list string. Commit it back to
 * the slot with ZICL_SWAP(&slot, Zicl_BoxList(*out)). */
int Zicl_DupAsList(Zicl_Interp *interp, Zicl_Value value, Zicl_List **out);

/* Shimmer a shimmerable to a list in place (for command arguments). */
int Zicl_ListShimmer(Zicl_Interp *interp, Zicl_Shimmerable *shim, const Zicl_List **out);

/* Typed operations on a mutable view. */
/* Pointer to the item array, valid for Zicl_ListLength(listPtr) items. Read
 * access only; use Zicl_ListSet to replace an item. */
const Zicl_Value *Zicl_ListItems(const Zicl_List *listPtr);
int Zicl_ListLength(const Zicl_List *listPtr);
/* Appends a borrowed copy of `item`; the caller keeps its reference. */
int Zicl_ListAppend(Zicl_List *listPtr, Zicl_Value item);
/* Replaces item `index`, releasing the old one and taking ownership of `item`
 * (the caller must not release `item` afterwards). A negative index panics at
 * the Zig boundary; an out-of-range positive index returns ZICL_ERR. */
int Zicl_ListSet(Zicl_List *listPtr, int index, Zicl_Value item);

/* Read item `index` from a shimmerable list. Writes a borrowed value to `*out`,
 * or ZICL_NONE when the index is out of range (negative or too large). Returns
 * ZICL_OOM/ZICL_ERR if shimmering the list fails. */
int Zicl_ShimListItem(Zicl_Interp *interp, Zicl_Shimmerable *shim, int index, Zicl_OptionalValue *out);

/* Absent when the index is out of range (negative or too large). The result is
 * borrowed from the list, so it is only valid while the list holds it. */
Zicl_OptionalValue Zicl_ListGetItem(Zicl_Interp *interp, Zicl_Value *list, int index);

/* Replace the item at `index` with `value` in place, without invalidating the
 * list's string rep. For writing a shimmered form of an already-stored item
 * back into its slot, where the shimmer preserved the string rep (so the list's
 * cached string is still valid). This is distinct from ZICL_SWAP, which is the
 * dup-branch commit. `index` must be in range: a negative index panics, an
 * out-of-range positive index returns ZICL_ERR. Borrows `value`. */
int Zicl_ListShimmerWriteback(Zicl_List *list, int index, Zicl_Value value);

/* ===== Dicts =====
 * The typed mutable body `*Dictionary` is the opaque handle `Zicl_Dict`; the
 * export functions take it directly, so no wrapper struct is needed. The
 * copy-on-write decision is exposed to the caller (`Zicl_AsDictMut` for the
 * no-copy fast path, `Zicl_DupAsDict` for the copy path) rather than hidden
 * inside `Zicl_DictPut`, mirroring `dict set` / `lappendCmd`. */
typedef struct Zicl_Dict Zicl_Dict;

/* Build a dict from `n_values` alternating key/value values (NULL/0 for an
 * empty dict). Each input value is borrowed, so the caller keeps its reference.
 * Result is NULL on OOM; the caller owns the returned handle. */
Zicl_Dict *Zicl_NewDict(const Zicl_Value *values, int n_values);
/* Wrap an owned dict handle as a value, transferring ownership. Do not touch
 * `dict` afterwards. */
Zicl_Value Zicl_BoxDict(Zicl_Dict *dict);
/* Release an owned dict handle. */
void Zicl_ReleaseDict(Zicl_Dict *dict);
/* Borrow a dict handle: the same handle with its refcount incremented. The
 * caller owns the returned handle and must release it with Zicl_ReleaseDict. */
Zicl_Dict *Zicl_BorrowDict(Zicl_Dict *dict);

/* Copy-on-write entry points. If `value` is uniquely owned, `*out` is a
 * borrowed mutable view of the same object (no copy). If it is shared,
 * cross-thread, or a primitive, `*out` is NULL and the caller must
 * Zicl_DupAsDict. Returns ZICL_OOM if shimmering allocates and fails, ZICL_ERR
 * for a malformed dict string (odd item count). A borrowed view is not owned:
 * do not pass it to Zicl_ReleaseDict. Commit a duplicate back to its slot with
 * ZICL_SWAP(&slot, Zicl_BoxDict(*out)). */
int Zicl_AsDictMut(Zicl_Interp *interp, Zicl_Value value, Zicl_Dict **out);
/* An owned mutable copy of `value` shimmered to a dict. Returns ZICL_OOM on OOM
 * (out is set to NULL), ZICL_ERR for a malformed dict string. Commit it back to
 * the slot with ZICL_SWAP(&slot, Zicl_BoxDict(*out)). */
int Zicl_DupAsDict(Zicl_Interp *interp, Zicl_Value value, Zicl_Dict **out);

/* Shimmer a shimmerable to a dict in place (for command arguments). */
int Zicl_DictShimmer(Zicl_Interp *interp, Zicl_Shimmerable *shim, const Zicl_Dict **out);

/* Typed operations on a mutable view. */
/* Number of key/value pairs. */
int Zicl_DictLength(const Zicl_Dict *dictPtr);
/* Pointer to the item array, valid for 2*Zicl_DictLength(dictPtr) values in
 * alternating key, value order. Read access only; use Zicl_DictPut to change. */
const Zicl_Value *Zicl_DictItems(const Zicl_Dict *dictPtr);
/* Insert or update `key` with `value`, borrowing both. The caller keeps its
 * references. Asserts the dict is mutable, so reach it through Zicl_AsDictMut
 * or Zicl_DupAsDict first. */
int Zicl_DictPut(Zicl_Dict *dictPtr, Zicl_Value key, Zicl_Value value);
/* Remove all pairs with `key`. Writes 1 to *removed if any pair was removed, 0
 * otherwise. Returns ZICL_OOM if flattening parent links allocates and fails. */
int Zicl_DictRemove(Zicl_Dict *dictPtr, Zicl_Value key, int *removed);

/* Read the value for `key` from a shimmerable dict, following `~parent` links.
 * Writes a borrowed value to *out, or ZICL_NONE when the key is absent. Returns
 * ZICL_OOM/ZICL_ERR if shimmering the dict or resolving a link fails. */
int Zicl_ShimDictGet(Zicl_Interp *interp, Zicl_Shimmerable *shim, Zicl_Value key, Zicl_OptionalValue *out);

/* Absent when the key is not present (following `~parent` links). The result is
 * borrowed from the dict, so it is only valid while the dict holds it. */
Zicl_OptionalValue Zicl_DictGet(Zicl_Interp *interp, Zicl_Value *dict, Zicl_Value key);

/* Replace the value for `key` with `value` in place, without invalidating the
 * dict's string rep. For writing a shimmered form of an already-stored value
 * back into its slot, where the shimmer preserved the string rep (so the dict's
 * cached string is still valid). This is distinct from ZICL_SWAP, which is the
 * dup-branch commit. `key` must already be present: the writeback walks the
 * hash table to find the value slot, so a missing key is a violated invariant
 * and panics. Returns ZICL_OOM if hashing the key allocates and fails. Borrows
 * `value`. */
int Zicl_DictShimmerWriteback(Zicl_Dict *dict, Zicl_Value key, Zicl_Value value);

/* ===== Source =====
 * A `Source` carries file/line metadata alongside a value's bytes, so
 * evaluation errors can point at the originating location. A value shimmers to
 * a Source with an empty location (`Source.shimmerFrom`), then the metadata is
 * read/write through the mutable view: annotate in place when the object is
 * uniquely owned (Zicl_AsSourceMut) or on a copy when it is shared
 * (Zicl_DupAsSource, committed with ZICL_SWAP). `Zicl_AttachSource` is the
 * convenience helper that copies the string and sets a fresh location in one
 * call. */

/* The body of a Source object, mirroring `objects.Source`. `file_name` is an
 * optional string (NULL when the source has no filename); `line_no` is the
 * 1-based line. `_hash` is an internal content-hash cache and must not be read
 * or written. The layout matches the Zig extern struct, so a pointer from
 * Zicl_AsSource or Zicl_AsSourceMut can be used directly. */
typedef struct Zicl_Source {
    Zicl_OptionalValue file_name;
    uint32_t line_no;
    void *_hash;
} Zicl_Source;

/* Narrow a value to its Source body, or NULL if the value is not a Source.
 * The pointer borrows the underlying object: it is valid only while the value
 * stays alive, and the fields must not be written. */
const Zicl_Source *Zicl_AsSource(Zicl_Value value);

/* Copy-on-write entry points. If `value` is uniquely owned, Zicl_AsSourceMut
 * returns a borrowed mutable view of the same object shimmered to a Source
 * (no copy); if it is shared, cross-thread, or a primitive, it returns NULL
 * and the caller must Zicl_DupAsSource. A shimmered-in Source starts with an
 * empty location (`file_name` absent, `line_no` 0); set them through the view.
 * `line_no` may be written directly. `file_name` is a refcounted value: to
 * change it, release the old Zicl_OptionalValue and store a borrowed one (the
 * caller owns the bookkeeping, as with any refcounted field). `_hash` is
 * internal and must not be touched. A borrowed view is not owned: do not pass it
 * to Zicl_ReleaseSource. */
Zicl_Source *Zicl_AsSourceMut(Zicl_Value value);
/* An owned mutable copy of `value` shimmered to a Source, or NULL on OOM.
 * Commit it back to the slot with ZICL_SWAP(&slot, Zicl_BoxSource(out)). A
 * Source carries no lookup state, so there is no specialized writeback -- the
 * generic swap is the commit path. */
Zicl_Source *Zicl_DupAsSource(Zicl_Value value);
/* Wrap an owned Source handle as a value, transferring ownership. Do not touch
 * `source` afterwards. */
Zicl_Value Zicl_BoxSource(Zicl_Source *source);
/* Release an owned Source handle. */
void Zicl_ReleaseSource(Zicl_Source *source);
/* Borrow a Source handle: the same handle with its refcount incremented. The
 * caller owns the returned handle and must release it with Zicl_ReleaseSource. */
Zicl_Source *Zicl_BorrowSource(Zicl_Source *source);

const char *Zicl_SourceGetFilename(Zicl_Value source);
int Zicl_SourceGetLine(Zicl_Value source);
/* Replaces *value with one carrying the given source location, releasing the
 * original on success. A convenience that copies the string and sets a fresh
 * location in one call; for in-place annotation use the copy-on-write entry
 * points above. */
int Zicl_AttachSource(Zicl_Value *value, const char *filename, int line_no);

/* ===== Interpreter =====
 * Registering commands, evaluating scripts, reading and writing the result,
 * setting variables, and the cooperative stop flag the runtime sets to
 * interrupt a running eval. */

/* Register `command` under `name`. `description` is a short usage string.
 * `min_arity`/`max_arity` are the argument bounds excluding the command name
 * itself; pass -1 for `max_arity` to leave it unbounded.
 * Returns ZICL_OOM on allocation failure. */
int Zicl_CreateCommand(Zicl_Interp *interp, const char *name, Zicl_CCommandFn command,
                       const char *description, int min_arity, int max_arity);
/* Register a lazy initializer for `name`. The initializer runs on first lookup,
 * and is expected to install the real command itself. Returns ZICL_ERR if `name`
 * is already registered, ZICL_OOM if the registry entry cannot be allocated. */
/* `library` identifies the registrant (e.g. a compiled extension's own
 * package name). Registering the same `name` again from the same `library`
 * is a no-op -- expected when independent threads each `load` the same
 * compiled library -- but a different `library` claiming a `name` already
 * taken is a real collision and returns ZICL_ERR. */
int Zicl_RegisterLazyFn(const char *name, const char *library, Zicl_LazyRegisterFn init_fn);
int Zicl_EvalValue(Zicl_Interp *interp, Zicl_Value script);
/* Evaluate a NUL-terminated script string. Boxes it as a value and delegates to
 * Zicl_EvalValue, so a top-level `return`/`break`/`continue` surfaces as
 * ZICL_PROPAGATE/ZICL_BREAK/ZICL_CONTINUE rather than being swallowed (matching
 * Tcl_Eval). The result is left on the interpreter; read it with Zicl_GetResult.
 * Returns ZICL_OOM if boxing the string allocates and fails. */
int Zicl_Eval(Zicl_Interp *interp, const char *script);
int Zicl_EvalFile(Zicl_Interp *interp, const char *filename);
/* Dynamically load a compiled Zicl extension: dlopen `path`, then call its
 * `Zicl_<pkgname>Init(interp)`, where `<pkgname>` is `path`'s basename up to
 * (not including) its first `.` (so `foo.so` calls `Zicl_fooInit`). The
 * library is never dlclose'd, since an extension can hand out function
 * pointers that outlive this call. This is what the `load` Tcl command calls;
 * use it directly to load an extension without going through script
 * evaluation.
 *
 * There are no namespaces to install commands into, so `Zicl_<pkgname>Init`
 * does not call Zicl_CreateCommand itself. Instead, for each command it
 * provides, it calls Zicl_RegisterLazyFn(registryName, path, real_registrar)
 * -- `real_registrar` is a plain internal function pointer, never its own
 * exported symbol, that does the actual Zicl_CreateCommand calls the first
 * time `registryName` is looked up on a given interp -- and returns an owned
 * Zicl_Dict of `{cleanName registryName ...}` (Zicl_LoadLibrary releases it).
 * The two names differ in purpose: `registryName` is whatever key was passed
 * to Zicl_RegisterLazyFn, typically qualified with the library's own package
 * name so unrelated libraries can't collide in the shared registry, while
 * `cleanName` is what the *result* dict below uses as its key. This split is
 * required, not cosmetic: dict sugar (`$lib::name`) treats `::` as its own
 * path separator, so a registry-style qualified name could never work as a
 * dict key. `path` doubles as Zicl_RegisterLazyFn's dedup key: re-registering
 * the same registryName from the same path is a no-op, since independent
 * threads may each `load` the same compiled file. On failure,
 * `Zicl_<pkgname>Init` sets the interp's result to an error message and
 * returns NULL.
 *
 * On success, Zicl_LoadLibrary turns that into `{cleanName1 {nativefn
 * registryName1} cleanName2 {nativefn registryName2} ...}` and leaves it as
 * the interp's result: an ordinary dict, not a namespace, and an ordinary
 * Folk value that propagates through envs and closures like any other. A
 * caller uses it with dict-sugar, e.g. `dict get $lib cleanName` or
 * `$lib::cleanName arg ...`; the latter drives the exact same
 * lazy-registration path a plain `nativefn` name would; the underlying
 * commands materialize on whichever interp first actually calls one.
 *
 * Returns ZICL_ERR (with a result message) if the file can't be opened, the
 * init symbol is missing, or the init function itself fails. */
int Zicl_LoadLibrary(Zicl_Interp *interp, const char *path);
Zicl_Value Zicl_GetScriptBeingEvaluated(Zicl_Interp *interp);
/* Index of the current (innermost) eval frame. Walk downwards from this to
 * inspect the stack; pair with Zicl_EvalFrameScript. */
uint32_t Zicl_CurrentEvalFrameIdx(Zicl_Interp *interp);
/* The script object being evaluated in eval frame `frame`. The value is borrowed
 * from the frame, so it is valid only while that frame remains on the stack.
 * `frame` must be a valid index (0 .. Zicl_CurrentEvalFrameIdx). */
Zicl_Value Zicl_EvalFrameScript(Zicl_Interp *interp, uint32_t frame);
Zicl_Value Zicl_GetResult(Zicl_Interp *interp);
void Zicl_SetResult(Zicl_Interp *interp, Zicl_Value value);
void Zicl_SetResultOwning(Zicl_Interp *interp, Zicl_Value value);
int Zicl_SetResultString(Zicl_Interp *interp, const char *str, int len);
/* Set the interpreter result to `str` and report it as an error: returns
 * ZICL_ERR on the success path, ZICL_OOM if storing the string allocates and
 * fails. Never returns ZICL_OK. `len` is the byte length, or -1 for NUL-terminated. */
int Zicl_SetErrorString(Zicl_Interp *interp, const char *str, int len);
int Zicl_SetResultBool(Zicl_Interp *interp, int value);
int Zicl_SetResultLong(Zicl_Interp *interp, long value);
int Zicl_SetEmptyResult(Zicl_Interp *interp);
int Zicl_SetVariable(Zicl_Interp *interp, Zicl_Value *name, Zicl_Value value);
int Zicl_MakeErrorMessage(Zicl_Interp *interp);

/* Ask the interpreter to stop evaluating. The next command boundary in a
 * running Zicl_Eval/Zicl_EvalValue/Zicl_EvalFile returns ZICL_EXIT. The runtime
 * sets this from its own signal-delivery path; the interpreter never clears it. */
void Zicl_RequestStop(Zicl_Interp *interp);
/* True once Zicl_RequestStop has been called. */
bool Zicl_StopRequested(Zicl_Interp *interp);
/* Reset the stop flag so the interpreter can be reused. Only call this when no
 * eval is in flight on `interp`. */
void Zicl_ClearStop(Zicl_Interp *interp);

/* ===== Capabilities =====
 * A capability is an unforgeable name (a `zicl://<host>/<type>/<id>` URL) for a
 * resource a script can hold and pass around. C code can define its own
 * capability types: allocate a backing struct that embeds a `Zicl_Head` as a
 * field, point the head's `vtable` at a static `Zicl_HeadVTable`, and register
 * it with `Zicl_CapabilityNew`. The same vtable pointer is what
 * `Zicl_GetBacking` compares against, so each capability type has exactly one
 * vtable instance. These layouts mirror `Capability.Head` and
 * `Capability.Head.VTable` on the Zig side, field-for-field, so they match on
 * any target both are compiled for. Recover the backing from the head Zicl
 * hands back with `Zicl_ContainerOf`. */

/* 128-bit capability identifier. Assigned by Zicl at registration; treat it as
 * opaque, and zero it before `Zicl_CapabilityNew`. */
#if defined(__SIZEOF_INT128__)
typedef __int128 Zicl_Id;
#else
#error "zicl requires 128-bit integer support (__int128)"
#endif

struct Zicl_Head;

typedef struct Zicl_HeadVTable {
    /* NUL-terminated, e.g. "file-handle". */
    const char *name;
    /* Deinits the body. Runs exactly once, from close. */
    void (*deinit_body)(struct Zicl_Head *head);
    /* Frees the backing. Runs at ref count zero, which may be long after close. */
    void (*destroy_backing)(struct Zicl_Head *head);
} Zicl_HeadVTable;

/* The generic part of a capability. Embed this as a field of a backing struct
 * (at any offset; recover the backing with `Zicl_ContainerOf`). C code sets
 * `vtable`; `Zicl_CapabilityNew` initializes the rest, so the remaining fields
 * are reserved for Zicl. The layout matches `Capability.Head` on the Zig side
 * for the target both are compiled for; the field order is fixed, so no size is
 * asserted here (it varies between 32- and 64-bit targets). */
typedef struct Zicl_Head {
    const Zicl_HeadVTable *vtable;
    Zicl_Id id;
    bool closed;
    uint32_t ref_count;
} Zicl_Head;

/* Parsed form of a capability URL. `host` and `type_name` point into the input
 * string and are not NUL-terminated. */
typedef struct Zicl_ParsedName {
    const char *host;
    int host_len;
    const char *type_name;
    int type_len;
    Zicl_Id id;
} Zicl_ParsedName;

/* Register `head` and return the capability object that names it. `head` is a
 * `Zicl_Head` embedded in a backing struct the caller allocated (at any offset);
 * Zicl initializes `id`, `closed`, and `ref_count`. The caller owns the returned
 * value, and recovers its backing from the head with `Zicl_ContainerOf`. */
int Zicl_CapabilityNew(Zicl_Value *out, Zicl_Head *head);
/* Close a capability (idempotent). No-op if `value` is not a capability. */
void Zicl_CapabilityClose(Zicl_Value value);
/* Resolve a capability URL string in place, replacing `*value` with the
 * capability object it names. Returns ZICL_ERR for a malformed or stale name. */
int Zicl_ResolveCapability(Zicl_Value *value);
/* The type segment of a capability's URL (e.g. "file-handle"), or NULL if
 * `value` is not a capability. */
const char *Zicl_CapabilityTypeName(Zicl_Value value);
/* Whether the capability has been closed, or false if `value` is not one. */
bool Zicl_CapabilityIsClosed(Zicl_Value value);

/* The C counterpart of Capability.getBacking. Validates that `value` is a
 * capability whose head carries `expected` (pass NULL to skip the type check),
 * that it has not been closed, and writes its head to `*out`. The head is
 * borrowed from the capability: valid while the capability stays alive and
 * open. Recover the backing with `Zicl_ContainerOf(*out, MyBacking, head)`. */
int Zicl_GetBacking(Zicl_Value value, const Zicl_HeadVTable *expected, Zicl_Head **out);

/* Head operations, mirroring Capability.Head. */
Zicl_Head *Zicl_HeadBorrow(Zicl_Head *head);
void Zicl_HeadRelease(Zicl_Head *head);
void Zicl_HeadClose(Zicl_Head *head);
bool Zicl_HeadIsClosed(Zicl_Head *head);
void Zicl_HeadGetId(Zicl_Head *head, Zicl_Id *out);

/* Parse a capability URL into its parts. `host` and `type_name` point into
 * `str` and are not NUL-terminated. */
int Zicl_ParseCapabilityName(const char *str, int len, Zicl_ParsedName *out);
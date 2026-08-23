#pragma once

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

#if defined(__cplusplus)
#define ZICL_NORETURN [[noreturn]]
#define ZICL_ALIGNAS(n) alignas(n)
#else
#define ZICL_NORETURN _Noreturn
#define ZICL_ALIGNAS(n) _Alignas(n)
#endif

/* ===== Values, types, and conventions ===== */
/* A heap allocated Zicl object. */
typedef struct Zicl_Object Zicl_Object;

/* The representation of values in Zicl. We use a 8 byte payload, along
 * with a 1 byte tag and 2 byte "extra" value. Mirrors `heap.ValueRep` on
 * the Zig side, so the two must be kept in step. */
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
        Zicl_Object *pointer;
        double float_value;
        int64_t integer;
        bool boolean;
        const char *interned;
    } as;
    /* Only meaningful when `tag` is ZICL_TAG_INTERNED. */
    uint16_t interned_string_len;
    Zicl_Tag tag;
} Zicl_ValueRep;

/* A non-null Value. */
typedef struct Zicl_Value {
    Zicl_ValueRep raw;
} Zicl_Value;

/* A nullable Value. */
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

/* Narrow an optional. Asserts that `value` is not none. */
static inline Zicl_Value Zicl_Unwrap(Zicl_OptionalValue value) {
    assert(Zicl_IsSome(value));
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
 * Zicl type (such as a `Zicl_CapabilityHead`) as a field in its own struct and uses this
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
 *     defer { Zicl_DropRef(script); }
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
 *     defer { if (rc) Zicl_DropRefList(list); }
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
 * `Zicl_DropRef` is a no-op for primitives and the `none` optional, so the
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
            Zicl_DropRef((Zicl_Value){ zicl_swap_old });   \
        }                                                       \
    } while (0)

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
 * `memutil.ScopedArena.Snapshot`. Treat the fields as opaque: hold the
 * value and pass it back to `Zicl_LocalArenaRewind`. A snapshot is only valid
 * on the thread that referenced it. */
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
/* Build a string value from a printf-style format, the C-side counterpart to
 * the Zig side's `objects.String.newFormatted`. A header inline rather than an
 * exported function because C variadic arguments can't cross the Zig/C ABI
 * boundary as `...`; this formats into a stack buffer (falling back to a
 * transient `malloc`'d one only if the result doesn't fit) and hands the
 * bytes to Zicl_NewString, so the only allocation Zicl itself tracks is the
 * copy Zicl_NewString makes. Returns ZICL_OK, ZICL_OOM (from Zicl_NewString or
 * the malloc fallback), or ZICL_ERR if vsnprintf itself reports an encoding
 * error. */
#if defined(__GNUC__) || defined(__clang__)
__attribute__((format(printf, 2, 3)))
#endif
static inline int Zicl_NewStringFormatted(Zicl_Value *out, const char *fmt, ...) {
    char stack_buf[256];
    va_list args;
    va_start(args, fmt);
    va_list args_copy;
    va_copy(args_copy, args);
    int needed = vsnprintf(stack_buf, sizeof(stack_buf), fmt, args);
    va_end(args);
    if (needed < 0) {
        va_end(args_copy);
        return ZICL_ERR;
    }
    if ((size_t)needed < sizeof(stack_buf)) {
        va_end(args_copy);
        return Zicl_NewString(out, stack_buf, needed);
    }

    char *heap_buf = (char *)malloc((size_t)needed + 1);
    if (!heap_buf) {
        va_end(args_copy);
        return ZICL_OOM;
    }
    vsnprintf(heap_buf, (size_t)needed + 1, fmt, args_copy);
    va_end(args_copy);
    int rc = Zicl_NewString(out, heap_buf, needed);
    free(heap_buf);
    return rc;
}
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
ZICL_NORETURN void Zicl_InternStrTooLong(void);
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

void Zicl_DropRef(Zicl_Value value);
Zicl_Value Zicl_Ref(Zicl_Value value);
/* A shallow copy of `value` as a fresh owned value with its own refcount. For a
 * pointer value this duplicates the underlying object (deep for the string rep;
 * collection items are borrowed) and can OOM; primitives (integer, float,
 * boolean, interned) return themselves, so it never fails for those. On success
 * stores the owned result in *out; the caller must release it or commit it via
 * ZICL_SWAP. Returns ZICL_OOM if the duplicate cannot be allocated. */
int Zicl_Duplicate(Zicl_Value value, Zicl_Value *out);
/* Zicl_Duplicate, except the result is always a heap object rather than a
 * possibly-inline value: a pointer value duplicates its object, and a
 * primitive is copied into a fresh object (integer into an Integer, float
 * into a Float, boolean or interned string into a String). Returns NULL on
 * OOM; otherwise an owned Zicl_Object* with a single reference. Hold it as a
 * value with Zicl_BoxObject (no refcount change), or release it with
 * Zicl_DropRef(Zicl_BoxObject(obj)). */
Zicl_Object *Zicl_DuplicateAsBoxed(Zicl_Value value);
/* Release every value in `argv[0..argc]`. A convenience for cleaning up an
 * array of values (such as an argv built for a command call): it loops and
 * calls Zicl_DropRef on each, which is a no-op for primitives, so the
 * array can hold a mix of heap objects and inline values. `argc` must not be
 * negative. */
void Zicl_DropRefArrayItems(Zicl_Value *argv, int argc);
/* The heap object a pointer-tagged value refers to, or NULL for primitives. */
Zicl_Object *Zicl_AsPtr(Zicl_Value value);
/* Wrap a heap object as a pointer-tagged value. The inverse of Zicl_AsPtr: no
 * refcount change, so the caller still owns the reference it had. */
Zicl_Value Zicl_BoxObject(Zicl_Object *obj);

/* Object debugging. `tag` is a plain field read, so there is no accessor for
 * it. Both of these are only meaningful for ZICL_TAG_POINTER values. */
uint32_t Zicl_RefCount(Zicl_Value value);
uint32_t *Zicl_RefCountPtr(Zicl_Value value);

/* ===== Custom native object types =====
 * A C-defined type built on the same Object infrastructure every built-in
 * type (String, List, Dict, ...) uses: ref-counted, with a small (<=
 * ZICL_OBJECT_BODY_MAX_SIZE, currently 48 bytes) inline body and a vtable of
 * behavior callbacks. A struct that fits lives inline with no extra
 * allocation; a bigger one needs its own out-of-line storage, but that's a
 * decision for the vtable's own callbacks to make, not something Zicl
 * tracks: since sizeof(T) is a compile-time constant, `if (sizeof(T) <=
 * ZICL_OBJECT_BODY_MAX_SIZE) ... else ...` inside a vtable callback compiles
 * down to whichever branch is live, so one uniform pattern -- the body holds
 * T directly, or the body holds a T* to a malloc'd copy -- costs nothing
 * either way, and Zicl's own Object code never needs to know which case it
 * is: to Zicl this is always just 48 opaque bytes plus callbacks that know
 * what to do with them. */

#define ZICL_OBJECT_BODY_MAX_SIZE 48

/* Opaque handle a struct's own `enumerate_struct` receives (never
 * constructs) and passes straight through to Zicl_StructWalkerAddField /
 * Zicl_StructWalkerFollowValue / Zicl_StructWalkerFollowStruct, to describe
 * that struct's own fields for a Zicl_LeakCheckAll dump. See those functions,
 * declared further down after Zicl_SetObjectString. */
typedef struct Zicl_StructWalker Zicl_StructWalker;
/* A struct's own describe-my-fields callback, used both as
 * Zicl_ObjectVTable's `enumerate_struct` and as the forwarding function
 * passed to Zicl_StructWalkerFollowStruct for a nested plain struct field.
 * Report through `ctx`, then return ZICL_OK or ZICL_OOM (any other result is
 * treated as ZICL_OOM).
 *
 * `node` means something different in the two roles, and the difference is
 * load-bearing, not cosmetic:
 *  - As Zicl_ObjectVTable's `enumerate_struct`, `node` is the Zicl_Object*
 *    itself (cast to const void*) -- call Zicl_ObjectBody/Zicl_ObjectBodyConst
 *    on it to reach your own struct data, the same as every other
 *    Zicl_ObjectVTable callback. It is deliberately *not* handed to you
 *    already-unwrapped: the Object pointer is this node's identity for
 *    dedup/cycle detection, and it's the same pointer every other path that
 *    can reach this object (a dict/list slot holding it, a sibling field
 *    following it via Zicl_StructWalkerFollowValue) arrives with. Handing out
 *    a different address here (e.g. the body) would make two paths to the
 *    same object look like two different nodes, breaking cycle detection for
 *    good.
 *  - As the `enumerateStruct` forwarded to Zicl_StructWalkerFollowStruct,
 *    `node` is exactly the `ptr` that call was given -- no Object wraps a
 *    nested plain struct field, so there's nothing to unwrap. */
typedef int (*Zicl_EnumerateStructFn)(Zicl_StructWalker *ctx, const void *node);

/* Layout-identical to the Zig side's `heap.Object.VTable` with the C union
 * variant selected (`is_c_vtable = true`); the two must be kept in step.
 *  - duplicate: called to copy the object (Zicl_Duplicate, or copy-on-write
 *    duplication inside a dict/list that holds it). Required -- NULL means
 *    the type can never be duplicated, and Zicl panics if it tries. There is
 *    no default: every type provides its own, however trivial (a POD
 *    struct's is a couple of lines -- Zicl_NewObject, memcpy the body,
 *    return).
 *  - update_string: called lazily the first time the object's string
 *    representation is needed (Zicl_String / Zicl_GetString on a value that
 *    hasn't been stringified yet). Returns ZICL_OK or ZICL_OOM (any other
 *    result is treated as ZICL_OOM). Required for the same reason as
 *    duplicate: Tcl's "everything is a string" model has no value that
 *    cannot render as one, so NULL here also panics rather than making
 *    Zicl_String return NULL.
 *  - free_internal_rep: called once, when the last reference is dropped,
 *    before the object's own storage is freed. NULL means there is nothing
 *    to free beyond that -- the right choice for a POD struct with no
 *    internal pointers.
 *  - make_crossthread: called once when a value crosses from the thread that
 *    created it to another (Zicl_MakeCrossthread). NULL means the type may
 *    never cross threads at all -- Zicl panics if it tries.
 *    Zicl_NoopMakeCrossthread is provided for a type with no cross-thread
 *    hazards (nothing in its body another thread could race on).
 *  - enumerate_struct: called when a Zicl_LeakCheckAll dump reaches one of
 *    this type's objects, to describe its fields. NULL means the object
 *    shows up in a dump as an opaque leaf (address only) -- unlike the
 *    others, this one is optional with a real "do nothing extra" meaning,
 *    since it only affects debug output, never correctness. */
typedef struct Zicl_ObjectVTable {
    bool is_c_vtable;
    const char *name;
    /* Note that we discard the union here, since the layout is identical without
     * the union. This only works because both variants have the exact same number
    * of function pointers. */
    Zicl_Object *(*duplicate)(const Zicl_Object *src);
    void (*free_internal_rep)(Zicl_Object *obj);
    int (*update_string)(Zicl_Object *obj);
    void (*make_crossthread)(Zicl_Object *obj);
    Zicl_EnumerateStructFn enumerate_struct;
} Zicl_ObjectVTable;

/* Layout-identical to the Zig side's `heap.Object`, field order included --
 * the two must be kept in step. Every field here is a plain type, matching
 * the Zig side: `heap.Object` has no atomic-qualified fields either, since
 * Zig models atomicity as a property of the operation (@atomicLoad,
 * @atomicRmw), not of the field's type. That said, `string`, `string_metadata`,
 * and `hash_metadata` *are* read and written atomically by the interpreter,
 * so touching them directly from C without an equivalent atomic access races
 * with it; go through the accessors below (Zicl_RefCount, Zicl_ObjectBody,
 * Zicl_SetObjectString, ...) instead of reading these fields directly.
 * `metadata`, `string_metadata`, and `hash_metadata` also each pack multiple
 * bits (Object.Metadata, Object.StringMetadata, Object.HashMetadata on the
 * Zig side); their bit layouts aren't exposed here. */
struct Zicl_Object {
    void *string;
    const Zicl_ObjectVTable *vtable;
    uint32_t ref_count;
    uint8_t metadata;
    uint32_t string_metadata;
    uint8_t hash_metadata;
    ZICL_ALIGNAS(8) uint8_t body_backing[ZICL_OBJECT_BODY_MAX_SIZE];
};

/* For a type with no cross-thread hazards: nothing in its body that another
 * thread reading it concurrently could race on. */
void Zicl_NoopMakeCrossthread(Zicl_Object *obj);

/* Allocates a new object under `vtable`, with `size` bytes of zeroed inline
 * storage (size must be <= ZICL_OBJECT_BODY_MAX_SIZE -- a bigger struct
 * stores a pointer here instead; see the section comment above). *out_body is
 * set to that storage; write the struct there. Returns NULL on OOM.
 *
 * Two objects are the same type exactly when they share the same `vtable`
 * pointer, compared by address, not contents -- Zicl_AsObject checks this.
 * So: one `static const Zicl_ObjectVTable` per type, and share its address
 * with any other compiled unit that needs to recognize the same type (e.g.
 * via the dict Zicl_LoadLibrary / `load` returns). */
Zicl_Object *Zicl_NewObject(const Zicl_ObjectVTable *vtable, size_t size, void **out_body);
/* NULL if `value` isn't a pointer-tagged value built by Zicl_NewObject with
 * this exact `vtable` (by address, not structural match). Otherwise, the
 * object's inline body -- the same pointer Zicl_NewObject handed back as
 * *out_body when the object was created. */
void *Zicl_AsObject(Zicl_Value value, const Zicl_ObjectVTable *vtable);
/* Raw access to an object's inline body, for use inside a vtable callback:
 * those receive a bare Zicl_Object*, not a boxed Zicl_Value, so Zicl_AsObject
 * doesn't apply there. Unlike Zicl_AsObject this does no type check -- a
 * vtable callback already knows its own object's type, since Zicl only ever
 * calls a type's callbacks on that type's own objects. */
void *Zicl_ObjectBody(Zicl_Object *obj);
const void *Zicl_ObjectBodyConst(const Zicl_Object *obj);
/* For use inside a vtable's `update_string` callback: computes the string
 * representation and copies it in. `str` need not be NUL-terminated (`len`
 * is the byte length), or pass -1 for NUL-terminated. Returns ZICL_OK or
 * ZICL_OOM; update_string should propagate this return value directly (see
 * Zicl_ObjectVTable's update_string docs above for how a non-ZICL_OK result
 * is treated). Without this, update_string -- a required callback, not an
 * optional one -- would have no way to actually fulfill its contract. */
int Zicl_SetObjectString(Zicl_Object *obj, const char *str, int len);

/* ===== Struct enumeration (leak-check dump introspection) =====
 * The C-callable counterpart to a Zig type's `enumerateStruct`: called from
 * an `enumerate_struct` implementation (Zicl_ObjectVTable's, or one passed to
 * Zicl_StructWalkerFollowStruct) to describe that struct's own fields for
 * Zicl_LeakCheckAll's dump. All three return ZICL_OK or ZICL_OOM;
 * enumerate_struct should propagate that return value directly.
 *
 * `fieldName` is never copied (across all three functions): it labels an
 * edge in the dump, and every existing caller of this same underlying
 * mechanism -- every Zig type's own enumerateStruct -- passes a string
 * literal, so pass one here too, not something built in a stack buffer that
 * won't outlive this call. */

/* Show `fieldName` as `valueStr` in the dump. Unlike `fieldName`, `valueStr`
 * *is* copied, so it's fine (expected, even) to format it into a stack
 * buffer that goes out of scope before the dump actually prints -- as
 * opposed to `Zicl_ObjectVTable.name` or a `Zicl_StructWalkerFollowStruct`
 * `typeName`, neither of which are copied either. */
int Zicl_StructWalkerAddField(Zicl_StructWalker *ctx, const char *fieldName, const char *valueStr);
/* Recurse into `fieldName`, a field that is itself a Zicl_Value (e.g. a
 * dict/list a custom type happens to hold onto). Cycle-safe and
 * dedup-tracked the same way any other Value reference is. */
int Zicl_StructWalkerFollowValue(Zicl_StructWalker *ctx, const char *fieldName, Zicl_Value value);
/* Recurse into `fieldName`, a plain (non-Zicl_Value) struct field. `ptr` is
 * the real field pointer -- its identity is what dedup/cycle detection keys
 * on, so pass the actual field, not a copy, or a genuinely cyclic structure
 * (one that points back to an ancestor) will recurse forever. `typeName`
 * labels it in the dump. `enumerateStruct` is the forwarding function that
 * describes *its* fields in turn -- NULL shows it as an opaque leaf (address
 * only), which is the right choice for a field with no further structure
 * worth expanding. */
int Zicl_StructWalkerFollowStruct(Zicl_StructWalker *ctx, const char *fieldName,
                                   const void *ptr, const char *typeName,
                                   Zicl_EnumerateStructFn enumerateStruct);

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
/* The shimmerable counterpart to Zicl_NewObject: converts `shim`'s current
 * value in place to the type identified by `vtable` (boxing a primitive, or
 * duplicating first if the object can't shimmer -- see Zicl_Shimmerable's
 * docs above), then hands back its raw body storage to fill in, the same
 * kind of pointer Zicl_NewObject hands back as *out_body. NULL on OOM. */
void *Zicl_PrepareToShimmer(Zicl_Shimmerable *shim, const Zicl_ObjectVTable *vtable);

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
void Zicl_DropRefList(Zicl_List *list);
/* Borrow a list handle: the same handle with its refcount incremented. The
 * caller owns the returned handle and must release it with Zicl_DropRefList. */
Zicl_List *Zicl_RefList(Zicl_List *list);

/* Copy-on-write entry points. If `value` is uniquely owned, `*out` is a
 * borrowed mutable view of the same object (no copy). If it is shared,
 * cross-thread, or a primitive, `*out` is NULL and the caller must
 * Zicl_DupAsList. Returns ZICL_OOM if shimmering allocates and fails, ZICL_ERR
 * for a malformed list string. A borrowed view is not owned: do not pass it to
 * Zicl_DropRefList. Commit a duplicate back to its slot with
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
void Zicl_DropRefDict(Zicl_Dict *dict);
/* Borrow a dict handle: the same handle with its refcount incremented. The
 * caller owns the returned handle and must release it with Zicl_DropRefDict. */
Zicl_Dict *Zicl_RefDict(Zicl_Dict *dict);

/* Copy-on-write entry points. If `value` is uniquely owned, `*out` is a
 * borrowed mutable view of the same object (no copy). If it is shared,
 * cross-thread, or a primitive, `*out` is NULL and the caller must
 * Zicl_DupAsDict. Returns ZICL_OOM if shimmering allocates and fails, ZICL_ERR
 * for a malformed dict string (odd item count). A borrowed view is not owned:
 * do not pass it to Zicl_DropRefDict. Commit a duplicate back to its slot with
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

/* Replace the value for `key` with `value` in place, without invalidating the
 * dict's string rep. For writing a shimmered form of an already-stored value
 * back into its slot, where the shimmer preserved the string rep (so the dict's
 * cached string is still valid). This is distinct from ZICL_SWAP, which is the
 * dup-branch commit. `key` must already be present: the writeback walks the
 * hash table to find the value slot, so a missing key is a violated invariant
 * and panics. Returns ZICL_OOM if hashing the key allocates and fails. Borrows
 * `value`. */
int Zicl_DictShimmerWriteback(Zicl_Dict *dict, Zicl_Value key, Zicl_Value value);

/* Like [dict link], but builds a fresh dict rather than mutating `dict` in
 * place: the caller keeps both `dict` and `parent` untouched. The result has
 * `~parent` as its first entry, a hash reference to `parent`, followed by
 * `dict`'s existing items. `parent` is borrowed, and boxed first if it is a
 * primitive. Returns NULL on OOM; the caller owns the returned handle. */
Zicl_Dict *Zicl_DictLink(const Zicl_Dict *dict, Zicl_Value parent);

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
 * to Zicl_DropRefSource. */
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
void Zicl_DropRefSource(Zicl_Source *source);
/* Borrow a Source handle: the same handle with its refcount incremented. The
 * caller owns the returned handle and must release it with Zicl_DropRefSource. */
Zicl_Source *Zicl_RefSource(Zicl_Source *source);

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

/* ===== Closures =====
 * A resolved closure plus the cache key its body evaluates under, opaque to
 * the C side. Get one with Zicl_GetClosure, invoke it (possibly more than
 * once) with Zicl_CallClosure, and release it with Zicl_DropRefClosure. */
typedef struct Zicl_Closure Zicl_Closure;

/* Resolve closure_value into a handle: parses it as a closure literal first
 * if it is not one already. The handle borrows the underlying closure object,
 * so closure_value need not survive the call. closure_value must not be a
 * [method] closure: like ordinary command dispatch, that returns ZICL_ERR
 * with "method cannot be invoked as function". Returns ZICL_OOM on allocation
 * failure. The caller owns *out and must release it with Zicl_DropRefClosure. */
int Zicl_GetClosure(Zicl_Interp *interp, Zicl_Value closure_value, Zicl_Closure **out);
/* Release a handle obtained from Zicl_GetClosure. */
void Zicl_DropRefClosure(Zicl_Closure *closure);
/* Call closure the same way the interpreter calls a closure it resolved from
 * a command name: argv[0] fills the command-name slot, argv[1..argc] are its
 * arguments. Letrec-bound closures are not reachable through this entry point
 * yet, so its scope is always NULL. The result is left on the interpreter;
 * read it with Zicl_GetResult. */
int Zicl_CallClosure(Zicl_Interp *interp, Zicl_Closure *closure, int argc, Zicl_Shimmerable *argv);
/* The closure's body, as a value borrowed from closure (valid only while
 * closure is alive; borrow it yourself to keep it longer). Pass it to
 * Zicl_AsSource / Zicl_SourceGetFilename / Zicl_SourceGetLine to read its
 * file/line info, if any was attached. */
Zicl_Value Zicl_ClosureGetBody(const Zicl_Closure *closure);
/* The closure's captured lexical scope, borrowed from closure (valid only
 * while closure is alive), or NULL if it has none. Look up a name in it
 * with Zicl_ShimDictGet, which follows ~parent links, so this reaches
 * variables from enclosing scopes too, not just this closure's own. */
Zicl_Dict *Zicl_ClosureGetScope(const Zicl_Closure *closure);
/* The current error's call stack, as a flat list of {name file line args}
 * groups repeated once per frame (innermost first), or an empty list if
 * there is none. Unlike Zicl_MakeErrorMessage, this doesn't consume or
 * reformat the interpreter's result -- it's a separate, structured read of
 * the same trace Zicl_MakeErrorMessage would render into prose. Borrowed
 * from the interpreter. */
Zicl_Value Zicl_GetErrorStack(Zicl_Interp *interp);

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
/* The name of the closure currently executing in the current call frame,
 * borrowed from the frame (valid only while it remains on the stack).
 * ZICL_NONE for the top-level frame, or a closure invoked without a name
 * (e.g. [apply] on a literal). */
Zicl_OptionalValue Zicl_GetClosureNameBeingEvaluated(Zicl_Interp *interp);
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
int Zicl_SetVariable(Zicl_Interp *interp, Zicl_Shimmerable *name, Zicl_Value value);
int Zicl_SetVariableString(Zicl_Interp *interp, const char *name, Zicl_Value value);
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
 * capability types: allocate a backing struct that embeds a `Zicl_CapabilityHead` as a
 * field, point the head's `vtable` at a static `Zicl_CapabilityHeadVTable`, and register
 * it with `Zicl_CapabilityNew`. The same vtable pointer is what
 * `Zicl_ResolveCapability` compares against, so each capability type has
 * exactly one vtable instance. These layouts mirror `Capability.Head` and
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

struct Zicl_CapabilityHead;

typedef struct Zicl_CapabilityHeadVTable {
    /* NUL-terminated, e.g. "file-handle". */
    const char *name;
    /* Deinits the body. Runs exactly once, from close. */
    void (*deinit_body)(struct Zicl_CapabilityHead *head);
    /* Frees the backing. Runs at ref count zero, which may be long after close. */
    void (*destroy_backing)(struct Zicl_CapabilityHead *head);
} Zicl_CapabilityHeadVTable;

/* The generic part of a capability. Embed this as a field of a backing struct
 * (at any offset; recover the backing with the `Zicl_ContainerOf` macro). C code sets
 * `vtable`; `Zicl_CapabilityNew` initializes the rest, so the remaining fields
 * are reserved for Zicl. The layout matches `Capability.Head` on the Zig side
 * for the target both are compiled for; the field order is fixed, so no size is
 * asserted here (it varies between 32- and 64-bit targets). */
typedef struct Zicl_CapabilityHead {
    const Zicl_CapabilityHeadVTable *vtable;
    Zicl_Id id;
    bool closed;
    uint32_t ref_count;
} Zicl_CapabilityHead;

/* Registers `head` and boxes the capability that names it as a value. `head`
 * is a `Zicl_CapabilityHead` embedded in a backing struct the caller
 * allocated (at any offset); Zicl initializes `id`, `closed`, and
 * `ref_count`. The caller owns the returned value, and recovers its backing
 * from `head` itself (the same pointer passed in, now registered) with
 * `Zicl_ContainerOf`. */
int Zicl_CapabilityNew(Zicl_Value *out, Zicl_CapabilityHead *head);

/* Resolves `shim` to a live capability, folding what would otherwise be two
 * calls (string resolution, then the type and closed-ness check) into one, since C
 * code -- an argument converter, chiefly -- always starts from a
 * Zicl_Shimmerable* that may still hold a string, never an already-resolved
 * value. Returns NULL if `shim` doesn't name a capability, names one of some
 * other type than `expected` (pass NULL to skip the type check), or names
 * one that has been closed. The returned head is borrowed from the
 * capability: valid while the capability stays alive and open. Recover the
 * backing struct with `Zicl_ContainerOf(head, MyBacking, head)`. The type
 * name lives on the head itself (`head->vtable->name`), so there's no
 * separate accessor for it; likewise closed-ness and lifetime from here on
 * are the `Zicl_CapabilityHead*` operations below, not a `Zicl_Value` one. */
Zicl_CapabilityHead *Zicl_ResolveCapability(Zicl_Shimmerable *shim, const Zicl_CapabilityHeadVTable *expected);

int Zicl_NewFileFromDescriptor(int descriptor, Zicl_Value *out);

/* Wraps `ptr` in a "pointer" capability whose lifetime is now managed by
 * Zicl -- useful for C code (chiefly generated FFI wrappers) that wants to
 * hand a script a raw pointer to hold and eventually release, without
 * defining a bespoke Zicl_CapabilityHeadVTable for every pointed-to type.
 * `type_name` is copied, and must match exactly what's later passed to
 * Zicl_GetPointerCapability -- see that function for why. If `destructor`
 * is non-NULL, it runs once, handed back `ptr`, when the capability is
 * closed (explicitly, or at process shutdown if never closed); it never runs
 * if `ptr` itself is NULL, since there is nothing to destroy. `ptr` may be
 * NULL: the capability's own identity (id, refcount, open/closed) is
 * independent of the pointer value it happens to carry, so a C API whose
 * pointer type uses NULL as a meaningful state (not just "allocation
 * failed") still round-trips through a capability like any other value. */
int Zicl_NewPointerCapability(void *ptr, const char *type_name,
                               void (*destructor)(void *ptr), Zicl_Value *out);
/* Recovers the pointer from a "pointer" capability into `*out`, resolving
 * `shim` in place first (same as Zicl_GetLong/Zicl_ListShimmer do for their
 * own target type) -- so this works directly on a value that's still in
 * string form, which is the common case for an argument coming from Tcl. The
 * type check can't ride on vtable identity the way Zicl_ResolveCapability
 * rides on it for capability types with their own vtable, since every
 * pointer capability shares one vtable; `expected_type_name` is required and
 * compared against what the capability was created with instead. Errors
 * (rather than writing NULL to `*out`) if `shim` doesn't resolve to a live
 * pointer capability, or if it's a pointer capability of some other type
 * (e.g. passing a "Gpu*" capability where "v4l2_capability*" was expected)
 * -- `*out` alone can't carry that distinction, since NULL is itself a valid
 * pointer to recover (see Zicl_NewPointerCapability). */
int Zicl_GetPointerCapability(Zicl_Shimmerable *shim, const char *expected_type_name, void **out);
/* The type_name a pointer capability was created with, or NULL if `value`
 * isn't a pointer capability. Borrowed; valid as long as the capability is. */
const char *Zicl_PointerCapabilityTypeName(Zicl_Value value);

/* Head operations, mirroring Capability.Head. */
Zicl_CapabilityHead *Zicl_CapabilityHeadBorrow(Zicl_CapabilityHead *head);
void Zicl_CapabilityHeadRelease(Zicl_CapabilityHead *head);
void Zicl_CapabilityHeadClose(Zicl_CapabilityHead *head);
bool Zicl_CapabilityHeadIsClosed(Zicl_CapabilityHead *head);
void Zicl_CapabilityHeadGetId(Zicl_CapabilityHead *head, Zicl_Id *out);

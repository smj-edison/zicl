#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* ===== Values, types, and conventions =====
 * The foundational representations every other section builds on: the value
 * and optional-value types, the shimmerable working buffer, the status codes
 * and ownership convention, and the opaque interpreter and object handles. */

/* The payload of a value. Small primitives (integers, floats, booleans, and
 * interned strings) live inline; everything else is a pointer to a ref-counted
 * heap object. Mirrors `heap.ValueRep` on the Zig side, so the two must be
 * kept in step. */
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
    uint8_t tag;
} Zicl_ValueRep;

typedef enum {
    ZICL_TAG_NONE = 0,
    ZICL_TAG_POINTER,
    ZICL_TAG_BOOLEAN,
    ZICL_TAG_INTEGER,
    ZICL_TAG_FLOAT,
    ZICL_TAG_INTERNED,
} Zicl_Tag;

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
#define ZICL_RETURN 2
#define ZICL_BREAK 3
#define ZICL_CONTINUE 4
#define ZICL_SIGNAL 5
#define ZICL_EXIT 6
#define ZICL_OOM 7
#define ZICL_USAGE 8
#define ZICL_TAILCALL 9

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
 *     defer { Zicl_DecrRefCount(script); }
 *     return Zicl_EvalObject(interp, script);
 *
 * `defer` comes from the optional <zicl-defer.h>; nothing here requires it, and
 * a consumer without it releases by hand as usual. Registering the release
 * after the constructor has succeeded is what keeps a Zicl_Value from ever
 * needing to represent "not filled in yet".
 *
 * When ownership transfers to the caller on success, the release belongs only
 * on the failing paths. The status ZICL_TRY writes is an ordinary variable, so
 * that is a plain guarded defer rather than anything special:
 *
 *     int rc = 0;
 *     Zicl_List *list = Zicl_NewList(NULL, 0);
 *     if (!list) return ZICL_OOM;
 *     defer { if (rc) Zicl_ListRelease(list); }
 *     ZICL_TRY(Zicl_ListAppend(list, item), rc);
 *     *out = Zicl_BoxListOwning(list);
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

/* A ref-counted heap object. Opaque because its layout carries atomic fields
 * and a type-erased body that C cannot usefully touch directly; reach its state
 * through the accessors below (`Zicl_AsPtr`, `Zicl_RefCount`, ...). */
typedef struct Zicl_Object Zicl_Object;

typedef struct Zicl_Interp Zicl_Interp;

typedef int (*Zicl_CCommandFn)(Zicl_Interp *interp, int argc, Zicl_Value *argv);

/* A lazy native command initializer, called the first time a registered command
 * name is looked up. It is expected to install the real command (via
 * `Zicl_CreateCommand`) and then return. Mirrors `heap.NativeInitFn`. */
typedef void (*Zicl_NativeInitFn)(void *interp);

/* ===== Lifecycle =====
 * Process and thread setup, interpreter creation, and teardown. The global
 * state is per-process; each thread that touches the interpreter calls
 * `Zicl_InitThread` once. */

void Zicl_SetGlobalStdout(int fd);
void Zicl_SetGlobalStderr(int fd);

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

/* ===== Strings =====
 * The string representation is the source of truth for every value, so these
 * are the most general accessors. `Zicl_String` and `Zicl_GetString` generate
 * the string rep on demand, which can allocate (and so return NULL on OOM). */

int Zicl_NewString(Zicl_Value *out, const char *ptr, int len);
const char *Zicl_String(Zicl_Value object);
const char *Zicl_GetString(Zicl_Value object, int *len);

/* ===== Reference counting and object introspection =====
 * Reaching and accounting for the heap object behind a pointer-tagged value.
 * The primitives (`integer`, `float`, `boolean`, `interned`) carry no object,
 * so `Zicl_AsPtr` returns NULL and the refcount accessors report zero. */

void Zicl_DecrRefCount(Zicl_Value value);
Zicl_Value Zicl_IncrRefCount(Zicl_Value value);
/* The heap object a pointer-tagged value refers to, or NULL for primitives. */
Zicl_Object *Zicl_AsPtr(Zicl_Value value);

/* Object debugging. `tag` is a plain field read, so there is no accessor for
 * it. Both of these are only meaningful for ZICL_TAG_POINTER values. */
uint32_t Zicl_RefCount(Zicl_Value value);
uint32_t *Zicl_RefCountPtr(Zicl_Value value);

/* ===== Numbers =====
 * Integer, float, and boolean values are stored inline, so the constructors
 * cannot fail. The coercions shimmer a value into the requested type through a
 * shimmerable, so they can fail (ZICL_OOM) or report a parse error (ZICL_ERR). */

Zicl_Value Zicl_NewInt(int64_t value);
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
/* Wrap an owned list handle as a value, transferring ownership. Do not touch
 * `list` afterwards. */
Zicl_Value Zicl_BoxListOwning(Zicl_List *list);
/* Release an owned list handle (error path). */
void Zicl_ListRelease(Zicl_List *list);

/* Copy-on-write entry points. If `value` is uniquely owned, `*out` is a
 * borrowed mutable view of the same object (no copy). If it is shared,
 * cross-thread, or a primitive, `*out` is NULL and the caller must
 * Zicl_DupAsList. Returns ZICL_OOM if shimmering allocates and fails, ZICL_ERR
 * for a malformed list string. A borrowed view is not owned: do not pass it to
 * Zicl_ListRelease or Zicl_ListShimmerWriteback. */
int Zicl_AsListMut(Zicl_Interp *interp, Zicl_Value value, Zicl_List **out);
/* An owned mutable copy of `value` shimmered to a list. Returns ZICL_OOM on OOM
 * (out is set to NULL), ZICL_ERR for a malformed list string. */
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

/* Commit an owned duplicate back, releasing the old `value` it replaces. Only
 * for the Zicl_DupAsList branch; in-place mutation needs no writeback. The
 * caller keeps `list` and stores it via Zicl_BoxListOwning. */
void Zicl_ListShimmerWriteback(Zicl_List *list, Zicl_Value value);

/* ===== Dicts =====
 * Dictionaries use the same copy-on-write shape as lists; `Zicl_DictPut` hides
 * the two branches internally, picking in-place mutation when the dict is
 * uniquely owned and duplicating otherwise. */

int Zicl_NewDict(Zicl_Value *out, Zicl_Value *values, int n_values);
int Zicl_DictPut(Zicl_Interp *interp, Zicl_Value *dict, Zicl_Value key, Zicl_Value value);

/* ===== Source =====
 * A `Source` carries file/line metadata alongside a value's bytes, so
 * evaluation errors can point at the originating location. The location is
 * fixed at construction, so `Zicl_AttachSource` replaces the slot with a copy
 * rather than annotating the existing object. */

const char *Zicl_SourceGetFilename(Zicl_Value source);
int Zicl_SourceGetLine(Zicl_Value source);
/* Replaces *value with one carrying the given source location, releasing the
 * original on success. A source location is fixed at construction, so this
 * cannot annotate the existing object in place. */
int Zicl_AttachSource(Zicl_Value *value, const char *filename, int line_no);

/* ===== Interpreter =====
 * Registering commands, evaluating scripts, reading and writing the result,
 * setting variables, and the signal-depth machinery that defers Tcl signal
 * delivery during C callbacks that must not be interrupted. */

int Zicl_CreateCommand(Zicl_Interp *interp, const char *name, Zicl_CCommandFn command);
/* Register a lazy initializer for `name`. The initializer runs on first lookup,
 * and is expected to install the real command itself. Returns ZICL_ERR if `name`
 * is already registered, ZICL_OOM if the registry entry cannot be allocated. */
int Zicl_RegisterNativeFn(const char *name, Zicl_NativeInitFn init_fn);
int Zicl_EvalObject(Zicl_Interp *interp, Zicl_Value script);
int Zicl_EvalFile(Zicl_Interp *interp, const char *filename);
Zicl_Value Zicl_GetScriptBeingEvaluated(Zicl_Interp *interp);
Zicl_Value Zicl_GetResult(Zicl_Interp *interp);
void Zicl_SetResult(Zicl_Interp *interp, Zicl_Value value);
void Zicl_SetResultOwning(Zicl_Interp *interp, Zicl_Value value);
int Zicl_SetResultString(Zicl_Interp *interp, const char *str, int len);
int Zicl_SetResultBool(Zicl_Interp *interp, int value);
int Zicl_SetResultInt(Zicl_Interp *interp, long value);
void Zicl_SetEmptyResult(Zicl_Interp *interp);
int Zicl_SetVariable(Zicl_Interp *interp, Zicl_Value *name, Zicl_Value value);
int Zicl_MakeErrorMessage(Zicl_Interp *interp);
void Zicl_IncrSignalDepth(Zicl_Interp *interp);
void Zicl_DecrSignalDepth(Zicl_Interp *interp);
uint64_t Zicl_GetSigmask(Zicl_Interp *interp);

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
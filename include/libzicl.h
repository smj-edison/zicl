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

typedef enum Zicl_RetCode : int {
    ZICL_OK = 0,
    ZICL_ERR = 1,
    ZICL_OOM = 2,
    ZICL_PROPAGATE = 3,
    ZICL_BREAK = 4,
    ZICL_CONTINUE = 5,
    ZICL_EXIT = 6,
    ZICL_USAGE = 7,
    ZICL_TAILCALL = 8
} Zicl_RetCode;

/* Convenience wrapper for checking the return code, and if not ZICL_OK,
 * return said return code. */
#define ZICL_TRY(call, status)                  \
    do {                                        \
        (status) = (call);                      \
        if ((status) != ZICL_OK)                \
            return (status);                    \
    } while (0)

/* Stolen and renamed from the Linux kernel's `container_of`. */
#define Zicl_ContainerOf(ptr, type, member) ({ \
    const typeof(((type *)0)->member) *__mptr = (ptr); \
    (type *)((char *)__mptr - offsetof(type, member)); })

/* ===== Core value types ===== */

/* The representation of values in Zicl. We use a 8 byte payload, along
 * with a 1 byte tag and 2 byte "extra" value. */

typedef enum Zicl_ValTag : uint8_t {
    ZICL_TAG_NONE = 0,
    ZICL_TAG_POINTER,
    ZICL_TAG_BOOLEAN,
    ZICL_TAG_INTEGER,
    ZICL_TAG_FLOAT,
    ZICL_TAG_INTERNED,
    /* If you want to pass around a custom data structure, tag it with
     * ZICL_TAG_EXTERNAL. As long as you don't generate a string for it directly
     * or indirectly, you can use it like a Zicl value (put it in a list, or a
     * dictionary value, etc). */
    ZICL_TAG_EXTERNAL = 255,
} Zicl_ValTag;
typedef struct Zicl_ValRep {
    union {
        /* Heap-allocated object, used for non-primitive variants. */
        struct Zicl_Obj *pointer;
        double float_val;
        int64_t integer;
        bool boolean;
        const char *interned;
        void *external;
    } as;
    /* Only meaningful when `tag` is ZICL_TAG_INTERNED. */
    uint16_t interned_string_len;
    Zicl_ValTag tag;
} Zicl_ValRep;

/* A guaranteed non-null Value. */
typedef struct Zicl_Val {
    Zicl_ValRep raw;
} Zicl_Val;

/* A nullable Value. */
typedef struct Zicl_OptVal {
    Zicl_ValRep raw;
} Zicl_OptVal;

#define ZICL_NONE ((Zicl_OptVal){{{0}, 0, ZICL_TAG_NONE}})

static inline bool Zicl_IsNone(Zicl_OptVal value) {
    return value.raw.tag == ZICL_TAG_NONE;
}
static inline bool Zicl_IsSome(Zicl_OptVal value) {
    return value.raw.tag != ZICL_TAG_NONE;
}

/* Narrow an optional. Asserts that `value` is not none. */
static inline Zicl_Val Zicl_Unwrap(Zicl_OptVal value) {
    assert(Zicl_IsSome(value));
    Zicl_Val narrowed;
    narrowed.raw = value.raw;
    return narrowed;
}

static inline Zicl_OptVal Zicl_Wrap(Zicl_Val value) {
    Zicl_OptVal widened;
    widened.raw = value.raw;
    return widened;
}

ZICL_NORETURN void Zicl_InternStrTooLong(void);
/* Create an interned string value. `ptr` must have a static lifetime. */
static inline Zicl_Val Zicl_InternStr(const char *ptr) {
    size_t len = strlen(ptr);
    if (len > 0xffff) Zicl_InternStrTooLong();
    Zicl_Val v;
    v.raw.as.interned = ptr;
    v.raw.interned_string_len = (uint16_t)len;
    v.raw.tag = ZICL_TAG_INTERNED;
    return v;
}

/* Zicl objects are a head + a body, where the body is a section of
 * reinterpretable memory. Each implementation is free to interpret this body
 * memory however it wants. This max size of this body is
 * `ZICL_OBJECT_BODY_MAX_SIZE`, defined below. */
#define ZICL_OBJECT_BODY_MAX_SIZE 48

/* Opaque value passed in when doing a heap trace. See `Zicl_StructWalker*`
 * functions for what you can do with this. */
typedef struct Zicl_StructWalker Zicl_StructWalker;
/* Called when a heap walk is happening. The body of this function calls
 * the `Zicl_StructWalker*` suite of functions to enumerate its fields. */
typedef Zicl_RetCode (*Zicl_EnumerateStructFn)(Zicl_StructWalker *ctx, const void *node);

/* The vtable type for each object. It has the following methods:
 *  - duplicate: returns a duplicate of the object. If set to NULL, it means
 *      this type can't be duplicated. Zicl asserts that this is not null.
 *  - update_string: called lazily the first time the object's string
 *    representation is needed. Returns ZICL_OK or ZICL_OOM. Zicl again
 *      asserts this as not null.
 *  - free_internal_rep: called once, when the last reference is dropped,
 *      before the object's own storage is freed. NULL is fine here if there's
 *      no destructor.
 *  - make_crossthread: called before an object crosses threads, or needs to
        be frozen. NULL means the type must never cross threads. Use
        `Zicl_NoopMakeCrossthread` when there's nothing to do.
 *  - enumerate_struct: called during a heap trace to have this object describe
        its fields. NULL means the object will be traced as an opaque leaf. */
typedef struct Zicl_ObjVTable {
    /* Always set to true. Used to distinguish C and Zig vtables, as they
     * have different calling conventions. */
    bool is_c_vtable;
    const char *name;

    /* Note that we discard the union used on the Zig side, since the layout is
     * identical without the union. This only works because both variants have
     * the same number of function pointers. */

    struct Zicl_Obj *(*duplicate)(const struct Zicl_Obj *src);
    void (*free_internal_rep)(struct Zicl_Obj *obj);
    int (*update_string)(struct Zicl_Obj *obj);
    void (*make_crossthread)(struct Zicl_Obj *obj);
    Zicl_EnumerateStructFn enumerate_struct;
} Zicl_ObjVTable;

/* Raw object type. I wouldn't suggest touching any of the fields besides
 * `body_backing` and `vtable` though, as the atomics are fairly complicated. */
typedef struct Zicl_Obj {
    /* Accessed with atomics when crossthread. Can either be a pointer to
     * a byte string or a pointer to a `SpecialString`. */
    void *string;
    const Zicl_ObjVTable *vtable;
    /* Accessed with atomics when crossthread. */
    uint32_t ref_count;
    uint8_t metadata;
    /* Accessed with atomics when crossthread. Stores the string length when it's
     * a pointer to a byte string, and also stores whether the object points
     * to a byte string or a `SpecialString`. */
    uint32_t string_metadata;
    /* Always accessed with atomics. */
    uint8_t hash_metadata;
    /* Body backing of the object, interpreted based on the object type. */
    ZICL_ALIGNAS(8) uint8_t body_backing[ZICL_OBJECT_BODY_MAX_SIZE];
} Zicl_Obj;

/* Convenience vtable function when there's nothing to do to make an object
 * crossthread. */
void Zicl_NoopMakeCrossthread(Zicl_Obj *obj);

/* Allocates a new object with type `vtable`. `size` should be the size of the
 * struct you use to interpret `body_backing`. `size` isn't actually used to
 * construct the object, but it does assert that the struct fits inside of
 * `body_backing`. Returns NULL if OOM occured. */
Zicl_Obj *Zicl_NewObj(const Zicl_ObjVTable *vtable, int size, void **out_body);
/* Returns NULL if `value` is a primitive. */
Zicl_Obj *Zicl_AsObj(Zicl_Val value);
/* Returns a pointer to `value`'s object backing, if the vtables match.
 * Otherwise returns NULL. */
void *Zicl_AsObjBody(Zicl_Val value, const Zicl_ObjVTable *vtable);
static inline void *Zicl_ObjBody(Zicl_Obj *obj) {
    return obj->body_backing;
}
static inline const void *Zicl_ObjBodyConst(const Zicl_Obj *obj) {
    return obj->body_backing;
}
/* Sets an object's string. This shouldn't be used outside of object creation
 * and inside of `update_string`, as it won't do anything if the object already
 * has a string. This is threadsafe. Will return ZICL_OK or ZICL_OOM, as it
 * can OOM when `str` is duplicated.  */
Zicl_RetCode Zicl_SetObjectString(Zicl_Obj *obj, const char *str, int len);

/* A shimmerable value. Values can't always shimmer in-place, which is why we
 * wrap it in this structure to allow it to shimmer, even when not in place. */
typedef struct Zicl_Shim {
    Zicl_Val original;
    Zicl_OptVal shimmered;
} Zicl_Shim;

/* Wrap a value with this to make it guaranteed shimmerable. If you create this
 * and pass it by reference, the potentially new `shimmered` value is owned by
 * you. Typically, you'll want to put `defer { Zicl_ShimDiscardChanges(&shim); }`
 * to clean up any new shimmered values stored in here. */
static inline Zicl_Shim Zicl_NewShim(Zicl_Val value) {
    Zicl_Shim shim;
    shim.original = value;
    shim.shimmered = ZICL_NONE;
    return shim;
}

/* ===== Object lifecycle and introspection ===== */

/* Decrement ref count by one, potentially running the destructor and freeing.
 * Does nothing on non-object variants. */
void Zicl_DropRef(Zicl_Val value);
/* Increment ref count by one, returning the same value. Useful for "creating"
 * a second object handle. Does nothing on non-object variants. */
Zicl_Val Zicl_Ref(Zicl_Val value);
/* Drop a reference on the old value in `slot`, if existing, and set it to a new
 * value. Does not take a reference of the new value. `slot` should be a pointer
 * to either `Zicl_Val` or `Zicl_OptVal`. */
#define ZICL_SWAP(slot, new_value)                              \
    do {                                                        \
        Zicl_ValRep zicl_swap_old = (slot)->raw;                \
        (slot)->raw = (new_value).raw;                          \
        if (zicl_swap_old.tag != ZICL_TAG_NONE) {               \
            Zicl_DropRef((Zicl_Val){ zicl_swap_old });          \
        }                                                       \
    } while (0)
/* Drop a ref on every value in `argv[0..argc]`. A convenience function. */
void Zicl_DropRefArrayItems(Zicl_Val *argv, int argc);

/* Marks the object as crossthread. This sets the crossthread bit _nonatomically_,
 * and also calls the `make_crossthread` function in the object vtable. Since the
 * crossthread bit is set nonatomically, you are responsible acquire/release
 * semantics when transferring this to a different thread. */
void Zicl_MakeCrossthread(Zicl_Val value);
/* If an object variant, this will call the object's duplicate function.
 * If not, just returns the value back. */
Zicl_RetCode Zicl_Duplicate(Zicl_Val value, Zicl_Val *out);
/* This guarantees to duplicate the value as an object, whereas `Zicl_Duplicate`
 * may pass the value back if not an object variant. */
Zicl_Obj *Zicl_DuplicateAsBoxed(Zicl_Val value);
/* Get the object's string rep. NULL on OOM. */
const char *Zicl_String(Zicl_Val object);
/* Get the object's string rep and length. NULL on OOM. */
const char *Zicl_GetString(Zicl_Val object, int *len);
/* Box an object pointer into the `Zicl_Val` tagged union. */
Zicl_Val Zicl_BoxObject(Zicl_Obj *obj);
/* Whether this value can mutate in place. Always false for non-object variants. */
bool Zicl_CanMutate(Zicl_Val value);
/* Whether this value can shimmer in place. Always false for non-object variants. */
bool Zicl_CanShimmer(Zicl_Val value);

/* String equality. May allocate, which means it also may return ZICL_OOM. */
Zicl_RetCode Zicl_Equals(Zicl_Val a, Zicl_Val b, int *out);
/* Fast equality that never allocates. This will never return a false positive,
 * but it may return a false negative. */
bool Zicl_QuickEquals(Zicl_Val a, Zicl_Val b);

/* Object debugging. Does a raw (relaxed) read of the ref count.
 * You probably want `Zicl_CanMutate` or `Zicl_CanShimmer`. */
uint32_t Zicl_RefCount(Zicl_Val value);
uint32_t *Zicl_RefCountPtr(Zicl_Val value);

/* ===== Shimmerable helpers ===== */

/* Get the active value of the `Zicl_Shim`. */
static inline Zicl_Val Zicl_Current(const Zicl_Shim *shim) {
    if (shim->shimmered.raw.tag != ZICL_TAG_NONE) return Zicl_Unwrap(shim->shimmered);
    return shim->original;
};
/* The string rep of the `Zicl_Shim`'s active value. If OOM occurs, will
 * return NULL. */
static inline const char *Zicl_ShimString(Zicl_Shim *shim) {
    return Zicl_String(Zicl_Current(shim));
};
/* Same as above, writing the byte length to `*len` when not NULL. */
static inline const char *Zicl_ShimGetString(Zicl_Shim *shim, int *len) {
    return Zicl_GetString(Zicl_Current(shim), len);
};
/* Drops `shim->shimmered` and clears it. */
void Zicl_ShimDiscardChanges(Zicl_Shim *shim);
/* The shimmerable counterpart to Zicl_NewObj: converts `shim`'s current
 * value in place to the type identified by `vtable` (boxing a primitive, or
 * duplicating first if the object can't shimmer -- see Zicl_Shim's
 * docs above), then hands back its raw body storage to fill in, the same
 * kind of pointer Zicl_NewObj hands back as *out_body. NULL on OOM. */

/* Before you want to shimmer an object, call this. After you call this,
 * you can modify `Zicl_Current(shim).as.pointer->body_backing`. */
void *Zicl_PrepareToShimmer(Zicl_Shim *shim, const Zicl_ObjVTable *vtable);

/* ===== Interpreter ===== */
typedef struct Zicl_Interp Zicl_Interp;

Zicl_Interp *Zicl_CreateInterp(void);
void Zicl_InterpDestroy(Zicl_Interp *interp);

typedef int (*Zicl_CCommandFn)(Zicl_Interp *interp, int argc, Zicl_Shim *argv);

Zicl_RetCode Zicl_CreateCommand(Zicl_Interp *interp, const char *name, Zicl_CCommandFn command,
                                const char *description, int min_arity, int max_arity);

/* Zicl has "lazy commands", commands that have their name registered, but have
 * not yet been initialized in an interpreter. This way, the first time an
 * interpreter tries running one of these "lazy commands", it'll register it
 * before it uses said command. This design allows for threads to independently
 * spin up interpreters, and also independently register new global commands,
 * all without stepping on each other's toes, as no synchronization is needed
 * when registering, apart from an RwLock on the global command table.
 *
 * This is the type of the function that registers these lazy commands, and it
 * will be called right before the command is used. */
typedef void (*Zicl_LazyRegisterFn)(Zicl_Interp *interp);
Zicl_RetCode Zicl_RegisterLazyFn(const char *name, const char *library, Zicl_LazyRegisterFn init_fn);

Zicl_RetCode Zicl_EvalValue(Zicl_Interp *interp, Zicl_Val script);
Zicl_RetCode Zicl_Eval(Zicl_Interp *interp, const char *script);
Zicl_RetCode Zicl_EvalFile(Zicl_Interp *interp, const char *filename);
Zicl_Val Zicl_GetErrorStack(Zicl_Interp *interp);
Zicl_RetCode Zicl_MakeErrorMessage(Zicl_Interp *interp);
Zicl_OptVal Zicl_GetClosureNameBeingEvaluated(Zicl_Interp *interp);
uint32_t Zicl_CurrentEvalFrameIdx(Zicl_Interp *interp);
Zicl_Val Zicl_GetScriptBeingEvaluated(Zicl_Interp *interp);
Zicl_Val Zicl_EvalFrameScript(Zicl_Interp *interp, uint32_t frame);
Zicl_Val Zicl_GetResult(Zicl_Interp *interp);
void Zicl_SetResult(Zicl_Interp *interp, Zicl_Val value);
void Zicl_SetResultOwning(Zicl_Interp *interp, Zicl_Val value);
Zicl_RetCode Zicl_SetResultString(Zicl_Interp *interp, const char *str, int len);
/* Set the interpreter result to `str` and report it as an error: returns
 * ZICL_ERR on the success path, ZICL_OOM if storing the string allocates and
 * fails. Never returns ZICL_OK. `len` is the byte length, or -1 for NUL-terminated. */
Zicl_RetCode Zicl_SetErrorString(Zicl_Interp *interp, const char *str, int len);
Zicl_RetCode Zicl_SetResultBool(Zicl_Interp *interp, int value);
Zicl_RetCode Zicl_SetResultLong(Zicl_Interp *interp, long value);
Zicl_RetCode Zicl_SetEmptyResult(Zicl_Interp *interp);

Zicl_RetCode Zicl_SetVariable(Zicl_Interp *interp, Zicl_Shim *name, Zicl_Val value);
Zicl_RetCode Zicl_SetVariableString(Zicl_Interp *interp, const char *name, Zicl_Val value);

void Zicl_RequestStop(Zicl_Interp *interp);
bool Zicl_StopRequested(Zicl_Interp *interp);
void Zicl_ClearStop(Zicl_Interp *interp);

/* ===== Core objects and object methods ===== */

Zicl_RetCode Zicl_NewString(Zicl_Val *out, const char *ptr, int len);

#if defined(__GNUC__) || defined(__clang__)
__attribute__((format(printf, 2, 3)))
#endif
/* C-style string formatting. */
static inline int Zicl_NewStringFormatted(Zicl_Val *out, const char *fmt, ...) {
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

/* Infallible, as this returns a primitive. */
static inline Zicl_Val Zicl_NewLong(int64_t value) {
    return (Zicl_Val){ .raw = {
        .as = { .integer = value },
        .interned_string_len = 0,
        .tag = ZICL_TAG_INTEGER
    } };
};
/* Infallible, as this returns a primitive. */
static inline Zicl_Val Zicl_NewDouble(double value) {
    return (Zicl_Val){ .raw = {
        .as = { .float_val = value },
        .interned_string_len = 0,
        .tag = ZICL_TAG_FLOAT
    } };
};
/* Infallible, as this returns a primitive. */
static inline Zicl_Val Zicl_NewBool(bool value) {
    return (Zicl_Val){ .raw = {
        .as = { .boolean = value },
        .interned_string_len = 0,
        .tag = ZICL_TAG_BOOLEAN
    } };
};
Zicl_RetCode Zicl_GetLong(Zicl_Interp *interp, Zicl_Shim *shim, long *out);
Zicl_RetCode Zicl_GetDouble(Zicl_Interp *interp, Zicl_Shim *shim, double *out);
Zicl_RetCode Zicl_GetBoolean(Zicl_Interp *interp, Zicl_Shim *shim, int *out);

/* Lists */
typedef struct Zicl_List Zicl_List;

/* Takes a reference of each value. */
Zicl_List *Zicl_NewList(const Zicl_Val *values, int n_values);
/* Takes a reference of each active value. */
Zicl_List *Zicl_NewListFromShims(const Zicl_Shim *shims, int n_shims);
Zicl_Val Zicl_BoxList(Zicl_List *list);
Zicl_List *Zicl_RefList(Zicl_List *list);
void Zicl_DropRefList(Zicl_List *list);

Zicl_RetCode Zicl_ShimmerToList(Zicl_Interp *interp, Zicl_Shim *shim, const Zicl_List **out);
const Zicl_Val *Zicl_ListItems(const Zicl_List *listPtr);
int Zicl_ListLength(const Zicl_List *listPtr);
/* ZICL_NONE if `index` is out of range. */
Zicl_OptVal Zicl_ListGetItem(Zicl_Interp *interp, Zicl_Val *list, int index);
/* Get an item from a list, handling all edge cases along the way. Sets `out` to
 * a value if `index` is in range, or ZICL_NONE if out of range. Returns
 * ZICL_ERR or ZICL_OOM if the shimmering failed. */
Zicl_RetCode Zicl_ShimListItem(Zicl_Interp *interp, Zicl_Shim *shim, int index, Zicl_OptVal *out);

/* COW helpers. `Zicl_AsListMut` attempts to prepare `value` for in-place mutation,
 * setting `out` to the list pointer on success. If not successful, `Zicl_AsListMut`
 *sets `out` to NULL, at which point the caller should use `Zicl_DupAsList`. */
Zicl_RetCode Zicl_AsListMut(Zicl_Interp *interp, Zicl_Val value, Zicl_List **out);
Zicl_RetCode Zicl_DupAsList(Zicl_Interp *interp, Zicl_Val value, Zicl_List **out);
/* `listPtr` must be mutable. Borrows `item` when setting. */
Zicl_RetCode Zicl_ListAppend(Zicl_List *listPtr, Zicl_Val item);
/* `listPtr` must be mutable. Borrows `item` when setting. */
Zicl_RetCode Zicl_ListSet(Zicl_List *listPtr, int index, Zicl_Val item);

/* Be careful with this one! This sets a list item _without_ invalidating
 * the string rep. This should _only_ be used when propagating a shimmered
 * value back up to where it came from. */
Zicl_RetCode Zicl_ListShimmerWriteback(Zicl_List *list, int index, Zicl_Val value);

/* Dictionaries */
typedef struct Zicl_Dict Zicl_Dict;

/* Takes a reference of each value. */
Zicl_Dict *Zicl_NewDict(const Zicl_Val *values, int n_values);
Zicl_Val Zicl_BoxDict(Zicl_Dict *dict);
Zicl_Dict *Zicl_RefDict(Zicl_Dict *dict);
void Zicl_DropRefDict(Zicl_Dict *dict);

Zicl_RetCode Zicl_ShimmerToDict(Zicl_Interp *interp, Zicl_Shim *shim, const Zicl_Dict **out);
/* Number of keys + values, including duplicate entries. */
int Zicl_DictLength(const Zicl_Dict *dictPtr);
const Zicl_Val *Zicl_DictItems(const Zicl_Dict *dictPtr);
Zicl_RetCode Zicl_DictGetNoFollow(const Zicl_Dict *dictPtr, Zicl_Val key, Zicl_OptVal *out);
/* Look up `key` in `shim`, following parent references if needed. Sets `out`
 * to ZICL_NONE if not found. */
Zicl_RetCode Zicl_ShimDictGet(Zicl_Interp *interp, Zicl_Shim *shim, Zicl_Val key, Zicl_OptVal *out);

/* COW helpers. `Zicl_AsDictMut` attempts to prepare `value` for in-place mutation,
 * setting `out` to the list pointer on success. If not successful, `Zicl_AsDictMut`
 *sets `out` to NULL, at which point the caller should use `Zicl_DupAsDict`. */
Zicl_RetCode Zicl_AsDictMut(Zicl_Interp *interp, Zicl_Val value, Zicl_Dict **out);
Zicl_RetCode Zicl_DupAsDict(Zicl_Interp *interp, Zicl_Val value, Zicl_Dict **out);
/* Set `key` to `value`, borrowing `value` and potentially `key`. Asserts that
 *`dictPtr` can mutate. */
Zicl_RetCode Zicl_DictPut(Zicl_Dict *dictPtr, Zicl_Val key, Zicl_Val value);
/* Removes all entries with key `key`. `removed` will be set to true if `key`
 * was removed, or false otherwise. */
Zicl_RetCode Zicl_DictRemove(Zicl_Dict *dictPtr, Zicl_Val key, bool *removed);
/* Create a new dictionary based on `dict`, but linked to `parent`. Returns
 * NULL on OOM. */
Zicl_Dict *Zicl_DictLink(const Zicl_Dict *dict, Zicl_Val parent);

/* Be careful with this one! This sets a dict item _without_ invalidating
 * the string rep. This should _only_ be used when propagating a shimmered
 * value back up to where it came from. */
Zicl_RetCode Zicl_DictShimmerWriteback(Zicl_Dict *dict, Zicl_Val key, Zicl_Val value);

/* Sources */
typedef struct Zicl_Source {
    Zicl_OptVal file_name;
    uint32_t line_no;
    void *_hash;
} Zicl_Source;

/* Cast `value` to a Source object, or return NULL. */
const Zicl_Source *Zicl_AsSource(Zicl_Val value);
Zicl_Val Zicl_BoxSource(Zicl_Source *source);
Zicl_Source *Zicl_RefSource(Zicl_Source *source);
void Zicl_DropRefSource(Zicl_Source *source);

/* NULL if not a source, or if OOM occured. */
const char *Zicl_SourceGetFilename(Zicl_Val source);
/* -1 if not a source. */
int Zicl_SourceGetLine(Zicl_Val source);
/* On success replace `value` with a new value, but with source info attached. */
Zicl_RetCode Zicl_AttachSource(Zicl_Val *value, const char *filename, int line_no);

/* COW helpers. `Zicl_AsSourceMut` attempts to prepare `value` for in-place mutation,
 * setting `out` to the list pointer on success. If not successful, `Zicl_AsSourceMut`
 *sets `out` to NULL, at which point the caller should use `Zicl_DupAsSource`. */
Zicl_Source *Zicl_AsSourceMut(Zicl_Val value);
Zicl_Source *Zicl_DupAsSource(Zicl_Val value);

/* Closures */
typedef struct Zicl_Closure Zicl_Closure;

/* Parse `closure_value` as a closure. */
Zicl_RetCode Zicl_GetClosure(Zicl_Interp *interp, Zicl_Val closure_value, Zicl_Closure **out);
void Zicl_DropClosure(Zicl_Closure *closure);
Zicl_RetCode Zicl_CallClosure(Zicl_Interp *interp, Zicl_Closure *closure, int argc, Zicl_Shim *argv);
/* Get the closure's body `Zicl_Val`. Useful to get source info and such. */
Zicl_Val Zicl_ClosureGetBody(const Zicl_Closure *closure);
/* Get the closure's scope, or NULL if it doesn't have any. */
Zicl_Dict *Zicl_ClosureGetScope(const Zicl_Closure *closure);

/* Dynamically load a library at `path`. This library should export a symbol
 * named `Zicl_<pkgname>Init(interp)`, where <pkgname> is `path`'s base name.
 * This init function should exclusively call `Zicl_RegisterLazyFn` for each of
 * the native functions it creates. This init function also needs to return a
 * `*Zicl_Dict` containing "{apiName1 internalName apiName2 internalName2 ...}".
 * */
Zicl_RetCode Zicl_LoadLibrary(Zicl_Interp *interp, const char *path);

/* ===== Globals and thread lifecycle ===== */

void Zicl_SetLocalStdout(int fd);
void Zicl_SetLocalStderr(int fd);

/* `host_name` is the name that created capabilities will use. Call will NULL to
 * use the default hostname. */
Zicl_RetCode Zicl_InitGlobals(const char *host_name);
/* Per-thread setup. Call whenever spinning up a new thread. */
Zicl_RetCode Zicl_InitThread(void);
void Zicl_DeinitThread(void);
void Zicl_DeinitGlobals(void);
/* Call before deiniting the globals and the thread, but after stopping
 * evaluation. */
void Zicl_LeakCheckAll(void);

/* Inspired by V8's Zones, this is a snapshot of the arena allocator at a
 * particular point in time, and can be rewound to this point. Rewind wisely! A
 * lot of Zicl code uses the arena for intermediate state, so you do want to
 * periodically rewind it between work. */
typedef struct Zicl_ArenaSnapshot {
    void *current;
    size_t end_index;
} Zicl_ArenaSnapshot;

Zicl_ArenaSnapshot Zicl_LocalArenaTakeSnapshot(void);
void Zicl_LocalArenaRestore(Zicl_ArenaSnapshot snap);

/* ===== Heap tracing =====
 * These methods should be called within the `enumerate_struct` vtable
 * function. They make the heap tracer aware of subfields, and pointers
 * it needs to follow. */

/* Add a literal value to the trace. `fieldName` must have a static lifetime.
 * `valueStr` is copied though. */
Zicl_RetCode Zicl_StructWalkerAddField(Zicl_StructWalker *ctx, const char *fieldName, const char *valueStr);
/* Follow a field of type `Zicl_Val`. */
Zicl_RetCode Zicl_StructWalkerFollowValue(Zicl_StructWalker *ctx, const char *fieldName, Zicl_Val value);
/* Follow a pointer field to its respective struct. `enumerateStruct` is the enumeration
 * function for the followed struct. `enumerateStruct` can be NULL, which will still trace
 * `ptr`, but will treat it as an opaque leaf. */
Zicl_RetCode Zicl_StructWalkerFollowStruct(Zicl_StructWalker *ctx, const char *fieldName,
                                           const void *ptr, const char *typeName,
                                           Zicl_EnumerateStructFn enumerateStruct);



/* ===== Capabilities =====
 * Capabilities are URLs such as
 * <zicl://folk-peridot.local/file-handle/sVye-a_2s3tvQm8xR4pLnW>, with three
 * notable parts: hostname (folk-peridot.local), capability type //!
 * (file-handle), and capability id (sVye-a_2s3tvQm8xR4pLnW).
 *
 * Lifetime management of capabilities is manual, as in all capabilities are
 * manually created and closed. This is since there's no good way to track when
 * an object is no longer in use, as everything in Zicl is a string. */

struct Zicl_CapHead;

typedef struct Zicl_CapHeadVTable {
    /* NUL-terminated, e.g. "file-handle". */
    const char *name;
    /* Deinits the body. Runs exactly once, from close. */
    void (*deinit_body)(struct Zicl_CapHead *head);
    /* Frees the backing. Runs at ref count zero, which may be long after close. */
    void (*destroy_backing)(struct Zicl_CapHead *head);
    /* Interrupts the capability so it can fully close. */
    void (*cancel)(struct Zicl_CapHead *head);

    void *stream_ops;
    void *socket_ops;
} Zicl_CapHeadVTable;

typedef struct Zicl_CapabilityId {
    __int128 value;
    bool is_set;
} Zicl_CapabilityId;

/* The generic part of a capability. Embed this as a field of the capability you
 * create. */
typedef struct Zicl_CapHead {
    const Zicl_CapHeadVTable *vtable;
    Zicl_CapabilityId id;
    /* Don't touch directly, as this is atomically changed. */
    uint32_t state;
    /* Don't touch directly, as this is atomically changed. */
    uint32_t ref_count;
} Zicl_CapHead;

/* Registers `head` in the Capability DB and creates a Capability object.
 * `head->vtable` needs to be set, but the rest is initialized here. */
Zicl_RetCode Zicl_CapNew(Zicl_CapHead *head, Zicl_Val *out);

/* Attempts to resolve `shim` as a live capability, failing if
 * 1. it's not a capability, 2. it's not the right capability type,
 * or 3. it's been closed. On success, the capability's in_flight
 * counter goes up by one, so be sure to call `Zicl_CapDropInFlight`
 * when you're done with the capability operation. */
Zicl_RetCode Zicl_ResolveCap(Zicl_Interp *interp, Zicl_Shim *shim, const Zicl_CapHeadVTable *expected, Zicl_CapHead **out);

/* Head operations, mirroring Capability.Head. */
Zicl_CapHead *Zicl_CapTakeRef(Zicl_CapHead *head);
void Zicl_CapDropRef(Zicl_CapHead *head);
void Zicl_CapClose(Zicl_CapHead *head);
void Zicl_CapDropInFlight(Zicl_CapHead *head);
bool Zicl_CapIsClosed(Zicl_CapHead *head);

Zicl_RetCode Zicl_NewFileCapFromFd(int descriptor, Zicl_Val *out);

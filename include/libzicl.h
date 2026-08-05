#pragma once

#include <stdbool.h>
#include <stdint.h>

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

#ifndef __cplusplus
_Static_assert(sizeof(Zicl_Value) == 16, "Zicl_Value must match heap.Value");
_Static_assert(sizeof(Zicl_OptionalValue) == 16, "Zicl_OptionalValue must match heap.OptionalValue");
#endif

/* The working buffer for shimmering. `original` is the value the caller handed
 * in; `shimmered` holds a duplicated object when the original could not be
 * converted in place. `Zicl_Current` returns whichever is effective. Mirrors
 * `objects.Shimmerable` on the Zig side, so the two must be kept in step. */
typedef struct Zicl_Shimmerable {
    Zicl_Value original;
    Zicl_OptionalValue shimmered;
} Zicl_Shimmerable;

#ifndef __cplusplus
_Static_assert(sizeof(Zicl_Shimmerable) == 32, "Zicl_Shimmerable must match objects.Shimmerable");
#endif

/* Build a shimmerable around a single value, with no shimmered duplicate. The
 * caller owns `value` for the lifetime of the shimmerable. */
static inline Zicl_Shimmerable Zicl_MakeShimmerable(Zicl_Value value) {
    Zicl_Shimmerable shim;
    shim.original = value;
    shim.shimmered = ZICL_NONE;
    return shim;
}

/* Return the effective value of a shimmerable: the shimmered duplicate when one
 * exists, otherwise the original. The result is non-owning; borrow it with
 * `Zicl_IncrRefCount` if it must outlive the shimmerable. */
Zicl_Value Zicl_Current(Zicl_Shimmerable shim);

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
 *     ZICL_TRY(Zicl_NewList(out, NULL, 0), rc);
 *     defer { if (rc) Zicl_DecrRefCount(*out); }
 *     ZICL_TRY(Zicl_ListAppend(interp, out, item), rc);
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

/* A ref-counted heap object. Opaque because its layout carries atomic fields
 * and a type-erased body that C cannot usefully touch directly; reach its state
 * through the accessors below (`Zicl_AsPtr`, `Zicl_RefCount`, ...). */
typedef struct Zicl_Object Zicl_Object;

typedef struct Zicl_Interp Zicl_Interp;

typedef int (*Zicl_CCommandFn)(Zicl_Interp *interp, int argc, Zicl_Value *argv);

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

int Zicl_NewString(Zicl_Value *out, const char *ptr, int len);
const char *Zicl_String(Zicl_Value object);
const char *Zicl_GetString(Zicl_Value object, int *len);
void Zicl_DecrRefCount(Zicl_Value value);
Zicl_Value Zicl_IncrRefCount(Zicl_Value value);
/* The heap object a pointer-tagged value refers to, or NULL for primitives. */
Zicl_Object *Zicl_AsPtr(Zicl_Value value);

/* Number functions. Primitives are stored inline, so these cannot fail. */
Zicl_Value Zicl_NewInt(int64_t value);
Zicl_Value Zicl_NewDouble(double value);
Zicl_Value Zicl_NewBool(bool value);
int Zicl_GetLong(Zicl_Interp *interp, Zicl_Value *value, long *out);
int Zicl_GetDouble(Zicl_Interp *interp, Zicl_Value *value, double *out);
int Zicl_GetBoolean(Zicl_Interp *interp, Zicl_Value *value, int *out);

/* List functions */
int Zicl_NewList(Zicl_Value *out, Zicl_Value *values, int n_values);
int Zicl_ListLength(Zicl_Interp *interp, Zicl_Value *list);
int Zicl_ListAppend(Zicl_Interp *interp, Zicl_Value *list, Zicl_Value item);
/* Absent when the index is out of range. The result is borrowed from the list,
 * so it is only valid while the list holds it. */
Zicl_OptionalValue Zicl_ListGetItem(Zicl_Interp *interp, Zicl_Value *list, uint32_t index);

/* Dict functions */
int Zicl_NewDict(Zicl_Value *out, Zicl_Value *values, int n_values);
int Zicl_DictPut(Zicl_Interp *interp, Zicl_Value *dict, Zicl_Value key, Zicl_Value value);

/* Source functions */
const char *Zicl_SourceGetFilename(Zicl_Value source);
int Zicl_SourceGetLine(Zicl_Value source);
/* Replaces *value with one carrying the given source location, releasing the
 * original on success. A source location is fixed at construction, so this
 * cannot annotate the existing object in place. */
int Zicl_AttachSource(Zicl_Value *value, const char *filename, int line_no);

/* Interpreter functions */
int Zicl_CreateCommand(Zicl_Interp *interp, const char *name, Zicl_CCommandFn command);
int Zicl_EvalObject(Zicl_Interp *interp, Zicl_Value script);
int Zicl_EvalFile(Zicl_Interp *interp, const char *filename);
Zicl_Value Zicl_GetResult(Zicl_Interp *interp);
void Zicl_SetResult(Zicl_Interp *interp, Zicl_Value value);
void Zicl_SetResultOwning(Zicl_Interp *interp, Zicl_Value value);
int Zicl_SetVariable(Zicl_Interp *interp, Zicl_Value *name, Zicl_Value value);
int Zicl_SetResultString(Zicl_Interp *interp, const char *str, int len);
int Zicl_SetResultBool(Zicl_Interp *interp, int value);
int Zicl_SetResultInt(Zicl_Interp *interp, long value);
void Zicl_SetEmptyResult(Zicl_Interp *interp);
int Zicl_MakeErrorMessage(Zicl_Interp *interp);
void Zicl_IncrSignalDepth(Zicl_Interp *interp);
void Zicl_DecrSignalDepth(Zicl_Interp *interp);
uint64_t Zicl_GetSigmask(Zicl_Interp *interp);
Zicl_Value Zicl_GetScriptBeingEvaluated(Zicl_Interp *interp);

/* Object debugging. `tag` is a plain field read, so there is no accessor for
 * it. Both of these are only meaningful for ZICL_TAG_POINTER values. */
uint32_t Zicl_RefCount(Zicl_Value value);
uint32_t *Zicl_RefCountPtr(Zicl_Value value);

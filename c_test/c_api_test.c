/* C API smoke test for libzicl.
 *
 * Linked against the combined libzicl archive and run from `zig build
 * test-c-api`. Exercises the C surface end-to-end: the header must compile and
 * the export signatures must link. It is not a behavior test (the Zig suite
 * covers semantics); it is a regression net for the C ABI, which nothing else
 * in `zig build test` touches.
 *
 * Covers lifecycle, strings, interned strings, reference counting, numbers,
 * shimmerables, the list and dict copy-on-write APIs (both branches), list
 * indexing, and the shimmerable discard path. */

#include "libzicl.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Fail fast: print the failing condition and abort, so a `zig build test-c-api`
 * failure points at the first broken contract. */
#define CHECK(cond)                                                  \
    do {                                                             \
        if (!(cond)) {                                               \
            fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #cond);  \
            abort();                                                 \
        }                                                            \
    } while (0)

/* Read list item `index` back as a long, via the shimmerable coercion path. */
static long item_as_long(Zicl_Interp *interp, Zicl_Value *list, int index) {
    Zicl_OptionalValue ov = Zicl_ListGetItem(interp, list, index);
    if (Zicl_IsNone(ov)) return -999999;
    Zicl_Shimmerable shim = Zicl_NewShimmerable(Zicl_Unwrap(ov));
    long n = -888888;
    if (Zicl_GetLong(interp, &shim, &n) != ZICL_OK) return -777777;
    return n;
}

/* Reports the name of the closure currently executing (or "(none)" at the
 * top level / inside an anonymous closure) as the result. */
static int whoami_cmd(Zicl_Interp *interp, int argc, Zicl_Shimmerable *argv) {
    (void)argc;
    (void)argv;
    Zicl_OptionalValue name = Zicl_GetClosureNameBeingEvaluated(interp);
    if (Zicl_IsNone(name)) {
        Zicl_Value none_marker;
        if (Zicl_NewString(&none_marker, "(none)", -1) != ZICL_OK) return ZICL_OOM;
        Zicl_SetResult(interp, none_marker);
        Zicl_DropRef(none_marker);
    } else {
        Zicl_SetResult(interp, Zicl_Unwrap(name));
    }
    return ZICL_OK;
}

/* A command that asks the interpreter to stop. The check in evalObjectInner
 * fires at the next command boundary, so the script never reaches the command
 * after this one. */
static int stop_cmd(Zicl_Interp *interp, int argc, Zicl_Shimmerable *argv) {
    (void)argc;
    (void)argv;
    Zicl_RequestStop(interp);
    return ZICL_OK;
}

/* ---- Custom native object types ----
 * Two vtables: Point2D fits inline (well under ZICL_OBJECT_BODY_MAX_SIZE),
 * BigStruct doesn't and boxes itself, entirely at this (C) layer -- Zicl's
 * Object code treats both exactly the same, as 48 opaque bytes. */

typedef struct { double x, y; } Point2D;

static Zicl_Object *point2d_duplicate(const Zicl_Object *src);
static void point2d_free_internal_rep(Zicl_Object *obj);
static int point2d_update_string(Zicl_Object *obj);

static const Zicl_ObjectVTable point2d_vtable = {
    .is_c_vtable = true,
    .name = "Point2D",
    .duplicate = point2d_duplicate,
    .free_internal_rep = point2d_free_internal_rep,
    .update_string = point2d_update_string,
    .make_crossthread = Zicl_NoopMakeCrossthread,
    .enumerate_struct = NULL,
};

static Zicl_Object *point2d_duplicate(const Zicl_Object *src) {
    void *body;
    Zicl_Object *obj = Zicl_NewObject(&point2d_vtable, sizeof(Point2D), &body);
    if (!obj) return NULL;
    memcpy(body, Zicl_ObjectBodyConst(src), sizeof(Point2D));
    return obj;
}
static void point2d_free_internal_rep(Zicl_Object *obj) { (void)obj; }
static int point2d_update_string(Zicl_Object *obj) {
    const Point2D *p = (const Point2D *)Zicl_ObjectBodyConst(obj);
    char buf[64];
    int len = snprintf(buf, sizeof(buf), "%.1f %.1f", p->x, p->y);
    return Zicl_SetObjectString(obj, buf, len);
}

/* Unrelated to Point2D; never instantiated, only used by address, to check
 * that Zicl_AsObject distinguishes types by vtable identity rather than by
 * structural shape. */
static const Zicl_ObjectVTable other_vtable = {
    .is_c_vtable = true,
    .name = "Other",
    .duplicate = NULL,
    .free_internal_rep = NULL,
    .update_string = NULL,
    .make_crossthread = Zicl_NoopMakeCrossthread,
    .enumerate_struct = NULL,
};

/* Bigger than ZICL_OBJECT_BODY_MAX_SIZE, so its body is a BigStruct* to a
 * separately malloc'd copy, rather than a BigStruct. sizeof(BigStruct*) is
 * what gets passed to Zicl_NewObject, not sizeof(BigStruct). */
typedef struct { char payload[128]; } BigStruct;

static Zicl_Object *bigstruct_duplicate(const Zicl_Object *src);
static void bigstruct_free_internal_rep(Zicl_Object *obj);

static const Zicl_ObjectVTable bigstruct_vtable = {
    .is_c_vtable = true,
    .name = "BigStruct",
    .duplicate = bigstruct_duplicate,
    .free_internal_rep = bigstruct_free_internal_rep,
    .update_string = NULL,
    .make_crossthread = Zicl_NoopMakeCrossthread,
    .enumerate_struct = NULL,
};

static Zicl_Object *bigstruct_duplicate(const Zicl_Object *src) {
    void *body;
    Zicl_Object *obj = Zicl_NewObject(&bigstruct_vtable, sizeof(BigStruct *), &body);
    if (!obj) return NULL;
    BigStruct *copy = (BigStruct *)malloc(sizeof(BigStruct));
    if (!copy) return NULL;
    BigStruct *src_data = *(BigStruct **)Zicl_ObjectBodyConst(src);
    memcpy(copy, src_data, sizeof(BigStruct));
    *(BigStruct **)body = copy;
    return obj;
}
static void bigstruct_free_internal_rep(Zicl_Object *obj) {
    free(*(BigStruct **)Zicl_ObjectBody(obj));
}

/* A plain (non-Zicl_Value, non-Object) nested struct, reached via
 * Zicl_StructWalkerFollowStruct. Its enumerate_struct receives `node` as
 * exactly the pointer FollowStruct was given -- no Object wraps it, so
 * nothing to unwrap, unlike Wrapper's own (top-level) enumerate_struct
 * below. */
typedef struct { int tag; } Inner;

static int inner_enumerate_struct(Zicl_StructWalker *ctx, const void *node) {
    const Inner *inner = (const Inner *)node;
    char buf[32];
    snprintf(buf, sizeof(buf), "%d", inner->tag);
    return Zicl_StructWalkerAddField(ctx, "tag", buf);
}

/* Exercises all three Zicl_StructWalker functions from one enumerate_struct:
 * a plain nested struct (FollowStruct), a field that's itself a Zicl_Value
 * (FollowValue), and (inside inner_enumerate_struct) a plain scalar field
 * (AddField). */
typedef struct {
    Inner inner;
    Zicl_Value label;
} Wrapper;

static Zicl_Object *wrapper_duplicate(const Zicl_Object *src);
static void wrapper_free_internal_rep(Zicl_Object *obj);
static int wrapper_enumerate_struct(Zicl_StructWalker *ctx, const void *node);

static const Zicl_ObjectVTable wrapper_vtable = {
    .is_c_vtable = true,
    .name = "Wrapper",
    .duplicate = wrapper_duplicate,
    .free_internal_rep = wrapper_free_internal_rep,
    .update_string = NULL,
    .make_crossthread = Zicl_NoopMakeCrossthread,
    .enumerate_struct = wrapper_enumerate_struct,
};

static Zicl_Object *wrapper_duplicate(const Zicl_Object *src) {
    void *body;
    Zicl_Object *obj = Zicl_NewObject(&wrapper_vtable, sizeof(Wrapper), &body);
    if (!obj) return NULL;
    const Wrapper *src_w = (const Wrapper *)Zicl_ObjectBodyConst(src);
    Wrapper *dst_w = (Wrapper *)body;
    dst_w->inner = src_w->inner;
    dst_w->label = Zicl_Ref(src_w->label);
    return obj;
}
static void wrapper_free_internal_rep(Zicl_Object *obj) {
    Wrapper *w = (Wrapper *)Zicl_ObjectBody(obj);
    Zicl_DropRef(w->label);
}
static int wrapper_enumerate_struct(Zicl_StructWalker *ctx, const void *node) {
    /* Top-level: `node` is the Zicl_Object* itself (see Zicl_EnumerateStructFn's
     * docs), so unwrap it the same way duplicate/free_internal_rep do. */
    Zicl_Object *obj = (Zicl_Object *)node;
    const Wrapper *w = (const Wrapper *)Zicl_ObjectBodyConst(obj);
    int rc = Zicl_StructWalkerFollowStruct(ctx, "inner", &w->inner, "Inner", inner_enumerate_struct);
    if (rc != ZICL_OK) return rc;
    return Zicl_StructWalkerFollowValue(ctx, "label", w->label);
}

int main(void) {
    CHECK(Zicl_InitGlobals(NULL) == ZICL_OK);
    CHECK(Zicl_InitThread() == ZICL_OK);
    Zicl_Interp *interp = Zicl_CreateInterp();
    CHECK(interp != NULL);

    /* Strings and reference counting. */
    {
        Zicl_Value s;
        CHECK(Zicl_NewString(&s, "hello", 5) == ZICL_OK);
        CHECK(Zicl_RefCount(s) == 1);  /* heap String object */
        Zicl_Value borrowed = Zicl_Ref(s);
        CHECK(Zicl_RefCount(s) == 2);
        Zicl_DropRef(borrowed);
        CHECK(Zicl_RefCount(s) == 1);
        CHECK(Zicl_GetString(s, NULL) != NULL);
        Zicl_DropRef(s);
    }

    /* Duplicate: a fresh owned copy. For a heap string it produces a distinct
     * object with its own refcount; for an inline integer it returns the same
     * value (no object). Everything is a string, so the copy compares equal. */
    {
        Zicl_Value s;
        CHECK(Zicl_NewString(&s, "hello", 5) == ZICL_OK);
        Zicl_Value d;
        CHECK(Zicl_Duplicate(s, &d) == ZICL_OK);
        CHECK(Zicl_RefCount(d) == 1);  /* independent copy */
        int eq = 0;
        CHECK(Zicl_Equals(d, s, &eq) == ZICL_OK && eq == 1);
        Zicl_DropRef(d);
        Zicl_DropRef(s);

        /* Primitives carry no object, so duplicate is infallible and identity. */
        Zicl_Value n = Zicl_NewLong(7);
        Zicl_Value nd;
        CHECK(Zicl_Duplicate(n, &nd) == ZICL_OK);
        CHECK(nd.raw.as.integer == 7);
        Zicl_DropRef(nd);  /* no-op for a primitive */
    }

    /* DuplicateAsBoxed: same copy semantics as Zicl_Duplicate, but the result
     * is always a heap object -- primitives come back boxed. */
    {
        Zicl_Value s;
        CHECK(Zicl_NewString(&s, "hello", 5) == ZICL_OK);
        Zicl_Object *sd = Zicl_DuplicateAsBoxed(s);
        CHECK(sd != NULL);
        CHECK(sd != Zicl_AsPtr(s));  /* independent copy, not the same object */
        Zicl_Value sdv = Zicl_BoxObject(sd);
        CHECK(Zicl_RefCount(sdv) == 1);
        int eq = 0;
        CHECK(Zicl_Equals(sdv, s, &eq) == ZICL_OK && eq == 1);
        Zicl_DropRef(sdv);
        Zicl_DropRef(s);

        /* An inline integer boxes into a fresh Integer object; the original
         * stays inline. Everything is a string, so they compare equal. */
        Zicl_Value n = Zicl_NewLong(7);
        Zicl_Object *nb = Zicl_DuplicateAsBoxed(n);
        CHECK(nb != NULL);
        Zicl_Value nbv = Zicl_BoxObject(nb);
        CHECK(Zicl_RefCount(nbv) == 1);
        CHECK(Zicl_AsPtr(n) == NULL);
        eq = 0;
        CHECK(Zicl_Equals(nbv, n, &eq) == ZICL_OK && eq == 1);
        CHECK(strcmp(Zicl_GetString(nbv, NULL), "7") == 0);
        Zicl_DropRef(nbv);
    }

    /* ReleaseArrayItems: frees a mix of heap objects and inline values. */
    {
        Zicl_Value argv[3];
        CHECK(Zicl_NewString(&argv[0], "a", 1) == ZICL_OK);
        argv[1] = Zicl_NewLong(2);       /* inline, no object */
        CHECK(Zicl_NewString(&argv[2], "c", 1) == ZICL_OK);
        Zicl_DropRefArrayItems(argv, 3);
        /* No leak: Zicl_LeakCheckAll at the end of main catches anything
         * still alive. */
    }

    /* Interned string: zero-copy wrap of a static buffer. */
    {
        static const char lit[] = "world";
        Zicl_Value iv = Zicl_InternStr(lit);
        CHECK(Zicl_RefCount(iv) == 0);  /* inline, no heap object */
        int len = -1;
        const char *got = Zicl_GetString(iv, &len);
        CHECK(got != NULL && len == 5 && strcmp(got, "world") == 0);
        /* "world" (interned) equals "world" (heap string): everything is a string. */
        Zicl_Value h;
        CHECK(Zicl_NewString(&h, "world", 5) == ZICL_OK);
        int eq = 0;
        CHECK(Zicl_Equals(iv, h, &eq) == ZICL_OK && eq == 1);
        Zicl_DropRef(h);
        /* No DecrRefCount: interned carries no object reference. */
    }

    /* Cross-thread marking: a marked object can no longer be mutated in place. */
    {
        Zicl_List *list = Zicl_NewList(NULL, 0);
        CHECK(Zicl_ListAppend(list, Zicl_NewLong(1)) == ZICL_OK);
        Zicl_Value lv = Zicl_BoxList(list);
        Zicl_MakeCrossthread(lv);
        Zicl_List *ml = NULL;
        CHECK(Zicl_AsListMut(interp, lv, &ml) == ZICL_OK);
        CHECK(ml == NULL);  /* cross-thread: cannot mutate in place */
        Zicl_DropRef(lv);
    }

    /* Value equality (compares by string representation, across types). */
    {
        Zicl_Value a = Zicl_NewLong(5);
        Zicl_Value b = Zicl_NewLong(5);
        Zicl_Value c = Zicl_NewLong(6);
        int eq = -1;
        CHECK(Zicl_Equals(a, b, &eq) == ZICL_OK && eq == 1);  /* int == int */
        CHECK(Zicl_Equals(a, c, &eq) == ZICL_OK && eq == 0);  /* int != int */

        Zicl_Value s5, shi;
        CHECK(Zicl_NewString(&s5, "5", 1) == ZICL_OK);
        CHECK(Zicl_NewString(&shi, "hi", 2) == ZICL_OK);
        /* "5" (string) equals 5 (int): everything is a string. */
        CHECK(Zicl_Equals(s5, a, &eq) == ZICL_OK && eq == 1);
        CHECK(Zicl_Equals(shi, a, &eq) == ZICL_OK && eq == 0);
        Zicl_DropRef(s5);
        Zicl_DropRef(shi);
    }

    /* Numbers: inline constructors, plus a shimmerable coercion. */
    {
        CHECK(Zicl_NewLong(42).raw.as.integer == 42);
        CHECK(Zicl_NewDouble(3.5).raw.as.float_value == 3.5);
        CHECK(Zicl_NewBool(true).raw.as.boolean);
        Zicl_Shimmerable shim = Zicl_NewShimmerable(Zicl_NewLong(7));
        long n = 0;
        CHECK(Zicl_GetLong(interp, &shim, &n) == ZICL_OK);
        CHECK(n == 7);
    }

    /* List copy-on-write: in-place branch (uniquely owned, no copy). */
    {
        Zicl_List *list = Zicl_NewList(NULL, 0);
        CHECK(list != NULL);
        CHECK(Zicl_ListAppend(list, Zicl_NewLong(1)) == ZICL_OK);
        CHECK(Zicl_ListAppend(list, Zicl_NewLong(2)) == ZICL_OK);
        CHECK(Zicl_ListLength(list) == 2);

        Zicl_Value lv = Zicl_BoxList(list);
        Zicl_List *ml = NULL;
        CHECK(Zicl_AsListMut(interp, lv, &ml) == ZICL_OK);
        CHECK(ml != NULL);  /* in place: no copy */
        uint32_t rc_before = Zicl_RefCount(lv);
        CHECK(Zicl_ListAppend(ml, Zicl_NewLong(3)) == ZICL_OK);
        CHECK(Zicl_RefCount(lv) == rc_before);  /* same object */
        CHECK(Zicl_ListLength(ml) == 3);
        Zicl_DropRef(lv);
    }

    /* List copy-on-write: dup branch (shared, copy once, batch, write back). */
    {
        Zicl_List *list = Zicl_NewList(NULL, 0);
        CHECK(Zicl_ListAppend(list, Zicl_NewLong(10)) == ZICL_OK);
        CHECK(Zicl_ListAppend(list, Zicl_NewLong(20)) == ZICL_OK);
        Zicl_Value lv = Zicl_BoxList(list);
        Zicl_Value shared = Zicl_Ref(lv);  /* refcount 2 */

        Zicl_List *ml = NULL;
        CHECK(Zicl_AsListMut(interp, shared, &ml) == ZICL_OK);
        CHECK(ml == NULL);  /* shared: must dup */
        CHECK(Zicl_DupAsList(interp, shared, &ml) == ZICL_OK);
        CHECK(ml != NULL);
        CHECK(Zicl_ListLength(ml) == 2);

        /* Batch two appends behind the single copy. */
        CHECK(Zicl_ListAppend(ml, Zicl_NewLong(30)) == ZICL_OK);
        CHECK(Zicl_ListAppend(ml, Zicl_NewLong(40)) == ZICL_OK);
        CHECK(Zicl_ListLength(ml) == 4);
        CHECK(Zicl_ListLength(list) == 2);  /* original untouched */

        /* Commit: release the old shared value, store the new list. */
        ZICL_SWAP(&shared, Zicl_BoxList(ml));
        CHECK(item_as_long(interp, &shared, 3) == 40);
        Zicl_DropRef(shared);  /* the new copy */
        Zicl_DropRef(lv);       /* the original, now refcount 1 */
    }

    /* List set/get and out-of-range handling. */
    {
        Zicl_List *list = Zicl_NewList(NULL, 0);
        CHECK(Zicl_ListAppend(list, Zicl_NewLong(100)) == ZICL_OK);
        CHECK(Zicl_ListAppend(list, Zicl_NewLong(200)) == ZICL_OK);
        Zicl_Value v = Zicl_NewLong(999);
        CHECK(Zicl_ListSet(list, 0, v) == ZICL_OK);  /* takes ownership of v */
        Zicl_Value v2 = Zicl_NewLong(555);
        CHECK(Zicl_ListSet(list, 5, v2) == ZICL_ERR);  /* out of range */

        Zicl_Value lv = Zicl_BoxList(list);
        CHECK(item_as_long(interp, &lv, 0) == 999);
        CHECK(item_as_long(interp, &lv, 1) == 200);
        CHECK(Zicl_IsNone(Zicl_ListGetItem(interp, &lv, 2)));   /* too large */
        CHECK(Zicl_IsNone(Zicl_ListGetItem(interp, &lv, -1)));  /* negative */

        /* ShimListItem over a shimmerable built from the list value. */
        Zicl_Shimmerable shim = Zicl_NewShimmerable(lv);
        Zicl_OptionalValue out;
        CHECK(Zicl_ShimListItem(interp, &shim, 1, &out) == ZICL_OK);
        CHECK(!Zicl_IsNone(out));
        CHECK(Zicl_ShimListItem(interp, &shim, 9, &out) == ZICL_OK);
        CHECK(Zicl_IsNone(out));
        CHECK(Zicl_ShimListItem(interp, &shim, -1, &out) == ZICL_OK);
        CHECK(Zicl_IsNone(out));

        /* DiscardChanges rolls back any shimmered duplicate. */
        Zicl_ShimDiscardChanges(&shim);

        Zicl_DropRef(lv);
    }

    /* NewList from an array borrows the inputs. */
    {
        Zicl_Value in[2] = { Zicl_NewLong(7), Zicl_NewLong(8) };
        Zicl_List *list = Zicl_NewList(in, 2);
        CHECK(list != NULL);
        CHECK(Zicl_ListLength(list) == 2);
        Zicl_Value lv = Zicl_BoxList(list);
        CHECK(item_as_long(interp, &lv, 0) == 7);
        Zicl_DropRef(lv);
    }

    /* BorrowList: a list handle borrowed as a second handle to the same object,
     * refcount incremented. The two handles are independent references, so each
     * must be released once. Zicl_BoxList is used only as a transient view to
     * feed the value-typed accessors; it does not change the refcount. */
    {
        Zicl_List *list = Zicl_NewList(NULL, 0);
        CHECK(Zicl_ListAppend(list, Zicl_NewLong(1)) == ZICL_OK);
        Zicl_List *bv = Zicl_RefList(list);  /* refcount 2 */
        CHECK(Zicl_RefCount(Zicl_BoxList(bv)) == 2);
        CHECK(Zicl_RefCount(Zicl_BoxList(list)) == 2);  /* same object */
        int eq = 0;
        CHECK(Zicl_Equals(Zicl_BoxList(bv), Zicl_BoxList(list), &eq) == ZICL_OK && eq == 1);
        Zicl_DropRefList(bv);
        CHECK(Zicl_RefCount(Zicl_BoxList(list)) == 1);
        Zicl_DropRefList(list);
    }

    /* List shimmer writeback: replace an item in place with a shimmered form of
     * the same string rep, so the list's cached string rep is preserved (the
     * second Zicl_GetString returns the same pointer as the first). Distinct
     * from the ZICL_SWAP dup-branch commit. */
    {
        Zicl_Value in[1] = { Zicl_NewLong(5) };
        Zicl_List *list = Zicl_NewList(in, 1);
        Zicl_Value lv = Zicl_BoxList(list);
        int len = -1;
        const char *s1 = Zicl_GetString(lv, &len);
        CHECK(s1 != NULL && len == 1 && s1[0] == '5');
        CHECK(Zicl_ListShimmerWriteback(list, 0, Zicl_NewLong(5)) == ZICL_OK);
        int len2 = -1;
        const char *s2 = Zicl_GetString(lv, &len2);
        CHECK(s2 == s1);  /* string rep not regenerated */
        CHECK(Zicl_ListShimmerWriteback(list, 5, Zicl_NewLong(5)) == ZICL_ERR);  /* out of range */
        Zicl_DropRef(lv);
    }

    /* Dict copy-on-write: in-place branch (uniquely owned, no copy). */
    {
        Zicl_Value kv[2] = { Zicl_NewLong(1), Zicl_NewLong(11) };
        Zicl_Dict *dict = Zicl_NewDict(kv, 2);
        CHECK(dict != NULL);
        CHECK(Zicl_DictLength(dict) == 1);

        Zicl_Value dv = Zicl_BoxDict(dict);
        Zicl_Dict *md = NULL;
        CHECK(Zicl_AsDictMut(interp, dv, &md) == ZICL_OK);
        CHECK(md != NULL);  /* in place: no copy */
        CHECK(Zicl_DictPut(md, Zicl_NewLong(2), Zicl_NewLong(22)) == ZICL_OK);
        CHECK(Zicl_DictLength(md) == 2);

        Zicl_Value k1 = Zicl_NewLong(1);
        Zicl_Shimmerable dv_shim = Zicl_NewShimmerable(dv);
        Zicl_OptionalValue got;
        CHECK(Zicl_ShimDictGet(interp, &dv_shim, k1, &got) == ZICL_OK);
        CHECK(!Zicl_IsNone(got));
        Zicl_ShimDiscardChanges(&dv_shim);
        Zicl_DropRef(k1);
        Zicl_DropRef(dv);
    }

    /* Dict copy-on-write: dup branch (shared, copy once, write back). */
    {
        Zicl_Value kv[2] = { Zicl_NewLong(10), Zicl_NewLong(100) };
        Zicl_Dict *dict = Zicl_NewDict(kv, 2);
        Zicl_Value dv = Zicl_BoxDict(dict);
        Zicl_Value shared = Zicl_Ref(dv);  /* refcount 2 */

        Zicl_Dict *md = NULL;
        CHECK(Zicl_AsDictMut(interp, shared, &md) == ZICL_OK);
        CHECK(md == NULL);  /* shared: must dup */
        CHECK(Zicl_DupAsDict(interp, shared, &md) == ZICL_OK);
        CHECK(md != NULL);
        CHECK(Zicl_DictPut(md, Zicl_NewLong(20), Zicl_NewLong(200)) == ZICL_OK);
        CHECK(Zicl_DictLength(md) == 2);
        CHECK(Zicl_DictLength(dict) == 1);  /* original untouched */

        /* Commit: release the old shared value, store the new dict. */
        ZICL_SWAP(&shared, Zicl_BoxDict(md));
        Zicl_Value k20 = Zicl_NewLong(20);
        Zicl_Shimmerable shared_shim = Zicl_NewShimmerable(shared);
        Zicl_OptionalValue got;
        CHECK(Zicl_ShimDictGet(interp, &shared_shim, k20, &got) == ZICL_OK);
        CHECK(!Zicl_IsNone(got));  /* new key present in the copy */
        Zicl_ShimDiscardChanges(&shared_shim);
        Zicl_DropRef(k20);
        Zicl_DropRef(shared);  /* the new copy */
        Zicl_DropRef(dv);       /* the original, now refcount 1 */
    }

    /* Dict remove. */
    {
        Zicl_Value kv[4] = { Zicl_NewLong(1), Zicl_NewLong(11), Zicl_NewLong(2), Zicl_NewLong(22) };
        Zicl_Dict *dict = Zicl_NewDict(kv, 4);
        Zicl_Value dv = Zicl_BoxDict(dict);
        Zicl_Dict *md = NULL;
        CHECK(Zicl_AsDictMut(interp, dv, &md) == ZICL_OK);
        CHECK(md != NULL);
        int removed = 0;
        CHECK(Zicl_DictRemove(md, Zicl_NewLong(1), &removed) == ZICL_OK);
        CHECK(removed == 1);
        CHECK(Zicl_DictLength(md) == 1);
        Zicl_Value k1 = Zicl_NewLong(1);
        Zicl_Shimmerable dv_shim = Zicl_NewShimmerable(dv);
        Zicl_OptionalValue got;
        CHECK(Zicl_ShimDictGet(interp, &dv_shim, k1, &got) == ZICL_OK);
        CHECK(Zicl_IsNone(got));  /* gone */
        Zicl_ShimDiscardChanges(&dv_shim);
        Zicl_DropRef(k1);
        Zicl_DropRef(dv);
    }

    /* Dict shimmer writeback: replace a key's value in place with a shimmered
     * form of the same string rep, so the dict's cached string rep is preserved
     * (the second Zicl_GetString returns the same pointer as the first). The
     * key must already be present. Distinct from the ZICL_SWAP dup-branch
     * commit. */
    {
        Zicl_Value kv[2] = { Zicl_NewLong(1), Zicl_NewLong(11) };
        Zicl_Dict *dict = Zicl_NewDict(kv, 2);
        Zicl_Value dv = Zicl_BoxDict(dict);
        int len = -1;
        const char *s1 = Zicl_GetString(dv, &len);
        CHECK(s1 != NULL);
        Zicl_Value k1 = Zicl_NewLong(1);
        CHECK(Zicl_DictShimmerWriteback(dict, k1, Zicl_NewLong(11)) == ZICL_OK);
        int len2 = -1;
        const char *s2 = Zicl_GetString(dv, &len2);
        CHECK(s2 == s1);  /* string rep not regenerated */
        Zicl_DropRef(k1);
        Zicl_DropRef(dv);
    }

    /* Dict link: build a fresh dict with a ~parent hash reference, leaving
     * both inputs untouched, and confirm a key that only the parent has
     * resolves through the link. */
    {
        Zicl_Value parent_kv[2] = { Zicl_NewLong(100), Zicl_NewLong(1000) };
        Zicl_Dict *parent = Zicl_NewDict(parent_kv, 2);
        Zicl_Value pv = Zicl_BoxDict(parent);

        Zicl_Value child_kv[2] = { Zicl_NewLong(1), Zicl_NewLong(11) };
        Zicl_Dict *child = Zicl_NewDict(child_kv, 2);

        Zicl_Dict *linked = Zicl_DictLink(child, pv);
        CHECK(linked != NULL);
        CHECK(Zicl_DictLength(linked) == 2);  /* ~parent plus child's one pair */
        CHECK(Zicl_DictLength(child) == 1);   /* child untouched */

        int klen = -1;
        const char *k0 = Zicl_GetString(Zicl_DictItems(linked)[0], &klen);
        CHECK(klen == 7 && memcmp(k0, "~parent", 7) == 0);

        Zicl_Value lv = Zicl_BoxDict(linked);
        int llen = -1;
        const char *ls = Zicl_GetString(lv, &llen);
        char buf[512];
        snprintf(buf, sizeof(buf), "dict get {%.*s} 100", llen, ls);
        CHECK(Zicl_Eval(interp, buf) == ZICL_OK);
        int rlen = -1;
        const char *got = Zicl_GetString(Zicl_GetResult(interp), &rlen);
        CHECK(rlen == 4 && memcmp(got, "1000", 4) == 0);

        Zicl_DropRef(lv);
        Zicl_DropRef(pv);
        Zicl_DropRefDict(child);
    }

    /* Source copy-on-write: in-place branch (uniquely owned, annotate line). */
    {
        Zicl_Value s;
        CHECK(Zicl_NewString(&s, "script text", 11) == ZICL_OK);
        CHECK(Zicl_AttachSource(&s, "file.tcl", 10) == ZICL_OK);
        CHECK(Zicl_AsSource(s) != NULL);  /* s is now a Source */

        Zicl_Source *ms = Zicl_AsSourceMut(s);
        CHECK(ms != NULL);  /* in place: no copy */
        ms->line_no = 20;   /* line_no is a plain uint32; safe to write directly */
        CHECK(Zicl_SourceGetLine(s) == 20);
        Zicl_DropRef(s);
    }

    /* Source shimmer-from-string: a plain string shimmers to a Source in place,
     * starting with an empty location, which the mutable view then fills in. */
    {
        Zicl_Value s;
        CHECK(Zicl_NewString(&s, "raw script", 10) == ZICL_OK);
        CHECK(Zicl_AsSource(s) == NULL);  /* still a plain string */

        Zicl_Source *ms = Zicl_AsSourceMut(s);
        CHECK(ms != NULL);  /* shimmered to a Source in place, no copy */
        CHECK(Zicl_SourceGetLine(s) == 0);  /* empty location to start */
        ms->line_no = 42;
        CHECK(Zicl_SourceGetLine(s) == 42);
        /* The string rep is preserved through the shimmer. */
        int len = -1;
        const char *got = Zicl_GetString(s, &len);
        CHECK(got != NULL && len == 10 && strcmp(got, "raw script") == 0);
        Zicl_DropRef(s);
    }

    /* Source copy-on-write: dup branch (shared, copy once, write back). */
    {
        Zicl_Value s;
        CHECK(Zicl_NewString(&s, "more script", 11) == ZICL_OK);
        CHECK(Zicl_AttachSource(&s, "other.tcl", 1) == ZICL_OK);
        Zicl_Value shared = Zicl_Ref(s);  /* refcount 2 */

        Zicl_Source *ms = Zicl_AsSourceMut(shared);
        CHECK(ms == NULL);  /* shared: must dup */
        ms = Zicl_DupAsSource(shared);
        CHECK(ms != NULL);
        ms->line_no = 99;
        CHECK(Zicl_SourceGetLine(shared) == 1);  /* original untouched */

        /* A Source carries no lookup state, so the generic swap is the commit
         * path -- no specialized writeback is needed. */
        ZICL_SWAP(&shared, Zicl_BoxSource(ms));
        CHECK(Zicl_SourceGetLine(shared) == 99);
        Zicl_DropRef(shared);  /* the new copy */
        Zicl_DropRef(s);       /* the original, now refcount 1 */
    }

    /* SetErrorString: reports the message as an error result. Returns ZICL_ERR
     * on the success path (never ZICL_OK), and the result string is the message. */
    {
        CHECK(Zicl_SetErrorString(interp, "boom", -1) == ZICL_ERR);
        int len = -1;
        const char *got = Zicl_GetString(Zicl_GetResult(interp), &len);
        CHECK(got != NULL && len == 4 && strcmp(got, "boom") == 0);

        /* Length-prefixed form. */
        CHECK(Zicl_SetErrorString(interp, "nope123", 4) == ZICL_ERR);
        got = Zicl_GetString(Zicl_GetResult(interp), &len);
        CHECK(got != NULL && len == 4 && strcmp(got, "nope") == 0);
    }

    /* Eval: run a NUL-terminated script string, read the result off the
     * interpreter. ZICL_OK on success, ZICL_ERR on a script error (with the
     * message as the result), ZICL_OOM if boxing the string fails. */
    {
        CHECK(Zicl_Eval(interp, "expr {6 * 7}") == ZICL_OK);
        int len = -1;
        const char *got = Zicl_GetString(Zicl_GetResult(interp), &len);
        CHECK(got != NULL && len == 2 && strcmp(got, "42") == 0);

        /* A script error leaves the message as the result and returns ZICL_ERR. */
        CHECK(Zicl_Eval(interp, "set") == ZICL_ERR);
        got = Zicl_GetString(Zicl_GetResult(interp), &len);
        CHECK(got != NULL && len > 0);  /* usage message */

        /* A top-level `return` surfaces as ZICL_PROPAGATE (not swallowed). */
        CHECK(Zicl_Eval(interp, "return 5") == ZICL_PROPAGATE);
        got = Zicl_GetString(Zicl_GetResult(interp), &len);
        CHECK(got != NULL && len == 1 && got[0] == '5');
    }

    /* Closures: GetClosure resolves a value into a reusable handle, GetBody
     * reads its (unattached, here) source location, CallClosure invokes it
     * -- possibly more than once -- and ReleaseClosure frees the handle.
     * [fn] leaves a closure value as the eval result; resolve it instead of
     * going through [apply]. argv[0] is the name slot callClosure expects
     * (unused for a plain, non-method closure). */
    {
        CHECK(Zicl_Eval(interp, "fn {a b} { + $a $b }") == ZICL_OK);
        Zicl_Value closure_value = Zicl_GetResult(interp);

        Zicl_Closure *closure = NULL;
        CHECK(Zicl_GetClosure(interp, closure_value, &closure) == ZICL_OK);
        CHECK(closure != NULL);

        /* The tokenizer wraps every literal word as a Source carrying a
         * relative line number, even without a file (evalString, not
         * evalFile, produced this script), so the filename is unset. */
        int blen = -1;
        const char *body = Zicl_GetString(Zicl_ClosureGetBody(closure), &blen);
        CHECK(body != NULL && blen > 0);
        CHECK(Zicl_AsSource(Zicl_ClosureGetBody(closure)) != NULL);
        CHECK(Zicl_SourceGetFilename(Zicl_ClosureGetBody(closure)) == NULL);
        CHECK(Zicl_SourceGetLine(Zicl_ClosureGetBody(closure)) >= 0);

        Zicl_Shimmerable argv[3] = {
            Zicl_NewShimmerable(closure_value),  /* name slot, unused */
            Zicl_NewShimmerable(Zicl_NewLong(10)),
            Zicl_NewShimmerable(Zicl_NewLong(20)),
        };
        CHECK(Zicl_CallClosure(interp, closure, 3, argv) == ZICL_OK);
        int len = -1;
        const char *got = Zicl_GetString(Zicl_GetResult(interp), &len);
        CHECK(got != NULL && len == 2 && memcmp(got, "30", 2) == 0);

        /* The same handle can be called again. */
        Zicl_Shimmerable argv2[3] = {
            Zicl_NewShimmerable(closure_value),
            Zicl_NewShimmerable(Zicl_NewLong(1)),
            Zicl_NewShimmerable(Zicl_NewLong(2)),
        };
        CHECK(Zicl_CallClosure(interp, closure, 3, argv2) == ZICL_OK);
        got = Zicl_GetString(Zicl_GetResult(interp), &len);
        CHECK(got != NULL && len == 1 && got[0] == '3');

        Zicl_DropRefClosure(closure);

        /* A [method] closure is rejected by Zicl_GetClosure with ZICL_ERR,
         * matching plain command dispatch when a method is invoked as a
         * function. */
        CHECK(Zicl_Eval(interp, "method {self} {} { }") == ZICL_OK);
        Zicl_Closure *method = NULL;
        CHECK(Zicl_GetClosure(interp, Zicl_GetResult(interp), &method) == ZICL_ERR);
        CHECK(method == NULL);
    }

    /* GetClosureNameBeingEvaluated: ZICL_NONE at the top level, the closure's
     * name once one is running. */
    {
        CHECK(Zicl_CreateCommand(interp, "whoami", whoami_cmd, "current closure name", 0, 0) == ZICL_OK);

        CHECK(Zicl_Eval(interp, "whoami") == ZICL_OK);
        int len = -1;
        const char *got = Zicl_GetString(Zicl_GetResult(interp), &len);
        CHECK(got != NULL && strcmp(got, "(none)") == 0);

        CHECK(Zicl_Eval(interp, "fn myproc {} { whoami }; myproc") == ZICL_OK);
        got = Zicl_GetString(Zicl_GetResult(interp), &len);
        CHECK(got != NULL && strcmp(got, "myproc") == 0);
    }

    /* Zicl_CallClosure runs a [tailcall] the closure body issues, rather than
     * handing back ZICL_TAILCALL with the target left unrun: it dispatches
     * through the same invokeCommand loop that consumes a tailcall for an
     * ordinary command call, instead of calling callClosure on its own. */
    {
        CHECK(Zicl_Eval(interp, "fn tc_b {} { return tailcalled }") == ZICL_OK);
        CHECK(Zicl_Eval(interp, "fn tc_a {} { tailcall tc_b }") == ZICL_OK);
        Zicl_Value closure_value = Zicl_GetResult(interp);

        Zicl_Closure *closure = NULL;
        CHECK(Zicl_GetClosure(interp, closure_value, &closure) == ZICL_OK);

        Zicl_Shimmerable argv[1] = { Zicl_NewShimmerable(closure_value) };
        CHECK(Zicl_CallClosure(interp, closure, 1, argv) == ZICL_OK);
        int len = -1;
        const char *got = Zicl_GetString(Zicl_GetResult(interp), &len);
        CHECK(got != NULL && len == 10 && memcmp(got, "tailcalled", 10) == 0);

        Zicl_DropRefClosure(closure);
    }

    /* Local arena snapshot/rewind: rendering an inline integer's string rep
     * allocates from the thread arena, so a snapshot taken across it advances,
     * and rewinding to the earlier snapshot restores the watermark exactly. */
    {
        Zicl_ArenaSnapshot a = Zicl_LocalArenaSnapshot();
        int len = -1;
        (void)Zicl_GetString(Zicl_NewLong(123456789), &len);  /* arena-allocated */
        Zicl_ArenaSnapshot b = Zicl_LocalArenaSnapshot();
        CHECK(b.end_index > a.end_index || b.current != a.current);  /* advanced */
        Zicl_LocalArenaRewind(a);
        Zicl_ArenaSnapshot c = Zicl_LocalArenaSnapshot();
        CHECK(c.current == a.current && c.end_index == a.end_index);  /* restored */
    }

    /* Cooperative stop: a command calls Zicl_RequestStop, and the eval unwinds
     * at the next command boundary with ZICL_EXIT. The command after `stopit`
     * never runs, and the flag persists until Zicl_ClearStop resets it. */
    {
        CHECK(Zicl_CreateCommand(interp, "stopit", stop_cmd, "stop the interpreter", 0, 0) == ZICL_OK);
        CHECK(!Zicl_StopRequested(interp));
        CHECK(Zicl_Eval(interp, "stopit; set x 99") == ZICL_EXIT);
        CHECK(Zicl_StopRequested(interp));
        Zicl_ClearStop(interp);
        CHECK(!Zicl_StopRequested(interp));
        /* Reusable after a clear: a later eval runs normally. */
        CHECK(Zicl_Eval(interp, "expr {1 + 1}") == ZICL_OK);
        int len = -1;
        const char *got = Zicl_GetString(Zicl_GetResult(interp), &len);
        CHECK(got != NULL && len == 1 && got[0] == '2');
    }

    /* Custom native object types: a POD struct living inline in the 48-byte
     * body, ref-counted and duplicated through the same Object machinery
     * every built-in type uses. */
    {
        Point2D *body;
        Zicl_Object *obj = Zicl_NewObject(&point2d_vtable, sizeof(Point2D), (void **)&body);
        CHECK(obj != NULL);
        body->x = 3.0;
        body->y = 4.0;

        Zicl_Value v = Zicl_BoxObject(obj);
        CHECK(Zicl_RefCount(v) == 1);

        /* Recognized by its own vtable, by address, not structurally. */
        Point2D *seen = (Point2D *)Zicl_AsObject(v, &point2d_vtable);
        CHECK(seen == body);
        CHECK(seen->x == 3.0 && seen->y == 4.0);
        CHECK(Zicl_AsObject(v, &other_vtable) == NULL);

        /* update_string is called lazily, on first need, via Zicl_SetObjectString. */
        const char *str = Zicl_String(v);
        CHECK(str != NULL && strcmp(str, "3.0 4.0") == 0);

        /* Duplicate goes through point2d_duplicate: independent object, same
         * field values. */
        Zicl_Value dup;
        CHECK(Zicl_Duplicate(v, &dup) == ZICL_OK);
        Point2D *dup_body = (Point2D *)Zicl_AsObject(dup, &point2d_vtable);
        CHECK(dup_body != NULL && dup_body != body);
        CHECK(dup_body->x == 3.0 && dup_body->y == 4.0);

        Zicl_DropRef(dup);
        Zicl_DropRef(v);
    }

    /* A struct too big to fit inline (BigStruct is 128 bytes, well over
     * ZICL_OBJECT_BODY_MAX_SIZE): the vtable's own callbacks decide to box
     * it, storing a pointer inline instead of the struct itself. Zicl's
     * Object code never needs to know this one is out-of-line. */
    {
        BigStruct **body;
        Zicl_Object *obj = Zicl_NewObject(&bigstruct_vtable, sizeof(BigStruct *), (void **)&body);
        CHECK(obj != NULL);
        *body = (BigStruct *)malloc(sizeof(BigStruct));
        CHECK(*body != NULL);
        memset((*body)->payload, 'a', sizeof((*body)->payload));

        Zicl_Value v = Zicl_BoxObject(obj);
        Zicl_Value dup;
        CHECK(Zicl_Duplicate(v, &dup) == ZICL_OK);
        BigStruct **dup_body = (BigStruct **)Zicl_AsObject(dup, &bigstruct_vtable);
        CHECK(dup_body != NULL && *dup_body != *body);  /* independently malloc'd */
        CHECK(memcmp((*dup_body)->payload, (*body)->payload, sizeof((*body)->payload)) == 0);

        Zicl_DropRef(dup);
        Zicl_DropRef(v);  /* exercises bigstruct_free_internal_rep */
    }

    /* enumerate_struct, exercised end to end via a deliberate, permanent
     * leak: Zicl_LeakCheckAll (called once below, at the very end of main --
     * see its own docs for why it's shutdown-only) walks it, driving
     * AddField, FollowStruct, and FollowValue. Not released on purpose. */
    {
        Wrapper *body;
        Zicl_Object *obj = Zicl_NewObject(&wrapper_vtable, sizeof(Wrapper), (void **)&body);
        CHECK(obj != NULL);
        body->inner.tag = 42;
        CHECK(Zicl_NewString(&body->label, "leaked-on-purpose", -1) == ZICL_OK);
    }

    Zicl_InterpDestroy(interp);
    Zicl_LeakCheckAll();
    Zicl_DeinitAll();

    printf("c API smoke test passed\n");
    return 0;
}
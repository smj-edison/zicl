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
        Zicl_Value borrowed = Zicl_Borrow(s);
        CHECK(Zicl_RefCount(s) == 2);
        Zicl_Release(borrowed);
        CHECK(Zicl_RefCount(s) == 1);
        CHECK(Zicl_GetString(s, NULL) != NULL);
        Zicl_Release(s);
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
        Zicl_Release(d);
        Zicl_Release(s);

        /* Primitives carry no object, so duplicate is infallible and identity. */
        Zicl_Value n = Zicl_NewLong(7);
        Zicl_Value nd;
        CHECK(Zicl_Duplicate(n, &nd) == ZICL_OK);
        CHECK(nd.raw.as.integer == 7);
        Zicl_Release(nd);  /* no-op for a primitive */
    }

    /* ReleaseArrayItems: frees a mix of heap objects and inline values. */
    {
        Zicl_Value argv[3];
        CHECK(Zicl_NewString(&argv[0], "a", 1) == ZICL_OK);
        argv[1] = Zicl_NewLong(2);       /* inline, no object */
        CHECK(Zicl_NewString(&argv[2], "c", 1) == ZICL_OK);
        Zicl_ReleaseArrayItems(argv, 3);
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
        Zicl_Release(h);
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
        Zicl_Release(lv);
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
        Zicl_Release(s5);
        Zicl_Release(shi);
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
        Zicl_Release(lv);
    }

    /* List copy-on-write: dup branch (shared, copy once, batch, write back). */
    {
        Zicl_List *list = Zicl_NewList(NULL, 0);
        CHECK(Zicl_ListAppend(list, Zicl_NewLong(10)) == ZICL_OK);
        CHECK(Zicl_ListAppend(list, Zicl_NewLong(20)) == ZICL_OK);
        Zicl_Value lv = Zicl_BoxList(list);
        Zicl_Value shared = Zicl_Borrow(lv);  /* refcount 2 */

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
        Zicl_Release(shared);  /* the new copy */
        Zicl_Release(lv);       /* the original, now refcount 1 */
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

        Zicl_Release(lv);
    }

    /* NewList from an array borrows the inputs. */
    {
        Zicl_Value in[2] = { Zicl_NewLong(7), Zicl_NewLong(8) };
        Zicl_List *list = Zicl_NewList(in, 2);
        CHECK(list != NULL);
        CHECK(Zicl_ListLength(list) == 2);
        Zicl_Value lv = Zicl_BoxList(list);
        CHECK(item_as_long(interp, &lv, 0) == 7);
        Zicl_Release(lv);
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
        Zicl_Release(lv);
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
        Zicl_OptionalValue got = Zicl_DictGet(interp, &dv, k1);
        CHECK(!Zicl_IsNone(got));
        Zicl_Release(k1);
        Zicl_Release(dv);
    }

    /* Dict copy-on-write: dup branch (shared, copy once, write back). */
    {
        Zicl_Value kv[2] = { Zicl_NewLong(10), Zicl_NewLong(100) };
        Zicl_Dict *dict = Zicl_NewDict(kv, 2);
        Zicl_Value dv = Zicl_BoxDict(dict);
        Zicl_Value shared = Zicl_Borrow(dv);  /* refcount 2 */

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
        Zicl_OptionalValue got = Zicl_DictGet(interp, &shared, k20);
        CHECK(!Zicl_IsNone(got));  /* new key present in the copy */
        Zicl_Release(k20);
        Zicl_Release(shared);  /* the new copy */
        Zicl_Release(dv);       /* the original, now refcount 1 */
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
        CHECK(Zicl_IsNone(Zicl_DictGet(interp, &dv, k1)));  /* gone */
        Zicl_Release(k1);
        Zicl_Release(dv);
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
        Zicl_Release(k1);
        Zicl_Release(dv);
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
        Zicl_Release(s);
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
        Zicl_Release(s);
    }

    /* Source copy-on-write: dup branch (shared, copy once, write back). */
    {
        Zicl_Value s;
        CHECK(Zicl_NewString(&s, "more script", 11) == ZICL_OK);
        CHECK(Zicl_AttachSource(&s, "other.tcl", 1) == ZICL_OK);
        Zicl_Value shared = Zicl_Borrow(s);  /* refcount 2 */

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
        Zicl_Release(shared);  /* the new copy */
        Zicl_Release(s);       /* the original, now refcount 1 */
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

    Zicl_InterpDestroy(interp);
    Zicl_LeakCheckAll();
    Zicl_DeinitAll();

    printf("c API smoke test passed\n");
    return 0;
}
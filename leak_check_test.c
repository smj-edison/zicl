/* leak_check_test.c -- tests + demo for the generic leak checker.
 *
 * Build:
 *   cc -rdynamic -O0 -g leak_check.c leak_check_test.c -o leak_check_test -ldl
 * Run:
 *   ./leak_check_test
 *
 * The first five tests are direct ports of the GraphWalker tests in
 * memutil.zig:666-744 (single edge, two children, cycle, diamond, leaf root).
 * The last test deliberately leaks a Node, calls leakchk_capture, and writes the
 * dot graph and per-object traces to stderr, then calls leakchk_dump_last_touched
 * to exercise the panic-path dump.
 *
 * To verify the compile-out path:
 *   cc -DLEAKCHK_ENABLED=0 leak_check.c leak_check_test.c -o leak_check_test_off
 *   ./leak_check_test_off
 *
 * --- Resolving stack addresses with addr2line ----------------------------
 *
 * The dumps print each frame as `0x<addr> in <symbol>+<off> (<module>)` using
 * dladdr(). dladdr only sees the dynamic symbol table, so static functions
 * show up as `??`, and it never gives file:line. addr2line uses the DWARF
 * debug info (-g), so it resolves statics and prints source locations.
 *
 * addr2line wants link-time addresses. On a PIE binary (the default on Linux)
 * ASLR rebases the runtime addresses the dump prints, so they won't resolve
 * directly. Build with -no-pie so the runtime addresses match the binary:
 *
 *   cc -no-pie -rdynamic -O0 -g leak_check.c leak_check_test.c \
 *       -o leak_check_test -ldl
 *
 * Then collect the frame addresses (lines containing ` in ` -- this skips the
 * `addr=0x...` heap-pointer lines, which are not code) and feed them to
 * addr2line:
 *
 *   ./leak_check_test 2>&1 \
 *       | grep -E ' in ' \
 *       | grep -oE '0x[0-9a-f]+' \
 *       | sort -u \
 *       | xargs addr2line -e ./leak_check_test -f -p -i -C
 *
 * Flag recap:
 *   -f   print the function name
 *   -p   pretty-print as `function at file:line`
 *   -i   follow inlined frames
 *   -C   demangle C++ symbol names (harmless for C)
 *
 * libc frames (e.g. __libc_start_main) resolve to `??:0` unless you have
 * libc debug symbols installed; that's expected. If you kept PIE, subtract the
 * load base (the lowest code address in the dump) from each address before
 * feeding it to addr2line, or just rebuild with -no-pie.
 */
#include "leak_check.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(cond)                                                           \
    do {                                                                      \
        if (!(cond)) {                                                        \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);   \
            abort();                                                          \
        }                                                                     \
    } while (0)

#if LEAKCHK_ENABLED

/* A node with up to two named children (`a`, `b`) for exercising cycles,
 * diamonds, and the two-child case. `name` is for human inspection only.
 * Mirrors StructIteratorTest.Node in memutil.zig. */
typedef struct Node {
    const char *name;
    struct Node *a;
    struct Node *b;
} Node;

/* The convention the LEAKCHK_ENUM macro expects: a type T declares its walker
 * as `T_enumerate`. Casts the void* node back to the typed struct and names the
 * children, exactly like Object.enumerateStruct in heap.zig:927. */
static void Node_enumerate(leakchk_walker_t *wk, const leakchk_node_info_t *info) {
    const Node *self = (const Node *)info->node;
    if (self->a) leakchk_follow_node(wk, info, "a", self->a, LEAKCHK_META(Node));
    if (self->b) leakchk_follow_node(wk, info, "b", self->b, LEAKCHK_META(Node));
}

static void test_single_edge(void) {
    leakchk_walker_t wk;
    leakchk_walker_init(&wk);
    Node bar = { "bar", NULL, NULL };
    Node foo = { "foo", &bar, NULL };
    leakchk_follow_unparented(&wk, &foo, LEAKCHK_META(Node));

    CHECK(leakchk_walker_node_count(&wk) == 2);
    CHECK(leakchk_walker_contains(&wk, &foo));
    CHECK(leakchk_walker_contains(&wk, &bar));
    CHECK(wk._edges_len == 1);
    CHECK(wk._edges[0].from == (const void *)&foo);
    CHECK(wk._edges[0].to == (const void *)&bar);
    CHECK(strcmp(wk._edges[0].field_name, "a") == 0);
    leakchk_walker_free(&wk);
}

static void test_two_children(void) {
    leakchk_walker_t wk;
    leakchk_walker_init(&wk);
    Node b = { "b", NULL, NULL };
    Node c = { "c", NULL, NULL };
    Node a = { "a", &b, &c };
    leakchk_follow_unparented(&wk, &a, LEAKCHK_META(Node));

    CHECK(leakchk_walker_node_count(&wk) == 3);
    CHECK(wk._edges_len == 2);
    leakchk_walker_free(&wk);
}

static void test_cycle(void) {
    leakchk_walker_t wk;
    leakchk_walker_init(&wk);
    Node a = { "a", NULL, NULL };
    Node b = { "b", NULL, NULL };
    a.a = &b;
    b.a = &a; /* back-edge: a -> b -> a */
    leakchk_follow_unparented(&wk, &a, LEAKCHK_META(Node));

    /* Exactly two nodes visited -- the back-edge did not re-enter a. */
    CHECK(leakchk_walker_node_count(&wk) == 2);
    /* Both directions recorded, because edges are recorded before the visited
     * check gates recursion. */
    CHECK(wk._edges_len == 2);
    leakchk_walker_free(&wk);
}

static void test_diamond(void) {
    leakchk_walker_t wk;
    leakchk_walker_init(&wk);
    Node d = { "d", NULL, NULL };
    Node b = { "b", &d, NULL };
    Node c = { "c", &d, NULL };
    Node a = { "a", &b, &c };
    leakchk_follow_unparented(&wk, &a, LEAKCHK_META(Node));

    /* d is visited once, but both edges into it are recorded. */
    CHECK(leakchk_walker_node_count(&wk) == 4);
    CHECK(wk._edges_len == 4);
    leakchk_walker_free(&wk);
}

static void test_leaf_root(void) {
    leakchk_walker_t wk;
    leakchk_walker_init(&wk);
    Node leaf = { "leaf", NULL, NULL };
    leakchk_follow_unparented(&wk, &leaf, LEAKCHK_META(Node));

    CHECK(leakchk_walker_node_count(&wk) == 1);
    CHECK(leakchk_walker_contains(&wk, &leaf));
    CHECK(wk._edges_len == 0);
    leakchk_walker_free(&wk);
}

/* Directly exercise the global log read accessors without capturing. */
static void test_global_log(void) {
    leakchk_init();

    int dummy = 0;
    const void *ptr = &dummy;
    leakchk_meta_t imeta = { "int", NULL };
    leakchk_trace(LEAKCHK_ALLOC, ptr, imeta, "alloc ev %d", 1);
    leakchk_trace(LEAKCHK_FREE, ptr, imeta, "free ev %d", 2);
    leakchk_trace(LEAKCHK_OTHER, NULL, imeta, "non-pointer %d", 3);

    CHECK(leakchk_log_count() == 3);
    /* ALLOC then FREE cancels; OTHER does not touch the balance. */
    CHECK(leakchk_alloc_count() == 0);

    leakchk_event_view_t ev;
    CHECK(leakchk_log_at(0, &ev) == 1);
    CHECK(ev.category == LEAKCHK_ALLOC);
    CHECK(ev.ptr == ptr);
    CHECK(ev.message != NULL && strstr(ev.message, "alloc") != NULL);

    CHECK(leakchk_log_at(1, &ev) == 1);
    CHECK(ev.category == LEAKCHK_FREE);
    CHECK(ev.ptr == ptr);

    CHECK(leakchk_log_at(2, &ev) == 1);
    CHECK(ev.category == LEAKCHK_OTHER);
    CHECK(ev.ptr == NULL);

    /* Out of range returns 0 and leaves `ev` untouched. */
    CHECK(leakchk_log_at(3, &ev) == 0);

    leakchk_deinit();
    /* After deinit the log reads as empty. */
    CHECK(leakchk_log_count() == 0);
    CHECK(leakchk_alloc_count() == 0);
}

/* Find an object_log by ptr in the flat array, or NULL. */
static const leakchk_object_log_view_t *find_log(const leakchk_result_t *r,
                                                 const void *ptr) {
    for (size_t i = 0; i < r->object_log_count; i++)
        if (r->object_logs[i].ptr == ptr) return &r->object_logs[i];
    return NULL;
}

/* Deliberately leak a Node, then capture and dump. The freed Node below
 * exercises the matched-alloc/free path: it must _not_ appear in the dump, and
 * its object_log must show leaked == 0 with both events. */
static void test_leak_capture(void) {
    leakchk_init();

    Node *leaked = malloc(sizeof(Node));
    CHECK(leaked != NULL);
    leaked->name = "leaked";
    leaked->a = NULL;
    leaked->b = NULL;
    leakchk_trace(LEAKCHK_ALLOC, leaked, LEAKCHK_META(Node),
                  "allocated Node at %p", (void *)leaked);

    Node *matched = malloc(sizeof(Node));
    CHECK(matched != NULL);
    matched->name = "matched";
    matched->a = NULL;
    matched->b = NULL;
    leakchk_trace(LEAKCHK_ALLOC, matched, LEAKCHK_META(Node),
                  "allocated Node at %p", (void *)matched);
    leakchk_trace(LEAKCHK_FREE, matched, LEAKCHK_META(Node),
                  "freed Node at %p", (void *)matched);

    /* A non-pointer trace entry must be skipped by capture, not crash it. It
     * has no enumerate fn, so build a meta with a NULL function pointer. */
    leakchk_trace(LEAKCHK_OTHER, NULL, (leakchk_meta_t){"int", NULL},
                  "non-pointer event %d", 42);

    leakchk_result_t *r = leakchk_capture();
    CHECK(r != NULL);
    CHECK(leakchk_walker_contains(&r->walker, leaked));
    CHECK(!leakchk_walker_contains(&r->walker, matched));

    /* object_logs: the leaked ptr has one ALLOC event and leaked set; the
     * matched ptr has ALLOC+FREE and leaked clear; the NULL-ptr OTHER entry is
     * skipped, so there are exactly two object_logs. */
    CHECK(r->object_log_count == 2);
    const leakchk_object_log_view_t *llog = find_log(r, leaked);
    CHECK(llog != NULL);
    CHECK(llog->leaked == 1);
    CHECK(llog->event_count == 1);
    CHECK(llog->events[0].category == LEAKCHK_ALLOC);
    const leakchk_object_log_view_t *mlog = find_log(r, matched);
    CHECK(mlog != NULL);
    CHECK(mlog->leaked == 0);
    CHECK(mlog->event_count == 2);
    CHECK(mlog->events[0].category == LEAKCHK_ALLOC);
    CHECK(mlog->events[1].category == LEAKCHK_FREE);
    /* A leaf leak: only the leaked node, no edges. */
    CHECK(r->node_count == 1);
    CHECK(r->nodes[0].ptr == leaked);
    CHECK(r->nodes[0].is_synthetic == 0);
    CHECK(r->walker._edges_len == 0);

    fprintf(stderr, "\n--- dump_dot ---\n");
    leakchk_result_dump_dot(r, 2);
    fprintf(stderr, "\n--- dump_details ---\n");
    leakchk_result_dump_details(r, 2);
    fprintf(stderr, "\n--- dump_last_touched ---\n");
    leakchk_dump_last_touched(2);

    leakchk_result_free(r);
    free(matched);
    free(leaked);
    leakchk_deinit();
}

/* Exercise the unified edges+nodes+object_logs surface on a graph with a
 * reachable child that is itself never traced. Determining that the parent is
 * a "root" is left to the caller: it is the only object_log with leaked set. */
static void test_unified_nodes(void) {
    leakchk_init();

    Node child = { "child", NULL, NULL };
    Node *parent = malloc(sizeof(Node));
    CHECK(parent != NULL);
    parent->name = "parent";
    parent->a = &child;
    parent->b = NULL;
    leakchk_trace(LEAKCHK_ALLOC, parent, LEAKCHK_META(Node),
                  "allocated Node at %p", (void *)parent);

    Node *matched = malloc(sizeof(Node));
    CHECK(matched != NULL);
    matched->name = "matched";
    matched->a = NULL;
    matched->b = NULL;
    leakchk_trace(LEAKCHK_ALLOC, matched, LEAKCHK_META(Node),
                  "allocated Node at %p", (void *)matched);
    leakchk_trace(LEAKCHK_FREE, matched, LEAKCHK_META(Node),
                  "freed Node at %p", (void *)matched);

    leakchk_result_t *r = leakchk_capture();
    CHECK(r != NULL);

    /* The graph walk reaches parent and child, so two nodes and one edge. */
    CHECK(r->node_count == 2);
    CHECK(r->walker._edges_len == 1);
    CHECK(r->walker._edges[0].from == (const void *)parent);
    CHECK(r->walker._edges[0].to == (const void *)&child);
    CHECK(strcmp(r->walker._edges[0].field_name, "a") == 0);

    /* The child was reached but never traced, so it has no object_log; the
     * parent and matched do. */
    CHECK(r->object_log_count == 2);
    CHECK(find_log(r, parent) != NULL);
    CHECK(find_log(r, &child) == NULL);
    const leakchk_object_log_view_t *plog = find_log(r, parent);
    CHECK(plog->leaked == 1);
    CHECK(find_log(r, matched)->leaked == 0);

    leakchk_result_free(r);
    free(matched);
    free(parent);
    leakchk_deinit();
}

int main(void) {
    test_single_edge();
    test_two_children();
    test_cycle();
    test_diamond();
    test_leaf_root();
    test_global_log();
    test_leak_capture();
    test_unified_nodes();
    printf("leak_check_test: all checks passed\n");
    return 0;
}

#else /* LEAKCHK_ENABLED == 0 */

/* Compile-out sanity: every public function is a no-op, so the program must
 * still link and run. The Node type and shape tests are skipped entirely. */
int main(void) {
    leakchk_init();
    leakchk_trace(LEAKCHK_ALLOC, (const void *)0x1, (leakchk_meta_t){"int", NULL},
                  "noop %d", 1);
    leakchk_result_t *r = leakchk_capture();        /* returns NULL */
    leakchk_result_dump_dot(r, 2);                  /* no-op */
    leakchk_result_dump_details(r, 2);              /* no-op */
    leakchk_result_free(r);                         /* no-op */
    leakchk_dump_last_touched(2);                   /* no-op */
    leakchk_deinit();
    printf("leak_check_test (disabled): no-op path ok\n");
    return 0;
}

#endif
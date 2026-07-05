/* leak_check.c -- generic C leak checker, backported from zicl's leak_check.zig
 * + memutil.zig GraphWalker. See leak_check.h for the public surface and the
 * design rationale.
 *
 * The log is keyed on (ptr, type_name, enumerate_fn) instead of a zicl Value,
 * so the checker tracks any typed allocation, not just Objects. StructIterator
 * and GraphWalker are merged into leakchk_walker_t (no vtable): the walker is
 * the only visitor here, so the indirection just added noise.
 *
 * TODO: log overfill currently panics (fail fast and loud). Better long-term
 * options, deferred for now:
 *   - segment/rope growth: when the current segment fills, threads synchronize
 *     on a mutex to allocate and link the next segment, so the log never drops
 *     and never aborts a live program;
 *   - log compaction under a mutex: drop redundant entries (e.g. matched
 *     alloc/free pairs) when the log nears capacity, preserving the recent
 *     history that actually matters for a leak dump.
 * Both trade simplicity for liveness; panic is the simple default.
 */
/* _GNU_SOURCE pulls in Dl_info/dladdr (POSIX) and SA_RESETHAND (GNU), which
 * are otherwise hidden under a strict -std. Must be defined before ANY system
 * header include (leak_check.h pulls in <stddef.h>), so it goes first. */
#define _GNU_SOURCE

#include "leak_check.h"

#if LEAKCHK_ENABLED

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdint.h>
#include <unistd.h>
#include <execinfo.h>
#include <dlfcn.h>
#include <signal.h>

/* ---- Log entry + globals ---------------------------------------------- *
 * The log is a fixed BSS array; it does _not_ wrap (wrapping would silently
 * drop important messages). Each writer claims a unique slot via an atomic
 * fetch_add on g_next; on overfill we panic. Messages are malloc'd to avoid
 * wasting a fixed per-entry buffer (most messages are short). */
typedef struct {
    _Atomic int initialized;
    leakchk_category_t category;
    const void *ptr;
    const char *type_name;
    leakchk_enumerate_fn enumerate;
    void *stack[LEAKCHK_STACK_DEPTH];
    int stack_n;
    char *message;
    int message_owned; /* 0 when message is a static fallback literal. */
} leakchk_log_entry_t;

static leakchk_log_entry_t g_log[LEAKCHK_LOG_CAPACITY];
static _Atomic size_t g_next = 0;
static _Atomic ptrdiff_t g_alloc_count = 0;
/* Re-entrancy guard for leakchk_dump_last_touched: the dump runs in signal
 * context, so a fault inside it would re-enter the handler and loop. Mirrors
 * leak_check.zig:284. */
static _Atomic int g_dump_in_progress = 0;

static void leakchk_panic(const char *msg) {
    dprintf(2, "leakchk panic: %s\n", msg);
    abort();
}

/* ---- Lifecycle -------------------------------------------------------- */
void leakchk_init(void) {
    /* Static BSS is already zero on first use; this is for re-init after
     * deinit (e.g. between test runs). Counters go to zero; entries' messages
     * are freed in deinit, so initialized flags are already clear there. */
    atomic_store(&g_next, 0);
    atomic_store(&g_alloc_count, 0);
}

void leakchk_deinit(void) {
    size_t n = atomic_load(&g_next);
    for (size_t i = 0; i < n && i < LEAKCHK_LOG_CAPACITY; i++) {
        leakchk_log_entry_t *e = &g_log[i];
        if (atomic_load_explicit(&e->initialized, memory_order_acquire)) {
            if (e->message_owned) free(e->message);
            e->message = NULL;
            e->message_owned = 0;
            atomic_store_explicit(&e->initialized, 0, memory_order_release);
        }
    }
    atomic_store(&g_next, 0);
    atomic_store(&g_alloc_count, 0);
}

/* ---- Ring log --------------------------------------------------------- */
void leakchk_trace(leakchk_category_t cat, const void *ptr,
                   leakchk_meta_t meta, const char *fmt, ...) {
    if (cat == LEAKCHK_ALLOC) atomic_fetch_add(&g_alloc_count, 1);
    else if (cat == LEAKCHK_FREE) atomic_fetch_sub(&g_alloc_count, 1);

    size_t slot = atomic_fetch_add(&g_next, 1);
    if (slot >= LEAKCHK_LOG_CAPACITY) {
        leakchk_panic("log full; raise -DLEAKCHK_LOG_CAPACITY or implement "
                      "segment growth (see TODO in leak_check.c)");
    }
    leakchk_log_entry_t *e = &g_log[slot];
    e->category = cat;
    e->ptr = ptr;
    e->type_name = meta.type_name;
    e->enumerate = meta.enumerate;
    e->stack_n = backtrace(e->stack, LEAKCHK_STACK_DEPTH);

    va_list ap, ap2;
    va_start(ap, fmt);
    va_copy(ap2, ap);
    int n = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (n < 0) {
        e->message = (char *)"<leakchk: format error>";
        e->message_owned = 0;
    } else {
        char *buf = malloc((size_t)n + 1);
        if (!buf) {
            e->message = (char *)"<leakchk: oom>";
            e->message_owned = 0;
        } else {
            vsnprintf(buf, (size_t)n + 1, fmt, ap2);
            e->message = buf;
            e->message_owned = 1;
        }
    }
    va_end(ap2);
    atomic_store_explicit(&e->initialized, 1, memory_order_release);
}

/* ---- Global log read accessors ---------------------------------------- *
 * Read-only views over g_log so callers (and tests) can inspect what was
 * traced without capturing. The views borrow pointers into the fixed BSS log,
 * which lives for the program's lifetime. */
size_t leakchk_log_count(void) {
    size_t n = atomic_load(&g_next);
    return n > LEAKCHK_LOG_CAPACITY ? LEAKCHK_LOG_CAPACITY : n;
}

ptrdiff_t leakchk_alloc_count(void) {
    return atomic_load(&g_alloc_count);
}

int leakchk_log_at(size_t i, leakchk_event_view_t *out) {
    if (i >= leakchk_log_count()) return 0;
    leakchk_log_entry_t *e = &g_log[i];
    if (atomic_load_explicit(&e->initialized, memory_order_acquire) == 0)
        return 0;
    out->category = e->category;
    out->ptr = e->ptr;
    out->type_name = e->type_name;
    out->message = e->message;
    out->stack = e->stack;
    out->stack_n = e->stack_n;
    return 1;
}

/* ---- ptr -> void* open-addressing hashmap ----------------------------- *
 * Used twice: the walker's nodes (value = leakchk_node_t *) and the capture
 * object_logs (value = obj_log *). No external dependency. */
typedef struct {
    const void **keys; /* NULL slot = empty. */
    void **vals;
    size_t cap;
    size_t count;
} ptrmap;

static size_t ptr_hash(const void *p) {
    uintptr_t x = (uintptr_t)p;
    x ^= x >> 16;
    x *= 0x85ebca6bu;
    x ^= x >> 13;
    return (size_t)x;
}

static void ptrmap_init(ptrmap *m) {
    m->keys = NULL;
    m->vals = NULL;
    m->cap = 0;
    m->count = 0;
}

static void ptrmap_free(ptrmap *m) {
    free(m->keys);
    free(m->vals);
    m->keys = NULL;
    m->vals = NULL;
    m->cap = 0;
    m->count = 0;
}

static int ptrmap_grow(ptrmap *m, size_t newcap) {
    const void **nk = calloc(newcap, sizeof(void *));
    void **nv = calloc(newcap, sizeof(void *));
    if (!nk || !nv) {
        free(nk);
        free(nv);
        return -1;
    }
    for (size_t i = 0; i < m->cap; i++) {
        if (m->keys[i]) {
            size_t h = ptr_hash(m->keys[i]) & (newcap - 1);
            while (nk[h]) h = (h + 1) & (newcap - 1);
            nk[h] = m->keys[i];
            nv[h] = m->vals[i];
        }
    }
    free(m->keys);
    free(m->vals);
    m->keys = nk;
    m->vals = nv;
    m->cap = newcap;
    return 0;
}

/* Returns a pointer to the value slot for `key`, inserting an empty slot if
 * absent. Returns NULL on OOM. */
static void **ptrmap_get_or_put(ptrmap *m, const void *key) {
    if (m->cap == 0) {
        if (ptrmap_grow(m, 16)) return NULL;
    } else if (m->count * 4 >= m->cap * 3) {
        if (ptrmap_grow(m, m->cap * 2)) return NULL;
    }
    size_t mask = m->cap - 1;
    size_t h = ptr_hash(key) & mask;
    while (m->keys[h]) {
        if (m->keys[h] == key) return &m->vals[h];
        h = (h + 1) & mask;
    }
    m->keys[h] = key;
    m->vals[h] = NULL;
    m->count++;
    return &m->vals[h];
}

static void *ptrmap_get(ptrmap *m, const void *key) {
    if (m->cap == 0) return NULL;
    size_t mask = m->cap - 1;
    size_t h = ptr_hash(key) & mask;
    while (m->keys[h]) {
        if (m->keys[h] == key) return m->vals[h];
        h = (h + 1) & mask;
    }
    return NULL;
}

/* ---- Walker (merged GraphWalker + StructIterator) -------------------- *
 * visit_node records the parent->child edge, dedups the node (cycle and
 * diamond guard -- the edge is recorded _before_ the dedup check, matching
 * memutil.zig:636, so both edges into a shared child survive while the child
 * is only walked once), stores the node, and calls the type's enumerate_struct
 * to name its children. */
static void walker_visit(leakchk_walker_t *wk, const leakchk_node_info_t *info,
                         const char *edge_from);
static void walker_free_nodes(leakchk_walker_t *wk);

static void walker_visit(leakchk_walker_t *wk, const leakchk_node_info_t *info,
                         const char *edge_from) {
    if (info->parent_info) {
        if (wk->_edges_len == wk->_edges_cap) {
            size_t ncap = wk->_edges_cap ? wk->_edges_cap * 2 : 16;
            leakchk_edge_t *ne = realloc(wk->_edges, ncap * sizeof(*ne));
            if (!ne) leakchk_panic("OOM growing walker edges");
            wk->_edges = ne;
            wk->_edges_cap = ncap;
        }
        wk->_edges[wk->_edges_len++] = (leakchk_edge_t){
            .from = info->parent_info->node,
            .to = info->node,
            .field_name = edge_from,
        };
    }
    ptrmap *nodes = wk->_nodes;
    if (ptrmap_get(nodes, info->node)) return; /* already walked: cycle/diamond */
    leakchk_node_t *node = malloc(sizeof(*node));
    if (!node) leakchk_panic("OOM allocating walker node");
    *node = (leakchk_node_t){
        .type_name = info->type_name,
        .as_string = info->as_string,
        .is_synthetic = info->is_synthetic,
    };
    void **slot = ptrmap_get_or_put(nodes, info->node);
    if (!slot) leakchk_panic("OOM growing walker nodes");
    *slot = node;
    wk->_nodes_count = nodes->count;
    if (info->enumerate_struct) info->enumerate_struct(wk, info);
}

void leakchk_walker_init(leakchk_walker_t *wk) {
    ptrmap *m = malloc(sizeof(*m));
    if (!m) leakchk_panic("OOM allocating walker node map");
    ptrmap_init(m);
    wk->_nodes = m;
    wk->_nodes_count = 0;
    wk->_edges = NULL;
    wk->_edges_len = 0;
    wk->_edges_cap = 0;
}

void leakchk_walker_free(leakchk_walker_t *wk) {
    walker_free_nodes(wk);
    wk->_nodes_count = 0;
}

size_t leakchk_walker_node_count(const leakchk_walker_t *wk) {
    return wk->_nodes_count;
}

int leakchk_walker_contains(const leakchk_walker_t *wk, const void *node) {
    return ptrmap_get(wk->_nodes, node) != NULL;
}

static void walker_free_nodes(leakchk_walker_t *wk) {
    ptrmap *m = wk->_nodes;
    for (size_t i = 0; i < m->cap; i++) {
        if (m->keys[i]) free(m->vals[i]);
    }
    ptrmap_free(m);
    free(m);
    wk->_nodes = NULL;
    free(wk->_edges);
    wk->_edges = NULL;
}

/* ---- Walk helpers ----------------------------------------------------- *
 * Mirror memutil.zig's followUnparentedNode / followNode / addField. Each
 * builds a node_info and hands it to walker_visit. Synthetic leaves get a
 * unique dummy pointer (a 1-byte malloc) so they dedup and edge correctly
 * (mirrors ctx.arena.create(u8) in memutil.zig:565-595).
 *
 * The duped `as_string` and the dummy pointers for synthetic leaves are
 * malloc'd here and intentionally never freed: they live only for the dump and
 * are scratch a leak checker can afford to leak. Keeping them means the walker
 * has no arena to thread around. */
void leakchk_follow_unparented(leakchk_walker_t *wk, const void *ptr,
                               leakchk_meta_t meta) {
    leakchk_node_info_t info = {
        .parent_info = NULL,
        .node = ptr,
        .enumerate_struct = meta.enumerate,
        .type_name = meta.type_name,
        .as_string = NULL,
        .is_synthetic = 0,
    };
    walker_visit(wk, &info, NULL);
}

void leakchk_follow_node(leakchk_walker_t *wk,
                         const leakchk_node_info_t *parent, const char *edge,
                         const void *ptr, leakchk_meta_t meta) {
    leakchk_node_info_t info = {
        .parent_info = parent,
        .node = ptr,
        .enumerate_struct = meta.enumerate,
        .type_name = meta.type_name,
        .as_string = NULL,
        .is_synthetic = 0,
    };
    walker_visit(wk, &info, edge);
}

void leakchk_add_field_string(leakchk_walker_t *wk,
                              const leakchk_node_info_t *parent,
                              const char *edge, const char *val) {
    /* Dupe the string so it outlives the caller's frame. Leaked by design. */
    size_t n = strlen(val) + 1;
    char *dup = malloc(n);
    if (!dup) leakchk_panic("OOM duping field string");
    memcpy(dup, val, n);
    void *dummy = malloc(1);
    if (!dummy) leakchk_panic("OOM allocating synthetic node");
    leakchk_node_info_t info = {
        .parent_info = parent,
        .node = dummy,
        .enumerate_struct = NULL,
        .type_name = "const char *",
        .as_string = dup,
        .is_synthetic = 1,
    };
    walker_visit(wk, &info, edge);
}

void leakchk_add_field_fmt(leakchk_walker_t *wk,
                           const leakchk_node_info_t *parent,
                           const char *edge, const char *type_name,
                           const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (n < 0) n = 15;
    char *buf = malloc((size_t)n + 1);
    if (!buf) leakchk_panic("OOM formatting field");
    va_start(ap, fmt);
    vsnprintf(buf, (size_t)n + 1, fmt, ap);
    va_end(ap);
    void *dummy = malloc(1);
    if (!dummy) leakchk_panic("OOM allocating synthetic node");
    leakchk_node_info_t info = {
        .parent_info = parent,
        .node = dummy,
        .enumerate_struct = NULL,
        .type_name = type_name,
        .as_string = buf,
        .is_synthetic = 1,
    };
    walker_visit(wk, &info, edge);
}

/* ---- Capture ---------------------------------------------------------- *
 * Group the log by ptr into object_logs, mark each ptr leaked/not-leaked
 * (alloc sets leaked, free clears it -- mirrors leak_check.zig:228-232), then
 * walk the graph from each leaked ptr using the entry's stored type_name and
 * enumerate_fn. */
typedef struct {
    const leakchk_log_entry_t **entries; /* pointers into g_log. */
    size_t len, cap;
    int leaked;
    const char *type_name;
    leakchk_enumerate_fn enumerate;
} obj_log;

static void obj_log_append(obj_log *l, const leakchk_log_entry_t *e) {
    if (l->len == l->cap) {
        size_t ncap = l->cap ? l->cap * 2 : 8;
        const leakchk_log_entry_t **ne =
            realloc(l->entries, ncap * sizeof(*ne));
        if (!ne) leakchk_panic("OOM growing object log");
        l->entries = ne;
        l->cap = ncap;
    }
    l->entries[l->len++] = e;
}

/* Borrow a log entry into a read-only view. The view's pointers alias the
 * fixed BSS log entry, which lives for the program's lifetime. */
static leakchk_event_view_t log_entry_view(const leakchk_log_entry_t *e) {
    leakchk_event_view_t v;
    v.category = e->category;
    v.ptr = e->ptr;
    v.type_name = e->type_name;
    v.message = e->message;
    v.stack = e->stack;
    v.stack_n = e->stack_n;
    return v;
}

/* Build res->object_logs from the logs ptrmap: one flat array of views, each
 * with a malloc'd events array. Frees the ptrmap and its obj_log structs (the
 * entries pointer arrays are superseded by the events arrays). */
static void build_object_logs(leakchk_result_t *res, ptrmap *logs) {
    res->object_logs = NULL;
    res->object_log_count = 0;
    if (logs->count == 0) return;

    leakchk_object_log_view_t *arr =
        malloc(logs->count * sizeof(*arr));
    if (!arr) leakchk_panic("OOM allocating object_logs view array");
    size_t out = 0;
    for (size_t i = 0; i < logs->cap; i++) {
        if (!logs->keys[i]) continue;
        obj_log *l = logs->vals[i];
        leakchk_event_view_t *events =
            malloc(l->len * sizeof(*events));
        if (!events) leakchk_panic("OOM allocating events view array");
        for (size_t j = 0; j < l->len; j++)
            events[j] = log_entry_view(l->entries[j]);
        arr[out].ptr = logs->keys[i];
        arr[out].leaked = l->leaked;
        arr[out].type_name = l->type_name;
        arr[out].events = events;
        arr[out].event_count = l->len;
        out++;
    }
    res->object_logs = arr;
    res->object_log_count = out;
}

/* Build res->nodes from the walker's _nodes ptrmap: one flat array of node
 * views, each carrying its ptr (the hashmap key). */
static void build_nodes(leakchk_result_t *res) {
    ptrmap *nodes = res->walker._nodes;
    res->nodes = NULL;
    res->node_count = 0;
    if (nodes->count == 0) return;

    leakchk_node_view_t *arr = malloc(nodes->count * sizeof(*arr));
    if (!arr) leakchk_panic("OOM allocating nodes view array");
    size_t out = 0;
    for (size_t i = 0; i < nodes->cap; i++) {
        if (!nodes->keys[i]) continue;
        leakchk_node_t *node = nodes->vals[i];
        arr[out].ptr = nodes->keys[i];
        arr[out].type_name = node->type_name;
        arr[out].as_string = node->as_string;
        arr[out].is_synthetic = node->is_synthetic;
        out++;
    }
    res->nodes = arr;
    res->node_count = out;
}

/* Free the logs ptrmap and its obj_log structs (used during capture, then
 * superseded by the flat object_logs array). */
static void free_obj_log_map(ptrmap *logs) {
    for (size_t i = 0; i < logs->cap; i++) {
        if (!logs->keys[i]) continue;
        obj_log *l = logs->vals[i];
        free(l->entries);
        free(l);
    }
    ptrmap_free(logs);
    free(logs);
}

leakchk_result_t *leakchk_capture(void) {
    if (atomic_load(&g_alloc_count) == 0) return NULL;

    leakchk_result_t *res = malloc(sizeof(*res));
    if (!res) leakchk_panic("OOM allocating result");
    /* nodes/edges/object_logs are populated below; init to empty so an error
     * path (none currently, but defensive against future errdefers) frees
     * cleanly. */
    res->nodes = NULL;
    res->node_count = 0;
    res->object_logs = NULL;
    res->object_log_count = 0;
    leakchk_walker_init(&res->walker);

    /* logs is a throwaway ptrmap used to group log entries by ptr; it is freed
     * once the flat object_logs array is built. */
    ptrmap *logs = malloc(sizeof(*logs));
    if (!logs) leakchk_panic("OOM allocating object_logs");
    ptrmap_init(logs);

    size_t n = atomic_load(&g_next);
    if (n > LEAKCHK_LOG_CAPACITY) n = LEAKCHK_LOG_CAPACITY;
    for (size_t i = 0; i < n; i++) {
        leakchk_log_entry_t *e = &g_log[i];
        if (atomic_load_explicit(&e->initialized, memory_order_acquire) == 0)
            continue;
        if (!e->ptr) continue; /* only track entries with a pointer. */
        void **slot = ptrmap_get_or_put(logs, e->ptr);
        if (!slot) leakchk_panic("OOM growing object_logs");
        obj_log *l = *slot;
        if (!l) {
            l = calloc(1, sizeof(*l));
            if (!l) leakchk_panic("OOM allocating obj_log");
            *slot = l;
            l->type_name = e->type_name;
            l->enumerate = e->enumerate;
        }
        obj_log_append(l, e);
        if (e->category == LEAKCHK_ALLOC) {
            l->leaked = 1;
            /* An address can be reused after a free: re-adopt the most recent
             * allocation's type for the graph walk. */
            l->type_name = e->type_name;
            l->enumerate = e->enumerate;
        } else if (e->category == LEAKCHK_FREE) {
            l->leaked = 0;
        }
    }

    /* Walk the graph from every leaked ptr. */
    for (size_t i = 0; i < logs->cap; i++) {
        if (!logs->keys[i]) continue;
        obj_log *l = logs->vals[i];
        if (!l->leaked || !l->enumerate) continue;
        leakchk_follow_unparented(&res->walker, logs->keys[i],
                                  (leakchk_meta_t){ l->type_name, l->enumerate });
    }

    /* Flatten the ptrmaps into the public arrays, then drop the throwaway logs
     * map. The walker's _nodes map stays alive for leakchk_walker_contains. */
    build_object_logs(res, logs);
    free_obj_log_map(logs);
    build_nodes(res);
    return res;
}

/* ---- Output helpers --------------------------------------------------- *
 * Plain dprintf for all dumps: this is a leak-check dump, not a hot path, so
 * the buffered writer from the Zig port was overkill here. dprintf is not
 * async-signal-safe, so a fault inside the panic-path dump could in theory
 * deadlock on a stdio lock; we accept that for the simplicity of one printing
 * path everywhere. */

/* Escape a string as a dot label body (quotes, backslashes, newlines). Ports
 * leak_check.zig:186. Batches normal chars into a stack buffer so we don't
 * issue a dprintf per character. */
static void write_escaped(int fd, const char *s) {
    char buf[256];
    size_t n = 0;
    buf[n++] = '"';
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        if (n > sizeof(buf) - 3) {
            dprintf(fd, "%.*s", (int)n, buf);
            n = 0;
        }
        switch (*p) {
        case '"': buf[n++] = '\\'; buf[n++] = '"'; break;
        case '\\': buf[n++] = '\\'; buf[n++] = '\\'; break;
        case '\n': buf[n++] = '\\'; buf[n++] = 'n'; break;
        default: buf[n++] = (char)*p; break;
        }
    }
    buf[n++] = '"';
    dprintf(fd, "%.*s", (int)n, buf);
}

/* Render a stack frame as `addr in symbol+off (module)` via dladdr. dladdr
 * does not malloc; it consults the dynamic linker's already-loaded tables. */
static void write_frame(int fd, const void *addr) {
    Dl_info info;
    if (dladdr(addr, &info) && info.dli_sname && info.dli_saddr) {
        ptrdiff_t off = (const char *)addr - (const char *)info.dli_saddr;
        dprintf(fd, "    %p in %s+%ld", addr, info.dli_sname, (long)off);
        if (info.dli_fname) dprintf(fd, " (%s)", info.dli_fname);
        dprintf(fd, "\n");
    } else {
        dprintf(fd, "    %p in ??\n", addr);
    }
}

/* ---- dump_dot (ports leak_check.zig:93) ------------------------------- */
void leakchk_result_dump_dot(const leakchk_result_t *r, int fd) {
    if (!r) return;
    dprintf(fd, "digraph leaks {\n");
    dprintf(fd, "  node [shape=box];\n");
    dprintf(fd, "  rankdir=LR;\n");

    for (size_t i = 0; i < r->node_count; i++) {
        const leakchk_node_view_t *node = &r->nodes[i];
        dprintf(fd, "  \"%lx\" [label=",
                (unsigned long)(uintptr_t)node->ptr);
        write_escaped(fd, node->as_string ? node->as_string : node->type_name);
        dprintf(fd, "];\n");
    }

    for (size_t i = 0; i < r->walker._edges_len; i++) {
        leakchk_edge_t *e = &r->walker._edges[i];
        dprintf(fd, "  \"%lx\" -> \"%lx\" [label=",
                (unsigned long)(uintptr_t)e->from,
                (unsigned long)(uintptr_t)e->to);
        write_escaped(fd, e->field_name);
        dprintf(fd, "];\n");
    }
    dprintf(fd, "}\n");
}

/* ---- dump_details (ports leak_check.zig:151) -------------------------- *
 * For each leaked ptr, print every logged event with its stack trace. No
 * string-rep reading -- that's zicl-Object-specific and doesn't belong in the
 * generic version. To get file:line from the addresses below, pipe the binary
 * through addr2line, e.g.:
 *   addr2line -e <binary> -f -p -i <addr1> <addr2> ... */
void leakchk_result_dump_details(const leakchk_result_t *r, int fd) {
    if (!r) return;
    size_t printed = 0;
    for (size_t i = 0; i < r->object_log_count; i++) {
        const leakchk_object_log_view_t *l = &r->object_logs[i];
        if (!l->leaked) continue;
        printed++;
        dprintf(fd, "== Trace for %s addr=%p ==\n",
                l->type_name ? l->type_name : "?", l->ptr);
        for (size_t j = 0; j < l->event_count; j++) {
            const leakchk_event_view_t *e = &l->events[j];
            const char *cat = e->category == LEAKCHK_ALLOC ? "alloc"
                            : e->category == LEAKCHK_FREE ? "free" : "other";
            dprintf(fd, "  [%s] %s\n", cat, e->message ? e->message : "");
            for (int k = 0; k < e->stack_n; k++) write_frame(fd, e->stack[k]);
        }
        dprintf(fd, "\n");
    }
    if (printed == 0) dprintf(fd, "(no leaked objects with traces)\n");
}

/* ---- result_free ------------------------------------------------------ */
void leakchk_result_free(leakchk_result_t *r) {
    if (!r) return;
    for (size_t i = 0; i < r->object_log_count; i++)
        free((void *)r->object_logs[i].events); /* cast: field is const, array is owned */
    free(r->object_logs);
    free(r->nodes);
    walker_free_nodes(&r->walker);
    free(r);
}

/* ---- dump_last_touched (ports leak_check.zig:305) -------------------- *
 * Prints the recent ~15 log entries for context, then the full operation
 * history of the most recently touched pointer. Only reads the log (never
 * traces, never allocates) and renders frames via dladdr. Re-entrancy guarded.
 * Uses dprintf, which is not async-signal-safe; see the note at the top of the
 * output-helpers section. */
void leakchk_dump_last_touched(int fd) {
    if (fd < 0) return;
    /* Swap-to-set: if already true, we re-entered from a fault inside the
     * dump -- bail out rather than recurse. */
    int expected = 0;
    if (!atomic_compare_exchange_strong(&g_dump_in_progress, &expected, 1))
        return;
    /* No defer in C; clear on every return path below. */

    size_t n = atomic_load(&g_next);
    if (n > LEAKCHK_LOG_CAPACITY) n = LEAKCHK_LOG_CAPACITY;
    if (n == 0) {
        dprintf(fd, "(no operations logged)\n");
        atomic_store(&g_dump_in_progress, 0);
        return;
    }

    /* Find the last initialized entry -- the most recent operation. Its ptr is
     * the last-touched pointer, the prime suspect. */
    size_t last_index = SIZE_MAX;
    for (size_t i = n; i > 0;) {
        i--;
        if (atomic_load_explicit(&g_log[i].initialized, memory_order_acquire)) {
            last_index = i;
            break;
        }
    }
    if (last_index == SIZE_MAX) {
        dprintf(fd, "(no initialized log entries)\n");
        atomic_store(&g_dump_in_progress, 0);
        return;
    }
    const leakchk_log_entry_t *last = &g_log[last_index];
    const void *last_ptr = last->ptr;

    dprintf(fd, "== Recent operations (last 15) ==\n");
    for (size_t j = (n >= 15 ? n - 15 : 0); j < n; j++) {
        const leakchk_log_entry_t *e = &g_log[j];
        if (atomic_load_explicit(&e->initialized, memory_order_acquire) == 0)
            continue;
        const char *cat = e->category == LEAKCHK_ALLOC ? "alloc"
                        : e->category == LEAKCHK_FREE ? "free" : "other";
        dprintf(fd, "  [%s] addr=%p %s\n", cat, e->ptr,
                e->message ? e->message : "");
    }

    if (last_ptr) {
        dprintf(fd, "\n== Full trace for last-touched addr=%p ==\n", last_ptr);
        for (size_t k = 0; k < n; k++) {
            const leakchk_log_entry_t *e = &g_log[k];
            if (atomic_load_explicit(&e->initialized, memory_order_acquire) == 0)
                continue;
            if (e->ptr != last_ptr) continue;
            const char *cat = e->category == LEAKCHK_ALLOC ? "alloc"
                            : e->category == LEAKCHK_FREE ? "free" : "other";
            dprintf(fd, "  [%s] %s\n", cat, e->message ? e->message : "");
            for (int s = 0; s < e->stack_n; s++) write_frame(fd, e->stack[s]);
        }
    } else {
        dprintf(fd, "\n(last operation had no object pointer)\n");
    }
    atomic_store(&g_dump_in_progress, 0);
}

/* ---- Optional SIGSEGV/SIGABRT install --------------------------------- *
 * Opt-in. Installs a handler that dumps the last-touched trace to `fd`, then
 * restores the previous disposition and re-raises so the process dies with the
 * original signal. If you manage signals yourself, register your own handler
 * and call leakchk_dump_last_touched directly instead. */
static int g_segv_fd = -1;
static struct sigaction g_prev_segv;
static struct sigaction g_prev_abrt;
static int g_have_segv = 0;
static int g_have_abrt = 0;

static void leakchk_segv_handler(int sig, siginfo_t *info, void *uctx) {
    (void)info;
    (void)uctx;
    leakchk_dump_last_touched(g_segv_fd);
    /* Restore the previous disposition and re-raise so the process dies with
     * the original signal (and any non-leakchk handler still runs). */
    if (sig == SIGSEGV && g_have_segv) sigaction(SIGSEGV, &g_prev_segv, NULL);
    if (sig == SIGABRT && g_have_abrt) sigaction(SIGABRT, &g_prev_abrt, NULL);
    raise(sig);
    _exit(127); /* raise() returned (it shouldn't for these): don't loop. */
}

void leakchk_install_dump_on_segv(int fd) {
    g_segv_fd = fd;
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = leakchk_segv_handler;
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSEGV, &sa, &g_prev_segv) == 0) g_have_segv = 1;
    if (sigaction(SIGABRT, &sa, &g_prev_abrt) == 0) g_have_abrt = 1;
}

#else /* LEAKCHK_ENABLED == 0 */

/* The header already provides no-op static inlines for the public surface when
 * LEAKCHK_ENABLED is 0, so this translation unit is empty. The file still
 * compiles (and exports nothing) so callers can link it unconditionally. */

#endif
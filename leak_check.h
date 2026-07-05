/* leak_check.h -- a generic, standalone leak checker for C.
 *
 * A backport of zicl's leak_check.zig + memutil.zig GraphWalker to plain C,
 * with no dependency on zicl's Value/Object/heap types. The log is keyed on
 * (ptr, type_name, enumerate_fn) instead of a zicl Value, so the checker can
 * track any typed allocation, not just Objects.
 *
 * Usage: call leakchk_init() once at startup, then leakchk_trace() at your
 * alloc/free/refcount sites. At a quiescent point (teardown, test finish) call
 * leakchk_capture() and leakchk_result_dump_dot/dump_details to see what
 * leaked and the operation history that left it dangling. From a signal
 * handler, call leakchk_dump_last_touched() to print the trace of the most
 * recently touched pointer.
 *
 * Build: compile leak_check.c alongside your code. On glibc, backtrace() and
 * dladdr() are in libc and libdl respectively, so link -ldl. Pass -rdynamic so
 * dladdr() can resolve symbols in your own binary. On BSD add -lexecinfo for
 * backtrace().
 *
 * Thread safety: log writes are lock-free (each writer claims a unique slot
 * via an atomic fetch_add). capture() and the dump functions assume a
 * quiescent point -- the same assumption zicl's testFinish makes -- so they do
 * not take a lock over the log.
 *
 * Compile out: define LEAKCHK_ENABLED=0 and every public function becomes a
 * no-op static inline, so call sites compile away with zero cost.
 */
#ifndef LEAKCHK_H
#define LEAKCHK_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Compile-time config (override with -D) --------------------------- */
#ifndef LEAKCHK_ENABLED
#define LEAKCHK_ENABLED 1
#endif
#ifndef LEAKCHK_LOG_CAPACITY
/* Static BSS array, demand-paged (virtual cost only until written). The log
 * does _not_ wrap -- wrapping would silently drop important messages. On
 * overfill, leakchk_trace panics (fail fast and loud) and tells you to raise
 * this. See the TODO in leak_check.c for the segment-growth alternative. */
#define LEAKCHK_LOG_CAPACITY (1 << 18)
#endif
#ifndef LEAKCHK_STACK_DEPTH
#define LEAKCHK_STACK_DEPTH 32
#endif

/* ---- Public types ----------------------------------------------------- */
typedef enum {
    LEAKCHK_ALLOC,
    LEAKCHK_FREE,
    LEAKCHK_OTHER,
} leakchk_category_t;

/* Forward declarations: the walker and node info reference each other and the
 * enumerate fn references both, so the order matters. */
typedef struct leakchk_walker_t leakchk_walker_t;
typedef struct leakchk_node_info_t leakchk_node_info_t;
typedef void (*leakchk_enumerate_fn)(leakchk_walker_t *wk,
                                     const leakchk_node_info_t *info);

/* A type's name + its enumerate fn, bundled so call sites pass one visible
 * argument (LEAKCHK_META) instead of two spliced ones. Passed by value: it is
 * just a pointer pair, so there is no indirection or copy cost. */
typedef struct leakchk_meta_t {
    const char *type_name;
    leakchk_enumerate_fn enumerate;
} leakchk_meta_t;

/* The merged graph walker + struct iterator. zicl split these (StructIterator
 * carried a vtable so multiple visitors could share the walk helpers); here
 * the walker is the only visitor, so the vtable indirection just added noise.
 *
 * The struct internals are exposed so callers building custom visitors (or
 * inspecting a captured result) can read them. The internal hashmap over
 * `nodes` is opaque only because it's an implementation detail of the .c; use
 * leakchk_walker_contains() to query it. */
typedef struct leakchk_edge_t {
    const void *from;
    const void *to;
    const char *field_name;
} leakchk_edge_t;

typedef struct leakchk_node_t {
    const char *type_name;
    const char *as_string; /* NULL unless this is a synthetic leaf. */
    int is_synthetic;
} leakchk_node_t;

struct leakchk_walker_t {
    /* ptr -> leakchk_node_t, the small open-addressing hashmap implemented in
     * the .c. Treated as opaque here; query via leakchk_walker_contains(). */
    void *_nodes;
    size_t _nodes_count;
    /* Edges recorded during the walk. */
    leakchk_edge_t *_edges;
    size_t _edges_len;
    size_t _edges_cap;
};

typedef struct leakchk_node_info_t {
    const leakchk_node_info_t *parent_info;
    const void *node;
    /* Type-specific walker, or NULL for synthetic/leaf nodes. Called by the
     * walker after the node is recorded so the type can name its children. */
    leakchk_enumerate_fn enumerate_struct;
    const char *type_name;
    /* Non-NULL only for synthetic leaf nodes added via leakchk_add_field_*. */
    const char *as_string;
    int is_synthetic;
} leakchk_node_info_t;

/* One logged operation, viewed read-only. `stack` points into the global log's
 * fixed BSS array, so it stays valid for the program's lifetime (the log is
 * never shrunk or moved). */
typedef struct leakchk_event_view_t {
    leakchk_category_t category;
    const void *ptr;
    const char *type_name;
    const char *message;
    void * const *stack;
    int stack_n;
} leakchk_event_view_t;

/* The full operation history for one pointer, plus whether it is currently
 * leaked (an alloc with no matching free). `leaked` is alloc-without-free
 * state -- it is _not_ a "is this a graph root" flag; log order has no
 * relationship to graph roots, so root-ness is for the caller to determine. */
typedef struct leakchk_object_log_view_t {
    const void *ptr;
    int leaked;
    const char *type_name;
    const leakchk_event_view_t *events;
    size_t event_count;
} leakchk_object_log_view_t;

/* A walked graph node. Mirrors memutil.GraphWalker.Node (type_name, as_string,
 * is_synthetic) plus the ptr (the hashmap key in the Zig version). No `is_root`
 * flag is tracked, for the same reason `object_log_view_t.leaked` is not a
 * root flag: the caller figures out roots themselves. */
typedef struct leakchk_node_view_t {
    const void *ptr;
    const char *type_name;
    const char *as_string; /* NULL unless is_synthetic. */
    int is_synthetic;
} leakchk_node_view_t;

/* Result of leakchk_capture(): the unified graph + per-pointer operation logs.
 * The graph edges are the array `walker._edges[0 .. walker._edges_len]`; the
 * nodes (with their ptrs) are the flat `nodes` array; the per-pointer logs are
 * the flat `object_logs` array. This is the "unify the roots with the graph"
 * surface -- everything a caller needs to inspect a leak programmatically. */
typedef struct leakchk_result_t {
    leakchk_walker_t walker;
    leakchk_node_view_t *nodes;
    size_t node_count;
    leakchk_object_log_view_t *object_logs;
    size_t object_log_count;
} leakchk_result_t;

#if LEAKCHK_ENABLED
/* ---- Walk helpers ----------------------------------------------------- *
 * Mirror memutil.zig's followUnparentedNode / followNode / addField. A type's
 * enumerate_struct calls these to name its children. */
void leakchk_follow_unparented(leakchk_walker_t *wk, const void *ptr,
                               leakchk_meta_t meta);
void leakchk_follow_node(leakchk_walker_t *wk,
                         const leakchk_node_info_t *parent, const char *edge,
                         const void *ptr, leakchk_meta_t meta);
/* Synthetic leaf nodes: a child that is a rendered scalar (a string or a
 * formatted value), not a real pointer to walk further. They carry no
 * enumerate fn, so leakchk_add_field_fmt takes a bare type_name. */
void leakchk_add_field_string(leakchk_walker_t *wk,
                              const leakchk_node_info_t *parent,
                              const char *edge, const char *val);
void leakchk_add_field_fmt(leakchk_walker_t *wk,
                           const leakchk_node_info_t *parent,
                           const char *edge, const char *type_name,
                           const char *fmt, ...)
#if defined(__GNUC__)
    __attribute__((format(printf, 5, 6)))
#endif
    ;
void leakchk_walker_init(leakchk_walker_t *wk);
void leakchk_walker_free(leakchk_walker_t *wk);
size_t leakchk_walker_node_count(const leakchk_walker_t *wk);
int leakchk_walker_contains(const leakchk_walker_t *wk, const void *node);

/* ---- Ring log --------------------------------------------------------- */
void leakchk_trace(leakchk_category_t cat, const void *ptr,
                   leakchk_meta_t meta, const char *fmt, ...)
#if defined(__GNUC__)
    __attribute__((format(printf, 4, 5)))
#endif
    ;

/* Read-only access to the global log, for inspection without capturing. */
/* Number of entries written so far (g_next). */
size_t leakchk_log_count(void);
/* Net alloc/free balance (g_alloc_count): +1 per ALLOC, -1 per FREE. */
ptrdiff_t leakchk_alloc_count(void);
/* Fill *out with a read-only view of log entry i. Returns 1 if i is an
 * initialized entry, 0 if i is out of range or the slot is uninitialized. */
int leakchk_log_at(size_t i, leakchk_event_view_t *out);

/* ---- Capture + dump --------------------------------------------------- */
/* Returns NULL when alloc_count is zero (nothing tracked). Otherwise returns
 * a result owned by the caller; free with leakchk_result_free. */
leakchk_result_t *leakchk_capture(void);
void leakchk_result_dump_dot(const leakchk_result_t *r, int fd);
void leakchk_result_dump_details(const leakchk_result_t *r, int fd);
void leakchk_result_free(leakchk_result_t *r);

/* ---- Panic-path dump -------------------------------------------------- *
 * Writes the operation history of the most recently touched pointer, plus the
 * last ~15 log entries for context, to `fd`. Intended for use from a SIGSEGV
 * handler: it only reads the log (never traces, never allocates) and renders
 * frames with dladdr() (not backtrace_symbols, which mallocs). Output goes
 * through dprintf, which is _not_ async-signal-safe, so a fault mid-dump could
 * in theory deadlock on a stdio lock; we accept that for a single printing
 * path. `fd` < 0 means no output. Re-entrancy guarded. */
void leakchk_dump_last_touched(int fd);

/* Optional convenience: install a SIGSEGV/SIGABRT handler that calls
 * leakchk_dump_last_touched(fd) then re-raises. Opt-in -- leakchk_init never
 * calls this. If you already manage signals, register your own handler and
 * call leakchk_dump_last_touched directly instead. */
void leakchk_install_dump_on_segv(int fd);

/* ---- Lifecycle -------------------------------------------------------- */
void leakchk_init(void);
void leakchk_deinit(void);

/* ---- Helper macros ---------------------------------------------------- *
 * C23 has no struct reflection (no field iteration, no typeof-to-string), so
 * enumerate_struct bodies stay hand-written per type. These macros cut the
 * call-site boilerplate of building a leakchk_meta_t by hand. The convention is
 * that a type T declares its walker as
 * `void T_enumerate(leakchk_walker_t *, const leakchk_node_info_t *);`. */
#define LEAKCHK_TYPE(T) ((const char *)(#T))
#define LEAKCHK_ENUM(T) (&(T##_enumerate))
/* The (type_name, enumerate_fn) pair as one visible leakchk_meta_t argument.
 * Use this at trace/follow call sites; use LEAKCHK_TYPE alone for the bare
 * type_name that leakchk_add_field_fmt expects. */
#define LEAKCHK_META(T) ((leakchk_meta_t){ LEAKCHK_TYPE(T), LEAKCHK_ENUM(T) })

#else /* LEAKCHK_ENABLED == 0 */
/* Compile-out: every public function becomes an empty static inline so
 * instrumented call sites compile away. Macros collapse too. */
#include <stdarg.h>
static inline void leakchk_trace(leakchk_category_t cat, const void *ptr,
                                leakchk_meta_t meta,
                                const char *fmt, ...) { (void)cat; (void)ptr; (void)meta; (void)fmt; }
static inline size_t leakchk_log_count(void) { return 0; }
static inline ptrdiff_t leakchk_alloc_count(void) { return 0; }
static inline int leakchk_log_at(size_t i, leakchk_event_view_t *out) { (void)i; (void)out; return 0; }
static inline leakchk_result_t *leakchk_capture(void) { return NULL; }
static inline void leakchk_result_dump_dot(const leakchk_result_t *r, int fd) { (void)r; (void)fd; }
static inline void leakchk_result_dump_details(const leakchk_result_t *r, int fd) { (void)r; (void)fd; }
static inline void leakchk_result_free(leakchk_result_t *r) { (void)r; }
static inline void leakchk_dump_last_touched(int fd) { (void)fd; }
static inline void leakchk_install_dump_on_segv(int fd) { (void)fd; }
static inline void leakchk_init(void) {}
static inline void leakchk_deinit(void) {}
static inline void leakchk_follow_unparented(leakchk_walker_t *wk, const void *ptr,
                                             leakchk_meta_t meta) { (void)wk; (void)ptr; (void)meta; }
static inline void leakchk_follow_node(leakchk_walker_t *wk,
                                       const leakchk_node_info_t *parent, const char *edge,
                                       const void *ptr,
                                       leakchk_meta_t meta) { (void)wk; (void)parent; (void)edge; (void)ptr; (void)meta; }
static inline void leakchk_add_field_string(leakchk_walker_t *wk,
                                            const leakchk_node_info_t *parent,
                                            const char *edge, const char *val) { (void)wk; (void)parent; (void)edge; (void)val; }
static inline void leakchk_add_field_fmt(leakchk_walker_t *wk,
                                         const leakchk_node_info_t *parent,
                                         const char *edge, const char *type_name,
                                         const char *fmt, ...) { (void)wk; (void)parent; (void)edge; (void)type_name; (void)fmt; }
static inline void leakchk_walker_init(leakchk_walker_t *wk) { (void)wk; }
static inline void leakchk_walker_free(leakchk_walker_t *wk) { (void)wk; }
static inline size_t leakchk_walker_node_count(const leakchk_walker_t *wk) { (void)wk; return 0; }
static inline int leakchk_walker_contains(const leakchk_walker_t *wk, const void *node) { (void)wk; (void)node; return 0; }
#undef LEAKCHK_TYPE
#undef LEAKCHK_ENUM
#undef LEAKCHK_META
#define LEAKCHK_TYPE(T) ((const char *)0)
#define LEAKCHK_ENUM(T) ((leakchk_enumerate_fn)0)
#define LEAKCHK_META(T) LEAKCHK_TYPE(T), LEAKCHK_ENUM(T)
#endif

#ifdef __cplusplus
}
#endif

#endif /* LEAKCHK_H */
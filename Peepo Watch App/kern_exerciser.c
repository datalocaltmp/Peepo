// kern_exerciser.c
// watchOS-friendly multithreaded “kernel-interface exerciser”.
// Goal: explore benign VM/Mach/thread/resource state transitions, log everything,
// and make runs replayable via (seed, steps). NOT designed to target known bugs.
//
// Logging:
// - Uses os_log for sysdiagnose/logarchive
// - Also mirrors key logs to your on-screen console via console_log(char *log)
//   (no format strings supported by console_log; we pre-format into a buffer)
//
// Build notes (Xcode):
// - Add this file to your Watch App target.
// - Include kern_exerciser.h in your bridging header / Swift via module map as needed.
// - Some Mach calls may be restricted on watchOS; this file degrades gracefully.
//
// Usage:
//   exerciser_start(seed, duration_seconds, worker_count, steps_per_worker);
//   exerciser_stop();

#include <os/log.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <time.h>
#include <pthread.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <stdlib.h>   // malloc/calloc/free

#if __has_include(<mach/mach.h>)
  #include <mach/mach.h>
  #define HAVE_MACH 1
#else
  #define HAVE_MACH 0
#endif

#if __has_include(<mach/mach_time.h>)
  #include <mach/mach_time.h>
  #define HAVE_MACH_TIME 1
#else
  #define HAVE_MACH_TIME 0
#endif

// Provided by your console logger (must accept a writable char*; no printf-style formatting)
extern void console_log(char *log);

// -------------------- Config knobs --------------------

#ifndef EXERCISER_MAX_REGIONS
#define EXERCISER_MAX_REGIONS 64
#endif

#ifndef EXERCISER_MAX_PORTS
#define EXERCISER_MAX_PORTS 64
#endif

#ifndef EXERCISER_MAX_FDS
#define EXERCISER_MAX_FDS 16
#endif

#ifndef EXERCISER_LOG_BUF
#define EXERCISER_LOG_BUF 512
#endif

// “Global budgets” (coordinator enforces)
static const size_t kMaxTotalMappedBytes = 6 * 1024 * 1024; // 6MB total across all workers
static const int    kMaxTotalPorts       = 64;
static const int    kMaxTotalFDs         = 32;

// Action timeouts (best-effort; we measure & flag slow ops)
static const uint64_t kSlowOpUsec = 25 * 1000; // 25ms

// -------------------- Logging --------------------

static os_log_t g_log;

static inline void log_init(void) {
    if (!g_log) g_log = os_log_create("com.datalocaltmp.exerciser", "kern");
}

// Pre-format + send to console_log(char*)
static void console_log_fmt(const char *fmt, ...) {
    char buf[EXERCISER_LOG_BUF];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    // console_log requires char*, no format string
    console_log(buf);
}

static void log_line(const char *fmt, ...) {
    log_init();

    char buf[EXERCISER_LOG_BUF];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    // Device logs
    os_log_with_type(g_log, OS_LOG_TYPE_DEFAULT, "%{public}s", buf);
    fprintf(stderr, "%s\n", buf);

    // On-screen console
    console_log(buf);
}

static void log_flag(const char *fmt, ...) {
    log_init();

    char buf[EXERCISER_LOG_BUF];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    os_log_with_type(g_log, OS_LOG_TYPE_ERROR, "%{public}s", buf);
    fprintf(stderr, "%s\n", buf);

    console_log(buf);
}

// -------------------- Time --------------------

static inline uint64_t now_abs(void) {
#if HAVE_MACH_TIME
    return mach_continuous_time(); // monotonic
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
#endif
}

// Convert elapsed abs ticks to microseconds (best effort)
static inline uint64_t elapsed_usecs(uint64_t start_abs, uint64_t end_abs) {
#if HAVE_MACH_TIME
    static mach_timebase_info_data_t tbi;
    static atomic_bool tbi_inited = false;

    bool expected = false;
    if (atomic_compare_exchange_strong(&tbi_inited, &expected, true)) {
        mach_timebase_info(&tbi);
    }
    if (tbi.denom != 0) {
        uint64_t diff = end_abs - start_abs;
        __uint128_t ns = (__uint128_t)diff * (__uint128_t)tbi.numer / (__uint128_t)tbi.denom;
        return (uint64_t)(ns / 1000);
    }
#endif
    // fallback: assume abs is ns
    uint64_t diff = end_abs - start_abs;
    return diff / 1000;
}

// -------------------- RNG --------------------

static inline uint32_t xorshift32(uint32_t *s) {
    uint32_t x = *s;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *s = x;
    return x;
}

static inline uint32_t rnd_range(uint32_t *s, uint32_t n) {
    return n ? (xorshift32(s) % n) : 0;
}

static inline uint32_t rnd_bool(uint32_t *s) { return xorshift32(s) & 1u; }

// -------------------- VM flag/prot selection (seed-driven) --------------------
// NOTE: Keep this conservative for watchOS. We only use flags that are typically
// available on Darwin, and we guard optional ones with #ifdef.

static inline int pick_mmap_flags(uint32_t *seed) {
    int flags = MAP_ANON;

    // private vs shared (both are valid for anonymous mappings)
    flags |= (rnd_bool(seed) ? MAP_PRIVATE : MAP_SHARED);

#ifdef MAP_NOCACHE
    if (rnd_range(seed, 4) == 0) flags |= MAP_NOCACHE;
#endif
#ifdef MAP_NORESERVE
    if (rnd_range(seed, 6) == 0) flags |= MAP_NORESERVE;
#endif
#ifdef MAP_HASSEMAPHORE
    if (rnd_range(seed, 10) == 0) flags |= MAP_HASSEMAPHORE;
#endif
    return flags;
}

static inline int pick_vm_prot(uint32_t *seed) {
    // Prefer sane combinations; include PROT_NONE sometimes for state transitions.
    switch (rnd_range(seed, 6)) {
        case 0:  return PROT_READ;
        case 1:  return PROT_READ | PROT_WRITE;
        case 2:  return PROT_NONE;
        case 3:  return PROT_READ; // bias readable
        case 4:  return PROT_READ | PROT_WRITE;
        default:
#ifdef PROT_EXEC
            // Some platforms permit; might fail at runtime — that’s fine (logged).
            return PROT_READ | PROT_EXEC;
#else
            return PROT_READ;
#endif
    }
}

// -------------------- Resource pools --------------------

typedef struct {
    void   *addr;
    size_t  len;
    int     prot;   // PROT_*
    bool    in_use;
} region_t;

typedef struct {
#if HAVE_MACH
    mach_port_t port;
#else
    uint32_t port;
#endif
    bool in_use;
} port_t;

typedef struct {
    int  fd;
    bool in_use;
} fd_t;

typedef struct {
    region_t regions[EXERCISER_MAX_REGIONS];
    port_t   ports[EXERCISER_MAX_PORTS];
    fd_t     fds[EXERCISER_MAX_FDS];
} pool_t;

// -------------------- Global coordinator state --------------------

typedef struct {
    atomic_bool   running;

    uint32_t      seed;
    int           worker_count;
    uint64_t      duration_sec;
    uint64_t      steps_per_worker;

    // budgets
    atomic_size_t total_mapped_bytes;
    atomic_int    total_ports;
    atomic_int    total_fds;

    // progress / watchdog
    atomic_uint_fast64_t global_step;
    atomic_uint_fast64_t last_progress_abs;

    // stop reason flags
    atomic_bool flagged_interesting;

    pthread_t    watchdog_thread;
    pthread_t   *worker_threads;
} coordinator_t;

static coordinator_t g_co;

// -------------------- Stats --------------------

static atomic_uint_fast64_t g_total_steps;     // “runs”
static atomic_uint_fast64_t g_total_findings;  // flagged events
static atomic_uint_fast64_t g_start_abs;       // start timestamp

// -------------------- Helpers --------------------

static int pool_pick_inuse_region(pool_t *p, uint32_t *seed) {
    int tries = 0;
    while (tries++ < 16) {
        int i = (int)rnd_range(seed, EXERCISER_MAX_REGIONS);
        if (p->regions[i].in_use) return i;
    }
    for (int i = 0; i < EXERCISER_MAX_REGIONS; i++) if (p->regions[i].in_use) return i;
    return -1;
}

static int pool_pick_free_region(pool_t *p, uint32_t *seed) {
    int tries = 0;
    while (tries++ < 16) {
        int i = (int)rnd_range(seed, EXERCISER_MAX_REGIONS);
        if (!p->regions[i].in_use) return i;
    }
    for (int i = 0; i < EXERCISER_MAX_REGIONS; i++) if (!p->regions[i].in_use) return i;
    return -1;
}

static int pool_pick_inuse_port(pool_t *p, uint32_t *seed) {
    int tries = 0;
    while (tries++ < 16) {
        int i = (int)rnd_range(seed, EXERCISER_MAX_PORTS);
        if (p->ports[i].in_use) return i;
    }
    for (int i = 0; i < EXERCISER_MAX_PORTS; i++) if (p->ports[i].in_use) return i;
    return -1;
}

static int pool_pick_free_port(pool_t *p, uint32_t *seed) {
    int tries = 0;
    while (tries++ < 16) {
        int i = (int)rnd_range(seed, EXERCISER_MAX_PORTS);
        if (!p->ports[i].in_use) return i;
    }
    for (int i = 0; i < EXERCISER_MAX_PORTS; i++) if (!p->ports[i].in_use) return i;
    return -1;
}

static int pool_pick_inuse_fd(pool_t *p, uint32_t *seed) {
    int tries = 0;
    while (tries++ < 16) {
        int i = (int)rnd_range(seed, EXERCISER_MAX_FDS);
        if (p->fds[i].in_use) return i;
    }
    for (int i = 0; i < EXERCISER_MAX_FDS; i++) if (p->fds[i].in_use) return i;
    return -1;
}

static int pool_pick_free_fd(pool_t *p, uint32_t *seed) {
    int tries = 0;
    while (tries++ < 16) {
        int i = (int)rnd_range(seed, EXERCISER_MAX_FDS);
        if (!p->fds[i].in_use) return i;
    }
    for (int i = 0; i < EXERCISER_MAX_FDS; i++) if (!p->fds[i].in_use) return i;
    return -1;
}

// -------------------- Interesting heuristics --------------------

static void maybe_flag_slow(uint64_t usec, const char *op, int tid, uint64_t step) {
    if (usec > kSlowOpUsec) {
        atomic_store(&g_co.flagged_interesting, true);
        atomic_fetch_add(&g_total_findings, 1);
        log_flag("[FLAG] slow_op tid=%d step=%llu op=%s dur_us=%llu",
                 tid, (unsigned long long)step, op, (unsigned long long)usec);
    }
}

static void maybe_flag_unexpected_kr(int kr, const char *op, int tid, uint64_t step) {
#if HAVE_MACH
    if (kr != KERN_SUCCESS) {
        atomic_store(&g_co.flagged_interesting, true);
        atomic_fetch_add(&g_total_findings, 1);
        log_flag("[FLAG] mach_fail tid=%d step=%llu op=%s kr=%d",
                 tid, (unsigned long long)step, op, kr);
    }
#else
    (void)kr; (void)op; (void)tid; (void)step;
#endif
}

static void maybe_flag_errno(int err, const char *op, int tid, uint64_t step) {
    if (err != 0) {
        atomic_store(&g_co.flagged_interesting, true);
        atomic_fetch_add(&g_total_findings, 1);
        log_flag("[FLAG] errno tid=%d step=%llu op=%s errno=%d(%s)",
                 tid, (unsigned long long)step, op, err, strerror(err));
    }
}

// -------------------- Stats reporting --------------------

static void log_stats_line(void) {
    uint64_t start = atomic_load(&g_start_abs);
    uint64_t now   = now_abs();
    uint64_t us    = elapsed_usecs(start, now);
    if (us == 0) return;

    uint64_t steps    = atomic_load(&g_total_steps);
    uint64_t findings = atomic_load(&g_total_findings);

    double seconds = (double)us / 1e6;
    double rps = (seconds > 0.0) ? ((double)steps / seconds) : 0.0;

    // Must pre-format before passing to console_log(char*)
    console_log_fmt("[KERN_FUZZ] runs=%llu | rps=%.1f | findings=%llu | mapped=%zu | ports=%d | fds=%d",
                    (unsigned long long)steps,
                    rps,
                    (unsigned long long)findings,
                    atomic_load(&g_co.total_mapped_bytes),
                    atomic_load(&g_co.total_ports),
                    atomic_load(&g_co.total_fds));
}

// -------------------- Actions --------------------

typedef enum {
    ACT_REGION_ALLOC = 0,
    ACT_REGION_PROTECT,
    ACT_REGION_TOUCH,
    ACT_REGION_FREE,

    ACT_FD_OPEN,
    ACT_FD_RW,
    ACT_FD_CLOSE,

    ACT_PORT_ALLOC,
    ACT_PORT_DEALLOC,

    ACT_YIELD_SLEEP,

    ACT_COUNT
} action_t;

static const char* action_name(action_t a) {
    switch (a) {
        case ACT_REGION_ALLOC:    return "region_alloc";
        case ACT_REGION_PROTECT:  return "region_protect";
        case ACT_REGION_TOUCH:    return "region_touch";
        case ACT_REGION_FREE:     return "region_free";
        case ACT_FD_OPEN:         return "fd_open";
        case ACT_FD_RW:           return "fd_rw";
        case ACT_FD_CLOSE:        return "fd_close";
        case ACT_PORT_ALLOC:      return "port_alloc";
        case ACT_PORT_DEALLOC:    return "port_dealloc";
        case ACT_YIELD_SLEEP:     return "yield_sleep";
        default:                  return "unknown";
    }
}

static bool budget_try_add_mapped(size_t bytes) {
    size_t cur = atomic_load(&g_co.total_mapped_bytes);
    while (true) {
        if (cur + bytes > kMaxTotalMappedBytes) return false;
        if (atomic_compare_exchange_weak(&g_co.total_mapped_bytes, &cur, cur + bytes)) return true;
    }
}

static void budget_sub_mapped(size_t bytes) {
    atomic_fetch_sub(&g_co.total_mapped_bytes, bytes);
}

static bool budget_try_add_port(void) {
    int cur = atomic_load(&g_co.total_ports);
    while (true) {
        if (cur + 1 > kMaxTotalPorts) return false;
        if (atomic_compare_exchange_weak(&g_co.total_ports, &cur, cur + 1)) return true;
    }
}

static void budget_sub_port(void) {
    atomic_fetch_sub(&g_co.total_ports, 1);
}

static bool budget_try_add_fd(void) {
    int cur = atomic_load(&g_co.total_fds);
    while (true) {
        if (cur + 1 > kMaxTotalFDs) return false;
        if (atomic_compare_exchange_weak(&g_co.total_fds, &cur, cur + 1)) return true;
    }
}

static void budget_sub_fd(void) {
    atomic_fetch_sub(&g_co.total_fds, 1);
}

static void act_region_alloc(pool_t *pool, uint32_t *seed, int tid, uint64_t step) {
    int slot = pool_pick_free_region(pool, seed);
    if (slot < 0) return;

    // sizes: 4K .. 256K
    size_t pages = 1u << rnd_range(seed, 7); // 1..64 pages
    size_t len = pages * 4096u;

    if (!budget_try_add_mapped(len)) return;

    int prot  = pick_vm_prot(seed);
    int flags = pick_mmap_flags(seed);

    uint64_t t0 = now_abs();
    void *addr = mmap(NULL, len, prot, flags, -1, 0);
    int err = (addr == MAP_FAILED) ? errno : 0;
    uint64_t t1 = now_abs();
    uint64_t usec = elapsed_usecs(t0, t1);

    if (addr == MAP_FAILED) {
        budget_sub_mapped(len);
        log_line("tid=%d step=%llu act=%s len=%zu prot=0x%x flags=0x%x => FAIL errno=%d(%s)",
                 tid, (unsigned long long)step, action_name(ACT_REGION_ALLOC),
                 len, prot, flags, err, strerror(err));
        maybe_flag_errno(err, action_name(ACT_REGION_ALLOC), tid, step);
        return;
    }

    pool->regions[slot].addr = addr;
    pool->regions[slot].len  = len;
    pool->regions[slot].prot = prot;
    pool->regions[slot].in_use = true;

    log_line("tid=%d step=%llu act=%s len=%zu prot=0x%x flags=0x%x => ok slot=%d",
             tid, (unsigned long long)step, action_name(ACT_REGION_ALLOC), len, prot, flags, slot);
    maybe_flag_slow(usec, action_name(ACT_REGION_ALLOC), tid, step);
}

static void act_region_protect(pool_t *pool, uint32_t *seed, int tid, uint64_t step) {
    int i = pool_pick_inuse_region(pool, seed);
    if (i < 0) return;

    region_t *r = &pool->regions[i];

    // Seed-driven prot changes (broader than before)
    int new_prot = pick_vm_prot(seed);

    uint64_t t0 = now_abs();
    int rc = mprotect(r->addr, r->len, new_prot);
    int err = (rc != 0) ? errno : 0;
    uint64_t t1 = now_abs();
    uint64_t usec = elapsed_usecs(t0, t1);

    log_line("tid=%d step=%llu act=%s slot=%d len=%zu prot:0x%x->0x%x => %s errno=%d",
             tid, (unsigned long long)step, action_name(ACT_REGION_PROTECT),
             i, r->len, r->prot, new_prot, (rc==0?"ok":"FAIL"), err);

    if (rc == 0) r->prot = new_prot;
    if (rc != 0) maybe_flag_errno(err, action_name(ACT_REGION_PROTECT), tid, step);
    maybe_flag_slow(usec, action_name(ACT_REGION_PROTECT), tid, step);
}

static void act_region_touch(pool_t *pool, uint32_t *seed, int tid, uint64_t step) {
    int i = pool_pick_inuse_region(pool, seed);
    if (i < 0) return;

    region_t *r = &pool->regions[i];
    if (r->prot == PROT_NONE) return;

    // Touch a few pages
    uint8_t *p = (uint8_t *)r->addr;
    size_t touches = 1 + rnd_range(seed, 8);
    size_t stride = 4096u * (1 + rnd_range(seed, 4));

    uint64_t t0 = now_abs();
    volatile uint8_t sink = 0;

    for (size_t k = 0; k < touches; k++) {
        size_t off = (k * stride) % r->len;
        if (r->prot & PROT_WRITE) {
            p[off] ^= (uint8_t)rnd_range(seed, 255);
        } else {
            sink ^= p[off];
        }
    }

    uint64_t t1 = now_abs();
    uint64_t usec = elapsed_usecs(t0, t1);
    (void)sink;

    log_line("tid=%d step=%llu act=%s slot=%d touches=%zu stride=%zu prot=0x%x => ok",
             tid, (unsigned long long)step, action_name(ACT_REGION_TOUCH),
             i, touches, stride, r->prot);
    maybe_flag_slow(usec, action_name(ACT_REGION_TOUCH), tid, step);
}

static void act_region_free(pool_t *pool, uint32_t *seed, int tid, uint64_t step) {
    int i = pool_pick_inuse_region(pool, seed);
    if (i < 0) return;

    region_t *r = &pool->regions[i];

    uint64_t t0 = now_abs();
    int rc = munmap(r->addr, r->len);
    int err = (rc != 0) ? errno : 0;
    uint64_t t1 = now_abs();
    uint64_t usec = elapsed_usecs(t0, t1);

    log_line("tid=%d step=%llu act=%s slot=%d len=%zu => %s errno=%d",
             tid, (unsigned long long)step, action_name(ACT_REGION_FREE),
             i, r->len, (rc==0?"ok":"FAIL"), err);

    if (rc == 0) {
        budget_sub_mapped(r->len);
        memset(r, 0, sizeof(*r));
    } else {
        maybe_flag_errno(err, action_name(ACT_REGION_FREE), tid, step);
    }
    maybe_flag_slow(usec, action_name(ACT_REGION_FREE), tid, step);
}

static void act_fd_open(pool_t *pool, uint32_t *seed, int tid, uint64_t step) {
    int slot = pool_pick_free_fd(pool, seed);
    if (slot < 0) return;
    if (!budget_try_add_fd()) return;

    const char *path = rnd_bool(seed) ? "/dev/null" : "/dev/zero";
    int flags = rnd_bool(seed) ? O_RDONLY : O_RDWR;

    uint64_t t0 = now_abs();
    int fd = open(path, flags);
    int err = (fd < 0) ? errno : 0;
    uint64_t t1 = now_abs();
    uint64_t usec = elapsed_usecs(t0, t1);

    if (fd < 0) {
        budget_sub_fd();
        log_line("tid=%d step=%llu act=%s path=%s flags=0x%x => FAIL errno=%d(%s)",
                 tid, (unsigned long long)step, action_name(ACT_FD_OPEN),
                 path, flags, err, strerror(err));
        maybe_flag_errno(err, action_name(ACT_FD_OPEN), tid, step);
        return;
    }

    pool->fds[slot].fd = fd;
    pool->fds[slot].in_use = true;

    log_line("tid=%d step=%llu act=%s path=%s flags=0x%x => ok slot=%d fd=%d",
             tid, (unsigned long long)step, action_name(ACT_FD_OPEN), path, flags, slot, fd);
    maybe_flag_slow(usec, action_name(ACT_FD_OPEN), tid, step);
}

static void act_fd_rw(pool_t *pool, uint32_t *seed, int tid, uint64_t step) {
    int i = pool_pick_inuse_fd(pool, seed);
    if (i < 0) return;

    int fd = pool->fds[i].fd;
    uint8_t buf[256];
    size_t n = 1 + rnd_range(seed, (uint32_t)sizeof(buf));

    uint64_t t0 = now_abs();
    ssize_t rc;
    if (rnd_bool(seed)) {
        rc = read(fd, buf, n);
    } else {
        memset(buf, (int)rnd_range(seed, 255), n);
        rc = write(fd, buf, n);
    }
    int err = (rc < 0) ? errno : 0;
    uint64_t t1 = now_abs();
    uint64_t usec = elapsed_usecs(t0, t1);

    log_line("tid=%d step=%llu act=%s slot=%d fd=%d n=%zu => rc=%zd errno=%d",
             tid, (unsigned long long)step, action_name(ACT_FD_RW), i, fd, n, rc, err);

    if (rc < 0) maybe_flag_errno(err, action_name(ACT_FD_RW), tid, step);
    maybe_flag_slow(usec, action_name(ACT_FD_RW), tid, step);
}

static void act_fd_close(pool_t *pool, uint32_t *seed, int tid, uint64_t step) {
    int i = pool_pick_inuse_fd(pool, seed);
    if (i < 0) return;

    int fd = pool->fds[i].fd;

    uint64_t t0 = now_abs();
    int rc = close(fd);
    int err = (rc != 0) ? errno : 0;
    uint64_t t1 = now_abs();
    uint64_t usec = elapsed_usecs(t0, t1);

    log_line("tid=%d step=%llu act=%s slot=%d fd=%d => %s errno=%d",
             tid, (unsigned long long)step, action_name(ACT_FD_CLOSE),
             i, fd, (rc==0?"ok":"FAIL"), err);

    if (rc == 0) {
        budget_sub_fd();
        memset(&pool->fds[i], 0, sizeof(pool->fds[i]));
    } else {
        maybe_flag_errno(err, action_name(ACT_FD_CLOSE), tid, step);
    }
    maybe_flag_slow(usec, action_name(ACT_FD_CLOSE), tid, step);
}

static void act_port_alloc(pool_t *pool, uint32_t *seed, int tid, uint64_t step) {
#if !HAVE_MACH
    (void)pool; (void)seed; (void)tid; (void)step;
    return;
#else
    int slot = pool_pick_free_port(pool, seed);
    if (slot < 0) return;
    if (!budget_try_add_port()) return;

    mach_port_t port = MACH_PORT_NULL;

    uint64_t t0 = now_abs();
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
    uint64_t t1 = now_abs();
    uint64_t usec = elapsed_usecs(t0, t1);

    if (kr != KERN_SUCCESS) {
        budget_sub_port();
        log_line("tid=%d step=%llu act=%s => FAIL kr=%d",
                 tid, (unsigned long long)step, action_name(ACT_PORT_ALLOC), kr);
        maybe_flag_unexpected_kr(kr, action_name(ACT_PORT_ALLOC), tid, step);
        return;
    }

    // Give ourselves a send right too (benign, owned by this task)
    kr = mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), port);
        budget_sub_port();
        log_line("tid=%d step=%llu act=%s insert_right => FAIL kr=%d",
                 tid, (unsigned long long)step, action_name(ACT_PORT_ALLOC), kr);
        maybe_flag_unexpected_kr(kr, "port_insert_right", tid, step);
        return;
    }

    pool->ports[slot].port = port;
    pool->ports[slot].in_use = true;

    log_line("tid=%d step=%llu act=%s => ok slot=%d port=0x%x",
             tid, (unsigned long long)step, action_name(ACT_PORT_ALLOC), slot, port);
    maybe_flag_slow(usec, action_name(ACT_PORT_ALLOC), tid, step);
#endif
}

static void act_port_dealloc(pool_t *pool, uint32_t *seed, int tid, uint64_t step) {
#if !HAVE_MACH
    (void)pool; (void)seed; (void)tid; (void)step;
    return;
#else
    int i = pool_pick_inuse_port(pool, seed);
    if (i < 0) return;

    mach_port_t port = pool->ports[i].port;

    uint64_t t0 = now_abs();
    kern_return_t kr = mach_port_deallocate(mach_task_self(), port);
    uint64_t t1 = now_abs();
    uint64_t usec = elapsed_usecs(t0, t1);

    log_line("tid=%d step=%llu act=%s slot=%d port=0x%x => kr=%d",
             tid, (unsigned long long)step, action_name(ACT_PORT_DEALLOC), i, port, kr);

    if (kr == KERN_SUCCESS) {
        budget_sub_port();
        memset(&pool->ports[i], 0, sizeof(pool->ports[i]));
    } else {
        maybe_flag_unexpected_kr(kr, action_name(ACT_PORT_DEALLOC), tid, step);
    }
    maybe_flag_slow(usec, action_name(ACT_PORT_DEALLOC), tid, step);
#endif
}

static void act_yield_sleep(uint32_t *seed, int tid, uint64_t step) {
    // tiny jitter: yield or nanosleep 0..5ms
    if (rnd_bool(seed)) {
        sched_yield();
        log_line("tid=%d step=%llu act=%s => yield",
                 tid, (unsigned long long)step, action_name(ACT_YIELD_SLEEP));
    } else {
        uint32_t ms = rnd_range(seed, 6);
        struct timespec ts;
        ts.tv_sec = 0;
        ts.tv_nsec = (long)ms * 1000000L;
        nanosleep(&ts, NULL);
        log_line("tid=%d step=%llu act=%s => sleep_ms=%u",
                 tid, (unsigned long long)step, action_name(ACT_YIELD_SLEEP), ms);
    }
}

// Weighted action selection with “sensical randomness”
static action_t choose_action(pool_t *pool, uint32_t *seed) {
    bool has_region = (pool_pick_inuse_region(pool, seed) >= 0);
    bool has_fd     = (pool_pick_inuse_fd(pool, seed) >= 0);
    bool has_port   = (pool_pick_inuse_port(pool, seed) >= 0);

    uint32_t roll = rnd_range(seed, 100);

    // Mutate (40%)
    if (roll < 40) {
        uint32_t m = rnd_range(seed, 3);
        if (m == 0 && has_region) return ACT_REGION_TOUCH;
        if (m == 1 && has_region) return ACT_REGION_PROTECT;
        if (m == 2 && has_fd)     return ACT_FD_RW;
        return ACT_YIELD_SLEEP;
    }

    // Create (30%)
    if (roll < 70) {
        uint32_t c = rnd_range(seed, 3);
        if (c == 0) return ACT_REGION_ALLOC;
        if (c == 1) return ACT_FD_OPEN;
#if HAVE_MACH
        if (c == 2) return ACT_PORT_ALLOC;
#endif
        return ACT_REGION_ALLOC;
    }

    // Destroy (30%)
    {
        uint32_t d = rnd_range(seed, 3);
        if (d == 0 && has_region) return ACT_REGION_FREE;
        if (d == 1 && has_fd)     return ACT_FD_CLOSE;
#if HAVE_MACH
        if (d == 2 && has_port)   return ACT_PORT_DEALLOC;
#endif
        return ACT_YIELD_SLEEP;
    }
}

// Cleanup all resources in a pool (best effort)
static void pool_cleanup(pool_t *pool, int tid) {
    // Close FDs
    for (int i = 0; i < EXERCISER_MAX_FDS; i++) {
        if (pool->fds[i].in_use) {
            int fd = pool->fds[i].fd;
            if (close(fd) == 0) budget_sub_fd();
            pool->fds[i].in_use = false;
        }
    }

    // Unmap regions
    for (int i = 0; i < EXERCISER_MAX_REGIONS; i++) {
        if (pool->regions[i].in_use) {
            void *addr = pool->regions[i].addr;
            size_t len = pool->regions[i].len;
            if (addr && len) {
                if (munmap(addr, len) == 0) budget_sub_mapped(len);
            }
            pool->regions[i].in_use = false;
        }
    }

#if HAVE_MACH
    // Deallocate ports
    for (int i = 0; i < EXERCISER_MAX_PORTS; i++) {
        if (pool->ports[i].in_use) {
            mach_port_t port = pool->ports[i].port;
            if (port != MACH_PORT_NULL) {
                if (mach_port_deallocate(mach_task_self(), port) == KERN_SUCCESS) {
                    budget_sub_port();
                }
            }
            pool->ports[i].in_use = false;
        }
    }
#endif

    log_line("tid=%d cleanup done (mapped=%zu ports=%d fds=%d)",
             tid,
             atomic_load(&g_co.total_mapped_bytes),
             atomic_load(&g_co.total_ports),
             atomic_load(&g_co.total_fds));
}

// -------------------- Worker thread --------------------

typedef struct {
    int      tid;
    uint32_t seed;
    pool_t   pool;
} worker_ctx_t;

// Persistent worker:
// - Previously: exited after i < steps_per_worker
// - Now: loops while g_co.running; steps_per_worker is treated as a "batch" size
static void* worker_main(void *arg) {
    worker_ctx_t *w = (worker_ctx_t *)arg;

    log_line("tid=%d worker_start seed=0x%08x steps_per_batch=%llu",
             w->tid, w->seed, (unsigned long long)g_co.steps_per_worker);

    uint64_t local_total_iters = 0;

    while (atomic_load(&g_co.running)) {
        for (uint64_t i = 0; atomic_load(&g_co.running) && i < g_co.steps_per_worker; i++) {
            uint64_t step = atomic_fetch_add(&g_co.global_step, 1);
            atomic_fetch_add(&g_total_steps, 1);
            local_total_iters++;

            action_t act = choose_action(&w->pool, &w->seed);

            // record progress for watchdog
            atomic_store(&g_co.last_progress_abs, now_abs());

            switch (act) {
                case ACT_REGION_ALLOC:   act_region_alloc(&w->pool, &w->seed, w->tid, step); break;
                case ACT_REGION_PROTECT: act_region_protect(&w->pool, &w->seed, w->tid, step); break;
                case ACT_REGION_TOUCH:   act_region_touch(&w->pool, &w->seed, w->tid, step); break;
                case ACT_REGION_FREE:    act_region_free(&w->pool, &w->seed, w->tid, step); break;

                case ACT_FD_OPEN:        act_fd_open(&w->pool, &w->seed, w->tid, step); break;
                case ACT_FD_RW:          act_fd_rw(&w->pool, &w->seed, w->tid, step); break;
                case ACT_FD_CLOSE:       act_fd_close(&w->pool, &w->seed, w->tid, step); break;

                case ACT_PORT_ALLOC:     act_port_alloc(&w->pool, &w->seed, w->tid, step); break;
                case ACT_PORT_DEALLOC:   act_port_dealloc(&w->pool, &w->seed, w->tid, step); break;

                case ACT_YIELD_SLEEP:    act_yield_sleep(&w->seed, w->tid, step); break;
                default:                 break;
            }

            // If something interesting got flagged, run a little more then stop globally
            if (atomic_load(&g_co.flagged_interesting) && (local_total_iters > 64)) {
                atomic_store(&g_co.running, false);
                break;
            }
        }

        // Tiny pause between batches so we don't get "stuck" in hot loops on watchOS
        // (also gives the watchdog/other threads breathing room)
        struct timespec ts = {.tv_sec = 0, .tv_nsec = 1 * 1000 * 1000L}; // 1ms
        nanosleep(&ts, NULL);
    }

    pool_cleanup(&w->pool, w->tid);
    log_line("tid=%d worker_exit", w->tid);
    return NULL;
}

// -------------------- Watchdog thread --------------------

static void* watchdog_main(void *arg) {
    (void)arg;

    uint64_t start_abs = now_abs();
    uint64_t last_stats_abs = start_abs;

    while (atomic_load(&g_co.running)) {
        uint64_t now = now_abs();

        // Emit stats ~1Hz to on-screen console (and you’ll also have per-op logs)
        if (elapsed_usecs(last_stats_abs, now) > 1000000ull) {
            log_stats_line();
            last_stats_abs = now;
        }

        // duration check
        uint64_t elapsed_us = elapsed_usecs(start_abs, now);
        if (g_co.duration_sec > 0 && elapsed_us > g_co.duration_sec * 1000000ull) {
            log_line("[watchdog] duration reached; stopping");
            atomic_store(&g_co.running, false);
            break;
        }

        // stall check: if no progress in ~2s, stop
        uint64_t last = atomic_load(&g_co.last_progress_abs);
        if (last != 0) {
            uint64_t since_us = elapsed_usecs(last, now);
            if (since_us > 2000000ull) {
                atomic_fetch_add(&g_total_findings, 1);
                log_flag("[watchdog] stall detected (no progress %llu us); stopping",
                         (unsigned long long)since_us);
                atomic_store(&g_co.running, false);
                break;
            }
        }

        // poll 100ms
        struct timespec ts = {.tv_sec = 0, .tv_nsec = 100000000L};
        nanosleep(&ts, NULL);
    }

    return NULL;
}

// -------------------- Public API --------------------

static worker_ctx_t *g_workers;

void exerciser_start(uint32_t seed, uint64_t duration_seconds, int worker_count, uint64_t steps_per_worker) {
    if (atomic_load(&g_co.running)) {
        log_line("exerciser already running");
        return;
    }

    memset(&g_co, 0, sizeof(g_co));
    g_co.seed = seed ? seed : 0xC0FFEEu;
    g_co.worker_count = (worker_count <= 0) ? 2 : worker_count;
    g_co.duration_sec = duration_seconds;
    g_co.steps_per_worker = (steps_per_worker == 0) ? 5000 : steps_per_worker;

    atomic_store(&g_co.total_mapped_bytes, 0);
    atomic_store(&g_co.total_ports, 0);
    atomic_store(&g_co.total_fds, 0);
    atomic_store(&g_co.global_step, 0);
    atomic_store(&g_co.last_progress_abs, now_abs());
    atomic_store(&g_co.flagged_interesting, false);
    atomic_store(&g_co.running, true);

    // stats init
    atomic_store(&g_total_steps, 0);
    atomic_store(&g_total_findings, 0);
    atomic_store(&g_start_abs, now_abs());

    log_line("exerciser_start seed=0x%08x duration_s=%llu workers=%d steps_per_batch=%llu "
             "budgets: mapped<=%zu ports<=%d fds<=%d",
             g_co.seed,
             (unsigned long long)g_co.duration_sec,
             g_co.worker_count,
             (unsigned long long)g_co.steps_per_worker,
             kMaxTotalMappedBytes, kMaxTotalPorts, kMaxTotalFDs);

    // quick console banner
    console_log_fmt("[KERN_FUZZ] start seed=0x%08x workers=%d steps/batch=%llu duration=%llus",
                    g_co.seed,
                    g_co.worker_count,
                    (unsigned long long)g_co.steps_per_worker,
                    (unsigned long long)g_co.duration_sec);

    // allocate worker contexts + threads
    g_workers = (worker_ctx_t *)calloc((size_t)g_co.worker_count, sizeof(worker_ctx_t));
    g_co.worker_threads = (pthread_t *)calloc((size_t)g_co.worker_count, sizeof(pthread_t));

    for (int i = 0; i < g_co.worker_count; i++) {
        g_workers[i].tid = i;
        g_workers[i].seed = g_co.seed ^ (0x9E3779B9u * (uint32_t)(i + 1));
        memset(&g_workers[i].pool, 0, sizeof(pool_t));

        pthread_create(&g_co.worker_threads[i], NULL, worker_main, &g_workers[i]);
    }

    pthread_create(&g_co.watchdog_thread, NULL, watchdog_main, NULL);
}

void exerciser_stop(void) {
    if (!atomic_load(&g_co.running)) {
        // still print summary if we were stopped by watchdog/worker
        // (if never started, these will be 0)
    } else {
        atomic_store(&g_co.running, false);
    }

    // join workers
    if (g_co.worker_threads) {
        for (int i = 0; i < g_co.worker_count; i++) {
            if (g_co.worker_threads[i]) pthread_join(g_co.worker_threads[i], NULL);
        }
    }

    if (g_co.watchdog_thread) pthread_join(g_co.watchdog_thread, NULL);

    uint64_t steps = atomic_load(&g_total_steps);
    uint64_t findings = atomic_load(&g_total_findings);

    uint64_t elapsed_us = elapsed_usecs(atomic_load(&g_start_abs), now_abs());
    double seconds = (double)elapsed_us / 1e6;
    double rps = (seconds > 0.0) ? ((double)steps / seconds) : 0.0;

    log_line("exerciser_stop steps=%llu flagged_interesting=%d findings=%llu elapsed=%.1fs rps=%.1f "
             "final_budgets: mapped=%zu ports=%d fds=%d",
             (unsigned long long)steps,
             atomic_load(&g_co.flagged_interesting) ? 1 : 0,
             (unsigned long long)findings,
             seconds,
             rps,
             atomic_load(&g_co.total_mapped_bytes),
             atomic_load(&g_co.total_ports),
             atomic_load(&g_co.total_fds));

    console_log_fmt("[KERN_FUZZ] stop runs=%llu rps=%.1f findings=%llu elapsed=%.1fs",
                    (unsigned long long)steps,
                    rps,
                    (unsigned long long)findings,
                    seconds);

    free(g_co.worker_threads);
    g_co.worker_threads = NULL;
    free(g_workers);
    g_workers = NULL;
}

// Optional helper: run with a time-based seed
uint32_t exerciser_seed_from_time(void) {
    uint64_t t = (uint64_t)time(NULL);
    uint32_t s = (uint32_t)(t ^ (t >> 32));
    return s ? s : 0xA5A5A5A5u;
}

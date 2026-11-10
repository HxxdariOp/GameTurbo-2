#ifndef Bridge_h
#define Bridge_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Snapshot of all processes. One line per process:
/// pid|ppid|uid|status|nice|threads|footprint|resident|virtual|cpu_ns|name|path
char *pt_snapshot(void);
void pt_free(char *p);

/// Run a command line (space separated; 0x1F inside a token is turned into a space).
/// root != 0 -> spawn with root persona. stdout+stderr returned in *out (free with pt_free).
/// Returns exit code, -1 on spawn failure.
int pt_run(const char *cmdline, int root, char **out);

/// Same as pt_run but does not wait: stdio goes to /dev/null, new session. Returns pid or -1.
int pt_spawn_detached(const char *cmdline, int root);

/// Human readable diagnostics of the last spawn (persona return codes etc.)
const char *pt_last_spawn_info(void);

/// 1 = entitlement present/true, 0 = absent/false, -1 = unknown
int pt_entitlement(const char *key);

/// 1 if path is readable by this process
int pt_can_read(const char *path);

/// GPU utilisation via IOKit registry. Returns 1 if found. Untouched outputs stay as given.
int pt_gpu(double *device, double *renderer, double *tiler, double *memMB);
const char *pt_gpu_info(void);

/// Per-core cumulative ticks. Returns number of cores.
int pt_cpu(uint64_t *busy, uint64_t *total, int maxCores);

/// out[0..7] = free, active, inactive, wired, compressed, speculative, purgeable, external (bytes)
int pt_mem(uint64_t *out8);

/// kern.memorystatus_vm_pressure_level (1 normal, 2 warn, 4 critical), -1 unknown
int pt_pressure(void);

/// glob() -> newline separated paths
char *pt_glob(const char *pattern);

/// Disk usage of a path in bytes
uint64_t pt_du(const char *path);

/// Delete CONTENTS of a directory (only whitelisted cache/tmp/log locations). Returns bytes freed.
uint64_t pt_rmcontents(const char *path);

/// Allocate and touch up to targetMB of memory to force the kernel to reclaim caches. Returns MB reached.
uint64_t pt_purge(uint64_t targetMB);

#ifdef __cplusplus
}
#endif

#endif /* Bridge_h */

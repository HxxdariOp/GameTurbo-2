#include "Bridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <dirent.h>
#include <dlfcn.h>
#include <glob.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <sys/resource.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/mach_host.h>
#include <CoreFoundation/CoreFoundation.h>

extern char **environ;

/* ---- libproc declarations (the iOS SDK does not ship libproc.h) ---- */
#define PT_PATHMAX 4096
#define PT_PIDTBSDINFO 3
#define PT_PIDTASKINFO 4
#define PT_RUSAGE_V2 2

extern int proc_listallpids(void *buffer, int buffersize);
extern int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
extern int proc_name(int pid, void *buffer, uint32_t buffersize);
extern int proc_pid_rusage(int pid, int flavor, void *buffer);

struct pt_bsdinfo {
    uint32_t pbi_flags;
    uint32_t pbi_status;
    uint32_t pbi_xstatus;
    uint32_t pbi_pid;
    uint32_t pbi_ppid;
    uid_t pbi_uid;
    gid_t pbi_gid;
    uid_t pbi_ruid;
    gid_t pbi_rgid;
    uid_t pbi_svuid;
    gid_t pbi_svgid;
    uint32_t rfu_1;
    char pbi_comm[16];
    char pbi_name[32];
    uint32_t pbi_nfiles;
    uint32_t pbi_pgid;
    uint32_t pbi_pjobc;
    uint32_t e_tdev;
    uint32_t e_tpgid;
    int32_t pbi_nice;
    uint64_t pbi_start_tvsec;
    uint64_t pbi_start_tvusec;
};

struct pt_taskinfo {
    uint64_t pti_virtual_size;
    uint64_t pti_resident_size;
    uint64_t pti_total_user;
    uint64_t pti_total_system;
    uint64_t pti_threads_user;
    uint64_t pti_threads_system;
    int32_t pti_policy;
    int32_t pti_faults;
    int32_t pti_pageins;
    int32_t pti_cow_faults;
    int32_t pti_messages_sent;
    int32_t pti_messages_received;
    int32_t pti_syscalls_mach;
    int32_t pti_syscalls_unix;
    int32_t pti_csw;
    int32_t pti_threadnum;
    int32_t pti_numrunning;
    int32_t pti_priority;
};

/* private persona APIs (same ones TrollStore uses to spawn root helpers) */
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t *__restrict, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *__restrict, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *__restrict, uid_t);
#define PT_PERSONA_FLAGS_OVERRIDE 1

#ifndef POSIX_SPAWN_SETSID
#define POSIX_SPAWN_SETSID 0x0400
#endif

/* ---------- small string builder ---------- */

typedef struct {
    char *buf;
    size_t len;
    size_t cap;
} sb_t;

static void sb_init(sb_t *s) {
    s->cap = 4096;
    s->len = 0;
    s->buf = (char *)malloc(s->cap);
    s->buf[0] = 0;
}

static void sb_append(sb_t *s, const char *str, size_t n) {
    if (s->len + n + 1 > s->cap) {
        while (s->len + n + 1 > s->cap) s->cap *= 2;
        s->buf = (char *)realloc(s->buf, s->cap);
    }
    memcpy(s->buf + s->len, str, n);
    s->len += n;
    s->buf[s->len] = 0;
}

void pt_free(char *p) {
    if (p) free(p);
}

/* ---------- process snapshot ---------- */

static void sanitize(char *s) {
    for (; *s; s++) {
        if (*s == '|' || *s == '\n' || *s == '\r') *s = '_';
    }
}

char *pt_snapshot(void) {
    sb_t sb;
    sb_init(&sb);

    int cap = proc_listallpids(NULL, 0);
    if (cap <= 0) return sb.buf;
    cap += 64;
    pid_t *pids = (pid_t *)malloc(sizeof(pid_t) * (size_t)cap);
    int n = proc_listallpids(pids, (int)(sizeof(pid_t) * (size_t)cap));

    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    if (tb.denom == 0) { tb.numer = 1; tb.denom = 1; }

    for (int i = 0; i < n; i++) {
        pid_t pid = pids[i];
        char name[256];
        char path[PT_PATHMAX];
        memset(name, 0, sizeof(name));
        memset(path, 0, sizeof(path));

        proc_name(pid, name, sizeof(name));
        proc_pidpath(pid, path, sizeof(path));

        struct pt_bsdinfo bsd;
        memset(&bsd, 0, sizeof(bsd));
        int hasBsd = proc_pidinfo(pid, PT_PIDTBSDINFO, 0, &bsd, sizeof(bsd)) == (int)sizeof(bsd);

        struct pt_taskinfo ti;
        memset(&ti, 0, sizeof(ti));
        int hasTask = proc_pidinfo(pid, PT_PIDTASKINFO, 0, &ti, sizeof(ti)) == (int)sizeof(ti);

        uint64_t foot = 0;
        uint64_t ru[128];
        memset(ru, 0, sizeof(ru));
        if (proc_pid_rusage(pid, PT_RUSAGE_V2, (void *)ru) == 0) {
            /* rusage_info_v2: 16-byte uuid, then user_time, system_time, pkg_idle,
               interrupt_wkups, pageins, wired, resident, phys_footprint (byte offset 72) */
            foot = ru[9];
        }

        if (name[0] == 0 && hasBsd) {
            strlcpy(name, bsd.pbi_name[0] ? bsd.pbi_name : bsd.pbi_comm, sizeof(name));
        }
        if (name[0] == 0 && pid == 0) strlcpy(name, "kernel_task", sizeof(name));
        if (name[0] == 0) continue;
        sanitize(name);
        sanitize(path);

        uint64_t cpuns = 0;
        if (hasTask) {
            cpuns = ((uint64_t)ti.pti_total_user + (uint64_t)ti.pti_total_system) * tb.numer / tb.denom;
        }

        char line[PT_PATHMAX + 512];
        int len = snprintf(line, sizeof(line), "%d|%d|%u|%u|%d|%d|%llu|%llu|%llu|%llu|%s|%s\n",
                           (int)pid,
                           hasBsd ? (int)bsd.pbi_ppid : 0,
                           hasBsd ? (unsigned)bsd.pbi_uid : 0u,
                           hasBsd ? (unsigned)bsd.pbi_status : 0u,
                           hasBsd ? (int)bsd.pbi_nice : 0,
                           hasTask ? (int)ti.pti_threadnum : 0,
                           (unsigned long long)foot,
                           hasTask ? (unsigned long long)ti.pti_resident_size : 0ULL,
                           hasTask ? (unsigned long long)ti.pti_virtual_size : 0ULL,
                           (unsigned long long)cpuns,
                           name, path);
        if (len > 0) sb_append(&sb, line, (size_t)len);
    }
    free(pids);
    return sb.buf;
}

/* ---------- spawn (optionally as root) ---------- */

static char g_info[512];

const char *pt_last_spawn_info(void) {
    return g_info;
}

static char **split_cmd(const char *cmd, char **dupOut, int *argcOut) {
    char *dup = strdup(cmd);
    size_t cap = 64, n = 0;
    char **argv = (char **)malloc(sizeof(char *) * cap);
    char *save = NULL;
    for (char *tok = strtok_r(dup, " ", &save); tok; tok = strtok_r(NULL, " ", &save)) {
        for (char *c = tok; *c; c++) {
            if (*c == 0x1f) *c = ' ';
        }
        if (n + 2 > cap) {
            cap *= 2;
            argv = (char **)realloc(argv, sizeof(char *) * cap);
        }
        argv[n++] = tok;
    }
    argv[n] = NULL;
    *dupOut = dup;
    *argcOut = (int)n;
    return argv;
}

static int do_spawn(const char *cmdline, int root, int detached, char **out) {
    if (out) *out = NULL;
    if (!cmdline) return -1;

    char *dup = NULL;
    int argc = 0;
    char **argv = split_cmd(cmdline, &dup, &argc);
    if (argc == 0) { free(argv); free(dup); return -1; }

    int pfd[2] = {-1, -1};
    if (!detached) {
        if (pipe(pfd) != 0) { free(argv); free(dup); return -1; }
    }

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    if (detached) {
        posix_spawn_file_actions_addopen(&fa, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
        posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
        posix_spawn_file_actions_addopen(&fa, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    } else {
        posix_spawn_file_actions_adddup2(&fa, pfd[1], STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&fa, pfd[1], STDERR_FILENO);
        posix_spawn_file_actions_addclose(&fa, pfd[0]);
        posix_spawn_file_actions_addclose(&fa, pfd[1]);
    }

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    /* flags first: setflags() would overwrite the persona flag if called afterwards */
    if (detached) posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);

    int r1 = 0, r2 = 0, r3 = 0;
    if (root) {
        r1 = posix_spawnattr_set_persona_np(&attr, 99, PT_PERSONA_FLAGS_OVERRIDE);
        r2 = posix_spawnattr_set_persona_uid_np(&attr, 0);
        r3 = posix_spawnattr_set_persona_gid_np(&attr, 0);
    }

    pid_t pid = 0;
    int rc = posix_spawn(&pid, argv[0], &fa, &attr, argv, environ);
    snprintf(g_info, sizeof(g_info), "root=%d persona_np=%d uid_np=%d gid_np=%d spawn=%d(%s) bin=%s",
             root, r1, r2, r3, rc, rc ? strerror(rc) : "ok", argv[0]);

    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);
    if (!detached) close(pfd[1]);

    if (rc != 0) {
        if (!detached) close(pfd[0]);
        if (out) {
            const char *msg = strerror(rc);
            *out = strdup(msg ? msg : "spawn failed");
        }
        free(argv);
        free(dup);
        return -1;
    }

    if (detached) {
        free(argv);
        free(dup);
        return (int)pid;
    }

    sb_t sb;
    sb_init(&sb);
    char tmp[4096];
    ssize_t r;
    while ((r = read(pfd[0], tmp, sizeof(tmp))) > 0) {
        sb_append(&sb, tmp, (size_t)r);
    }
    close(pfd[0]);

    int st = 0;
    waitpid(pid, &st, 0);
    int code = -1;
    if (WIFEXITED(st)) code = WEXITSTATUS(st);
    else if (WIFSIGNALED(st)) code = 128 + WTERMSIG(st);

    if (out) *out = sb.buf; else free(sb.buf);
    free(argv);
    free(dup);
    return code;
}

int pt_run(const char *cmdline, int root, char **out) {
    return do_spawn(cmdline, root, 0, out);
}

int pt_spawn_detached(const char *cmdline, int root) {
    return do_spawn(cmdline, root, 1, NULL);
}

/* ---------- entitlement / access checks ---------- */

typedef void *(*fn_taskself_t)(CFAllocatorRef);
typedef CFTypeRef (*fn_taskval_t)(void *, CFStringRef, CFErrorRef *);

int pt_entitlement(const char *key) {
    void *h = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY);
    if (!h) return -1;
    fn_taskself_t f1 = (fn_taskself_t)dlsym(h, "SecTaskCreateFromSelf");
    fn_taskval_t f2 = (fn_taskval_t)dlsym(h, "SecTaskCopyValueForEntitlement");
    if (!f1 || !f2) return -1;
    void *task = f1(kCFAllocatorDefault);
    if (!task) return -1;
    CFStringRef k = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    int result = 0;
    if (k) {
        CFTypeRef v = f2(task, k, NULL);
        if (v) {
            if (CFGetTypeID(v) == CFBooleanGetTypeID()) result = CFBooleanGetValue((CFBooleanRef)v) ? 1 : 0;
            else result = 1;
            CFRelease(v);
        }
        CFRelease(k);
    }
    CFRelease((CFTypeRef)task);
    return result;
}

int pt_can_read(const char *path) {
    return access(path, R_OK) == 0 ? 1 : 0;
}

/* ---------- GPU via IOKit (dlopen so no linking / headers needed) ---------- */

typedef CFMutableDictionaryRef (*fn_matching_t)(const char *);
typedef kern_return_t (*fn_services_t)(mach_port_t, CFDictionaryRef, mach_port_t *);
typedef mach_port_t (*fn_next_t)(mach_port_t);
typedef CFTypeRef (*fn_prop_t)(mach_port_t, CFStringRef, CFAllocatorRef, uint32_t);
typedef CFTypeRef (*fn_search_t)(mach_port_t, const char *, CFStringRef, CFAllocatorRef, uint32_t);
typedef kern_return_t (*fn_release_t)(mach_port_t);

static char g_gpu_info[768];

const char *pt_gpu_info(void) {
    return g_gpu_info;
}

static double dict_num(CFDictionaryRef d, const char *key) {
    CFStringRef k = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    double result = -1;
    if (k) {
        CFTypeRef v = CFDictionaryGetValue(d, k);
        if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
            double x = 0;
            if (CFNumberGetValue((CFNumberRef)v, kCFNumberDoubleType, &x)) result = x;
        }
        CFRelease(k);
    }
    return result;
}

static double find_util(CFDictionaryRef d) {
    static const char *keys[] = {"Device Utilization %", "GPU Activity(%)", "GPU Core Utilization", NULL};
    for (int i = 0; keys[i]; i++) {
        double v = dict_num(d, keys[i]);
        if (v >= 0) return v;
    }
    CFIndex n = CFDictionaryGetCount(d);
    if (n <= 0 || n > 256) return -1;
    const void *ks[256];
    const void *vs[256];
    CFDictionaryGetKeysAndValues(d, ks, vs);
    for (CFIndex i = 0; i < n; i++) {
        if (CFGetTypeID(ks[i]) != CFStringGetTypeID()) continue;
        char kb[160];
        if (!CFStringGetCString((CFStringRef)ks[i], kb, sizeof(kb), kCFStringEncodingUTF8)) continue;
        if (strstr(kb, "Utilization") && CFGetTypeID(vs[i]) == CFNumberGetTypeID()) {
            double x = 0;
            if (CFNumberGetValue((CFNumberRef)vs[i], kCFNumberDoubleType, &x)) return x;
        }
    }
    return -1;
}

static void append_keys(CFDictionaryRef d, char *buf, size_t n) {
    CFIndex cnt = CFDictionaryGetCount(d);
    if (cnt <= 0 || cnt > 256) return;
    const void *ks[256];
    const void *vs[256];
    CFDictionaryGetKeysAndValues(d, ks, vs);
    size_t used = strlen(buf);
    int shown = 0;
    for (CFIndex i = 0; i < cnt && shown < 5; i++) {
        if (CFGetTypeID(ks[i]) != CFStringGetTypeID()) continue;
        char kb[96];
        if (!CFStringGetCString((CFStringRef)ks[i], kb, sizeof(kb), kCFStringEncodingUTF8)) continue;
        if (used + strlen(kb) + 4 >= n) break;
        used += (size_t)snprintf(buf + used, n - used, "[%s]", kb);
        shown++;
    }
}

int pt_gpu(double *device, double *renderer, double *tiler, double *memMB) {
    static int inited = 0;
    static void *handle = NULL;
    static fn_matching_t f_matching = NULL;
    static fn_services_t f_services = NULL;
    static fn_next_t f_next = NULL;
    static fn_prop_t f_prop = NULL;
    static fn_search_t f_search = NULL;
    static fn_release_t f_release = NULL;

    g_gpu_info[0] = 0;
    if (!inited) {
        inited = 1;
        handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (handle) {
            f_matching = (fn_matching_t)dlsym(handle, "IOServiceMatching");
            f_services = (fn_services_t)dlsym(handle, "IOServiceGetMatchingServices");
            f_next = (fn_next_t)dlsym(handle, "IOIteratorNext");
            f_prop = (fn_prop_t)dlsym(handle, "IORegistryEntryCreateCFProperty");
            f_search = (fn_search_t)dlsym(handle, "IORegistryEntrySearchCFProperty");
            f_release = (fn_release_t)dlsym(handle, "IOObjectRelease");
        }
    }
    if (!handle) {
        snprintf(g_gpu_info, sizeof(g_gpu_info), "dlopen(IOKit) failed");
        return 0;
    }
    if (!f_matching || !f_services || !f_next || !f_prop || !f_release) {
        snprintf(g_gpu_info, sizeof(g_gpu_info), "dlsym(IOKit) failed");
        return 0;
    }

    static const char *classes[] = {"AGXAccelerator", "IOAccelerator", "IMGSGX", "IOGraphicsAccelerator2", NULL};
    int found = 0;
    for (int ci = 0; classes[ci] && !found; ci++) {
        size_t off = strlen(g_gpu_info);
        if (off > sizeof(g_gpu_info) - 120) break;
        CFMutableDictionaryRef match = f_matching(classes[ci]);
        if (!match) continue;
        mach_port_t it = 0;
        kern_return_t kr = f_services(0, match, &it);
        if (kr != KERN_SUCCESS) {
            snprintf(g_gpu_info + off, sizeof(g_gpu_info) - off, "%s:kr=%d; ", classes[ci], (int)kr);
            continue;
        }
        int svcCount = 0, statCount = 0;
        mach_port_t svc;
        while ((svc = f_next(it)) != 0) {
            svcCount++;
            CFTypeRef ps = f_prop(svc, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
            if (!ps && f_search) ps = f_search(svc, "IOService", CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 1);
            if (!ps && f_search) ps = f_search(svc, "IOService", CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 2);
            if (ps && CFGetTypeID(ps) == CFDictionaryGetTypeID()) {
                statCount++;
                double d = find_util((CFDictionaryRef)ps);
                if (d >= 0) {
                    *device = d;
                    double r = dict_num((CFDictionaryRef)ps, "Renderer Utilization %");
                    double t = dict_num((CFDictionaryRef)ps, "Tiler Utilization %");
                    double m = dict_num((CFDictionaryRef)ps, "In use system memory");
                    if (r >= 0) *renderer = r;
                    if (t >= 0) *tiler = t;
                    if (m >= 0) *memMB = m / 1048576.0;
                    found = 1;
                } else {
                    append_keys((CFDictionaryRef)ps, g_gpu_info, sizeof(g_gpu_info));
                }
            }
            if (ps) CFRelease(ps);
            f_release(svc);
            if (found) break;
        }
        f_release(it);
        off = strlen(g_gpu_info);
        if (off < sizeof(g_gpu_info) - 80) {
            snprintf(g_gpu_info + off, sizeof(g_gpu_info) - off, " %s:services=%d stats=%d; ",
                     classes[ci], svcCount, statCount);
        }
    }
    return found;
}

/* ---------- CPU / memory ---------- */

int pt_cpu(uint64_t *busy, uint64_t *total, int maxCores) {
    natural_t n = 0;
    processor_info_array_t info = NULL;
    mach_msg_type_number_t cnt = 0;
    if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt) != KERN_SUCCESS) return 0;
    processor_cpu_load_info_t l = (processor_cpu_load_info_t)info;
    int cores = (int)n < maxCores ? (int)n : maxCores;
    for (int i = 0; i < cores; i++) {
        uint64_t u = l[i].cpu_ticks[CPU_STATE_USER];
        uint64_t s = l[i].cpu_ticks[CPU_STATE_SYSTEM];
        uint64_t id = l[i].cpu_ticks[CPU_STATE_IDLE];
        uint64_t ni = l[i].cpu_ticks[CPU_STATE_NICE];
        busy[i] = u + s + ni;
        total[i] = u + s + ni + id;
    }
    vm_deallocate(mach_task_self(), (vm_address_t)info, cnt * sizeof(integer_t));
    return cores;
}

int pt_mem(uint64_t *o) {
    vm_statistics64_data_t v;
    mach_msg_type_number_t c = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&v, &c) != KERN_SUCCESS) return 0;
    vm_size_t ps = 0;
    host_page_size(mach_host_self(), &ps);
    uint64_t p = (uint64_t)ps;
    o[0] = (uint64_t)v.free_count * p;
    o[1] = (uint64_t)v.active_count * p;
    o[2] = (uint64_t)v.inactive_count * p;
    o[3] = (uint64_t)v.wire_count * p;
    o[4] = (uint64_t)v.compressor_page_count * p;
    o[5] = (uint64_t)v.speculative_count * p;
    o[6] = (uint64_t)v.purgeable_count * p;
    o[7] = (uint64_t)v.external_page_count * p;
    return 1;
}

int pt_pressure(void) {
    int level = 0;
    size_t len = sizeof(level);
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &len, NULL, 0) != 0) return -1;
    return level;
}

/* ---------- files ---------- */

char *pt_glob(const char *pattern) {
    sb_t sb;
    sb_init(&sb);
    glob_t g;
    memset(&g, 0, sizeof(g));
    if (glob(pattern, GLOB_NOSORT, NULL, &g) == 0) {
        for (size_t i = 0; i < g.gl_pathc; i++) {
            sb_append(&sb, g.gl_pathv[i], strlen(g.gl_pathv[i]));
            sb_append(&sb, "\n", 1);
        }
    }
    globfree(&g);
    return sb.buf;
}

static uint64_t du_rec(const char *path, int depth) {
    struct stat st;
    if (lstat(path, &st) != 0) return 0;
    uint64_t total = (uint64_t)st.st_blocks * 512ULL;
    if (S_ISDIR(st.st_mode) && depth < 40) {
        DIR *d = opendir(path);
        if (!d) return total;
        struct dirent *e;
        while ((e = readdir(d)) != NULL) {
            if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
            size_t pl = strlen(path) + strlen(e->d_name) + 2;
            char *child = (char *)malloc(pl);
            snprintf(child, pl, "%s/%s", path, e->d_name);
            total += du_rec(child, depth + 1);
            free(child);
        }
        closedir(d);
    }
    return total;
}

uint64_t pt_du(const char *path) {
    if (!path) return 0;
    return du_rec(path, 0);
}

static int path_allowed(const char *p) {
    if (!p || strstr(p, "..")) return 0;
    static const char *roots[] = {
        "/var/mobile/", "/private/var/mobile/",
        "/var/tmp", "/private/var/tmp",
        "/var/log", "/private/var/log",
        "/tmp", "/private/tmp", NULL
    };
    int rootOK = 0;
    for (int i = 0; roots[i]; i++) {
        if (strncmp(p, roots[i], strlen(roots[i])) == 0) { rootOK = 1; break; }
    }
    if (!rootOK) return 0;
    static const char *marks[] = {
        "/Caches", "/tmp", "/Logs", "/log", "/Snapshots", "/MappedImageCache", "/GeoServices", NULL
    };
    for (int i = 0; marks[i]; i++) {
        if (strstr(p, marks[i])) return 1;
    }
    return 0;
}

static uint64_t rm_children(const char *dir, int depth) {
    uint64_t freed = 0;
    DIR *d = opendir(dir);
    if (!d) return 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        size_t pl = strlen(dir) + strlen(e->d_name) + 2;
        char *child = (char *)malloc(pl);
        snprintf(child, pl, "%s/%s", dir, e->d_name);
        struct stat st;
        if (lstat(child, &st) == 0) {
            if (S_ISDIR(st.st_mode) && depth < 40) {
                freed += rm_children(child, depth + 1);
                if (rmdir(child) == 0) freed += (uint64_t)st.st_blocks * 512ULL;
            } else {
                if (unlink(child) == 0) freed += (uint64_t)st.st_blocks * 512ULL;
            }
        }
        free(child);
    }
    closedir(d);
    return freed;
}

uint64_t pt_rmcontents(const char *path) {
    if (!path_allowed(path)) return 0;
    return rm_children(path, 0);
}

/* ---------- RAM purge ---------- */

uint64_t pt_purge(uint64_t targetMB) {
    const size_t chunk = 32ULL << 20;
    uint64_t target = targetMB << 20;
    size_t maxBlocks = (size_t)(target / chunk) + 2;
    void **blocks = (void **)malloc(sizeof(void *) * maxBlocks);
    size_t nb = 0;
    uint64_t done = 0;

    while (done < target && nb < maxBlocks) {
        int pr = pt_pressure();
        if (pr >= 4) break;
        void *p = mmap(NULL, chunk, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        if (p == MAP_FAILED) break;
        for (size_t off = 0; off < chunk; off += 4096) {
            ((volatile char *)p)[off] = 1;
        }
        blocks[nb++] = p;
        done += chunk;
        usleep(20000);
    }
    usleep(300000);
    for (size_t i = 0; i < nb; i++) munmap(blocks[i], chunk);
    free(blocks);
    return done >> 20;
}

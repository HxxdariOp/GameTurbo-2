/*
 * ptroot — tiny root helper (no UIKit / no Swift). Spawned by the app with the root persona.
 * Compiled separately in the GitHub workflow and placed inside the .app bundle.
 */
#include "Bridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/resource.h>
#include <CoreFoundation/CoreFoundation.h>

#define PIDFILE "/var/tmp/ptroot.pid"

/* ---------- helpers ---------- */

typedef void (*proc_cb)(int pid, const char *name, void *ctx);

static void each_proc(proc_cb cb, void *ctx) {
    char *snap = pt_snapshot();
    if (!snap) return;
    char *save = NULL;
    for (char *line = strtok_r(snap, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        char copy[8192];
        strlcpy(copy, line, sizeof(copy));
        char *tok[12];
        int n = 0;
        char *s2 = NULL;
        for (char *t = strtok_r(copy, "|", &s2); t && n < 12; t = strtok_r(NULL, "|", &s2)) tok[n++] = t;
        if (n < 11) continue;
        cb(atoi(tok[0]), tok[10], ctx);
    }
    pt_free(snap);
}

static int name_in(const char *name, const char *csv) {
    if (!csv || !*csv || !strcmp(csv, "-")) return 0;
    size_t nl = strlen(name);
    const char *p = csv;
    while (*p) {
        const char *e = strchr(p, ',');
        size_t len = e ? (size_t)(e - p) : strlen(p);
        if (len == nl && strncmp(p, name, len) == 0) return 1;
        if (!e) break;
        p = e + 1;
    }
    return 0;
}

static int is_protected(const char *name) {
    static const char *hard[] = {
        "launchd", "kernel_task", "SpringBoard", "backboardd", "configd", "powerd",
        "thermalmonitord", "mediaserverd", "UserEventAgent", "cfprefsd", "ptroot", "PerfTool", NULL
    };
    for (int i = 0; hard[i]; i++) {
        if (!strcmp(name, hard[i])) return 1;
    }
    return 0;
}

/* ---------- setpref (binary plist edit) ---------- */

static void kill_cb(int pid, const char *name, void *ctx) {
    (void)ctx;
    if (!strcmp(name, "cfprefsd")) kill(pid, SIGTERM);
}

static int set_pref(const char *path, const char *key, int on) {
    CFMutableDictionaryRef dict = NULL;
    FILE *f = fopen(path, "rb");
    if (f) {
        fseek(f, 0, SEEK_END);
        long sz = ftell(f);
        fseek(f, 0, SEEK_SET);
        if (sz > 0 && sz < 8 * 1024 * 1024) {
            unsigned char *buf = (unsigned char *)malloc((size_t)sz);
            if (buf && fread(buf, 1, (size_t)sz, f) == (size_t)sz) {
                CFDataRef data = CFDataCreate(kCFAllocatorDefault, buf, sz);
                if (data) {
                    CFPropertyListRef pl = CFPropertyListCreateWithData(kCFAllocatorDefault, data,
                                                                        kCFPropertyListMutableContainers, NULL, NULL);
                    if (pl && CFGetTypeID(pl) == CFDictionaryGetTypeID()) dict = (CFMutableDictionaryRef)pl;
                    else if (pl) CFRelease(pl);
                    CFRelease(data);
                }
            }
            free(buf);
        }
        fclose(f);
    }
    if (!dict) {
        dict = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
                                         &kCFTypeDictionaryValueCallBacks);
    }
    CFStringRef k = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    CFDictionarySetValue(dict, k, on ? kCFBooleanTrue : kCFBooleanFalse);
    CFRelease(k);

    CFDataRef out = CFPropertyListCreateData(kCFAllocatorDefault, dict, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
    CFRelease(dict);
    if (!out) return 0;

    char tmp[1024];
    snprintf(tmp, sizeof(tmp), "%s.ptmp", path);
    FILE *w = fopen(tmp, "wb");
    if (!w) { CFRelease(out); return 0; }
    fwrite(CFDataGetBytePtr(out), 1, (size_t)CFDataGetLength(out), w);
    fclose(w);
    CFRelease(out);
    chown(tmp, 501, 501);
    chmod(tmp, 0600);
    if (rename(tmp, path) != 0) return 0;

    each_proc(kill_cb, NULL);   /* make cfprefsd drop its cache */
    return 1;
}

/* ---------- game mode supervisor ---------- */

static volatile sig_atomic_t g_stop = 0;

static void on_term(int s) {
    (void)s;
    g_stop = 1;
}

typedef struct {
    const char *boost;
    int boostNice;
    const char *freeze;
    pid_t frozen[256];
    int nfrozen;
} game_t;

static void game_cb(int pid, const char *name, void *ctx) {
    game_t *g = (game_t *)ctx;
    if (g->boost && g->boost[0] && strcmp(g->boost, "-") != 0 && !strcmp(name, g->boost)) {
        setpriority(PRIO_PROCESS, (id_t)pid, g->boostNice);
    }
    if (name_in(name, g->freeze) && !is_protected(name)) {
        for (int i = 0; i < g->nfrozen; i++) {
            if (g->frozen[i] == pid) return;
        }
        if (g->nfrozen < 256 && kill(pid, SIGSTOP) == 0) g->frozen[g->nfrozen++] = pid;
    }
}

static int game_mode(int secs, const char *boost, int nice, const char *freeze) {
    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);
    FILE *pf = fopen(PIDFILE, "w");
    if (pf) { fprintf(pf, "%d\n", (int)getpid()); fclose(pf); }

    game_t g;
    memset(&g, 0, sizeof(g));
    g.boost = boost;
    g.boostNice = nice;
    g.freeze = freeze;

    time_t end = time(NULL) + secs;
    while (!g_stop && time(NULL) < end) {
        each_proc(game_cb, &g);
        for (int i = 0; i < 6 && !g_stop; i++) usleep(500000);
    }
    for (int i = 0; i < g.nfrozen; i++) kill(g.frozen[i], SIGCONT);
    unlink(PIDFILE);
    return 0;
}

static int read_pidfile(void) {
    FILE *f = fopen(PIDFILE, "r");
    if (!f) return 0;
    int pid = 0;
    if (fscanf(f, "%d", &pid) != 1) pid = 0;
    fclose(f);
    return pid;
}

static void resume_cb(int pid, const char *name, void *ctx) {
    if (name_in(name, (const char *)ctx)) kill(pid, SIGCONT);
}

/* ---------- main ---------- */

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc < 2) return 2;
    const char *cmd = argv[1];

    if (!strcmp(cmd, "whoami")) {
        printf("ROOT:%d\n", (int)getuid());
        return 0;
    }

    if (!strcmp(cmd, "snapshot")) {
        char *s = pt_snapshot();
        if (s) { fputs(s, stdout); pt_free(s); }
        return 0;
    }

    if (!strcmp(cmd, "kill") && argc >= 3) {
        int sig = atoi(argv[2]);
        for (int i = 3; i < argc; i++) {
            int pid = atoi(argv[i]);
            if (pid <= 1) continue;
            int r = kill(pid, sig);
            printf("%d|%s\n", pid, r == 0 ? "ok" : strerror(errno));
        }
        return 0;
    }

    if (!strcmp(cmd, "renice") && argc >= 3) {
        int nice = atoi(argv[2]);
        for (int i = 3; i < argc; i++) {
            int pid = atoi(argv[i]);
            if (pid <= 1) continue;
            int r = setpriority(PRIO_PROCESS, (id_t)pid, nice);
            printf("%d|%s\n", pid, r == 0 ? "ok" : strerror(errno));
        }
        return 0;
    }

    if (!strcmp(cmd, "glob") && argc >= 3) {
        char *g = pt_glob(argv[2]);
        if (g) { fputs(g, stdout); pt_free(g); }
        return 0;
    }

    if (!strcmp(cmd, "dusum")) {
        unsigned long long sum = 0;
        for (int i = 2; i < argc; i++) sum += pt_du(argv[i]);
        printf("%llu\n", sum);
        return 0;
    }

    if (!strcmp(cmd, "rmc")) {
        unsigned long long sum = 0;
        for (int i = 2; i < argc; i++) sum += pt_rmcontents(argv[i]);
        printf("%llu\n", sum);
        return 0;
    }

    if (!strcmp(cmd, "setpref") && argc >= 5) {
        int ok = set_pref(argv[2], argv[3], atoi(argv[4]));
        printf(ok ? "ok\n" : "fail\n");
        return ok ? 0 : 1;
    }

    if (!strcmp(cmd, "gamemode") && argc >= 6) {
        return game_mode(atoi(argv[2]), argv[3], atoi(argv[4]), argv[5]);
    }

    if (!strcmp(cmd, "gamestatus")) {
        int pid = read_pidfile();
        if (pid > 0 && kill(pid, 0) == 0) printf("RUNNING:%d\n", pid);
        else printf("IDLE\n");
        return 0;
    }

    if (!strcmp(cmd, "gamestop")) {
        int pid = read_pidfile();
        if (pid > 0 && kill(pid, 0) == 0) {
            kill(pid, SIGTERM);
            usleep(1800000);
            printf("STOPPED\n");
        } else {
            printf("IDLE\n");
        }
        return 0;
    }

    if (!strcmp(cmd, "resume") && argc >= 3) {
        each_proc(resume_cb, (void *)argv[2]);
        printf("ok\n");
        return 0;
    }

    fprintf(stderr, "unknown command\n");
    return 2;
}

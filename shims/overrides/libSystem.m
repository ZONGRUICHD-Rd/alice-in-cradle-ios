// libSystem compatibility shim for Alice in Cradle on iOS 27 (arm64).
// Provides:
//  1. Case-insensitive path resolution inside the app container (macOS Unity games assume APFS case-insensitivity)
//  2. Save-data redirection: ~/Library/Application Support/NanameHacha/AliceInCradle -> <Container>/Documents/Saves/AliceInCradle
//  3. _smmp alias for Mono's guarded __LINKEDIT _mmap records: strips MAP_JIT on non-executable data pages
//  4. Reported memory override via Info.plist SHIMReportedMemoryGB
//  5. Diagnostic crash handler logging PC/LR + managed Mono stack walk when available

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/ucontext.h>
#include <unistd.h>

#define EXPORT __attribute__((visibility("default")))
#define REAL(ret, name, ...) \
    typedef ret (*Fn)(__VA_ARGS__); \
    static Fn real = NULL; \
    if (!real) real = (Fn)dlsym(RTLD_NEXT, name);

static NSString *gHomeDir = nil;
static NSString *gDocsSavesDir = nil;
static NSString *gBundlePath = nil;

static void ShimInitPaths(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gHomeDir = NSHomeDirectory();
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (docs) {
            gDocsSavesDir = [docs stringByAppendingPathComponent:@"Saves/AliceInCradle"];
            [NSFileManager.defaultManager createDirectoryAtPath:gDocsSavesDir
                                    withIntermediateDirectories:YES
                                                     attributes:nil
                                                          error:nil];
        }
        gBundlePath = NSBundle.mainBundle.bundlePath;
    });
}

// Resolve a single missing path component case-insensitively inside container/bundle
static bool ResolveCaseInsensitive(const char *path, char *out, size_t outSize) {
    if (!path || path[0] != '/' || !gHomeDir) return false;
    const char *home = gHomeDir.UTF8String;
    const char *bundle = gBundlePath ? gBundlePath.UTF8String : NULL;
    size_t homeLen = strlen(home);
    size_t bundleLen = bundle ? strlen(bundle) : 0;

    size_t prefixLen = 0;
    if (strncmp(path, home, homeLen) == 0) {
        prefixLen = homeLen;
    } else if (bundle && strncmp(path, bundle, bundleLen) == 0) {
        prefixLen = bundleLen;
    } else {
        return false;
    }

    if (prefixLen >= outSize) return false;
    memcpy(out, path, prefixLen);
    out[prefixLen] = '\0';

    const char *cursor = path + prefixLen;
    while (*cursor == '/') cursor++;

    while (*cursor) {
        const char *slash = strchr(cursor, '/');
        size_t compLen = slash ? (size_t)(slash - cursor) : strlen(cursor);
        if (compLen == 0) {
            cursor = slash + 1;
            continue;
        }
        char comp[NAME_MAX + 1];
        if (compLen > NAME_MAX) return false;
        memcpy(comp, cursor, compLen);
        comp[compLen] = '\0';

        // Fast path: exact match exists
        size_t curLen = strlen(out);
        if (curLen + 1 + compLen >= outSize) return false;
        char candidate[PATH_MAX];
        snprintf(candidate, sizeof(candidate), "%s/%s", out, comp);
        struct stat st;
        if (lstat(candidate, &st) == 0) {
            strlcpy(out, candidate, outSize);
        } else {
            // Case-insensitive directory scan
            DIR *d = opendir(out);
            bool found = false;
            if (d) {
                struct dirent *ent;
                while ((ent = readdir(d)) != NULL) {
                    if (strcasecmp(ent->d_name, comp) == 0) {
                        snprintf(candidate, sizeof(candidate), "%s/%s", out, ent->d_name);
                        strlcpy(out, candidate, outSize);
                        found = true;
                        break;
                    }
                }
                closedir(d);
            }
            if (!found) {
                // Keep original component for creation paths (e.g. O_CREAT)
                snprintf(candidate, sizeof(candidate), "%s/%s", out, comp);
                strlcpy(out, candidate, outSize);
            }
        }
        cursor = slash ? (slash + 1) : (cursor + compLen);
        while (*cursor == '/') cursor++;
    }
    return true;
}

static const char *RedirectPath(const char *path, char *buf, size_t bufSize) {
    if (!path || !path[0]) return path;
    ShimInitPaths();

    // Redirect macOS save directory into Files-visible Documents/Saves/AliceInCradle
    if (gDocsSavesDir) {
        const char *marker = "/Library/Application Support/NanameHacha/AliceInCradle";
        const char *hit = strstr(path, marker);
        if (hit) {
            const char *rest = hit + strlen(marker);
            snprintf(buf, bufSize, "%s%s", gDocsSavesDir.UTF8String, rest);
            return buf;
        }
        const char *unityMarker = "/Library/Application Support/unity.NanameHacha.AliceInCradle";
        const char *uhit = strstr(path, unityMarker);
        if (uhit) {
            const char *rest = uhit + strlen(unityMarker);
            snprintf(buf, bufSize, "%s%s", gDocsSavesDir.UTF8String, rest);
            return buf;
        }
    }

    // Fast path: existing file doesn't need case-insensitive scan
    struct stat st;
    if (lstat(path, &st) == 0) return path;

    if (ResolveCaseInsensitive(path, buf, bufSize)) {
        return buf;
    }
    return path;
}

EXPORT int open(const char *path, int oflag, ...) {
    mode_t mode = 0;
    if (oflag & O_CREAT) {
        va_list ap;
        va_start(ap, oflag);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    REAL(int, "open", const char *, int, ...);
    char buf[PATH_MAX];
    const char *p = RedirectPath(path, buf, sizeof(buf));
    return (oflag & O_CREAT) ? real(p, oflag, mode) : real(p, oflag);
}

EXPORT int stat(const char *path, struct stat *st) {
    REAL(int, "stat", const char *, struct stat *);
    char buf[PATH_MAX];
    return real(RedirectPath(path, buf, sizeof(buf)), st);
}

EXPORT int lstat(const char *path, struct stat *st) {
    REAL(int, "lstat", const char *, struct stat *);
    char buf[PATH_MAX];
    return real(RedirectPath(path, buf, sizeof(buf)), st);
}

EXPORT int access(const char *path, int mode) {
    REAL(int, "access", const char *, int);
    char buf[PATH_MAX];
    return real(RedirectPath(path, buf, sizeof(buf)), mode);
}

EXPORT FILE *fopen(const char *path, const char *mode) {
    REAL(FILE *, "fopen", const char *, const char *);
    char buf[PATH_MAX];
    return real(RedirectPath(path, buf, sizeof(buf)), mode);
}

EXPORT DIR *opendir(const char *path) {
    REAL(DIR *, "opendir", const char *);
    char buf[PATH_MAX];
    return real(RedirectPath(path, buf, sizeof(buf)));
}

EXPORT char *realpath$DARWIN_EXTSN(const char *path, char *out) {
    REAL(char *, "realpath$DARWIN_EXTSN", const char *, char *);
    char buf[PATH_MAX];
    return real(RedirectPath(path, buf, sizeof(buf)), out);
}

// MARK: Mono non-executable data mapping adapter (_smmp)
// When libmonobdwgc-2.0.dylib has its guarded __LINKEDIT _mmap records aliased to _smmp,
// strip MAP_JIT on non-executable mappings so iOS 27 kernel permits the allocation without JIT.
#ifndef MAP_JIT
#define MAP_JIT 0x0800
#endif

EXPORT void *smmp(void *addr, size_t len, int prot, int flags, int fd, off_t offset) {
    REAL(void *, "mmap", void *, size_t, int, int, int, off_t);
    int adjustedFlags = flags;
    if ((flags & MAP_JIT) && !(prot & PROT_EXEC)) {
        adjustedFlags &= ~MAP_JIT;
    }
    return real(addr, len, prot, adjustedFlags, fd, offset);
}

// MARK: Reported RAM override
static uint64_t ShimReportedMemory(void) {
    static uint64_t cached = UINT64_MAX;
    if (cached == UINT64_MAX) {
        NSNumber *gb = NSBundle.mainBundle.infoDictionary[@"SHIMReportedMemoryGB"];
        cached = gb ? (uint64_t)(gb.doubleValue * 1073741824.0) : 0;
    }
    return cached;
}

EXPORT int sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    REAL(int, "sysctlbyname", const char *, void *, size_t *, void *, size_t);
    int r = real(name, oldp, oldlenp, newp, newlen);
    uint64_t mem = ShimReportedMemory();
    if (r == 0 && name && mem && (!strcmp(name, "hw.memsize") || !strcmp(name, "hw.physmem")) &&
        oldp && oldlenp && *oldlenp >= sizeof(uint64_t)) {
        *(uint64_t *)oldp = mem;
    }
    return r;
}

EXPORT int sysctl(int *mib, u_int n, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    REAL(int, "sysctl", int *, u_int, void *, size_t *, void *, size_t);
    int r = real(mib, n, oldp, oldlenp, newp, newlen);
    uint64_t mem = ShimReportedMemory();
    if (r == 0 && n >= 2 && mib[0] == CTL_HW && mib[1] == HW_MEMSIZE && mem &&
        oldp && oldlenp && *oldlenp >= sizeof(uint64_t)) {
        *(uint64_t *)oldp = mem;
    }
    return r;
}

// MARK: Crash diagnostics with optional Mono stack trace
static struct sigaction gGameAction[NSIG];

static void ShimLogFaultAddress(const char *label, uintptr_t addr) {
    Dl_info d = {0};
    char line[400];
    if (dladdr((void *)addr, &d) && d.dli_fname) {
        const char *base = strrchr(d.dli_fname, '/');
        snprintf(line, sizeof(line), "AIC-SHIM FAULT %s 0x%lx = %s+0x%lx (%s)\n",
                 label, (unsigned long)addr, base ? base + 1 : d.dli_fname,
                 (unsigned long)(addr - (uintptr_t)d.dli_fbase), d.dli_sname ? d.dli_sname : "?");
    } else {
        snprintf(line, sizeof(line), "AIC-SHIM FAULT %s 0x%lx\n", label, (unsigned long)addr);
    }
    (void)write(STDERR_FILENO, line, strlen(line));
}

static int ShimMonoWalkFrame(void *method, int32_t nativeOffset, int32_t ilOffset, int managed, void *ctx) {
    if (!method || !ctx) return 0;
    char *(*nameFn)(void *, int) = dlsym(ctx, "mono_method_full_name");
    void (*freeFn)(void *) = dlsym(ctx, "mono_free");
    if (nameFn && freeFn) {
        char *fullName = nameFn(method, 1);
        if (fullName) {
            fprintf(stderr, "AIC-SHIM MANAGED %s (il=0x%x, native=0x%x)\n", fullName, ilOffset, nativeOffset);
            freeFn(fullName);
        }
    }
    return 0;
}

static void ShimFaultHandler(int sig, siginfo_t *si, void *ctx) {
    static int logged = 0;
    if (logged++ < 3) {
        ucontext_t *uc = (ucontext_t *)ctx;
        char line[128];
        snprintf(line, sizeof(line), "AIC-SHIM FAULT signal=%d addr=0x%lx\n", sig, (unsigned long)(si ? si->si_addr : 0));
        (void)write(STDERR_FILENO, line, strlen(line));
        if (uc && uc->uc_mcontext) {
            ShimLogFaultAddress("pc", (uintptr_t)arm_thread_state64_get_pc(uc->uc_mcontext->__ss));
            ShimLogFaultAddress("lr", (uintptr_t)arm_thread_state64_get_lr(uc->uc_mcontext->__ss));
        }
        NSString *monoPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Mac/Contents/Frameworks/libmonobdwgc-2.0.dylib"];
        void *rt = dlopen(monoPath.UTF8String, RTLD_LAZY | RTLD_NOLOAD);
        if (rt) {
            void (*walk)(int (*)(void *, int32_t, int32_t, int, void *), void *) = dlsym(rt, "mono_stack_walk");
            if (walk) walk(ShimMonoWalkFrame, rt);
        }
    }
    struct sigaction *g = &gGameAction[sig];
    if ((g->sa_flags & SA_SIGINFO) && g->sa_sigaction) {
        g->sa_sigaction(sig, si, ctx);
    } else if (g->sa_handler != SIG_DFL && g->sa_handler != SIG_IGN && g->sa_handler != NULL) {
        g->sa_handler(sig);
    } else {
        signal(sig, SIG_DFL);
    }
}

EXPORT int sigaction(int sig, const struct sigaction *act, struct sigaction *old) {
    REAL(int, "sigaction", int, const struct sigaction *, struct sigaction *);
    bool isFault = (sig == SIGSEGV || sig == SIGBUS || sig == SIGILL || sig == SIGABRT);
    if (!isFault || !act || act->sa_handler == SIG_DFL || act->sa_handler == SIG_IGN) {
        return real(sig, act, old);
    }
    struct sigaction prev = gGameAction[sig];
    struct sigaction mine = *act;
    mine.sa_sigaction = ShimFaultHandler;
    mine.sa_flags |= SA_SIGINFO;
    int r = real(sig, &mine, old);
    if (r == 0) {
        if (old && old->sa_sigaction == ShimFaultHandler) *old = prev;
        gGameAction[sig] = *act;
    }
    return r;
}

EXPORT void (*signal(int sig, void (*h)(int)))(int) {
    struct sigaction act = {0}, old = {0};
    act.sa_handler = h;
    sigemptyset(&act.sa_mask);
    return sigaction(sig, &act, &old) == 0 ? old.sa_handler : SIG_ERR;
}

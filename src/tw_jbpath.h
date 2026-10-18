// tw_jbpath.h — the ONE place that maps a bootstrap-relative path to a real
// path, per package flavor. This is also the only file allowed to contain the
// literal string "/var/jb" (check-source.sh enforces that).
//
// Exactly one of TW_SCHEME_ROOTHIDE / TW_SCHEME_ROOTLESS is defined by
// build-ios.sh --scheme. There is no silent default: defining both, or
// neither, is a compile error, so a wrong build can never ship as the other
// layout.
//
//   roothide: jbroot()/rootfs()/jbrand() come from libroothide (linked via our
//             own MIT stub). The bootstrap root is randomized per jailbreak, so
//             these must be real function calls, resolved at runtime.
//   rootless: the bootstrap lives at a fixed /var/jb. jbroot()/rootfs() are
//             real inline functions (not literal-only macros) that add or strip
//             that prefix; jbrand() returns 0. libroothide is never linked and
//             upstream stub.h (which returns paths unchanged) is never used.
//
// Wrap ONLY paths that live inside the bootstrap. Never wrap /System, system
// /usr/lib dylibs, app containers, preference domains read by cfprefsd, or hook
// targets: those belong to the real rootfs on both layouts.
#pragma once

#if defined(TW_SCHEME_ROOTHIDE) && defined(TW_SCHEME_ROOTLESS)
#error "tw_jbpath.h: both TW_SCHEME_ROOTHIDE and TW_SCHEME_ROOTLESS are defined"
#endif
#if !defined(TW_SCHEME_ROOTHIDE) && !defined(TW_SCHEME_ROOTLESS)
#error "tw_jbpath.h: define TW_SCHEME_ROOTHIDE=1 or TW_SCHEME_ROOTLESS=1 (build-ios.sh --scheme)"
#endif

// TW_JBROOT(path): THE path macro. Call sites use it, never jbroot() directly,
// so one grep finds every bootstrap-relative path. Returns a const char * that
// stays valid until a few later calls (both layouts cache the result).
#define TW_JBROOT(path) jbroot(path)

#if defined(TW_SCHEME_ROOTHIDE)

#include "roothide.h"  // official MIT header; symbols resolve from libroothide

#else  // TW_SCHEME_ROOTLESS

#include <string.h>
#include <stdlib.h>
#ifdef __cplusplus
#include <string>
#endif
#ifdef __OBJC__
#import <Foundation/NSString.h>
#endif

#define TW_ROOTLESS_PREFIX "/var/jb"

#ifdef __cplusplus
extern "C" {
#endif

// A jbroot-based path maps to <prefix><path> on rootless. Idempotent: a path
// already under the prefix is returned unchanged.
static inline const char *jbroot_alloc(const char *path) {
    if (!path) return NULL;
    size_t plen = sizeof(TW_ROOTLESS_PREFIX) - 1;
    if (strncmp(path, TW_ROOTLESS_PREFIX, plen) == 0
        && (path[plen] == '/' || path[plen] == '\0')) {
        return strdup(path);
    }
    size_t need = plen + strlen(path) + 1;
    char *out = (char *)malloc(need);
    if (!out) return NULL;
    memcpy(out, TW_ROOTLESS_PREFIX, plen);
    strcpy(out + plen, path);
    return out;
}

// A rootfs-based path maps to itself with the prefix stripped, for persisting a
// path in portable form. Inverse of jbroot_alloc.
static inline const char *rootfs_alloc(const char *path) {
    if (!path) return NULL;
    size_t plen = sizeof(TW_ROOTLESS_PREFIX) - 1;
    if (strncmp(path, TW_ROOTLESS_PREFIX, plen) == 0
        && (path[plen] == '/' || path[plen] == '\0')) {
        return strdup(path + plen);
    }
    return strdup(path);
}

static inline const char *jbrootat_alloc(int fd, const char *path) {
    (void)fd;
    return jbroot_alloc(path);
}

static inline unsigned long long jbrand(void) { return 0ULL; }

// The auto-cached forms mirror libroothide's contract. A tiny ring of buffers
// keeps the "return points into a static cache" convenience for call sites.
static inline const char *tw_jb_cache_put(const char *heap) {
    enum { N = 8 };
    static char *slots[N];
    static int next;
    if (!heap) return NULL;
    int i = next++ % N;
    free(slots[i]);
    slots[i] = (char *)heap;
    return heap;
}
static inline const char *jbroot(const char *path) { return tw_jb_cache_put(jbroot_alloc(path)); }
static inline const char *rootfs(const char *path) { return tw_jb_cache_put(rootfs_alloc(path)); }

#ifdef __cplusplus
}  // extern "C"
#endif

#ifdef __OBJC__
__attribute__((overloadable)) static inline NSString *jbroot(NSString *path) {
    if (![path hasPrefix:@TW_ROOTLESS_PREFIX])
        return [@TW_ROOTLESS_PREFIX stringByAppendingString:path];
    return path;
}
__attribute__((overloadable)) static inline NSString *rootfs(NSString *path) {
    if ([path hasPrefix:@TW_ROOTLESS_PREFIX])
        return [path substringFromIndex:(sizeof(TW_ROOTLESS_PREFIX) - 1)];
    return path;
}
#endif

#ifdef __cplusplus
static inline std::string jbroot(std::string path) {
    std::string prefix = TW_ROOTLESS_PREFIX;
    if (path.compare(0, prefix.size(), prefix) == 0
        && (path.size() == prefix.size() || path[prefix.size()] == '/')) {
        return path;
    }
    return prefix + path;
}
static inline std::string rootfs(std::string path) {
    std::string prefix = TW_ROOTLESS_PREFIX;
    if (path.compare(0, prefix.size(), prefix) == 0
        && (path.size() == prefix.size() || path[prefix.size()] == '/')) {
        return path.substr(prefix.size());
    }
    return path;
}
#endif

#endif  // TW_SCHEME_ROOTLESS

// tw_hook.h — Logos-free ObjC method hooking through the runtime only.
//
// This is the default backend: no Substrate, no logo.pl, no %hook. A hook is
// written as an ordinary C/ObjC function and registered with TW_HOOK; a single
// guarded constructor in tweak.m then calls tw_install_all() (see
// constructor-safe-mode). TW_HOOK only appends to a table — it installs
// nothing on its own, so no hook runs before the identity guard and kill
// switch have passed.
//
// All hooks and the one call to tw_install_all() must live in ONE translation
// unit (tweak.m). The table has static storage, so a second .m that defined
// hooks would get its own empty table. Class methods and C-function hooks are
// deliberately NOT covered here; only instance methods.
//
// Before installing, the target method's type encoding is compared against the
// encoding the hook was written for, after normalizing away frame size,
// per-argument offsets and the r/n/V qualifiers. A mismatch (or a nil/empty
// encoding, or an absent method) skips the hook: the original stays, one line
// is logged, and the feature is left degraded rather than corrupting registers.
// Precedent: a shipping tweak's runtime-ABI guard (see SKILL.md).
//
// A class that is not loaded yet (it lives in a framework or plugin the host
// dlopens later) is not a skip: the hook stays pending, and every image dyld
// adds afterwards schedules one retry of the pending hooks on the main queue —
// by then the ObjC runtime has registered the new image's classes. The table is
// only ever touched on the main thread (the constructor, then main-queue
// retries), so it needs no lock.
#pragma once
#import <objc/runtime.h>
#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <mach-o/dyld.h>
#include <os/log.h>
#include <string.h>
#include "tw_config.h"

// One os_log subsystem, equal to the package id. Static string only.
static inline os_log_t tw_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create(TW_PACKAGE_ID, "hook"); });
    return log;
}

// Normalize an ObjC method type encoding for structural comparison: drop the
// digits (frame size and per-argument byte offsets) and the r/n/V type
// qualifiers, keeping the return type followed by the argument types. self and
// _cmd are part of the string on both sides, so they cancel out. Objects all
// encode as '@' and blocks as '@?', so this guards register class and struct
// layout, not the concrete id class or block signature (guard those at runtime
// and record them in AGENTS.md). Writes at most cap-1 chars plus a NUL.
static inline int tw_encoding_normalize(const char *enc, char *out, size_t cap) {
    if (!enc || !*enc || cap == 0) { if (cap) out[0] = '\0'; return 0; }
    size_t j = 0;
    for (const char *p = enc; *p && j + 1 < cap; ++p) {
        if (*p >= '0' && *p <= '9') continue;      // frame size / offsets
        if (*p == 'r' || *p == 'n' || *p == 'V') continue; // const / in / oneway
        out[j++] = *p;
    }
    out[j] = '\0';
    return (int)j;
}

static inline int tw_encoding_matches(const char *expected, const char *actual) {
    if (!expected || !*expected || !actual || !*actual) return 0;
    char a[256], b[256];
    tw_encoding_normalize(expected, a, sizeof a);
    tw_encoding_normalize(actual, b, sizeof b);
    return a[0] != '\0' && strcmp(a, b) == 0;
}

typedef struct tw_hook_entry {
    const char *name;
    const char *cls;
    const char *sel;
    const char *enc;   // encoding the hook body was written for
    IMP replacement;
    IMP *orig;         // where the callable original is stored
    int state;         // TW_HOOK_PENDING until tw_hook_install_one decides
} tw_hook_entry;

enum { TW_HOOK_PENDING = 0, TW_HOOK_INSTALLED = 1, TW_HOOK_SKIPPED = 2 };

#ifndef TW_HOOK_MAX
#define TW_HOOK_MAX 128
#endif

static tw_hook_entry tw_hook_table[TW_HOOK_MAX];
static int tw_hook_count;

static inline void tw_hook_register(const tw_hook_entry *entry) {
    if (tw_hook_count < TW_HOOK_MAX) tw_hook_table[tw_hook_count++] = *entry;
}

// Decide one pending entry: installed, skipped for good, or (class not loaded
// yet) still pending. Until it installs, the original pointer stays NULL and
// the body must guard TW_ORIG before calling it.
static inline void tw_hook_install_one(tw_hook_entry *e) {
    if (e->orig) *e->orig = NULL;
    Class c = objc_getClass(e->cls);
    if (!c) return;  // stays TW_HOOK_PENDING; retried when an image is added
    e->state = TW_HOOK_SKIPPED;
    SEL sel = sel_registerName(e->sel);
    Method m = class_getInstanceMethod(c, sel);
    if (!m) {
        os_log_error(tw_log(), "skip %s: method absent", e->name);
        return;
    }
    const char *actual = method_getTypeEncoding(m);
    if (!tw_encoding_matches(e->enc, actual)) {
        os_log_error(tw_log(), "skip %s: encoding mismatch", e->name);
        return;
    }
    IMP current = method_getImplementation(m);
    // class_addMethod succeeds only when c does not own the method (it merely
    // inherits it): add an override on c and chain to the inherited IMP.
    // Otherwise c owns the method: swap the IMP in place.
    if (class_addMethod(c, sel, e->replacement, actual)) {
        if (e->orig) *e->orig = current;
    } else {
        IMP previous = method_setImplementation(m, e->replacement);
        if (e->orig) *e->orig = previous;
    }
    e->state = TW_HOOK_INSTALLED;
}

// Try every pending entry once. Returns how many are still pending.
static inline int tw_hook_install_pending(void) {
    int pending = 0;
    for (int i = 0; i < tw_hook_count; ++i) {
        tw_hook_entry *e = &tw_hook_table[i];
        if (e->state != TW_HOOK_PENDING) continue;
        tw_hook_install_one(e);
        if (e->state == TW_HOOK_PENDING) pending++;
    }
    return pending;
}

static inline int tw_hook_count_state(int state) {
    int n = 0;
    for (int i = 0; i < tw_hook_count; ++i) n += tw_hook_table[i].state == state;
    return n;
}

static int tw_hook_retry_scheduled;  // main thread only

static void tw_hook_on_add_image(const struct mach_header *mh, intptr_t slide) {
    (void)mh; (void)slide;
    // Called on whichever thread is loading the image; hop to the main queue
    // and coalesce a burst of images into one retry.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (tw_hook_retry_scheduled) return;
        tw_hook_retry_scheduled = 1;
        dispatch_async(dispatch_get_main_queue(), ^{
            tw_hook_retry_scheduled = 0;
            int before = tw_hook_count_state(TW_HOOK_INSTALLED);
            tw_hook_install_pending();
            int now = tw_hook_count_state(TW_HOOK_INSTALLED);
            if (now != before) os_log(tw_log(), "late install: %d of %d hooks now installed", now, tw_hook_count);
        });
    });
}

static inline void tw_install_all(void) {
    int pending = tw_hook_install_pending();
    os_log(tw_log(), "installed %d of %d hooks, %d waiting for their class",
           tw_hook_count_state(TW_HOOK_INSTALLED), tw_hook_count, pending);
    if (pending) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{ _dyld_register_func_for_add_image(tw_hook_on_add_image); });
    }
}

#define TW_CAT_(a, b) a##b
#define TW_CAT(a, b) TW_CAT_(a, b)

// @encode tokens do not concatenate as adjacent string literals, so the expected
// encoding is given as a NULL-terminated list of @encode results and joined at
// registration (a constructor, so runtime). Return type, then self ("@") and
// _cmd (":"), then the argument types:
//
//   TW_ENC(@encode(void), "@:", @encode(NSInteger))
//
// Hand-write a raw string element where @encode cannot express the target.
#define TW_ENC(...) ((const char *const[]){ __VA_ARGS__, (const char *)0 })

static inline const char *tw_join_enc(char *buf, size_t cap, const char *const *parts) {
    size_t j = 0;
    for (int i = 0; parts[i]; ++i) {
        for (const char *p = parts[i]; *p && j + 1 < cap; ++p) buf[j++] = *p;
    }
    if (cap) buf[j] = '\0';
    return buf;
}

// TW_HOOK(Name, "ClassName", "selector:", TW_ENC(...), ReturnType, args...)
// {
//     ... body; call TW_ORIG(Name)(self, _cmd, args...) ...
// }
// The encoding is compared (normalized) against the live method before the hook
// installs; a mismatch skips it. TW_ENC(...) is required (check-source.sh
// rejects a TW_HOOK without it).
#define TW_ORIG(NAME) (TW_CAT(NAME, _orig))
#define TW_HOOK(NAME, CLSNAME, SELNAME, ENCLIST, RET, ...) \
    static char TW_CAT(NAME, _encbuf)[256]; \
    static RET (*TW_CAT(NAME, _orig))(id, SEL, ##__VA_ARGS__); \
    static RET TW_CAT(NAME, _fn)(id self, SEL _cmd, ##__VA_ARGS__); \
    __attribute__((constructor(200))) static void TW_CAT(NAME, _reg)(void) { \
        const char *enc = tw_join_enc(TW_CAT(NAME, _encbuf), \
                                      sizeof(TW_CAT(NAME, _encbuf)), ENCLIST); \
        tw_hook_entry e = { #NAME, CLSNAME, SELNAME, enc, \
                            (IMP)TW_CAT(NAME, _fn), (IMP *)&TW_CAT(NAME, _orig), \
                            TW_HOOK_PENDING }; \
        tw_hook_register(&e); \
    } \
    static RET TW_CAT(NAME, _fn)(id self, SEL _cmd, ##__VA_ARGS__)

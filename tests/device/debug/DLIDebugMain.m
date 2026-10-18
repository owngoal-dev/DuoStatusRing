// DLIDebugMain.m — entry of the development-only DuoStatusRingDebug.dylib, loaded
// into SpringBoard next to the tweak on a vphone guest (tests/device/deploy.sh).
// Never packaged: the release build (scripts/build-ios.sh) compiles src/ only.
#import <Foundation/Foundation.h>
#include <string.h>
#import "DLIAnimationRecorder.h"
#import "DLIDebugCapture.h"
#import "DLIDebugDump.h"

void DLIDebugHooksInstall(void);

__attribute__((constructor)) static void DLIDebugMain(void) {
    const char *name = getprogname();
    if (!name || strcmp(name, "SpringBoard") != 0) return;
    DLIDebugDumpInstall();
    DLIAnimationRecorderInstall();
    DLIDebugCaptureInstall();
    DLIDebugHooksInstall();
}

#ifndef ALICE_SHIM_COMMON_H
#define ALICE_SHIM_COMMON_H

#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdbool.h>

#define SHIM_EXPORT __attribute__((visibility("default")))

#ifdef __cplusplus
extern "C" {
#endif

// Shared virtual input & telemetry hooks resolved across shim dylibs via dlsym or direct link
SHIM_EXPORT void ShimPostVirtualKey(unsigned short macKeyCode, BOOL isDown, NSString *characters);
SHIM_EXPORT void ShimSetVirtualKeyState(unsigned short macKeyCode, BOOL isDown);
SHIM_EXPORT BOOL ShimGetVirtualKeyState(unsigned short macKeyCode);
SHIM_EXPORT void ShimRecordPresentedFrame(void);
SHIM_EXPORT unsigned ShimPresentedFPS(void);
SHIM_EXPORT int ShimTargetFPS(void);
SHIM_EXPORT void ShimSetTargetFPS(int fps);

#ifdef __cplusplus
}
#endif

#endif // ALICE_SHIM_COMMON_H

// Real-time presented FPS & memory telemetry for Alice in Cradle iOS 27 HUD.
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <mach/mach.h>
#include <stdatomic.h>
#include <dlfcn.h>

#define EXPORT __attribute__((visibility("default")))

static _Atomic unsigned gFrameCount = 0;
static _Atomic unsigned gPresentedFPS = 0;
static _Atomic int gTargetFPS = 120;
static CFTimeInterval gLastSampleTime = 0;

EXPORT void ShimRecordPresentedFrame(void) {
    unsigned c = atomic_fetch_add(&gFrameCount, 1) + 1;
    CFTimeInterval now = CACurrentMediaTime();
    if (gLastSampleTime == 0) {
        gLastSampleTime = now;
        return;
    }
    CFTimeInterval dt = now - gLastSampleTime;
    if (dt >= 0.5) {
        unsigned fps = (unsigned)((double)c / dt + 0.5);
        atomic_store(&gPresentedFPS, fps);
        atomic_store(&gFrameCount, 0);
        gLastSampleTime = now;
    }
}

EXPORT unsigned ShimPresentedFPS(void) {
    return atomic_load(&gPresentedFPS);
}

EXPORT int ShimTargetFPS(void) {
    return atomic_load(&gTargetFPS);
}

EXPORT void ShimSetTargetFPS(int fps) {
    int clamped = (fps >= 90) ? 120 : 60;
    atomic_store(&gTargetFPS, clamped);
    void (*cvSet)(int) = (void (*)(int))dlsym(RTLD_DEFAULT, "ShimCVSetTargetFPS");
    if (cvSet) cvSet(clamped);
}

EXPORT double ShimMemoryFootprintMB(void) {
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &count) == KERN_SUCCESS) {
        return (double)vmInfo.phys_footprint / (1024.0 * 1024.0);
    }
    return 0.0;
}

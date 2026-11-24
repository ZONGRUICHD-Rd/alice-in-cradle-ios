// Process-level runtime hooks installed via __attribute__((constructor)) before main().
//  - NSBundle mainBundle path redirection for Mac/Contents bundle layout (SHIMMacRoot = "Mac")
//  - Automatic Mono AOT/Interpreter mode switch on libmonobdwgc load (configurable via Info.plist AICMonoMode)
//  - Metal compatibility fixes: MTLStorageModeManaged(1) -> MTLStorageModeShared(0), Mac2 GPU family,
//    CAMetalLayer drawable presentation telemetry for 60/120Hz FPS HUD
//  - Safe NSProcessInfo physicalMemory override when SHIMReportedMemoryGB is set

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdlib.h>
#include <string.h>

extern void ShimRecordPresentedFrame(void);

// MonoAotMode values from Mono runtime
enum {
    AIC_MONO_AOT_MODE_NONE = 0,        // Standard JIT (requires JIT enabled in LiveContainer/StikDebug)
    AIC_MONO_AOT_MODE_INTERP = 5,      // AOT + Interpreter fallback (no JIT)
    AIC_MONO_AOT_MODE_INTERP_ONLY = 8, // Pure Interpreter (no JIT, no AOT binaries needed)
};

static int ConfiguredMonoMode(void) {
    const char *env = getenv("SHIM_MONO_AOT_MODE");
    if (env && env[0]) return atoi(env);
    id plistVal = NSBundle.mainBundle.infoDictionary[@"AICMonoMode"];
    if ([plistVal isKindOfClass:NSNumber.class]) return [plistVal intValue];
    if ([plistVal isKindOfClass:NSString.class]) {
        NSString *s = [(NSString *)plistVal lowercaseString];
        if ([s isEqualToString:@"jit"]) return AIC_MONO_AOT_MODE_NONE;
        if ([s isEqualToString:@"aot"]) return AIC_MONO_AOT_MODE_INTERP;
        if ([s isEqualToString:@"interp"]) return AIC_MONO_AOT_MODE_INTERP_ONLY;
        return [s intValue];
    }
    return AIC_MONO_AOT_MODE_INTERP_ONLY;
}

static void OnDyldImageAdded(const struct mach_header *mh, intptr_t slide) {
    (void)slide;
    Dl_info info = {0};
    if (!dladdr(mh, &info) || !info.dli_fname) return;
    if (!strstr(info.dli_fname, "libmonobdwgc")) return;

    int mode = ConfiguredMonoMode();
    if (mode == AIC_MONO_AOT_MODE_NONE) {
        NSLog(@"AIC-SHIM Mono loaded (%s): JIT mode requested (mode=0)", info.dli_fname);
        return;
    }

    void *handle = dlopen(info.dli_fname, RTLD_NOLOAD | RTLD_LAZY);
    void (*setAotMode)(int) = handle ? (void (*)(int))dlsym(handle, "mono_jit_set_aot_mode") : NULL;
    NSLog(@"AIC-SHIM Mono loaded (%s): setting mono_jit_set_aot_mode(%d) [%s]",
          info.dli_fname, mode, setAotMode ? "OK" : "SYMBOL MISSING");
    if (setAotMode) {
        setAotMode(mode);
    }
}

// MARK: NSBundle Mac/Contents redirection
static NSString *gMacRootPath = nil;
static IMP gOrigBundlePath, gOrigExecPath, gOrigResourcePath;
static IMP gOrigBundleURL, gOrigExecURL, gOrigResourceURL;
static IMP gOrigPathForRes, gOrigURLForRes;

static NSString *HookBundlePath(NSBundle *self, SEL _cmd) {
    if (self == NSBundle.mainBundle && gMacRootPath) return gMacRootPath;
    return ((NSString *(*)(id, SEL))gOrigBundlePath)(self, _cmd);
}

static NSString *HookResourcePath(NSBundle *self, SEL _cmd) {
    if (self == NSBundle.mainBundle && gMacRootPath) {
        return [gMacRootPath stringByAppendingPathComponent:@"Contents/Resources"];
    }
    return ((NSString *(*)(id, SEL))gOrigResourcePath)(self, _cmd);
}

static NSString *HookExecutablePath(NSBundle *self, SEL _cmd) {
    NSString *real = ((NSString *(*)(id, SEL))gOrigExecPath)(self, _cmd);
    if (self != NSBundle.mainBundle || !gMacRootPath) return real;
    return [gMacRootPath stringByAppendingFormat:@"/Contents/MacOS/%@", real.lastPathComponent];
}

static NSURL *HookBundleURL(NSBundle *self, SEL _cmd) {
    if (self == NSBundle.mainBundle && gMacRootPath) {
        return [NSURL fileURLWithPath:gMacRootPath isDirectory:YES];
    }
    return ((NSURL *(*)(id, SEL))gOrigBundleURL)(self, _cmd);
}

static NSURL *HookResourceURL(NSBundle *self, SEL _cmd) {
    if (self == NSBundle.mainBundle && gMacRootPath) {
        return [NSURL fileURLWithPath:[gMacRootPath stringByAppendingPathComponent:@"Contents/Resources"] isDirectory:YES];
    }
    return ((NSURL *(*)(id, SEL))gOrigResourceURL)(self, _cmd);
}

static NSURL *HookExecutableURL(NSBundle *self, SEL _cmd) {
    if (self == NSBundle.mainBundle && gMacRootPath) {
        return [NSURL fileURLWithPath:HookExecutablePath(self, @selector(executablePath))];
    }
    return ((NSURL *(*)(id, SEL))gOrigExecURL)(self, _cmd);
}

static NSString *FindMacResource(NSString *name, NSString *ext) {
    if (!gMacRootPath || !name) return nil;
    NSString *file = ext.length ? [name stringByAppendingPathExtension:ext] : name;
    NSString *candidate = [gMacRootPath stringByAppendingFormat:@"/Contents/Resources/%@", file];
    return [NSFileManager.defaultManager fileExistsAtPath:candidate] ? candidate : nil;
}

static NSString *HookPathForResource(NSBundle *self, SEL _cmd, NSString *name, NSString *ext) {
    NSString *r = ((NSString *(*)(id, SEL, id, id))gOrigPathForRes)(self, _cmd, name, ext);
    if (r || self != NSBundle.mainBundle || !name) return r;
    return FindMacResource(name, ext);
}

static NSURL *HookURLForResource(NSBundle *self, SEL _cmd, NSString *name, NSString *ext) {
    NSURL *r = ((NSURL *(*)(id, SEL, id, id))gOrigURLForRes)(self, _cmd, name, ext);
    if (r || self != NSBundle.mainBundle || !name) return r;
    NSString *p = FindMacResource(name, ext);
    return p ? [NSURL fileURLWithPath:p] : nil;
}

// MARK: Metal macOS compatibility hooks
// On macOS, MTLStorageModeManaged == 1 and MTLResourceStorageModeManaged == (1 << 4).
// On iOS unified memory (Apple Silicon), remap Managed -> Shared (0).
static IMP gOrigTexSetStorageMode = NULL;
static void HookTexSetStorageMode(id self, SEL _cmd, MTLStorageMode mode) {
    if ((NSUInteger)mode == 1) mode = MTLStorageModeShared;
    ((void (*)(id, SEL, MTLStorageMode))gOrigTexSetStorageMode)(self, _cmd, mode);
}

static IMP gOrigTexSetResourceOpts = NULL;
static void HookTexSetResourceOpts(id self, SEL _cmd, MTLResourceOptions opts) {
    if ((opts & 0xF0) == 0x10) {
        opts = (opts & ~((MTLResourceOptions)0xF0)) | MTLResourceStorageModeShared;
    }
    ((void (*)(id, SEL, MTLResourceOptions))gOrigTexSetResourceOpts)(self, _cmd, opts);
}

static IMP gOrigNewBufferWithLen = NULL;
static id HookNewBufferWithLen(id self, SEL _cmd, NSUInteger len, MTLResourceOptions opts) {
    if ((opts & 0xF0) == 0x10) {
        opts = (opts & ~((MTLResourceOptions)0xF0)) | MTLResourceStorageModeShared;
    }
    return ((id (*)(id, SEL, NSUInteger, MTLResourceOptions))gOrigNewBufferWithLen)(self, _cmd, len, opts);
}

static IMP gOrigNewBufferWithBytes = NULL;
static id HookNewBufferWithBytes(id self, SEL _cmd, const void *ptr, NSUInteger len, MTLResourceOptions opts) {
    if ((opts & 0xF0) == 0x10) {
        opts = (opts & ~((MTLResourceOptions)0xF0)) | MTLResourceStorageModeShared;
    }
    return ((id (*)(id, SEL, const void *, NSUInteger, MTLResourceOptions))gOrigNewBufferWithBytes)(self, _cmd, ptr, len, opts);
}

static IMP gOrigNextDrawable = NULL;
static id HookNextDrawable(id self, SEL _cmd) {
    ShimRecordPresentedFrame();
    return ((id (*)(id, SEL))gOrigNextDrawable)(self, _cmd);
}

static void HookMacOnlyNoOpVoid(id self, SEL _cmd) { (void)self; (void)_cmd; }
static BOOL HookMacOnlyReturnNO(id self, SEL _cmd) { (void)self; (void)_cmd; return NO; }
static BOOL HookMacOnlyReturnYES(id self, SEL _cmd) { (void)self; (void)_cmd; return YES; }

static void InstallMetalShims(void) {
    // Texture descriptor Managed -> Shared
    Class texDescCls = NSClassFromString(@"MTLTextureDescriptorInternal") ?: [MTLTextureDescriptor class];
    Method mSM = class_getInstanceMethod(texDescCls, @selector(setStorageMode:));
    if (mSM) gOrigTexSetStorageMode = method_setImplementation(mSM, (IMP)HookTexSetStorageMode);
    Method mRO = class_getInstanceMethod(texDescCls, @selector(setResourceOptions:));
    if (mRO) gOrigTexSetResourceOpts = method_setImplementation(mRO, (IMP)HookTexSetResourceOpts);

    // CAMetalLayer nextDrawable -> FPS telemetry & macOS displaySyncEnabled no-op
    Method mND = class_getInstanceMethod([CAMetalLayer class], @selector(nextDrawable));
    if (mND) gOrigNextDrawable = method_setImplementation(mND, (IMP)HookNextDrawable);
    class_addMethod([CAMetalLayer class], NSSelectorFromString(@"setDisplaySyncEnabled:"), (IMP)HookMacOnlyNoOpVoid, "v@:B");
    class_addMethod([CAMetalLayer class], NSSelectorFromString(@"displaySyncEnabled"), (IMP)HookMacOnlyReturnYES, "B@:");

    // MTLDevice buffer Managed -> Shared & macOS-only properties
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (dev) {
        Class devCls = object_getClass(dev);
        Method mBL = class_getInstanceMethod(devCls, @selector(newBufferWithLength:options:));
        if (mBL) gOrigNewBufferWithLen = method_setImplementation(mBL, (IMP)HookNewBufferWithLen);
        Method mBB = class_getInstanceMethod(devCls, @selector(newBufferWithBytes:length:options:));
        if (mBB) gOrigNewBufferWithBytes = method_setImplementation(mBB, (IMP)HookNewBufferWithBytes);
        class_addMethod(devCls, NSSelectorFromString(@"isLowPower"), (IMP)HookMacOnlyReturnNO, "B@:");
        class_addMethod(devCls, NSSelectorFromString(@"isRemovable"), (IMP)HookMacOnlyReturnNO, "B@:");
        class_addMethod(devCls, NSSelectorFromString(@"isHeadless"), (IMP)HookMacOnlyReturnNO, "B@:");
        class_addMethod(devCls, NSSelectorFromString(@"isDepth24Stencil8PixelFormatSupported"), (IMP)HookMacOnlyReturnNO, "B@:");
    }
}

__attribute__((constructor))
static void AICShimRuntimeInit(void) {
    _dyld_register_func_for_add_image(OnDyldImageAdded);

    NSBundle *main = NSBundle.mainBundle;
    NSString *macRoot = main.infoDictionary[@"SHIMMacRoot"];
    if (macRoot.length > 0) {
        gMacRootPath = [main.bundlePath stringByAppendingPathComponent:macRoot];
        Class cls = [NSBundle class];
        Method m;
        if ((m = class_getInstanceMethod(cls, @selector(bundlePath))))     gOrigBundlePath = method_setImplementation(m, (IMP)HookBundlePath);
        if ((m = class_getInstanceMethod(cls, @selector(resourcePath))))   gOrigResourcePath = method_setImplementation(m, (IMP)HookResourcePath);
        if ((m = class_getInstanceMethod(cls, @selector(executablePath)))) gOrigExecPath = method_setImplementation(m, (IMP)HookExecutablePath);
        if ((m = class_getInstanceMethod(cls, @selector(bundleURL))))      gOrigBundleURL = method_setImplementation(m, (IMP)HookBundleURL);
        if ((m = class_getInstanceMethod(cls, @selector(resourceURL))))    gOrigResourceURL = method_setImplementation(m, (IMP)HookResourceURL);
        if ((m = class_getInstanceMethod(cls, @selector(executableURL))))  gOrigExecURL = method_setImplementation(m, (IMP)HookExecutableURL);
        if ((m = class_getInstanceMethod(cls, @selector(pathForResource:ofType:)))) gOrigPathForRes = method_setImplementation(m, (IMP)HookPathForResource);
        if ((m = class_getInstanceMethod(cls, @selector(URLForResource:withExtension:)))) gOrigURLForRes = method_setImplementation(m, (IMP)HookURLForResource);
        NSLog(@"AIC-SHIM NSBundle MacRoot active: %@", gMacRootPath);
    }

    InstallMetalShims();
}

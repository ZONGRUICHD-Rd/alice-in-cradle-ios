// CoreVideo CVDisplayLink shim targeting iPhone 18 Pro 60Hz / 120Hz ProMotion.
#import <Foundation/Foundation.h>
#import <CoreVideo/CVBase.h>
#import <CoreVideo/CVReturn.h>
#include <mach/mach_time.h>
#include <stdatomic.h>

typedef struct __CVDisplayLink *CVDisplayLinkRef;
typedef CVReturn (*CVDisplayLinkOutputCallback)(
    CVDisplayLinkRef displayLink,
    const CVTimeStamp *inNow,
    const CVTimeStamp *inOutputTime,
    CVOptionFlags flagsIn,
    CVOptionFlags *flagsOut,
    void *displayLinkContext
);

static char kLinkQueueKey;
static _Atomic int gTargetHz = 120; // Default 120Hz ProMotion for iPhone 18 Pro
static NSHashTable *gLinks = nil;

static NSHashTable *LinkRegistry(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLinks = [NSHashTable weakObjectsHashTable];
    });
    return gLinks;
}

static uint64_t PeriodNS(void) {
    int hz = atomic_load(&gTargetHz);
    if (hz <= 0) hz = 60;
    return NSEC_PER_SEC / (uint64_t)hz;
}

@interface AICCVDisplayLink : NSObject
@property(strong) dispatch_queue_t queue;
@property(strong) dispatch_source_t timer;
@property CVDisplayLinkOutputCallback callback;
@property void *context;
@property BOOL running;
@property uint32_t displayID;
@end

@implementation AICCVDisplayLink
- (instancetype)init {
    if ((self = [super init])) {
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        _queue = dispatch_queue_create("com.alicecradle.ios.displaylink", attr);
        dispatch_queue_set_specific(_queue, &kLinkQueueKey, (__bridge void *)self, NULL);
        _displayID = 1;
        NSHashTable *reg = LinkRegistry();
        @synchronized(reg) { [reg addObject:self]; }
    }
    return self;
}
- (void)dealloc {
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
}
@end

static AICCVDisplayLink *UnwrapLink(CVDisplayLinkRef ref) {
    return (__bridge AICCVDisplayLink *)(void *)ref;
}

static void RunOnLinkQueue(AICCVDisplayLink *link, dispatch_block_t block) {
    if (dispatch_get_specific(&kLinkQueueKey) == (__bridge void *)link) {
        block();
    } else {
        dispatch_sync(link.queue, block);
    }
}

static CVTimeStamp MakeStamp(uint64_t hostTime) {
    static mach_timebase_info_data_t base;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&base); });
    CVTimeStamp ts = {0};
    ts.hostTime = hostTime;
    ts.videoTimeScale = (int32_t)NSEC_PER_SEC;
    ts.videoTime = (int64_t)(((__uint128_t)hostTime * base.numer) / base.denom);
    ts.videoRefreshPeriod = (int64_t)PeriodNS();
    ts.rateScalar = 1.0;
    ts.flags = kCVTimeStampVideoHostTimeValid | kCVTimeStampVideoRefreshPeriodValid | kCVTimeStampRateScalarValid;
    return ts;
}

__attribute__((visibility("default")))
int ShimCVGetTargetFPS(void) {
    return atomic_load(&gTargetHz);
}

__attribute__((visibility("default")))
void ShimCVSetTargetFPS(int fps) {
    int clamped = (fps >= 90) ? 120 : 60;
    atomic_store(&gTargetHz, clamped);
    NSHashTable *reg = LinkRegistry();
    NSArray *snapshot = nil;
    @synchronized(reg) { snapshot = reg.allObjects; }
    for (AICCVDisplayLink *link in snapshot) {
        dispatch_async(link.queue, ^{
            if (link.running && link.timer) {
                uint64_t p = PeriodNS();
                dispatch_source_set_timer(link.timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)p), p, NSEC_PER_MSEC / 4);
            }
        });
    }
    NSLog(@"AIC-SHIM CVDisplayLink target FPS -> %d Hz", clamped);
}

__attribute__((visibility("default")))
CVReturn CVDisplayLinkCreateWithActiveCGDisplays(CVDisplayLinkRef *out) {
    if (!out) return kCVReturnInvalidArgument;
    *out = (CVDisplayLinkRef)CFBridgingRetain([AICCVDisplayLink new]);
    return kCVReturnSuccess;
}

__attribute__((visibility("default")))
CVReturn CVDisplayLinkCreateWithCGDisplay(uint32_t displayID, CVDisplayLinkRef *out) {
    CVReturn r = CVDisplayLinkCreateWithActiveCGDisplays(out);
    if (r == kCVReturnSuccess && out && *out) {
        UnwrapLink(*out).displayID = displayID ? displayID : 1;
    }
    return r;
}

__attribute__((visibility("default")))
CVReturn CVDisplayLinkCreateWithCGDisplays(uint32_t *displayArray, CFIndex count, CVDisplayLinkRef *out) {
    return CVDisplayLinkCreateWithCGDisplay((count > 0 && displayArray) ? displayArray[0] : 1, out);
}

__attribute__((visibility("default")))
CVReturn CVDisplayLinkSetCurrentCGDisplay(CVDisplayLinkRef ref, uint32_t displayID) {
    if (!ref) return kCVReturnInvalidArgument;
    UnwrapLink(ref).displayID = displayID ? displayID : 1;
    return kCVReturnSuccess;
}

__attribute__((visibility("default")))
uint32_t CVDisplayLinkGetCurrentCGDisplay(CVDisplayLinkRef ref) {
    return ref ? UnwrapLink(ref).displayID : 1;
}

__attribute__((visibility("default")))
CVReturn CVDisplayLinkSetOutputCallback(CVDisplayLinkRef ref, CVDisplayLinkOutputCallback cb, void *ctx) {
    if (!ref) return kCVReturnInvalidArgument;
    AICCVDisplayLink *link = UnwrapLink(ref);
    RunOnLinkQueue(link, ^{
        link.callback = cb;
        link.context = ctx;
    });
    return kCVReturnSuccess;
}

__attribute__((visibility("default")))
CVReturn CVDisplayLinkStart(CVDisplayLinkRef ref) {
    if (!ref) return kCVReturnInvalidArgument;
    AICCVDisplayLink *link = UnwrapLink(ref);
    RunOnLinkQueue(link, ^{
        if (link.running) return;
        link.running = YES;
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, link.queue);
        uint64_t period = PeriodNS();
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)period), period, NSEC_PER_MSEC / 4);
        __weak AICCVDisplayLink *weakLink = link;
        dispatch_source_set_event_handler(timer, ^{
            AICCVDisplayLink *strong = weakLink;
            if (!strong || !strong.running || !strong.callback) return;
            uint64_t now = mach_absolute_time();
            CVTimeStamp tsNow = MakeStamp(now);
            CVTimeStamp tsOut = tsNow;
            tsOut.videoTime += tsNow.videoRefreshPeriod;
            CVOptionFlags outFlags = 0;
            strong.callback((__bridge CVDisplayLinkRef)(__bridge void *)strong, &tsNow, &tsOut, 0, &outFlags, strong.context);
        });
        link.timer = timer;
        dispatch_resume(timer);
    });
    return kCVReturnSuccess;
}

__attribute__((visibility("default")))
CVReturn CVDisplayLinkStop(CVDisplayLinkRef ref) {
    if (!ref) return kCVReturnInvalidArgument;
    AICCVDisplayLink *link = UnwrapLink(ref);
    RunOnLinkQueue(link, ^{
        link.running = NO;
        if (link.timer) {
            dispatch_source_cancel(link.timer);
            link.timer = nil;
        }
    });
    return kCVReturnSuccess;
}

__attribute__((visibility("default")))
Boolean CVDisplayLinkIsRunning(CVDisplayLinkRef ref) {
    return ref ? (Boolean)UnwrapLink(ref).running : false;
}

__attribute__((visibility("default")))
CVTime CVDisplayLinkGetNominalOutputVideoRefreshPeriod(CVDisplayLinkRef ref) {
    (void)ref;
    CVTime t = {0};
    t.timeValue = (int64_t)PeriodNS();
    t.timeScale = (int32_t)NSEC_PER_SEC;
    t.flags = 0;
    return t;
}

__attribute__((visibility("default")))
double CVDisplayLinkGetActualOutputVideoRefreshPeriod(CVDisplayLinkRef ref) {
    (void)ref;
    int hz = atomic_load(&gTargetHz);
    return 1.0 / (double)(hz > 0 ? hz : 60);
}

__attribute__((visibility("default")))
CVDisplayLinkRef CVDisplayLinkRetain(CVDisplayLinkRef ref) {
    if (ref) CFRetain((CFTypeRef)ref);
    return ref;
}

__attribute__((visibility("default")))
void CVDisplayLinkRelease(CVDisplayLinkRef ref) {
    if (ref) CFRelease((CFTypeRef)ref);
}

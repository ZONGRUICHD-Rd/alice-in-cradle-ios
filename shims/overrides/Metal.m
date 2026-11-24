// Metal macOS GPU enumeration shim for iOS 27 (iPhone 18 Pro).
#import <Metal/Metal.h>

__attribute__((visibility("default")))
NSArray<id<MTLDevice>> *MTLCopyAllDevices(void) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    return dev ? @[dev] : @[];
}

__attribute__((visibility("default")))
NSArray<id<MTLDevice>> *MTLCopyAllDevicesWithObserver(id *observer, void (^handler)(id<MTLDevice>, NSString *)) {
    if (observer) *observer = [NSObject new];
    return MTLCopyAllDevices();
}

__attribute__((visibility("default")))
void MTLRemoveDeviceObserver(id observer) {
    (void)observer;
}

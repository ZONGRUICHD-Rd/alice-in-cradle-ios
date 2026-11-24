// SystemConfiguration macOS-only dynamic store / proxy stubs for iOS 27.
#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>

#define EXPORT __attribute__((visibility("default")))

EXPORT CFStringRef SCDynamicStoreCopyComputerName(void *store, CFStringEncoding *encoding) {
    (void)store;
    if (encoding) *encoding = kCFStringEncodingUTF8;
    return CFBridgingRetain(@"iPhone 18 Pro");
}

EXPORT CFStringRef SCDynamicStoreCopyLocalHostName(void *store) {
    (void)store;
    return CFBridgingRetain(@"iPhone-18-Pro");
}

EXPORT CFDictionaryRef SCDynamicStoreCopyProxies(void *store) {
    (void)store;
    return (CFDictionaryRef)CFBridgingRetain(@{});
}

// Security macOS-only API shims for iOS 27.
#import <Foundation/Foundation.h>
#import <Security/Security.h>

#define EXPORT __attribute__((visibility("default")))

EXPORT OSStatus SecCodeCopySelf(uint32_t flags, void **selfCode) {
    (void)flags;
    if (selfCode) *selfCode = (void *)CFBridgingRetain([NSObject new]);
    return errSecSuccess;
}

EXPORT OSStatus SecCodeCheckValidity(void *code, uint32_t flags, void *requirement) {
    (void)code; (void)flags; (void)requirement;
    return errSecSuccess;
}

EXPORT OSStatus SecCodeCopySigningInformation(void *code, uint32_t flags, CFDictionaryRef *information) {
    (void)code; (void)flags;
    if (information) {
        NSDictionary *info = @{
            @"identifier": NSBundle.mainBundle.bundleIdentifier ?: @"com.alicecradle.ios",
        };
        *information = (CFDictionaryRef)CFBridgingRetain(info);
    }
    return errSecSuccess;
}

EXPORT OSStatus SecTrustSettingsCopyCertificates(uint32_t domain, CFArrayRef *certArray) {
    (void)domain;
    if (certArray) *certArray = (CFArrayRef)CFBridgingRetain(@[]);
    return errSecSuccess;
}

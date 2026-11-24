// Carbon TIS (Text Input Source) fixed US keyboard shim for Unity macOS input driver on iOS 27.
#import <Foundation/Foundation.h>

#define EXPORT __attribute__((visibility("default")))

EXPORT CFStringRef const kTISPropertyUnicodeKeyLayoutData = CFSTR("kTISPropertyUnicodeKeyLayoutData");
EXPORT CFStringRef const kTISPropertyInputSourceID = CFSTR("kTISPropertyInputSourceID");
EXPORT CFStringRef const kTISPropertyInputSourceType = CFSTR("kTISPropertyInputSourceType");
EXPORT CFStringRef const kTISTypeKeyboardLayout = CFSTR("kTISTypeKeyboardLayout");
EXPORT CFStringRef const kTISNotifySelectedKeyboardInputSourceChanged = CFSTR("kTISNotifySelectedKeyboardInputSourceChanged");

static NSDictionary *AICFixedUSInputSource(void) {
    static NSDictionary *source = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const unsigned char token[] = "AIC-US-KEYBOARD-v1";
        source = @{
            (__bridge NSString *)kTISPropertyUnicodeKeyLayoutData: [NSData dataWithBytes:token length:sizeof(token)],
            (__bridge NSString *)kTISPropertyInputSourceID: @"com.alicecradle.ios.FixedUS",
            (__bridge NSString *)kTISPropertyInputSourceType: (__bridge NSString *)kTISTypeKeyboardLayout,
        };
    });
    return source;
}

EXPORT CFTypeRef TISCopyCurrentASCIICapableKeyboardLayoutInputSource(void) {
    return CFBridgingRetain(AICFixedUSInputSource());
}

EXPORT CFTypeRef TISCopyCurrentKeyboardLayoutInputSource(void) {
    return CFBridgingRetain(AICFixedUSInputSource());
}

EXPORT CFTypeRef TISCopyCurrentKeyboardInputSource(void) {
    return CFBridgingRetain(AICFixedUSInputSource());
}

EXPORT CFTypeRef TISGetInputSourceProperty(CFTypeRef source, CFStringRef property) {
    if (!source || !property || CFGetTypeID(source) != CFDictionaryGetTypeID()) return NULL;
    return CFDictionaryGetValue((CFDictionaryRef)source, property);
}

EXPORT uint8_t LMGetKbdType(void) {
    return 40; // ANSI US keyboard
}

EXPORT uint32_t GetCurrentKeyModifiers(void) {
    return 0;
}

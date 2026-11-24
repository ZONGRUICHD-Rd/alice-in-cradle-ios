// IOKit power management & HID manager compatibility stubs for Unity macOS builds on iOS 27.
#import <Foundation/Foundation.h>
#include <mach/mach.h>

#define EXPORT __attribute__((visibility("default")))

typedef uint32_t io_object_t;
typedef uint32_t io_connect_t;
typedef uint32_t io_service_t;
typedef uint32_t io_registry_entry_t;
typedef uint32_t io_iterator_t;
typedef void *IONotificationPortRef;
typedef void *IOHIDManagerRef;
typedef uint32_t IOPMAssertionID;

EXPORT const mach_port_t kIOMasterPortDefault = 0;
EXPORT const mach_port_t kIOMainPortDefault = 0;

EXPORT io_connect_t IORegisterForSystemPower(void *refcon, IONotificationPortRef *portRef, void *callback, io_object_t *notifier) {
    (void)refcon; (void)callback;
    if (portRef) *portRef = (IONotificationPortRef)0x1;
    if (notifier) *notifier = 1;
    return 1;
}

EXPORT kern_return_t IODeregisterForSystemPower(io_object_t *notifier) {
    if (notifier) *notifier = 0;
    return KERN_SUCCESS;
}

EXPORT kern_return_t IOServiceClose(io_connect_t connect) { (void)connect; return KERN_SUCCESS; }
EXPORT kern_return_t IOObjectRelease(io_object_t obj) { (void)obj; return KERN_SUCCESS; }
EXPORT kern_return_t IOAllowPowerChange(io_connect_t kernelPort, intptr_t notificationID) { (void)kernelPort; (void)notificationID; return KERN_SUCCESS; }

EXPORT IONotificationPortRef IONotificationPortCreate(mach_port_t mainPort) { (void)mainPort; return (IONotificationPortRef)0x1; }
EXPORT void IONotificationPortDestroy(IONotificationPortRef notify) { (void)notify; }
EXPORT CFRunLoopSourceRef IONotificationPortGetRunLoopSource(IONotificationPortRef notify) {
    (void)notify;
    CFRunLoopSourceContext ctx = {0};
    return CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &ctx);
}

EXPORT kern_return_t IOPMAssertionCreateWithName(CFStringRef type, uint32_t level, CFStringRef name, IOPMAssertionID *outID) {
    (void)type; (void)level; (void)name;
    static IOPMAssertionID nextID = 100;
    if (outID) *outID = ++nextID;
    return KERN_SUCCESS;
}

EXPORT kern_return_t IOPMAssertionRelease(IOPMAssertionID assertionID) {
    (void)assertionID;
    return KERN_SUCCESS;
}

EXPORT CFMutableDictionaryRef IOServiceMatching(const char *name) {
    CFMutableDictionaryRef dict = CFDictionaryCreateMutable(kCFAllocatorDefault, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (name) {
        CFStringRef s = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingUTF8);
        if (s) {
            CFDictionarySetValue(dict, CFSTR("IOProviderClass"), s);
            CFRelease(s);
        }
    }
    return dict;
}

EXPORT io_service_t IOServiceGetMatchingService(mach_port_t mainPort, CFDictionaryRef matching) {
    (void)mainPort;
    if (matching) CFRelease(matching);
    return 0;
}

EXPORT kern_return_t IOServiceGetMatchingServices(mach_port_t mainPort, CFDictionaryRef matching, io_iterator_t *existing) {
    (void)mainPort;
    if (matching) CFRelease(matching);
    if (existing) *existing = 0;
    return KERN_SUCCESS;
}

EXPORT io_object_t IOIteratorNext(io_iterator_t iterator) { (void)iterator; return 0; }

EXPORT CFTypeRef IORegistryEntryCreateCFProperty(io_registry_entry_t entry, CFStringRef key, CFAllocatorRef alloc, uint32_t opts) {
    (void)entry; (void)key; (void)alloc; (void)opts;
    return NULL;
}

// HID Manager stubs (gamepads are handled natively via GameController.framework in AppKit_AliceControls.m)
EXPORT IOHIDManagerRef IOHIDManagerCreate(CFAllocatorRef alloc, uint32_t opts) {
    (void)alloc; (void)opts;
    return (IOHIDManagerRef)CFBridgingRetain([NSObject new]);
}
EXPORT kern_return_t IOHIDManagerOpen(IOHIDManagerRef mgr, uint32_t opts) { (void)mgr; (void)opts; return KERN_SUCCESS; }
EXPORT kern_return_t IOHIDManagerClose(IOHIDManagerRef mgr, uint32_t opts) { (void)mgr; (void)opts; return KERN_SUCCESS; }
EXPORT void IOHIDManagerSetDeviceMatching(IOHIDManagerRef mgr, CFDictionaryRef matching) { (void)mgr; (void)matching; }
EXPORT void IOHIDManagerSetDeviceMatchingMultiple(IOHIDManagerRef mgr, CFArrayRef multiple) { (void)mgr; (void)multiple; }
EXPORT void IOHIDManagerRegisterDeviceMatchingCallback(IOHIDManagerRef mgr, void *cb, void *ctx) { (void)mgr; (void)cb; (void)ctx; }
EXPORT void IOHIDManagerRegisterDeviceRemovalCallback(IOHIDManagerRef mgr, void *cb, void *ctx) { (void)mgr; (void)cb; (void)ctx; }
EXPORT void IOHIDManagerRegisterInputValueCallback(IOHIDManagerRef mgr, void *cb, void *ctx) { (void)mgr; (void)cb; (void)ctx; }
EXPORT void IOHIDManagerScheduleWithRunLoop(IOHIDManagerRef mgr, CFRunLoopRef rl, CFStringRef mode) { (void)mgr; (void)rl; (void)mode; }
EXPORT void IOHIDManagerUnscheduleFromRunLoop(IOHIDManagerRef mgr, CFRunLoopRef rl, CFStringRef mode) { (void)mgr; (void)rl; (void)mode; }
EXPORT CFSetRef IOHIDManagerCopyDevices(IOHIDManagerRef mgr) { (void)mgr; return NULL; }

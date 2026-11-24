// CoreGraphics display enumeration + virtual keyboard state shim for iOS 27 (iPhone 18 Pro).
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdatomic.h>

#define EXPORT __attribute__((visibility("default")))

typedef uint32_t CGDirectDisplayID;
typedef const struct __CGDisplayMode *CGDisplayModeRef;

static _Atomic uint8_t gKeyStates[256];

EXPORT void ShimSetVirtualKeyState(unsigned short macKeyCode, BOOL isDown) {
    if (macKeyCode < 256) {
        atomic_store(&gKeyStates[macKeyCode], isDown ? 1 : 0);
    }
}

EXPORT BOOL ShimGetVirtualKeyState(unsigned short macKeyCode) {
    return (macKeyCode < 256) ? (atomic_load(&gKeyStates[macKeyCode]) != 0) : NO;
}

EXPORT bool CGEventSourceKeyState(int32_t stateID, uint16_t keyCode) {
    (void)stateID;
    return ShimGetVirtualKeyState(keyCode) ? true : false;
}

EXPORT uint64_t CGEventSourceFlagsState(int32_t stateID) {
    (void)stateID;
    uint64_t flags = 0;
    if (ShimGetVirtualKeyState(56) || ShimGetVirtualKeyState(60)) flags |= (1ULL << 17); // Shift
    if (ShimGetVirtualKeyState(59) || ShimGetVirtualKeyState(62)) flags |= (1ULL << 18); // Control
    if (ShimGetVirtualKeyState(58) || ShimGetVirtualKeyState(61)) flags |= (1ULL << 19); // Option
    if (ShimGetVirtualKeyState(55) || ShimGetVirtualKeyState(54)) flags |= (1ULL << 20); // Command
    return flags;
}

static CGSize ScreenPixelSize(void) {
    UIScreen *s = UIScreen.mainScreen;
    CGRect b = s.nativeBounds;
    // Landscape dimensions for Alice in Cradle
    CGFloat w = MAX(b.size.width, b.size.height);
    CGFloat h = MIN(b.size.width, b.size.height);
    if (w <= 0 || h <= 0) return CGSizeMake(2622, 1206); // iPhone Pro landscape fallback
    return CGSizeMake(w, h);
}

EXPORT CGDirectDisplayID CGMainDisplayID(void) { return 1; }

EXPORT CGError CGGetActiveDisplayList(uint32_t maxDisplays, CGDirectDisplayID *activeDisplays, uint32_t *displayCount) {
    if (activeDisplays && maxDisplays >= 1) activeDisplays[0] = 1;
    if (displayCount) *displayCount = 1;
    return 0;
}

EXPORT CGError CGGetOnlineDisplayList(uint32_t maxDisplays, CGDirectDisplayID *onlineDisplays, uint32_t *displayCount) {
    return CGGetActiveDisplayList(maxDisplays, onlineDisplays, displayCount);
}

EXPORT CGRect CGDisplayBounds(CGDirectDisplayID display) {
    (void)display;
    CGSize px = ScreenPixelSize();
    return CGRectMake(0, 0, px.width, px.height);
}

EXPORT size_t CGDisplayPixelsWide(CGDirectDisplayID display) {
    (void)display;
    return (size_t)ScreenPixelSize().width;
}

EXPORT size_t CGDisplayPixelsHigh(CGDirectDisplayID display) {
    (void)display;
    return (size_t)ScreenPixelSize().height;
}

EXPORT CGSize CGDisplayScreenSize(CGDirectDisplayID display) {
    (void)display;
    return CGSizeMake(146.0, 67.0); // ~6.3" iPhone Pro physical size in mm (landscape)
}

EXPORT uint32_t CGDisplayUnitNumber(CGDirectDisplayID display) { (void)display; return 0; }
EXPORT uint32_t CGDisplayVendorNumber(CGDirectDisplayID display) { (void)display; return 0x0610; }
EXPORT uint32_t CGDisplayModelNumber(CGDirectDisplayID display) { (void)display; return 0xA050; }
EXPORT int CGDisplayIsBuiltin(CGDirectDisplayID display) { (void)display; return 1; }
EXPORT int CGDisplayIsActive(CGDirectDisplayID display) { (void)display; return 1; }
EXPORT int CGDisplayIsMain(CGDirectDisplayID display) { (void)display; return 1; }

@interface AICDisplayMode : NSObject
@property size_t width;
@property size_t height;
@property double refreshRate;
@end
@implementation AICDisplayMode @end

static AICDisplayMode *CurrentModeObj(void) {
    AICDisplayMode *m = [AICDisplayMode new];
    CGSize px = ScreenPixelSize();
    m.width = (size_t)px.width;
    m.height = (size_t)px.height;
    NSInteger maxHz = UIScreen.mainScreen.maximumFramesPerSecond;
    m.refreshRate = (maxHz >= 90) ? 120.0 : 60.0;
    return m;
}

EXPORT CGDisplayModeRef CGDisplayCopyDisplayMode(CGDirectDisplayID display) {
    (void)display;
    return (CGDisplayModeRef)CFBridgingRetain(CurrentModeObj());
}

EXPORT CFArrayRef CGDisplayCopyAllDisplayModes(CGDirectDisplayID display, CFDictionaryRef options) {
    (void)display; (void)options;
    return CFBridgingRetain(@[CurrentModeObj()]);
}

EXPORT void CGDisplayModeRelease(CGDisplayModeRef mode) {
    if (mode) CFRelease((CFTypeRef)mode);
}

EXPORT CGDisplayModeRef CGDisplayModeRetain(CGDisplayModeRef mode) {
    if (mode) CFRetain((CFTypeRef)mode);
    return mode;
}

EXPORT size_t CGDisplayModeGetWidth(CGDisplayModeRef mode) {
    return mode ? ((__bridge AICDisplayMode *)(void *)mode).width : (size_t)ScreenPixelSize().width;
}

EXPORT size_t CGDisplayModeGetHeight(CGDisplayModeRef mode) {
    return mode ? ((__bridge AICDisplayMode *)(void *)mode).height : (size_t)ScreenPixelSize().height;
}

EXPORT size_t CGDisplayModeGetPixelWidth(CGDisplayModeRef mode) {
    return CGDisplayModeGetWidth(mode);
}

EXPORT size_t CGDisplayModeGetPixelHeight(CGDisplayModeRef mode) {
    return CGDisplayModeGetHeight(mode);
}

EXPORT double CGDisplayModeGetRefreshRate(CGDisplayModeRef mode) {
    return mode ? ((__bridge AICDisplayMode *)(void *)mode).refreshRate : 120.0;
}

EXPORT uint32_t CGDisplayModeGetIOFlags(CGDisplayModeRef mode) { (void)mode; return 0x7; }
EXPORT bool CGDisplayModeIsUsableForDesktopGUI(CGDisplayModeRef mode) { (void)mode; return true; }

EXPORT CGError CGWarpMouseCursorPosition(CGPoint pt) { (void)pt; return 0; }
EXPORT CGError CGAssociateMouseAndMouseCursorPosition(bool connected) { (void)connected; return 0; }
EXPORT CGError CGDisplayHideCursor(CGDirectDisplayID d) { (void)d; return 0; }
EXPORT CGError CGDisplayShowCursor(CGDirectDisplayID d) { (void)d; return 0; }
EXPORT void CGGetLastMouseDelta(int32_t *dx, int32_t *dy) { if (dx) *dx = 0; if (dy) *dy = 0; }
EXPORT CGColorSpaceRef CGDisplayCopyColorSpace(CGDirectDisplayID d) { (void)d; return CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3); }

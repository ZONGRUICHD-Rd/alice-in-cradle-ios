// AppKit-on-UIKit shim for Unity macOS ARM64 games (Alice in Cradle) on iOS 27.
// Provides NSApplication, NSWindow, NSView, NSViewController, NSScreen, NSEvent,
// NSCursor, NSWorkspace, NSColor, NSImage, NSAlert, NSPasteboard, NSApplicationMain.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>

#pragma clang diagnostic ignored "-Wundeclared-selector"
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"

#define EXPORT __attribute__((visibility("default")))

// Forward declaration for Alice in Cradle touch/controller overlay
extern void ShimInstallAliceControlsOnWindow(UIWindow *window);

// MARK: AppKit Notifications & Constants
EXPORT NSString *const NSApplicationDidFinishLaunchingNotification = @"NSApplicationDidFinishLaunchingNotification";
EXPORT NSString *const NSApplicationWillFinishLaunchingNotification = @"NSApplicationWillFinishLaunchingNotification";
EXPORT NSString *const NSApplicationDidBecomeActiveNotification = @"NSApplicationDidBecomeActiveNotification";
EXPORT NSString *const NSApplicationWillResignActiveNotification = @"NSApplicationWillResignActiveNotification";
EXPORT NSString *const NSApplicationDidResignActiveNotification = @"NSApplicationDidResignActiveNotification";
EXPORT NSString *const NSApplicationWillTerminateNotification = @"NSApplicationWillTerminateNotification";
EXPORT NSString *const NSApplicationDidHideNotification = @"NSApplicationDidHideNotification";
EXPORT NSString *const NSApplicationDidUnhideNotification = @"NSApplicationDidUnhideNotification";
EXPORT NSString *const NSWindowDidResizeNotification = @"NSWindowDidResizeNotification";
EXPORT NSString *const NSWindowDidBecomeKeyNotification = @"NSWindowDidBecomeKeyNotification";
EXPORT NSString *const NSWindowDidResignKeyNotification = @"NSWindowDidResignKeyNotification";
EXPORT NSString *const NSWindowDidBecomeMainNotification = @"NSWindowDidBecomeMainNotification";
EXPORT NSString *const NSWindowWillCloseNotification = @"NSWindowWillCloseNotification";
EXPORT NSString *const NSWindowDidChangeBackingPropertiesNotification = @"NSWindowDidChangeBackingPropertiesNotification";
EXPORT NSString *const NSWindowDidEnterFullScreenNotification = @"NSWindowDidEnterFullScreenNotification";
EXPORT NSString *const NSWindowDidExitFullScreenNotification = @"NSWindowDidExitFullScreenNotification";
EXPORT NSString *const NSDeviceResolution = @"NSDeviceResolution";
EXPORT NSString *const NSDeviceSize = @"NSDeviceSize";
EXPORT NSString *const NSPasteboardTypeString = @"public.utf8-plain-text";
EXPORT NSString *const NSStringPboardType = @"NSStringPboardType";

// NSEventType subset matching macOS AppKit values
typedef NS_ENUM(NSUInteger, AICEvType) {
    AICEvLeftMouseDown = 1,
    AICEvLeftMouseUp = 2,
    AICEvRightMouseDown = 3,
    AICEvRightMouseUp = 4,
    AICEvMouseMoved = 5,
    AICEvLeftMouseDragged = 6,
    AICEvKeyDown = 10,
    AICEvKeyUp = 11,
    AICEvFlagsChanged = 12,
    AICEvScrollWheel = 22,
};

@class NSApplication, NSWindow, NSView, NSScreen, NSEvent;

EXPORT NSApplication *NSApp = nil;
static UIWindow *gUIWindow = nil;
static UIView *gGameHostView = nil;
static NSWindow *gMainNSWindow = nil;
static NSMutableArray<NSEvent *> *gEventQueue = nil;
static NSMutableArray *gLocalEventMonitors = nil;

// MARK: NSEvent
EXPORT
@interface NSEvent : NSObject
@property(nonatomic) NSUInteger type;
@property(nonatomic) NSUInteger modifierFlags;
@property(nonatomic) NSTimeInterval timestamp;
@property(nonatomic, weak) NSWindow *window;
@property(nonatomic) NSInteger windowNumber;
@property(nonatomic) CGPoint locationInWindow;
@property(nonatomic) unsigned short keyCode;
@property(nonatomic, copy) NSString *characters;
@property(nonatomic, copy) NSString *charactersIgnoringModifiers;
@property(nonatomic, getter=isARepeat) BOOL ARepeat;
@property(nonatomic) CGFloat deltaX;
@property(nonatomic) CGFloat deltaY;
@property(nonatomic) CGFloat scrollingDeltaX;
@property(nonatomic) CGFloat scrollingDeltaY;
@property(nonatomic) NSInteger clickCount;
@property(nonatomic) NSInteger buttonNumber;
+ (CGPoint)mouseLocation;
+ (NSUInteger)pressedMouseButtons;
+ (NSUInteger)modifierFlags;
+ (id)addLocalMonitorForEventsMatchingMask:(NSUInteger)mask handler:(NSEvent *(^)(NSEvent *))block;
+ (void)removeMonitor:(id)monitor;
@end

static CGPoint gLastMousePt = {0, 0};
static NSUInteger gPressedButtons = 0;
static NSUInteger gCurrentModifiers = 0;

@implementation NSEvent
+ (CGPoint)mouseLocation { return gLastMousePt; }
+ (NSUInteger)pressedMouseButtons { return gPressedButtons; }
+ (NSUInteger)modifierFlags { return gCurrentModifiers; }
+ (id)addLocalMonitorForEventsMatchingMask:(NSUInteger)mask handler:(NSEvent *(^)(NSEvent *))block {
    if (!gLocalEventMonitors) gLocalEventMonitors = [NSMutableArray new];
    NSDictionary *entry = @{@"mask": @(mask), @"block": [block copy]};
    [gLocalEventMonitors addObject:entry];
    return entry;
}
+ (void)removeMonitor:(id)monitor {
    [gLocalEventMonitors removeObject:monitor];
}
- (BOOL)hasPreciseScrollingDeltas { return YES; }
@end

// MARK: NSScreen
EXPORT
@interface NSScreen : NSObject
+ (NSScreen *)mainScreen;
+ (NSArray<NSScreen *> *)screens;
- (CGRect)frame;
- (CGRect)visibleFrame;
- (CGFloat)backingScaleFactor;
- (NSDictionary *)deviceDescription;
- (NSInteger)maximumFramesPerSecond;
@end

@implementation NSScreen
+ (NSScreen *)mainScreen {
    static NSScreen *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NSScreen new]; });
    return s;
}
+ (NSArray<NSScreen *> *)screens { return @[[self mainScreen]]; }
- (CGRect)frame {
    CGRect b = UIScreen.mainScreen.bounds;
    CGFloat w = MAX(b.size.width, b.size.height);
    CGFloat h = MIN(b.size.width, b.size.height);
    return CGRectMake(0, 0, w, h);
}
- (CGRect)visibleFrame { return [self frame]; }
- (CGFloat)backingScaleFactor { return UIScreen.mainScreen.scale ?: 3.0; }
- (NSInteger)maximumFramesPerSecond { return UIScreen.mainScreen.maximumFramesPerSecond ?: 120; }
- (NSDictionary *)deviceDescription {
    CGRect f = [self frame];
    return @{
        @"NSScreenNumber": @(1),
        NSDeviceSize: [NSValue valueWithCGSize:f.size],
        NSDeviceResolution: [NSValue valueWithCGSize:CGSizeMake(72.0 * self.backingScaleFactor, 72.0 * self.backingScaleFactor)],
    };
}
@end

// MARK: NSView
EXPORT
@interface NSView : NSObject
@property(nonatomic) CGRect frame;
@property(nonatomic) CGRect bounds;
@property(nonatomic, weak) NSWindow *window;
@property(nonatomic, weak) NSView *superview;
@property(nonatomic, strong) NSMutableArray<NSView *> *subviews;
@property(nonatomic, strong) CALayer *layer;
@property(nonatomic) BOOL wantsLayer;
@property(nonatomic) BOOL wantsBestResolutionOpenGLSurface;
@property(nonatomic) NSUInteger autoresizingMask;
@property(nonatomic, strong) UIView *backingUIView;
- (instancetype)initWithFrame:(CGRect)frameRect;
- (void)addSubview:(NSView *)view;
- (void)removeFromSuperview;
- (CGRect)convertRectToBacking:(CGRect)rect;
- (CGRect)convertRectFromBacking:(CGRect)rect;
- (CGPoint)convertPoint:(CGPoint)pt fromView:(NSView *)view;
- (void)setNeedsDisplay:(BOOL)flag;
- (CALayer *)makeBackingLayer;
- (BOOL)acceptsFirstResponder;
- (void)keyDown:(NSEvent *)event;
- (void)keyUp:(NSEvent *)event;
- (void)mouseDown:(NSEvent *)event;
- (void)mouseUp:(NSEvent *)event;
- (void)mouseDragged:(NSEvent *)event;
@end

@implementation NSView
- (instancetype)init {
    return [self initWithFrame:NSScreen.mainScreen.frame];
}
- (instancetype)initWithFrame:(CGRect)frameRect {
    if ((self = [super init])) {
        _frame = frameRect;
        _bounds = CGRectMake(0, 0, frameRect.size.width, frameRect.size.height);
        _subviews = [NSMutableArray new];
        _backingUIView = [[UIView alloc] initWithFrame:frameRect];
        _backingUIView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _backingUIView.backgroundColor = UIColor.blackColor;
        _layer = _backingUIView.layer;
    }
    return self;
}
- (void)setWantsLayer:(BOOL)wantsLayer {
    _wantsLayer = wantsLayer;
    if (wantsLayer) {
        CALayer *custom = [self makeBackingLayer];
        if (custom && custom != _layer) {
            [self setLayer:custom];
        }
    }
}
- (void)setLayer:(CALayer *)layer {
    if (_layer && _layer.superlayer == _backingUIView.layer) {
        [_layer removeFromSuperlayer];
    }
    _layer = layer;
    if (layer && layer != _backingUIView.layer) {
        layer.frame = _backingUIView.bounds;
        if ([layer isKindOfClass:[CAMetalLayer class]]) {
            CAMetalLayer *ml = (CAMetalLayer *)layer;
            ml.contentsScale = NSScreen.mainScreen.backingScaleFactor;
        }
        [_backingUIView.layer addSublayer:layer];
    }
}
- (CALayer *)makeBackingLayer { return [CALayer layer]; }
- (void)addSubview:(NSView *)view {
    if (!view) return;
    view.superview = self;
    view.window = self.window;
    [_subviews addObject:view];
    [_backingUIView addSubview:view.backingUIView];
}
- (void)removeFromSuperview {
    [_backingUIView removeFromSuperview];
    [_superview.subviews removeObject:self];
    _superview = nil;
}
- (CGRect)convertRectToBacking:(CGRect)rect {
    CGFloat s = NSScreen.mainScreen.backingScaleFactor;
    return CGRectMake(rect.origin.x * s, rect.origin.y * s, rect.size.width * s, rect.size.height * s);
}
- (CGRect)convertRectFromBacking:(CGRect)rect {
    CGFloat s = NSScreen.mainScreen.backingScaleFactor;
    return CGRectMake(rect.origin.x / s, rect.origin.y / s, rect.size.width / s, rect.size.height / s);
}
- (CGPoint)convertPoint:(CGPoint)pt fromView:(NSView *)view { (void)view; return pt; }
- (void)setNeedsDisplay:(BOOL)flag { (void)flag; [_backingUIView setNeedsDisplay]; }
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)event { (void)event; }
- (void)keyUp:(NSEvent *)event { (void)event; }
- (void)mouseDown:(NSEvent *)event { (void)event; }
- (void)mouseUp:(NSEvent *)event { (void)event; }
- (void)mouseDragged:(NSEvent *)event { (void)event; }
@end

// MARK: NSViewController
EXPORT
@interface NSViewController : NSObject
@property(nonatomic, strong) NSView *view;
@property(nonatomic, copy) NSString *title;
- (void)loadView;
- (void)viewDidLoad;
@end
@implementation NSViewController
- (void)loadView { self.view = [[NSView alloc] initWithFrame:NSScreen.mainScreen.frame]; }
- (void)viewDidLoad {}
@end

// MARK: NSWindow
EXPORT
@interface NSWindow : NSObject
@property(nonatomic) CGRect frame;
@property(nonatomic, strong) NSView *contentView;
@property(nonatomic, weak) id delegate;
@property(nonatomic, copy) NSString *title;
@property(nonatomic) NSUInteger styleMask;
@property(nonatomic) NSInteger level;
@property(nonatomic) BOOL acceptsMouseMovedEvents;
@property(nonatomic) BOOL ignoresMouseEvents;
@property(nonatomic) BOOL opaque;
@property(nonatomic) BOOL releasedWhenClosed;
@property(nonatomic) CGFloat alphaValue;
@property(nonatomic, weak) id firstResponder;
@property(nonatomic, readonly) NSInteger windowNumber;
- (instancetype)initWithContentRect:(CGRect)contentRect styleMask:(NSUInteger)style backing:(NSUInteger)backing defer:(BOOL)flag;
- (instancetype)initWithContentRect:(CGRect)contentRect styleMask:(NSUInteger)style backing:(NSUInteger)backing defer:(BOOL)flag screen:(NSScreen *)screen;
- (void)makeKeyAndOrderFront:(id)sender;
- (void)orderFront:(id)sender;
- (void)orderOut:(id)sender;
- (void)center;
- (void)close;
- (BOOL)makeFirstResponder:(id)responder;
- (NSScreen *)screen;
- (CGFloat)backingScaleFactor;
- (CGRect)contentRectForFrameRect:(CGRect)frameRect;
- (CGRect)frameRectForContentRect:(CGRect)contentRect;
- (CGRect)convertRectToBacking:(CGRect)rect;
- (CGRect)convertRectToScreen:(CGRect)rect;
- (void)setFrame:(CGRect)frameRect display:(BOOL)flag;
- (void)setContentSize:(CGSize)size;
- (void)toggleFullScreen:(id)sender;
- (BOOL)isKeyWindow;
- (BOOL)isMainWindow;
- (BOOL)isVisible;
- (void)sendEvent:(NSEvent *)event;
@end

@implementation NSWindow
- (instancetype)initWithContentRect:(CGRect)contentRect styleMask:(NSUInteger)style backing:(NSUInteger)backing defer:(BOOL)flag screen:(NSScreen *)screen {
    (void)backing; (void)flag; (void)screen;
    if ((self = [super init])) {
        CGRect screenRect = NSScreen.mainScreen.frame;
        _frame = screenRect;
        _styleMask = style;
        _alphaValue = 1.0;
        _opaque = YES;
        _windowNumber = 1;
        _contentView = [[NSView alloc] initWithFrame:screenRect];
        _contentView.window = self;
        _firstResponder = _contentView;
        gMainNSWindow = self;
        if (gGameHostView) {
            _contentView.backingUIView.frame = gGameHostView.bounds;
            [gGameHostView addSubview:_contentView.backingUIView];
        }
    }
    return self;
}
- (instancetype)initWithContentRect:(CGRect)contentRect styleMask:(NSUInteger)style backing:(NSUInteger)backing defer:(BOOL)flag {
    return [self initWithContentRect:contentRect styleMask:style backing:backing defer:flag screen:NSScreen.mainScreen];
}
- (void)setContentView:(NSView *)contentView {
    if (_contentView) [_contentView.backingUIView removeFromSuperview];
    _contentView = contentView;
    _contentView.window = self;
    _firstResponder = contentView;
    if (gGameHostView && contentView) {
        contentView.backingUIView.frame = gGameHostView.bounds;
        [gGameHostView addSubview:contentView.backingUIView];
    }
}
- (void)makeKeyAndOrderFront:(id)sender {
    (void)sender;
    gMainNSWindow = self;
    if (gGameHostView && _contentView && !_contentView.backingUIView.superview) {
        _contentView.backingUIView.frame = gGameHostView.bounds;
        [gGameHostView addSubview:_contentView.backingUIView];
    }
    [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidBecomeKeyNotification object:self];
    [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidBecomeMainNotification object:self];
}
- (void)orderFront:(id)sender { [self makeKeyAndOrderFront:sender]; }
- (void)orderOut:(id)sender { (void)sender; }
- (void)center {}
- (void)close {
    [NSNotificationCenter.defaultCenter postNotificationName:NSWindowWillCloseNotification object:self];
}
- (BOOL)makeFirstResponder:(id)responder { _firstResponder = responder ?: _contentView; return YES; }
- (NSScreen *)screen { return NSScreen.mainScreen; }
- (CGFloat)backingScaleFactor { return NSScreen.mainScreen.backingScaleFactor; }
- (CGRect)contentRectForFrameRect:(CGRect)frameRect { return frameRect; }
- (CGRect)frameRectForContentRect:(CGRect)contentRect { return contentRect; }
- (CGRect)convertRectToBacking:(CGRect)rect { return [_contentView convertRectToBacking:rect]; }
- (CGRect)convertRectToScreen:(CGRect)rect { return rect; }
- (void)setFrame:(CGRect)frameRect display:(BOOL)flag {
    (void)flag;
    _frame = NSScreen.mainScreen.frame;
    if (_contentView) {
        _contentView.frame = _frame;
        _contentView.bounds = CGRectMake(0, 0, _frame.size.width, _frame.size.height);
        for (CALayer *sub in _contentView.backingUIView.layer.sublayers) {
            sub.frame = _contentView.backingUIView.bounds;
        }
    }
    [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidResizeNotification object:self];
}
- (void)setContentSize:(CGSize)size { (void)size; }
- (void)toggleFullScreen:(id)sender { (void)sender; }
- (BOOL)isKeyWindow { return YES; }
- (BOOL)isMainWindow { return YES; }
- (BOOL)isVisible { return YES; }
- (void)sendEvent:(NSEvent *)event {
    if (!event) return;
    id target = _firstResponder ?: _contentView;
    switch (event.type) {
        case AICEvKeyDown:
            if ([target respondsToSelector:@selector(keyDown:)]) [target keyDown:event];
            break;
        case AICEvKeyUp:
            if ([target respondsToSelector:@selector(keyUp:)]) [target keyUp:event];
            break;
        case AICEvLeftMouseDown:
            if ([target respondsToSelector:@selector(mouseDown:)]) [target mouseDown:event];
            break;
        case AICEvLeftMouseUp:
            if ([target respondsToSelector:@selector(mouseUp:)]) [target mouseUp:event];
            break;
        case AICEvLeftMouseDragged:
            if ([target respondsToSelector:@selector(mouseDragged:)]) [target mouseDragged:event];
            break;
        default: break;
    }
}
@end

// MARK: NSApplication
EXPORT
@interface NSApplication : NSObject
@property(nonatomic, weak) id delegate;
@property(nonatomic, strong) id mainMenu;
@property(nonatomic, readonly) NSWindow *mainWindow;
@property(nonatomic, readonly) NSWindow *keyWindow;
@property(nonatomic, readonly) NSArray<NSWindow *> *windows;
@property(nonatomic, readonly, getter=isActive) BOOL active;
@property(nonatomic, readonly, getter=isRunning) BOOL running;
@property(nonatomic, readonly) NSEvent *currentEvent;
+ (NSApplication *)sharedApplication;
- (void)setActivationPolicy:(NSInteger)policy;
- (void)activateIgnoringOtherApps:(BOOL)flag;
- (void)finishLaunching;
- (void)run;
- (void)stop:(id)sender;
- (void)terminate:(id)sender;
- (void)sendEvent:(NSEvent *)event;
- (void)postEvent:(NSEvent *)event atStart:(BOOL)atStart;
- (NSEvent *)nextEventMatchingMask:(NSUInteger)mask untilDate:(NSDate *)expiration inMode:(NSRunLoopMode)mode dequeue:(BOOL)deqFlag;
- (void)updateWindows;
@end

@implementation NSApplication {
    NSEvent *_currentEvent;
    BOOL _running;
}
+ (NSApplication *)sharedApplication {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSApp = [NSApplication new];
        gEventQueue = [NSMutableArray new];
    });
    return NSApp;
}
- (NSWindow *)mainWindow { return gMainNSWindow; }
- (NSWindow *)keyWindow { return gMainNSWindow; }
- (NSArray<NSWindow *> *)windows { return gMainNSWindow ? @[gMainNSWindow] : @[]; }
- (BOOL)isActive { return YES; }
- (BOOL)isRunning { return _running; }
- (NSEvent *)currentEvent { return _currentEvent; }
- (void)setActivationPolicy:(NSInteger)policy { (void)policy; }
- (void)activateIgnoringOtherApps:(BOOL)flag { (void)flag; }
- (void)finishLaunching {
    [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationWillFinishLaunchingNotification object:self];
    if ([_delegate respondsToSelector:@selector(applicationWillFinishLaunching:)]) {
        [_delegate performSelector:@selector(applicationWillFinishLaunching:) withObject:[NSNotification notificationWithName:NSApplicationWillFinishLaunchingNotification object:self]];
    }
    [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidFinishLaunchingNotification object:self];
    if ([_delegate respondsToSelector:@selector(applicationDidFinishLaunching:)]) {
        [_delegate performSelector:@selector(applicationDidFinishLaunching:) withObject:[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:self]];
    }
}
- (void)run {
    _running = YES;
    [self finishLaunching];
}
- (void)stop:(id)sender { (void)sender; _running = NO; }
- (void)terminate:(id)sender {
    (void)sender;
    [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationWillTerminateNotification object:self];
    exit(0);
}
- (void)sendEvent:(NSEvent *)event {
    if (!event) return;
    _currentEvent = event;
    NSEvent *filtered = event;
    for (NSDictionary *entry in [gLocalEventMonitors copy]) {
        NSEvent *(^blk)(NSEvent *) = entry[@"block"];
        if (blk) {
            filtered = blk(filtered);
            if (!filtered) return;
        }
    }
    [gMainNSWindow sendEvent:filtered];
}
- (void)postEvent:(NSEvent *)event atStart:(BOOL)atStart {
    if (!event) return;
    @synchronized(gEventQueue) {
        if (atStart) [gEventQueue insertObject:event atIndex:0];
        else [gEventQueue addObject:event];
    }
}
- (NSEvent *)nextEventMatchingMask:(NSUInteger)mask untilDate:(NSDate *)expiration inMode:(NSRunLoopMode)mode dequeue:(BOOL)deqFlag {
    (void)mask;
    @synchronized(gEventQueue) {
        if (gEventQueue.count > 0) {
            NSEvent *ev = gEventQueue.firstObject;
            if (deqFlag) [gEventQueue removeObjectAtIndex:0];
            return ev;
        }
    }
    if (expiration && [expiration timeIntervalSinceNow] > 0) {
        [NSRunLoop.currentRunLoop runMode:(mode ?: NSDefaultRunLoopMode) beforeDate:expiration];
    }
    return nil;
}
- (void)updateWindows {}
@end

// MARK: Supporting AppKit Classes (NSCursor, NSWorkspace, NSColor, NSImage, NSPasteboard, NSAlert)
EXPORT @interface NSCursor : NSObject
+ (NSCursor *)arrowCursor;
+ (void)hide;
+ (void)unhide;
+ (void)setHiddenUntilMouseMoves:(BOOL)flag;
- (void)set;
@end
@implementation NSCursor
+ (NSCursor *)arrowCursor { static NSCursor *c; static dispatch_once_t o; dispatch_once(&o, ^{ c = [NSCursor new]; }); return c; }
+ (void)hide {}
+ (void)unhide {}
+ (void)setHiddenUntilMouseMoves:(BOOL)flag { (void)flag; }
- (void)set {}
@end

EXPORT @interface NSWorkspace : NSObject
+ (NSWorkspace *)sharedWorkspace;
- (BOOL)openURL:(NSURL *)url;
- (NSNotificationCenter *)notificationCenter;
@end
@implementation NSWorkspace
+ (NSWorkspace *)sharedWorkspace { static NSWorkspace *w; static dispatch_once_t o; dispatch_once(&o, ^{ w = [NSWorkspace new]; }); return w; }
- (BOOL)openURL:(NSURL *)url {
    if (!url) return NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    });
    return YES;
}
- (NSNotificationCenter *)notificationCenter { return NSNotificationCenter.defaultCenter; }
@end

EXPORT @interface NSColor : NSObject
+ (id)blackColor;
+ (id)whiteColor;
+ (id)clearColor;
+ (id)colorWithCalibratedRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a;
+ (id)colorWithSRGBRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a;
@end
@implementation NSColor
+ (id)blackColor { return UIColor.blackColor; }
+ (id)whiteColor { return UIColor.whiteColor; }
+ (id)clearColor { return UIColor.clearColor; }
+ (id)colorWithCalibratedRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a { return [UIColor colorWithRed:r green:g blue:b alpha:a]; }
+ (id)colorWithSRGBRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a { return [UIColor colorWithRed:r green:g blue:b alpha:a]; }
@end

EXPORT @interface NSPasteboard : NSObject
+ (NSPasteboard *)generalPasteboard;
- (NSString *)stringForType:(NSString *)type;
- (BOOL)setString:(NSString *)string forType:(NSString *)type;
- (NSInteger)clearContents;
@end
@implementation NSPasteboard
+ (NSPasteboard *)generalPasteboard { static NSPasteboard *p; static dispatch_once_t o; dispatch_once(&o, ^{ p = [NSPasteboard new]; }); return p; }
- (NSString *)stringForType:(NSString *)type { (void)type; return UIPasteboard.generalPasteboard.string; }
- (BOOL)setString:(NSString *)string forType:(NSString *)type { (void)type; UIPasteboard.generalPasteboard.string = string; return YES; }
- (NSInteger)clearContents { UIPasteboard.generalPasteboard.string = @""; return 1; }
@end

EXPORT @interface NSAlert : NSObject
@property(nonatomic, copy) NSString *messageText;
@property(nonatomic, copy) NSString *informativeText;
- (void)addButtonWithTitle:(NSString *)title;
- (NSInteger)runModal;
@end
@implementation NSAlert
- (void)addButtonWithTitle:(NSString *)title { (void)title; }
- (NSInteger)runModal {
    NSLog(@"AIC-SHIM NSAlert: %@ - %@", self.messageText, self.informativeText);
    return 1000;
}
@end

// MARK: Virtual Key Bridge called by AppKit_AliceControls.m
EXPORT void ShimPostVirtualKey(unsigned short macKeyCode, BOOL isDown, NSString *characters) {
    // Sync CoreGraphics key state for polling engines (Input.GetKey)
    void (*setState)(unsigned short, BOOL) = (void (*)(unsigned short, BOOL))dlsym(RTLD_DEFAULT, "ShimSetVirtualKeyState");
    if (setState) setState(macKeyCode, isDown);

    NSEvent *ev = [NSEvent new];
    ev.type = isDown ? AICEvKeyDown : AICEvKeyUp;
    ev.keyCode = macKeyCode;
    ev.characters = characters ?: @"";
    ev.charactersIgnoringModifiers = characters ?: @"";
    ev.timestamp = CACurrentMediaTime();
    ev.window = gMainNSWindow;
    ev.windowNumber = 1;
    ev.modifierFlags = gCurrentModifiers;

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSApplication sharedApplication] postEvent:ev atStart:NO];
        [[NSApplication sharedApplication] sendEvent:ev];
    });
}

// MARK: UIKit Host ViewController & AppDelegate for NSApplicationMain
@interface AICGameHostViewController : UIViewController
@end

@implementation AICGameHostViewController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    gGameHostView = self.view;
    if (gMainNSWindow && gMainNSWindow.contentView) {
        gMainNSWindow.contentView.backingUIView.frame = self.view.bounds;
        [self.view addSubview:gMainNSWindow.contentView.backingUIView];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (gMainNSWindow && gMainNSWindow.contentView) {
        gMainNSWindow.contentView.backingUIView.frame = self.view.bounds;
        [gMainNSWindow setFrame:self.view.bounds display:YES];
    }
}
@end

@interface AICShimUIAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation AICShimUIAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application; (void)launchOptions;
    UIApplication.sharedApplication.idleTimerDisabled = YES;

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.backgroundColor = UIColor.blackColor;
    AICGameHostViewController *vc = [AICGameHostViewController new];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    gUIWindow = self.window;

    // Install Alice in Cradle touch + controller overlay above Unity Metal view
    ShimInstallAliceControlsOnWindow(self.window);

    // Boot macOS NSApplication lifecycle
    dispatch_async(dispatch_get_main_queue(), ^{
        NSApplication *app = [NSApplication sharedApplication];
        // Discover Unity's PlayerAppDelegate class if present
        Class playerDelegate = NSClassFromString(@"PlayerAppDelegate");
        if (playerDelegate && !app.delegate) {
            app.delegate = [playerDelegate new];
        }
        [app run];
    });
    return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application {
    (void)application;
    [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationWillResignActiveNotification object:NSApp];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    (void)application;
    [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidBecomeActiveNotification object:NSApp];
}

- (void)applicationWillTerminate:(UIApplication *)application {
    (void)application;
    [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationWillTerminateNotification object:NSApp];
}
@end

EXPORT int NSApplicationMain(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        return UIApplicationMain(argc, (char **)argv, nil, NSStringFromClass([AICShimUIAppDelegate class]));
    }
}

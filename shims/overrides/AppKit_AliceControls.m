// Alice in Cradle (爱丽丝的摇篮) iOS 27 Touch Controls, Layout Editor, GameController & FPS HUD.
// Designed for iPhone 18 Pro landscape safe areas (Dynamic Island + ProMotion 60/120Hz).

#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>

#define EXPORT __attribute__((visibility("default")))

extern void ShimPostVirtualKey(unsigned short macKeyCode, BOOL isDown, NSString *characters);
extern unsigned ShimPresentedFPS(void);
extern int ShimTargetFPS(void);
extern void ShimSetTargetFPS(int fps);
extern double ShimMemoryFootprintMB(void);

// macOS ANSI virtual key codes matching Alice in Cradle default bindings
enum {
    kKeyA = 0,
    kKeyS = 1,
    kKeyD = 2,
    kKeyZ = 6,      // Attack / Staff
    kKeyX = 7,      // Guard / Shield / Parry
    kKeyC = 8,      // Magic / Shot
    kKeyQ = 12,     // Quick Item / Heal
    kKeyW = 13,     // Up / Interact
    kKeyE = 14,     // Secondary Action
    kKeyReturn = 36,// Confirm
    kKeyM = 46,     // Map
    kKeySpace = 49, // Jump
    kKeyEsc = 53,   // Menu / Pause
    kKeyShift = 56, // Evade / Dash
    kKeyLeft = 123,
    kKeyRight = 124,
    kKeyDown = 125,
    kKeyUp = 126,
};

static NSString *KeyCharsForCode(NSInteger code) {
    switch (code) {
        case kKeyA: return @"a";
        case kKeyS: return @"s";
        case kKeyD: return @"d";
        case kKeyW: return @"w";
        case kKeyZ: return @"z";
        case kKeyX: return @"x";
        case kKeyC: return @"c";
        case kKeyQ: return @"q";
        case kKeyE: return @"e";
        case kKeyM: return @"m";
        case kKeySpace: return @" ";
        case kKeyReturn: return @"\r";
        case kKeyEsc: return @"\x1b";
        case kKeyShift: return @"";
        case kKeyLeft:  { unichar u = 0xF702; return [NSString stringWithCharacters:&u length:1]; }
        case kKeyRight: { unichar u = 0xF703; return [NSString stringWithCharacters:&u length:1]; }
        case kKeyDown:  { unichar u = 0xF701; return [NSString stringWithCharacters:&u length:1]; }
        case kKeyUp:    { unichar u = 0xF700; return [NSString stringWithCharacters:&u length:1]; }
        default: return @"";
    }
}

@interface AICControlButton : UIButton
@property(nonatomic, copy) NSString *controlID;
@property(nonatomic) unsigned short macKeyCode;
@property(nonatomic) CGFloat defaultSize;
@end

@implementation AICControlButton
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.transform = highlighted ? CGAffineTransformMakeScale(0.92, 0.92) : CGAffineTransformIdentity;
    self.backgroundColor = highlighted
        ? [UIColor colorWithRed:0.64 green:0.46 blue:0.98 alpha:0.55]
        : [UIColor colorWithWhite:0.08 alpha:0.38];
}
@end

@interface AICTouchOverlayView : UIView
@property(nonatomic, strong) UIView *stickBase;
@property(nonatomic, strong) UIView *stickKnob;
@property(nonatomic, weak) UITouch *stickTouch;
@property(nonatomic, strong) NSMutableArray<AICControlButton *> *actionButtons;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *touchKeys;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *padKeys;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *sentKeys;
@property(nonatomic, strong) UILabel *fpsLabel;
@property(nonatomic, strong) UIButton *settingsButton;
@property(nonatomic, strong) UIView *settingsPanel;
@property(nonatomic, strong) UIView *editorBanner;
@property(nonatomic, strong) CADisplayLink *controllerLink;
@property(nonatomic, strong) NSTimer *hudTimer;
@property(nonatomic, strong) NSMutableDictionary *savedLayout;
@property(nonatomic) BOOL editingLayout;
@property(nonatomic) BOOL showFPS;
@property(nonatomic) BOOL autoHideOnController;
@property(nonatomic) CGFloat hudOpacity;
@property(nonatomic) CGFloat hudScale;
@end

@implementation AICTouchOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.multipleTouchEnabled = YES;
        self.backgroundColor = UIColor.clearColor;

        _actionButtons = [NSMutableArray new];
        _touchKeys = [NSMutableSet new];
        _padKeys = [NSMutableSet new];
        _sentKeys = [NSMutableSet new];

        NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
        _savedLayout = [[ud dictionaryForKey:@"AICControlLayoutV1"] mutableCopy] ?: [NSMutableDictionary new];
        _showFPS = [ud objectForKey:@"AICShowFPS"] ? [ud boolForKey:@"AICShowFPS"] : YES;
        _autoHideOnController = [ud objectForKey:@"AICAutoHidePad"] ? [ud boolForKey:@"AICAutoHidePad"] : YES;
        _hudOpacity = [ud objectForKey:@"AICHUDOpacity"] ? [ud floatForKey:@"AICHUDOpacity"] : 0.78f;
        _hudScale = [ud objectForKey:@"AICHUDScale"] ? [ud floatForKey:@"AICHUDScale"] : 1.0f;

        [self buildControls];
        [self buildTopBarAndPanel];
        [self startPolling];
    }
    return self;
}

- (void)dealloc {
    [_controllerLink invalidate];
    [_hudTimer invalidate];
}

// Allow touches outside controls to fall through to Unity view
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) {
        if (self.editingLayout) return self;
        // Capture left-bottom quadrant for virtual stick when visible
        if (!self.stickBase.hidden && CGRectContainsPoint(CGRectInset(self.stickBase.frame, -34, -34), point)) {
            return self;
        }
        return nil;
    }
    return hit;
}

- (void)buildControls {
    // Virtual Joystick
    _stickBase = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 132, 132)];
    _stickBase.layer.cornerRadius = 66;
    _stickBase.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.28];
    _stickBase.layer.borderWidth = 1.8;
    _stickBase.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.42].CGColor;
    _stickBase.userInteractionEnabled = NO;
    [self addSubview:_stickBase];

    _stickKnob = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 48, 48)];
    _stickKnob.layer.cornerRadius = 24;
    _stickKnob.backgroundColor = [UIColor colorWithRed:0.74 green:0.58 blue:1.0 alpha:0.72];
    _stickKnob.layer.borderWidth = 1.5;
    _stickKnob.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.85].CGColor;
    _stickKnob.center = CGPointMake(66, 66);
    [_stickBase addSubview:_stickKnob];

    // Alice in Cradle Action Buttons
    NSArray<NSDictionary *> *specs = @[
        @{@"id": @"jump",  @"title": @"跳跃", @"sub": @"SPC", @"key": @(kKeySpace), @"size": @(64)},
        @{@"id": @"atk",   @"title": @"法杖", @"sub": @"Z",   @"key": @(kKeyZ),     @"size": @(64)},
        @{@"id": @"guard", @"title": @"盾防", @"sub": @"X",   @"key": @(kKeyX),     @"size": @(56)},
        @{@"id": @"magic", @"title": @"魔法", @"sub": @"C",   @"key": @(kKeyC),     @"size": @(56)},
        @{@"id": @"evade", @"title": @"回避", @"sub": @"SHF", @"key": @(kKeyShift), @"size": @(56)},
        @{@"id": @"item",  @"title": @"道具", @"sub": @"Q",   @"key": @(kKeyQ),     @"size": @(48)},
        @{@"id": @"ok",    @"title": @"确认", @"sub": @"ENT", @"key": @(kKeyReturn),@"size": @(46)},
        @{@"id": @"map",   @"title": @"地图", @"sub": @"M",   @"key": @(kKeyM),     @"size": @(44)},
        @{@"id": @"menu",  @"title": @"菜单", @"sub": @"ESC", @"key": @(kKeyEsc),   @"size": @(44)},
    ];

    for (NSDictionary *sp in specs) {
        AICControlButton *btn = [AICControlButton buttonWithType:UIButtonTypeCustom];
        btn.controlID = sp[@"id"];
        btn.macKeyCode = [sp[@"key"] unsignedShortValue];
        btn.defaultSize = [sp[@"size"] floatValue];
        btn.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.38];
        btn.layer.borderWidth = 1.4;
        btn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.45].CGColor;
        btn.titleLabel.numberOfLines = 2;
        btn.titleLabel.textAlignment = NSTextAlignmentCenter;

        NSString *label = [NSString stringWithFormat:@"%@\n%@", sp[@"title"], sp[@"sub"]];
        NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:label];
        NSRange line1 = NSMakeRange(0, [sp[@"title"] length]);
        NSRange line2 = NSMakeRange(line1.length, label.length - line1.length);
        [attr addAttributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold],
            NSForegroundColorAttributeName: UIColor.whiteColor
        } range:line1];
        [attr addAttributes:@{
            NSFontAttributeName: [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightMedium],
            NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.65]
        } range:line2];
        [btn setAttributedTitle:attr forState:UIControlStateNormal];

        [btn addTarget:self action:@selector(onButtonDown:) forControlEvents:UIControlEventTouchDown];
        [btn addTarget:self action:@selector(onButtonUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onDragControl:)];
        [btn addGestureRecognizer:pan];

        [_actionButtons addObject:btn];
        [self addSubview:btn];
    }

    UIPanGestureRecognizer *stickPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onDragControl:)];
    [_stickBase addGestureRecognizer:stickPan];
}

- (void)buildTopBarAndPanel {
    _fpsLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _fpsLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightSemibold];
    _fpsLabel.textColor = [UIColor colorWithRed:0.75 green:1.0 blue:0.82 alpha:0.95];
    _fpsLabel.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.52];
    _fpsLabel.textAlignment = NSTextAlignmentCenter;
    _fpsLabel.layer.cornerRadius = 8;
    _fpsLabel.clipsToBounds = YES;
    _fpsLabel.text = @"120 FPS · -- MB";
    [self addSubview:_fpsLabel];

    _settingsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_settingsButton setTitle:@"⚙ 面板" forState:UIControlStateNormal];
    [_settingsButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _settingsButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    _settingsButton.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.52];
    _settingsButton.layer.cornerRadius = 14;
    _settingsButton.layer.borderWidth = 1;
    _settingsButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.3].CGColor;
    [_settingsButton addTarget:self action:@selector(toggleSettingsPanel) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_settingsButton];

    // Settings Panel (iOS 27 Glass / UIVisualEffectView)
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    UIVisualEffectView *panel = [[UIVisualEffectView alloc] initWithEffect:blur];
    panel.layer.cornerRadius = 22;
    panel.clipsToBounds = YES;
    panel.layer.borderWidth = 1;
    panel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
    panel.hidden = YES;

    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [panel.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-16],
        [stack.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-16],
    ]];

    UILabel *title = [UILabel new];
    title.text = @"爱丽丝的摇篮 · iOS 27 控制面板";
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    title.textColor = UIColor.whiteColor;
    [stack addArrangedSubview:title];

    UISegmentedControl *fpsSeg = [[UISegmentedControl alloc] initWithItems:@[@"60 Hz", @"120 Hz ProMotion"]];
    fpsSeg.selectedSegmentIndex = (ShimTargetFPS() >= 90) ? 1 : 0;
    [fpsSeg addTarget:self action:@selector(onFPSChanged:) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:fpsSeg];

    UIButton *editBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [editBtn setTitle:@"编辑虚拟键位布局 (拖拽调整)" forState:UIControlStateNormal];
    editBtn.tintColor = [UIColor colorWithRed:0.78 green:0.65 blue:1.0 alpha:1.0];
    editBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [editBtn addTarget:self action:@selector(toggleLayoutEditor) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:editBtn];

    UIButton *fpsToggle = [UIButton buttonWithType:UIButtonTypeSystem];
    [fpsToggle setTitle:@"切换 FPS / 内存浮窗显示" forState:UIControlStateNormal];
    fpsToggle.tintColor = UIColor.whiteColor;
    [fpsToggle addTarget:self action:@selector(toggleFPSDisplay) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:fpsToggle];

    UIButton *resetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [resetBtn setTitle:@"恢复默认键位布局" forState:UIControlStateNormal];
    resetBtn.tintColor = [UIColor colorWithRed:1.0 green:0.55 blue:0.55 alpha:1.0];
    [resetBtn addTarget:self action:@selector(resetLayout) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:resetBtn];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [closeBtn setTitle:@"关闭面板" forState:UIControlStateNormal];
    closeBtn.tintColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    [closeBtn addTarget:self action:@selector(toggleSettingsPanel) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:closeBtn];

    _settingsPanel = panel;
    [self addSubview:panel];

    // Layout editor banner
    _editorBanner = [[UIView alloc] initWithFrame:CGRectZero];
    _editorBanner.backgroundColor = [UIColor colorWithRed:0.42 green:0.25 blue:0.85 alpha:0.88];
    _editorBanner.layer.cornerRadius = 14;
    _editorBanner.hidden = YES;
    UILabel *bannerLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, 220, 34)];
    bannerLbl.text = @"键位编辑中：拖动按钮调整位置";
    bannerLbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    bannerLbl.textColor = UIColor.whiteColor;
    [_editorBanner addSubview:bannerLbl];
    UIButton *doneEdit = [UIButton buttonWithType:UIButtonTypeSystem];
    doneEdit.frame = CGRectMake(232, 2, 64, 30);
    [doneEdit setTitle:@"完成" forState:UIControlStateNormal];
    [doneEdit setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    doneEdit.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    [doneEdit addTarget:self action:@selector(toggleLayoutEditor) forControlEvents:UIControlEventTouchUpInside];
    [_editorBanner addSubview:doneEdit];
    [self addSubview:_editorBanner];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    UIEdgeInsets safe = self.safeAreaInsets;
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat left = MAX(safe.left, 24.0);
    CGFloat right = MAX(safe.right, 24.0);
    CGFloat bottom = MAX(safe.bottom, 18.0);
    CGFloat top = MAX(safe.top, 12.0);

    _fpsLabel.frame = CGRectMake(left, top, 140, 26);
    _fpsLabel.hidden = !_showFPS;
    _settingsButton.frame = CGRectMake(w - right - 74, top, 74, 28);
    _settingsPanel.frame = CGRectMake((w - 300) / 2.0, (h - 270) / 2.0, 300, 270);
    _editorBanner.frame = CGRectMake((w - 304) / 2.0, top, 304, 34);

    // Default ergonomic positions for iPhone 18 Pro landscape
    NSDictionary<NSString *, NSValue *> *defaults = @{
        @"stick": [NSValue valueWithCGPoint:CGPointMake(left + 84, h - bottom - 84)],
        @"jump":  [NSValue valueWithCGPoint:CGPointMake(w - right - 54,  h - bottom - 52)],
        @"atk":   [NSValue valueWithCGPoint:CGPointMake(w - right - 126, h - bottom - 64)],
        @"guard": [NSValue valueWithCGPoint:CGPointMake(w - right - 48,  h - bottom - 126)],
        @"magic": [NSValue valueWithCGPoint:CGPointMake(w - right - 118, h - bottom - 134)],
        @"evade": [NSValue valueWithCGPoint:CGPointMake(w - right - 188, h - bottom - 96)],
        @"item":  [NSValue valueWithCGPoint:CGPointMake(w - right - 182, h - bottom - 166)],
        @"ok":    [NSValue valueWithCGPoint:CGPointMake(w - right - 116, h - bottom - 202)],
        @"map":   [NSValue valueWithCGPoint:CGPointMake(w - right - 132, top + 16)],
        @"menu":  [NSValue valueWithCGPoint:CGPointMake(w - right - 188, top + 16)],
    };

    CGFloat stickSz = 132.0 * _hudScale;
    _stickBase.bounds = CGRectMake(0, 0, stickSz, stickSz);
    _stickBase.layer.cornerRadius = stickSz / 2.0;
    _stickBase.center = [self centerForID:@"stick" fallback:defaults[@"stick"].CGPointValue];
    if (!_stickTouch) {
        _stickKnob.center = CGPointMake(stickSz / 2.0, stickSz / 2.0);
    }
    _stickBase.alpha = _hudOpacity;

    for (AICControlButton *btn in _actionButtons) {
        CGFloat sz = btn.defaultSize * _hudScale;
        btn.bounds = CGRectMake(0, 0, sz, sz);
        btn.layer.cornerRadius = sz / 2.0;
        btn.center = [self centerForID:btn.controlID fallback:defaults[btn.controlID].CGPointValue];
        btn.alpha = _hudOpacity;
    }
}

- (CGPoint)centerForID:(NSString *)cid fallback:(CGPoint)fallback {
    NSDictionary *entry = _savedLayout[cid];
    if ([entry isKindOfClass:NSDictionary.class] && entry[@"nx"] && entry[@"ny"]) {
        return CGPointMake([entry[@"nx"] doubleValue] * self.bounds.size.width,
                           [entry[@"ny"] doubleValue] * self.bounds.size.height);
    }
    return fallback;
}

- (void)saveCenter:(CGPoint)pt forID:(NSString *)cid {
    if (self.bounds.size.width <= 0 || self.bounds.size.height <= 0) return;
    _savedLayout[cid] = @{
        @"nx": @(pt.x / self.bounds.size.width),
        @"ny": @(pt.y / self.bounds.size.height),
    };
    [NSUserDefaults.standardUserDefaults setObject:_savedLayout forKey:@"AICControlLayoutV1"];
}

// MARK: Button & Stick Input Handling
- (void)syncKeys {
    NSMutableSet<NSNumber *> *next = [_touchKeys mutableCopy];
    [next unionSet:_padKeys];
    for (NSNumber *k in _sentKeys) {
        if (![next containsObject:k]) {
            ShimPostVirtualKey(k.unsignedShortValue, NO, KeyCharsForCode(k.integerValue));
        }
    }
    for (NSNumber *k in next) {
        if (![_sentKeys containsObject:k]) {
            ShimPostVirtualKey(k.unsignedShortValue, YES, KeyCharsForCode(k.integerValue));
        }
    }
    _sentKeys = next;
}

- (void)onButtonDown:(AICControlButton *)sender {
    if (_editingLayout) return;
    [_touchKeys addObject:@(sender.macKeyCode)];
    [self syncKeys];
}

- (void)onButtonUp:(AICControlButton *)sender {
    [_touchKeys removeObject:@(sender.macKeyCode)];
    [self syncKeys];
}

- (void)updateStickFromPoint:(CGPoint)pt {
    CGPoint c = _stickBase.center;
    CGFloat dx = pt.x - c.x;
    CGFloat dy = pt.y - c.y;
    CGFloat maxR = (_stickBase.bounds.size.width * 0.42);
    CGFloat dist = hypot(dx, dy);
    if (dist > maxR && dist > 0.001) {
        dx = dx * (maxR / dist);
        dy = dy * (maxR / dist);
    }
    _stickKnob.center = CGPointMake(_stickBase.bounds.size.width / 2.0 + dx,
                                    _stickBase.bounds.size.height / 2.0 + dy);

    CGFloat nx = dx / maxR;
    CGFloat ny = dy / maxR;
    CGFloat dead = 0.24;

    NSArray *dirKeys = @[@(kKeyA), @(kKeyD), @(kKeyW), @(kKeyS), @(kKeyLeft), @(kKeyRight), @(kKeyUp), @(kKeyDown)];
    for (NSNumber *k in dirKeys) [_touchKeys removeObject:k];

    if (nx < -dead) { [_touchKeys addObject:@(kKeyA)]; [_touchKeys addObject:@(kKeyLeft)]; }
    if (nx >  dead) { [_touchKeys addObject:@(kKeyD)]; [_touchKeys addObject:@(kKeyRight)]; }
    if (ny < -dead) { [_touchKeys addObject:@(kKeyW)]; [_touchKeys addObject:@(kKeyUp)]; }
    if (ny >  dead) { [_touchKeys addObject:@(kKeyS)]; [_touchKeys addObject:@(kKeyDown)]; }
    [self syncKeys];
}

- (void)resetStick {
    _stickTouch = nil;
    _stickKnob.center = CGPointMake(_stickBase.bounds.size.width / 2.0, _stickBase.bounds.size.height / 2.0);
    NSArray *dirKeys = @[@(kKeyA), @(kKeyD), @(kKeyW), @(kKeyS), @(kKeyLeft), @(kKeyRight), @(kKeyUp), @(kKeyDown)];
    for (NSNumber *k in dirKeys) [_touchKeys removeObject:k];
    [self syncKeys];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (_editingLayout) return;
    for (UITouch *t in touches) {
        CGPoint pt = [t locationInView:self];
        if (!_stickTouch && CGRectContainsPoint(CGRectInset(_stickBase.frame, -34, -34), pt)) {
            _stickTouch = t;
            [self updateStickFromPoint:pt];
        }
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (_stickTouch && [touches containsObject:_stickTouch]) {
        [self updateStickFromPoint:[_stickTouch locationInView:self]];
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (_stickTouch && [touches containsObject:_stickTouch]) [self resetStick];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self touchesEnded:touches withEvent:event];
}

// MARK: Layout Editor & Settings Panel
- (void)onDragControl:(UIPanGestureRecognizer *)pan {
    if (!_editingLayout) return;
    UIView *v = pan.view;
    CGPoint delta = [pan translationInView:self];
    v.center = CGPointMake(v.center.x + delta.x, v.center.y + delta.y);
    [pan setTranslation:CGPointZero inView:self];
    if (pan.state == UIGestureRecognizerStateEnded) {
        NSString *cid = (v == _stickBase) ? @"stick" : ((AICControlButton *)v).controlID;
        [self saveCenter:v.center forID:cid];
    }
}

- (void)toggleSettingsPanel {
    _settingsPanel.hidden = !_settingsPanel.hidden;
}

- (void)toggleLayoutEditor {
    _editingLayout = !_editingLayout;
    _editorBanner.hidden = !_editingLayout;
    _settingsPanel.hidden = YES;
    _stickBase.userInteractionEnabled = _editingLayout;
    if (_editingLayout) {
        [self resetStick];
    }
}

- (void)toggleFPSDisplay {
    _showFPS = !_showFPS;
    _fpsLabel.hidden = !_showFPS;
    [NSUserDefaults.standardUserDefaults setBool:_showFPS forKey:@"AICShowFPS"];
}

- (void)onFPSChanged:(UISegmentedControl *)seg {
    ShimSetTargetFPS(seg.selectedSegmentIndex == 1 ? 120 : 60);
}

- (void)resetLayout {
    [_savedLayout removeAllObjects];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"AICControlLayoutV1"];
    [self setNeedsLayout];
    [self layoutIfNeeded];
    _settingsPanel.hidden = YES;
}

// MARK: MFi / Xbox / DualSense Hardware Controller Polling & FPS HUD
- (void)startPolling {
    _controllerLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(pollGameControllers)];
    [_controllerLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];

    __weak typeof(self) weakSelf = self;
    _hudTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer * _Nonnull timer) {
        (void)timer;
        AICTouchOverlayView *s = weakSelf;
        if (!s || !s.showFPS) return;
        s.fpsLabel.text = [NSString stringWithFormat:@"%u FPS · %.0f MB", ShimPresentedFPS(), ShimMemoryFootprintMB()];
    }];
}

- (void)pollGameControllers {
    GCController *ctrl = GCController.controllers.firstObject;
    GCExtendedGamepad *gp = ctrl.extendedGamepad;
    BOOL hideTouch = (_autoHideOnController && gp != nil && !_editingLayout);
    if (_stickBase.hidden != hideTouch) {
        _stickBase.hidden = hideTouch;
        for (AICControlButton *b in _actionButtons) b.hidden = hideTouch;
    }

    [_padKeys removeAllObjects];
    if (gp) {
        float lx = gp.leftThumbstick.xAxis.value;
        float ly = gp.leftThumbstick.yAxis.value;
        if (lx < -0.3f || gp.dpad.left.pressed)  { [_padKeys addObject:@(kKeyA)]; [_padKeys addObject:@(kKeyLeft)]; }
        if (lx >  0.3f || gp.dpad.right.pressed) { [_padKeys addObject:@(kKeyD)]; [_padKeys addObject:@(kKeyRight)]; }
        if (ly >  0.3f || gp.dpad.up.pressed)    { [_padKeys addObject:@(kKeyW)]; [_padKeys addObject:@(kKeyUp)]; }
        if (ly < -0.3f || gp.dpad.down.pressed)  { [_padKeys addObject:@(kKeyS)]; [_padKeys addObject:@(kKeyDown)]; }

        if (gp.buttonA.pressed) [_padKeys addObject:@(kKeySpace)];
        if (gp.buttonX.pressed) [_padKeys addObject:@(kKeyZ)];
        if (gp.buttonB.pressed) [_padKeys addObject:@(kKeyX)];
        if (gp.buttonY.pressed) [_padKeys addObject:@(kKeyC)];
        if (gp.rightTrigger.pressed || gp.rightShoulder.pressed) [_padKeys addObject:@(kKeyShift)];
        if (gp.leftShoulder.pressed) [_padKeys addObject:@(kKeyQ)];
        if (gp.buttonOptions.pressed) [_padKeys addObject:@(kKeyM)];
        if (gp.buttonMenu.pressed) [_padKeys addObject:@(kKeyEsc)];
    }
    [self syncKeys];
}

@end

static AICTouchOverlayView *gOverlay = nil;

EXPORT void ShimInstallAliceControlsOnWindow(UIWindow *window) {
    if (!window) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gOverlay && gOverlay.superview == window) return;
        gOverlay = [[AICTouchOverlayView alloc] initWithFrame:window.bounds];
        gOverlay.layer.zPosition = 9999;
        [window addSubview:gOverlay];
    });
}

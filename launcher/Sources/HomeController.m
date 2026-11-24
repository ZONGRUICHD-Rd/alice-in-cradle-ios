#import "HomeController.h"
#import "GameInspector.h"
#import "GameBuilder.h"
#import "ZipArchive.h"
#import "SaveManager.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

typedef NS_ENUM(NSInteger, AICPickerKind) {
    AICPickerKindGameFolderOrZip = 1,
    AICPickerKindSaveFile = 2,
};

@interface AICHomeController () <UIDocumentPickerDelegate>
@property(nonatomic, strong) UIScrollView *scrollView;
@property(nonatomic, strong) UIStackView *mainStack;
@property(nonatomic, strong) UILabel *gameStatusLabel;
@property(nonatomic, strong) UILabel *gameDetailLabel;
@property(nonatomic, strong) UISegmentedControl *modeSegment;
@property(nonatomic, strong) UIButton *importButton;
@property(nonatomic, strong) UIButton *buildButton;
@property(nonatomic, strong) UIButton *shareIPAButton;
@property(nonatomic, strong) UIProgressView *progressBar;
@property(nonatomic, strong) UILabel *progressLabel;
@property(nonatomic, strong) UITextView *logView;
@property(nonatomic, strong) UILabel *saveCountLabel;

@property(nonatomic) AICPickerKind activePicker;
@property(nonatomic, strong, nullable) AICGameInspection *currentInspection;
@property(nonatomic, strong, nullable) NSURL *importedTempRoot;
@property(nonatomic, strong, nullable) NSURL *lastExportedIPA;
@property(nonatomic) BOOL busy;
@end

@implementation AICHomeController

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setupGradientBackground];
    [self setupLayout];
    [self refreshSaveSummary];
    [self appendLog:@"Alice in Cradle iOS 27 独立启动器已就绪。"];
    [self appendLog:@"提示：请导入正版 macOS Apple Silicon (ARM64) 版 AliceInCradle.app 或 .zip。"];
}

- (void)setupGradientBackground {
    self.view.backgroundColor = [UIColor colorWithRed:0.06 green:0.05 blue:0.11 alpha:1.0];
    CAGradientLayer *grad = [CAGradientLayer layer];
    grad.frame = UIScreen.mainScreen.bounds;
    grad.colors = @[
        (id)[UIColor colorWithRed:0.12 green:0.07 blue:0.22 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.05 green:0.05 blue:0.10 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.04 green:0.08 blue:0.14 alpha:1.0].CGColor,
    ];
    grad.startPoint = CGPointMake(0.0, 0.0);
    grad.endPoint = CGPointMake(1.0, 1.0);
    [self.view.layer insertSublayer:grad atIndex:0];
}

// Glass card container compatible with iOS 26/27 Liquid Glass + iOS 17+ ultra-thin material
- (UIView *)makeGlassCardWithStack:(UIStackView **)outStack {
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:blur];
    card.layer.cornerRadius = 24;
    card.clipsToBounds = YES;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *st = [UIStackView new];
    st.axis = UILayoutConstraintAxisVertical;
    st.spacing = 12;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    [card.contentView addSubview:st];
    [NSLayoutConstraint activateConstraints:@[
        [st.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:18],
        [st.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-18],
        [st.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:18],
        [st.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-18],
    ]];
    if (outStack) *outStack = st;
    return card;
}

- (UIButton *)makePrimaryButton:(NSString *)title color:(UIColor *)color action:(SEL)sel {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    btn.backgroundColor = color;
    btn.layer.cornerRadius = 15;
    [btn.heightAnchor constraintEqualToConstant:48].active = YES;
    [btn addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (void)setupLayout {
    _scrollView = [UIScrollView new];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:_scrollView];

    _mainStack = [UIStackView new];
    _mainStack.axis = UILayoutConstraintAxisVertical;
    _mainStack.spacing = 16;
    _mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    [_scrollView addSubview:_mainStack];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_scrollView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [_scrollView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [_scrollView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],

        [_mainStack.topAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.topAnchor constant:16],
        [_mainStack.bottomAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.bottomAnchor constant:-24],
        [_mainStack.leadingAnchor constraintEqualToAnchor:_scrollView.frameLayoutGuide.leadingAnchor constant:18],
        [_mainStack.trailingAnchor constraintEqualToAnchor:_scrollView.frameLayoutGuide.trailingAnchor constant:-18],
    ]];

    // Header
    UILabel *titleLbl = [UILabel new];
    titleLbl.text = @"爱丽丝的摇篮 · iOS 27";
    titleLbl.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    titleLbl.textColor = UIColor.whiteColor;
    [_mainStack addArrangedSubview:titleLbl];

    UILabel *subLbl = [UILabel new];
    subLbl.text = @"游戏本体与启动器分离 · iPhone 18 Pro 120Hz 原生移植工具";
    subLbl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    subLbl.textColor = [UIColor colorWithRed:0.78 green:0.72 blue:0.96 alpha:0.9];
    subLbl.numberOfLines = 0;
    [_mainStack addArrangedSubview:subLbl];

    // Card 1: Game Import & Inspection
    UIStackView *importStack = nil;
    UIView *importCard = [self makeGlassCardWithStack:&importStack];
    [_mainStack addArrangedSubview:importCard];

    UILabel *step1 = [UILabel new];
    step1.text = @"1. 导入游戏本体（BYOG）";
    step1.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    step1.textColor = UIColor.whiteColor;
    [importStack addArrangedSubview:step1];

    _gameStatusLabel = [UILabel new];
    _gameStatusLabel.text = @"尚未导入 AliceInCradle.app 或 .zip";
    _gameStatusLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _gameStatusLabel.textColor = [UIColor colorWithRed:1.0 green:0.82 blue:0.45 alpha:1.0];
    _gameStatusLabel.numberOfLines = 0;
    [importStack addArrangedSubview:_gameStatusLabel];

    _gameDetailLabel = [UILabel new];
    _gameDetailLabel.text = @"在 LiveContainer 中请先开启 Fix File Picker，再选择正版 macOS Apple Silicon 游戏目录或 ZIP 包。";
    _gameDetailLabel.font = [UIFont systemFontOfSize:12];
    _gameDetailLabel.textColor = [UIColor colorWithWhite:0.82 alpha:0.9];
    _gameDetailLabel.numberOfLines = 0;
    [importStack addArrangedSubview:_gameDetailLabel];

    _importButton = [self makePrimaryButton:@"从「文件」导入 .app 或 .zip"
                                      color:[UIColor colorWithRed:0.46 green:0.32 blue:0.88 alpha:1.0]
                                     action:@selector(onTapImportGame)];
    [importStack addArrangedSubview:_importButton];

    // Card 2: Runtime Mode & Export IPA
    UIStackView *buildStack = nil;
    UIView *buildCard = [self makeGlassCardWithStack:&buildStack];
    [_mainStack addArrangedSubview:buildCard];

    UILabel *step2 = [UILabel new];
    step2.text = @"2. 运行模式与打包 iOS 27 IPA";
    step2.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    step2.textColor = UIColor.whiteColor;
    [buildStack addArrangedSubview:step2];

    _modeSegment = [[UISegmentedControl alloc] initWithItems:@[@"免 JIT (Mode 8)", @"JIT 高性能", @"IL2CPP 原生"]];
    _modeSegment.selectedSegmentIndex = 0;
    [buildStack addArrangedSubview:_modeSegment];

    _buildButton = [self makePrimaryButton:@"生成 iOS 27 游戏 IPA"
                                     color:[UIColor colorWithRed:0.18 green:0.62 blue:0.48 alpha:1.0]
                                    action:@selector(onTapBuildIPA)];
    _buildButton.enabled = NO;
    _buildButton.alpha = 0.45;
    [buildStack addArrangedSubview:_buildButton];

    _progressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _progressBar.progressTintColor = [UIColor colorWithRed:0.68 green:0.52 blue:1.0 alpha:1.0];
    _progressBar.progress = 0.0;
    [buildStack addArrangedSubview:_progressBar];

    _progressLabel = [UILabel new];
    _progressLabel.text = @"等待导入游戏本体...";
    _progressLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightMedium];
    _progressLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    [buildStack addArrangedSubview:_progressLabel];

    _shareIPAButton = [self makePrimaryButton:@"分享 / 导出生成的 IPA 到 LiveContainer"
                                        color:[UIColor colorWithRed:0.22 green:0.46 blue:0.88 alpha:1.0]
                                       action:@selector(onTapShareIPA)];
    _shareIPAButton.hidden = YES;
    [buildStack addArrangedSubview:_shareIPAButton];

    // Card 3: Save Manager
    UIStackView *saveStack = nil;
    UIView *saveCard = [self makeGlassCardWithStack:&saveStack];
    [_mainStack addArrangedSubview:saveCard];

    UILabel *step3 = [UILabel new];
    step3.text = @"3. 存档同步管理";
    step3.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    step3.textColor = UIColor.whiteColor;
    [saveStack addArrangedSubview:step3];

    _saveCountLabel = [UILabel new];
    _saveCountLabel.font = [UIFont systemFontOfSize:13];
    _saveCountLabel.textColor = [UIColor colorWithWhite:0.84 alpha:1.0];
    _saveCountLabel.numberOfLines = 0;
    [saveStack addArrangedSubview:_saveCountLabel];

    UIButton *importSaveBtn = [self makePrimaryButton:@"导入 PC / Mac 存档文件"
                                                color:[UIColor colorWithWhite:0.22 alpha:0.9]
                                               action:@selector(onTapImportSave)];
    [saveStack addArrangedSubview:importSaveBtn];

    // Card 4: Console Log
    UIStackView *logStack = nil;
    UIView *logCard = [self makeGlassCardWithStack:&logStack];
    [_mainStack addArrangedSubview:logCard];

    UILabel *logTitle = [UILabel new];
    logTitle.text = @"运行与转换日志";
    logTitle.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    logTitle.textColor = UIColor.whiteColor;
    [logStack addArrangedSubview:logTitle];

    _logView = [UITextView new];
    _logView.editable = NO;
    _logView.backgroundColor = [UIColor colorWithWhite:0.03 alpha:0.65];
    _logView.textColor = [UIColor colorWithRed:0.74 green:0.96 blue:0.80 alpha:1.0];
    _logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _logView.layer.cornerRadius = 12;
    [_logView.heightAnchor constraintEqualToConstant:150].active = YES;
    [logStack addArrangedSubview:_logView];
}

- (void)appendLog:(NSString *)line {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *cur = self.logView.text ?: @"";
        self.logView.text = cur.length ? [cur stringByAppendingFormat:@"\n%@", line] : line;
        if (self.logView.text.length > 0) {
            [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length - 1, 1)];
        }
    });
}

- (void)setBusyState:(BOOL)busy {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.busy = busy;
        self.importButton.enabled = !busy;
        self.importButton.alpha = busy ? 0.5 : 1.0;
        BOOL canBuild = (!busy && self.currentInspection && self.currentInspection.hasARM64);
        self.buildButton.enabled = canBuild;
        self.buildButton.alpha = canBuild ? 1.0 : 0.45;
    });
}

- (void)refreshSaveSummary {
    NSArray *saves = [AICSaveManager listSaveFiles];
    _saveCountLabel.text = [NSString stringWithFormat:@"当前本地存档目录：Documents/Saves/AliceInCradle（已发现 %lu 个文件）", (unsigned long)saves.count];
}

// MARK: Actions
- (void)onTapImportGame {
    if (_busy) return;
    _activePicker = AICPickerKindGameFolderOrZip;
    NSArray<UTType *> *types = @[UTTypeFolder, UTTypeArchive, UTTypeZIP, UTTypeApplicationBundle];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:NO];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)onTapImportSave {
    _activePicker = AICPickerKindSaveFile;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:NO];
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)onTapBuildIPA {
    if (_busy || !_currentInspection) return;
    AICRuntimeMode mode = (AICRuntimeMode)_modeSegment.selectedSegmentIndex;
    [self setBusyState:YES];
    _shareIPAButton.hidden = YES;
    [self appendLog:@"开始转换 AliceInCradle.app -> iOS 27 IPA..."];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        AICBuildResult *res = AICBuildGameIPA(self.currentInspection, mode, @"com.alicecradle.ios.game", ^(NSString *status, double frac) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.progressLabel.text = status;
                self.progressBar.progress = (float)frac;
            });
        }, &err);

        dispatch_async(dispatch_get_main_queue(), ^{
            [self setBusyState:NO];
            if (!res) {
                self.progressLabel.text = [@"转换失败：" stringByAppendingString:err.localizedDescription ?: @"未知错误"];
                [self appendLog:[NSString stringWithFormat:@"[ERROR] %@", err.localizedDescription]];
                return;
            }
            self.lastExportedIPA = res.outputIPAURL;
            self.shareIPAButton.hidden = NO;
            double mb = (double)res.ipaSizeBytes / (1024.0 * 1024.0);
            self.progressLabel.text = [NSString stringWithFormat:@"完成！已生成 %@ (%.1f MB)", res.outputIPAURL.lastPathComponent, mb];
            [self appendLog:[NSString stringWithFormat:@"[OK] 输出路径: %@", res.outputIPAURL.path]];
            [self appendLog:[NSString stringWithFormat:@"[OK] 已转换 %lu 个 Mach-O，注入 %lu 个 iOS 27 Shim，大小 %.1f MB",
                             (unsigned long)res.convertedMachOCount, (unsigned long)res.shimCount, mb]];
        });
    });
}

- (void)onTapShareIPA {
    if (!_lastExportedIPA) return;
    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[_lastExportedIPA] applicationActivities:nil];
    avc.popoverPresentationController.sourceView = _shareIPAButton;
    [self presentViewController:avc animated:YES completion:nil];
}

// MARK: UIDocumentPickerDelegate
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    if (urls.count == 0) return;

    if (_activePicker == AICPickerKindSaveFile) {
        NSUInteger imported = 0;
        for (NSURL *u in urls) {
            if ([AICSaveManager importSaveFileAtURL:u error:nil]) imported++;
        }
        [self refreshSaveSummary];
        [self appendLog:[NSString stringWithFormat:@"[Saves] 已导入 %lu 个存档文件。", (unsigned long)imported]];
        return;
    }

    NSURL *picked = urls.firstObject;
    [self setBusyState:YES];
    [self appendLog:[NSString stringWithFormat:@"正在分析导入项: %@", picked.lastPathComponent]];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL scoped = [picked startAccessingSecurityScopedResource];
        NSURL *appToInspect = nil;
        NSError *err = nil;

        NSString *ext = picked.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"zip"]) {
            if (self.importedTempRoot) {
                [NSFileManager.defaultManager removeItemAtURL:self.importedTempRoot error:nil];
            }
            NSString *extractPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                     [NSString stringWithFormat:@"AICImport-%@", NSUUID.UUID.UUIDString]];
            NSURL *extractURL = [NSURL fileURLWithPath:extractPath isDirectory:YES];
            self.importedTempRoot = extractURL;
            BOOL ok = AICExtractZipArchive(picked, extractURL, ^(NSString *st, double f) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.progressLabel.text = st;
                    self.progressBar.progress = (float)f;
                });
            }, &err);
            if (ok) appToInspect = AICLocateMacAppBundle(extractURL);
        } else {
            // Copy selected .app folder into app-accessible temp staging to avoid security-scope expiration
            NSURL *located = AICLocateMacAppBundle(picked);
            if (located) {
                if (self.importedTempRoot) {
                    [NSFileManager.defaultManager removeItemAtURL:self.importedTempRoot error:nil];
                }
                NSString *copyRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                      [NSString stringWithFormat:@"AICImport-%@", NSUUID.UUID.UUIDString]];
                [NSFileManager.defaultManager createDirectoryAtPath:copyRoot withIntermediateDirectories:YES attributes:nil error:nil];
                NSURL *dstApp = [NSURL fileURLWithPath:[copyRoot stringByAppendingPathComponent:located.lastPathComponent] isDirectory:YES];
                self.importedTempRoot = [NSURL fileURLWithPath:copyRoot isDirectory:YES];
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.progressLabel.text = @"正在导入 .app 目录到工作区...";
                    self.progressBar.progress = 0.5f;
                });
                if ([NSFileManager.defaultManager copyItemAtURL:located toURL:dstApp error:&err]) {
                    appToInspect = dstApp;
                }
            }
        }

        if (scoped) [picked stopAccessingSecurityScopedResource];

        AICGameInspection *insp = appToInspect ? AICInspectMacAppBundle(appToInspect, &err) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.currentInspection = insp;
            [self setBusyState:NO];
            self.progressBar.progress = insp ? 1.0f : 0.0f;

            if (!insp) {
                self.gameStatusLabel.text = @"导入失败：未找到有效的 AliceInCradle.app";
                self.gameStatusLabel.textColor = [UIColor colorWithRed:1.0 green:0.45 blue:0.45 alpha:1.0];
                self.gameDetailLabel.text = err.localizedDescription ?: @"请确保选择的是 macOS 版游戏 .app 文件夹或 .zip 压缩包。";
                [self appendLog:[NSString stringWithFormat:@"[ERROR] %@", self.gameDetailLabel.text]];
                return;
            }

            double mb = (double)insp.totalBytes / (1024.0 * 1024.0);
            NSString *backendStr = (insp.backend == AICScriptBackendIL2CPP) ? @"IL2CPP (原生 ARM64)"
                                 : (insp.backend == AICScriptBackendMono) ? [NSString stringWithFormat:@"Mono (%lu DLLs)", (unsigned long)insp.managedDLLCount]
                                 : @"未知脚本后端";

            if (insp.backend == AICScriptBackendIL2CPP) {
                self.modeSegment.selectedSegmentIndex = AICRuntimeModeIL2CPPNative;
            } else {
                self.modeSegment.selectedSegmentIndex = AICRuntimeModeZeroJITInterp;
            }

            if (insp.hasARM64) {
                self.gameStatusLabel.text = [NSString stringWithFormat:@"已就绪：%@ v%@ (ARM64 ✓)", insp.appName, insp.gameVersion];
                self.gameStatusLabel.textColor = [UIColor colorWithRed:0.45 green:0.96 blue:0.68 alpha:1.0];
                self.gameDetailLabel.text = [NSString stringWithFormat:@"引擎：%@ · 后端：%@ · 大小：%.1f MB", insp.unityVersion, backendStr, mb];
                self.progressLabel.text = @"游戏校验通过，点击下方按钮生成 iOS 27 IPA";
            } else {
                self.gameStatusLabel.text = @"架构不兼容：缺少 ARM64 切片";
                self.gameStatusLabel.textColor = [UIColor colorWithRed:1.0 green:0.45 blue:0.45 alpha:1.0];
                self.gameDetailLabel.text = insp.warningMessage ?: @"缺少 Apple Silicon ARM64 二进制。";
            }
            [self appendLog:[NSString stringWithFormat:@"[Inspect] %@ | %@ | %@ | %.1f MB", insp.appName, insp.unityVersion, backendStr, mb]];
        });
    });
}

@end

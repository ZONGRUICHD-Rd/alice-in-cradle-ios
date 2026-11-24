#import "GameBuilder.h"
#import "MachOConverter.h"
#import "ZipArchive.h"
#include <sys/stat.h>

@implementation AICBuildResult @end

static NSError *BuildErr(NSString *msg) {
    return [NSError errorWithDomain:@"com.alicecradle.ios.builder"
                               code:300
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

NSURL *AICExportsDirectoryURL(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    // Detect LiveContainer shared Documents layout when running inside LiveContainer
    NSString *lcDocs = NSProcessInfo.processInfo.environment[@"LC_HOME_PATH"];
    NSString *base = lcDocs.length ? [lcDocs stringByAppendingPathComponent:@"Documents"] : docs;
    NSString *exports = [base stringByAppendingPathComponent:@"AliceCradle Exports"];
    [fm createDirectoryAtPath:exports withIntermediateDirectories:YES attributes:nil error:nil];
    return [NSURL fileURLWithPath:exports isDirectory:YES];
}

static NSURL *UniqueOutputURL(NSURL *dir, NSString *baseName) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *cand = [dir URLByAppendingPathComponent:[baseName stringByAppendingString:@".ipa"]];
    if (![fm fileExistsAtPath:cand.path]) return cand;
    for (int i = 2; i < 999; i++) {
        NSURL *alt = [dir URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-%d.ipa", baseName, i]];
        if (![fm fileExistsAtPath:alt.path]) return alt;
    }
    return cand;
}

static BOOL ShouldConvertBinaryAtPath(NSString *relPath, NSString *fullPath) {
    NSString *ext = relPath.pathExtension.lowercaseString;
    BOOL likely = ([ext isEqualToString:@"dylib"] || [ext isEqualToString:@"so"] ||
                   [relPath hasPrefix:@"MacOS/"] || [relPath hasPrefix:@"Frameworks/"] ||
                   [relPath hasPrefix:@"PlugIns/"] || [relPath containsString:@"/MacOS/"] ||
                   [relPath containsString:@"/Frameworks/"] || [relPath containsString:@"/PlugIns/"]);
    if (!likely) return NO;
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:fullPath];
    if (!fh) return NO;
    NSData *magic = [fh readDataOfLength:4];
    [fh closeFile];
    return AICMachOIsBinary(magic);
}

AICBuildResult * _Nullable AICBuildGameIPA(
    AICGameInspection *inspection,
    AICRuntimeMode runtimeMode,
    NSString *outputBundleID,
    void (^ _Nullable progress)(NSString *status, double fraction),
    NSError * _Nullable * _Nullable error
) {
    if (!inspection || !inspection.macAppURL) {
        if (error) *error = BuildErr(@"未选择有效的 AliceInCradle.app");
        return nil;
    }
    if (!inspection.hasARM64) {
        if (error) *error = BuildErr(@"该游戏本体不包含 ARM64 (Apple Silicon) 二进制切片，无法转换。");
        return nil;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableString *log = [NSMutableString new];

    // Create isolated temporary staging folder
    NSString *stageRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"AICStage-%@", NSUUID.UUID.UUIDString]];
    NSString *outAppDir = [stageRoot stringByAppendingPathComponent:@"AliceInCradle.app"];
    NSString *macSubdir = [outAppDir stringByAppendingPathComponent:@"Mac"];
    NSString *macContentsDst = [macSubdir stringByAppendingPathComponent:@"Contents"];
    NSString *fwDstDir = [outAppDir stringByAppendingPathComponent:@"Frameworks"];

    [fm createDirectoryAtPath:macSubdir withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:fwDstDir withIntermediateDirectories:YES attributes:nil error:nil];

    if (progress) progress(@"正在复制 macOS 游戏目录结构...", 0.08);
    NSString *srcContents = [inspection.macAppURL.path stringByAppendingPathComponent:@"Contents"];
    NSError *copyErr = nil;
    if (![fm copyItemAtPath:srcContents toPath:macContentsDst error:&copyErr]) {
        [fm removeItemAtPath:stageRoot error:nil];
        if (error) *error = BuildErr([NSString stringWithFormat:@"复制游戏目录失败: %@", copyErr.localizedDescription]);
        return nil;
    }

    // Remove macOS _CodeSignature folders so LiveContainer / user codesign starts clean
    [fm removeItemAtPath:[macContentsDst stringByAppendingPathComponent:@"_CodeSignature"] error:nil];

    // Step 1: Copy all pre-compiled iOS 27 libShim_*.dylib from Launcher bundle
    if (progress) progress(@"注入 iOS 27 原生兼容层 (libShim_*.dylib)...", 0.22);
    NSString *shimsSrc = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Shims"];
    NSArray<NSString *> *shimFiles = [fm contentsOfDirectoryAtPath:shimsSrc error:nil];
    NSUInteger shimCount = 0;
    for (NSString *sf in shimFiles) {
        if ([sf hasSuffix:@".dylib"]) {
            NSString *src = [shimsSrc stringByAppendingPathComponent:sf];
            NSString *dst = [fwDstDir stringByAppendingPathComponent:sf];
            [fm removeItemAtPath:dst error:nil];
            if ([fm copyItemAtPath:src toPath:dst error:nil]) {
                shimCount++;
            }
        }
    }
    if (shimCount == 0) {
        [fm removeItemAtPath:stageRoot error:nil];
        if (error) *error = BuildErr(@"启动器内缺少 Shims/libShim_*.dylib 兼容层，请使用 GitHub Actions 重新构建启动器 IPA。");
        return nil;
    }
    [log appendFormat:@"[Shims] Injected %lu iOS 27 shim libraries\n", (unsigned long)shimCount];

    // Step 2: Convert main executable & place at iOS app bundle root
    if (progress) progress(@"转换主程序 Mach-O (ARM64 -> iOS 27)...", 0.32);
    NSString *origExecPath = [[macContentsDst stringByAppendingPathComponent:@"MacOS"] stringByAppendingPathComponent:inspection.executableName];
    NSData *origExecData = [NSData dataWithContentsOfFile:origExecPath];
    NSError *machoErr = nil;
    NSData *convExec = AICConvertMacMachOToIOS27(origExecData, AICMachOOptionAddLauncherRPaths, &machoErr);
    if (!convExec) {
        [fm removeItemAtPath:stageRoot error:nil];
        if (error) *error = BuildErr([NSString stringWithFormat:@"主程序转换失败: %@", machoErr.localizedDescription]);
        return nil;
    }
    NSString *rootExecPath = [outAppDir stringByAppendingPathComponent:inspection.executableName];
    [convExec writeToFile:rootExecPath atomically:YES];
    chmod(rootExecPath.UTF8String, 0755);
    // Keep Mac/Contents/MacOS/<exe> converted as well in case anything inspects it
    [convExec writeToFile:origExecPath atomically:YES];
    chmod(origExecPath.UTF8String, 0755);
    NSUInteger convertedCount = 1;
    [log appendFormat:@"[Mach-O] Converted main executable: %@\n", inspection.executableName];

    // Step 3: Walk Mac/Contents and convert every ARM64 Mach-O binary (UnityPlayer, Mono, PlugIns, etc.)
    NSMutableArray<NSString *> *machoTargets = [NSMutableArray new];
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:macContentsDst];
    NSString *rel;
    while ((rel = [en nextObject]) != nil) {
        if ([rel isEqualToString:[@"MacOS/" stringByAppendingString:inspection.executableName]]) continue;
        NSString *full = [macContentsDst stringByAppendingPathComponent:rel];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:full isDirectory:&isDir] && !isDir) {
            if (ShouldConvertBinaryAtPath(rel, full)) {
                [machoTargets addObject:rel];
            }
        }
    }

    for (NSUInteger i = 0; i < machoTargets.count; i++) {
        NSString *r = machoTargets[i];
        NSString *full = [macContentsDst stringByAppendingPathComponent:r];
        if (progress) {
            double frac = 0.35 + 0.30 * ((double)(i + 1) / (double)MAX(machoTargets.count, 1));
            progress([NSString stringWithFormat:@"转换原生模块: %@ (%lu/%lu)", r.lastPathComponent, (unsigned long)(i + 1), (unsigned long)machoTargets.count], frac);
        }
        NSData *binData = [NSData dataWithContentsOfFile:full];
        if (!AICMachOHasARM64Slice(binData)) {
            [log appendFormat:@"[Skip] x86_64-only plugin skipped: %@\n", r];
            continue;
        }
        AICMachOOptions opts = AICMachOOptionNone;
        if (runtimeMode == AICRuntimeModeZeroJITInterp && [r.lastPathComponent containsString:@"libmonobdwgc"]) {
            opts |= AICMachOOptionAliasMonoMmapToSmmp;
        }
        NSError *bErr = nil;
        NSData *converted = AICConvertMacMachOToIOS27(binData, opts, &bErr);
        if (!converted) {
            [log appendFormat:@"[Warn] Could not convert %@: %@\n", r, bErr.localizedDescription];
            continue;
        }
        [converted writeToFile:full atomically:YES];
        chmod(full.UTF8String, 0755);
        convertedCount++;
        [log appendFormat:@"[Mach-O] Converted: %@%@\n", r, (opts & AICMachOOptionAliasMonoMmapToSmmp) ? @" (+_smmp)" : @""];
    }

    // Step 4: Generate iOS 27 Info.plist
    if (progress) progress(@"写入 iOS 27 Info.plist 与 Game Mode 配置...", 0.68);
    NSString *tplPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Templates/Info-game-ios.plist"];
    NSMutableDictionary *iosPlist = [NSMutableDictionary dictionaryWithContentsOfFile:tplPath] ?: [NSMutableDictionary new];
    iosPlist[@"CFBundleExecutable"] = inspection.executableName;
    iosPlist[@"CFBundleIdentifier"] = outputBundleID.length ? outputBundleID : @"com.alicecradle.ios.game";
    iosPlist[@"CFBundleDisplayName"] = @"爱丽丝的摇篮";
    iosPlist[@"CFBundleName"] = @"AliceInCradle";
    iosPlist[@"CFBundleShortVersionString"] = inspection.gameVersion ?: @"1.0";
    iosPlist[@"CFBundleVersion"] = @"1";
    iosPlist[@"SHIMMacRoot"] = @"Mac";
    iosPlist[@"LSSupportsGameMode"] = @YES;
    iosPlist[@"CADisableMinimumFrameDurationOnPhone"] = @YES;
    if (runtimeMode == AICRuntimeModeLiveContainerJIT) {
        iosPlist[@"AICMonoMode"] = @"jit";
    } else if (runtimeMode == AICRuntimeModeIL2CPPNative) {
        iosPlist[@"AICMonoMode"] = @"none";
    } else {
        iosPlist[@"AICMonoMode"] = @"interp";
    }

    // Copy launcher icon as fallback app icon if present
    NSString *iconSrc = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"AppIcon60x60@3x.png"];
    if ([fm fileExistsAtPath:iconSrc]) {
        [fm copyItemAtPath:iconSrc toPath:[outAppDir stringByAppendingPathComponent:@"AppIcon60x60@3x.png"] error:nil];
        iosPlist[@"CFBundleIcons"] = @{
            @"CFBundlePrimaryIcon": @{
                @"CFBundleIconFiles": @[@"AppIcon60x60"]
            }
        };
    }

    NSString *outPlistPath = [outAppDir stringByAppendingPathComponent:@"Info.plist"];
    [iosPlist writeToFile:outPlistPath atomically:YES];

    // Step 5: Package into ZIP64 IPA
    NSString *modeTag = (runtimeMode == AICRuntimeModeLiveContainerJIT) ? @"JIT"
                      : (runtimeMode == AICRuntimeModeIL2CPPNative) ? @"IL2CPP" : @"NoJIT";
    NSString *baseName = [NSString stringWithFormat:@"AliceInCradle-iOS27-%@", modeTag];
    NSURL *exportDir = AICExportsDirectoryURL();
    NSURL *finalIPA = UniqueOutputURL(exportDir, baseName);
    NSURL *tempIPA = [exportDir URLByAppendingPathComponent:[finalIPA.lastPathComponent stringByAppendingString:@".building"]];

    NSError *zipErr = nil;
    BOOL packed = AICCreateIPAFromAppBundle([NSURL fileURLWithPath:outAppDir isDirectory:YES], tempIPA, ^(NSString *st, double f) {
        if (progress) progress(st, 0.70 + 0.28 * f);
    }, &zipErr);

    [fm removeItemAtPath:stageRoot error:nil];
    if (!packed) {
        [fm removeItemAtURL:tempIPA error:nil];
        if (error) *error = BuildErr([NSString stringWithFormat:@"打包 IPA 失败: %@", zipErr.localizedDescription]);
        return nil;
    }

    [fm removeItemAtURL:finalIPA error:nil];
    [fm moveItemAtURL:tempIPA toURL:finalIPA error:nil];

    NSDictionary *attrs = [fm attributesOfItemAtPath:finalIPA.path error:nil];
    AICBuildResult *res = [AICBuildResult new];
    res.outputIPAURL = finalIPA;
    res.convertedMachOCount = convertedCount;
    res.shimCount = shimCount;
    res.ipaSizeBytes = [attrs fileSize];
    res.summaryLog = log;
    if (progress) progress(@"转换完成！IPA 已就绪", 1.0);
    return res;
}

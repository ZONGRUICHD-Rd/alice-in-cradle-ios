#import "GameInspector.h"
#import "MachOConverter.h"

@implementation AICGameInspection @end

NSURL * _Nullable AICLocateMacAppBundle(NSURL *selectedURL) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *path = selectedURL.path;
    if ([path.pathExtension.lowercaseString isEqualToString:@"app"] &&
        [fm fileExistsAtPath:[path stringByAppendingPathComponent:@"Contents/Info.plist"]]) {
        return selectedURL;
    }

    // Search up to depth 2 for an .app bundle containing Contents/Info.plist
    NSArray<NSString *> *top = [fm contentsOfDirectoryAtPath:path error:nil];
    for (NSString *item in top) {
        NSString *sub = [path stringByAppendingPathComponent:item];
        if ([item.pathExtension.lowercaseString isEqualToString:@"app"] &&
            [fm fileExistsAtPath:[sub stringByAppendingPathComponent:@"Contents/Info.plist"]]) {
            return [NSURL fileURLWithPath:sub isDirectory:YES];
        }
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:sub isDirectory:&isDir] && isDir) {
            NSArray<NSString *> *nested = [fm contentsOfDirectoryAtPath:sub error:nil];
            for (NSString *child in nested) {
                NSString *cpath = [sub stringByAppendingPathComponent:child];
                if ([child.pathExtension.lowercaseString isEqualToString:@"app"] &&
                    [fm fileExistsAtPath:[cpath stringByAppendingPathComponent:@"Contents/Info.plist"]]) {
                    return [NSURL fileURLWithPath:cpath isDirectory:YES];
                }
            }
        }
    }
    return nil;
}

static NSString *DetectUnityVersion(NSString *dataDir) {
    NSString *ggm = [dataDir stringByAppendingPathComponent:@"globalgamemanagers"];
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:ggm];
    if (!fh) return @"Unity (Unknown)";
    NSData *head = [fh readDataOfLength:256];
    [fh closeFile];
    if (head.length < 32) return @"Unity";

    const uint8_t *b = head.bytes;
    // Unity serialized header stores null-terminated version string around offset 20 (or 48 in v22+)
    for (NSUInteger off = 16; off + 8 < head.length; off++) {
        if ((b[off] == '2' && b[off+1] == '0') || (b[off] == '6' && b[off+1] == '0')) {
            NSUInteger end = off;
            while (end < head.length && b[end] >= 0x20 && b[end] <= 0x7E && (end - off) < 24) end++;
            NSString *cand = [[NSString alloc] initWithBytes:(b + off) length:(end - off) encoding:NSASCIIStringEncoding];
            if ([cand containsString:@"."] && ([cand containsString:@"f"] || [cand containsString:@"p"] || [cand containsString:@"b"])) {
                return cand;
            }
        }
    }
    return @"Unity";
}

AICGameInspection * _Nullable AICInspectMacAppBundle(NSURL *macAppURL, NSError * _Nullable * _Nullable error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *contents = [macAppURL.path stringByAppendingPathComponent:@"Contents"];
    NSString *plistPath = [contents stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (!plist) {
        if (error) *error = [NSError errorWithDomain:@"com.alicecradle.ios.inspect" code:1 userInfo:@{NSLocalizedDescriptionKey: @"未在所选目录中找到有效的 macOS Contents/Info.plist"}];
        return nil;
    }

    NSString *execName = plist[@"CFBundleExecutable"];
    if (!execName.length) {
        if (error) *error = [NSError errorWithDomain:@"com.alicecradle.ios.inspect" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Info.plist 缺少 CFBundleExecutable"}];
        return nil;
    }

    NSString *execPath = [[contents stringByAppendingPathComponent:@"MacOS"] stringByAppendingPathComponent:execName];
    NSData *execData = [NSData dataWithContentsOfFile:execPath options:NSDataReadingMappedIfSafe error:nil];
    if (!execData.length) {
        if (error) *error = [NSError errorWithDomain:@"com.alicecradle.ios.inspect" code:3 userInfo:@{NSLocalizedDescriptionKey: @"找不到主程序二进制文件"}];
        return nil;
    }

    AICGameInspection *info = [AICGameInspection new];
    info.macAppURL = macAppURL;
    info.appName = plist[@"CFBundleDisplayName"] ?: plist[@"CFBundleName"] ?: macAppURL.lastPathComponent.stringByDeletingPathExtension;
    info.executableName = execName;
    info.gameVersion = plist[@"CFBundleShortVersionString"] ?: plist[@"CFBundleVersion"] ?: @"Unknown";
    info.hasARM64 = AICMachOHasARM64Slice(execData);

    NSString *fwDir = [contents stringByAppendingPathComponent:@"Frameworks"];
    NSString *dataDir = [contents stringByAppendingPathComponent:@"Resources/Data"];
    info.unityVersion = DetectUnityVersion(dataDir);

    if ([fm fileExistsAtPath:[fwDir stringByAppendingPathComponent:@"GameAssembly.dylib"]] ||
        [fm fileExistsAtPath:[dataDir stringByAppendingPathComponent:@"il2cpp_data/Metadata/global-metadata.dat"]]) {
        info.backend = AICScriptBackendIL2CPP;
    } else if ([fm fileExistsAtPath:[fwDir stringByAppendingPathComponent:@"libmonobdwgc-2.0.dylib"]] ||
               [fm fileExistsAtPath:[dataDir stringByAppendingPathComponent:@"Managed/Assembly-CSharp.dll"]]) {
        info.backend = AICScriptBackendMono;
        NSArray *dlls = [fm contentsOfDirectoryAtPath:[dataDir stringByAppendingPathComponent:@"Managed"] error:nil];
        NSUInteger cnt = 0;
        for (NSString *f in dlls) if ([f.pathExtension.lowercaseString isEqualToString:@"dll"]) cnt++;
        info.managedDLLCount = cnt;
    } else {
        info.backend = AICScriptBackendUnknown;
    }

    // Also verify UnityPlayer.dylib ARM64 slice if present
    NSString *unityPlayer = [fwDir stringByAppendingPathComponent:@"UnityPlayer.dylib"];
    if ([fm fileExistsAtPath:unityPlayer]) {
        NSData *upData = [NSData dataWithContentsOfFile:unityPlayer options:NSDataReadingMappedIfSafe error:nil];
        if (upData.length && !AICMachOHasARM64Slice(upData)) {
            info.hasARM64 = NO;
        }
    }

    if (!info.hasARM64) {
        info.warningMessage = @"检测到该 macOS 包仅含 Intel (x86_64) 架构，缺少 Apple Silicon (ARM64) 切片，无法在 iPhone 原生运行。请使用支持 Apple Silicon 的新版 macOS 游戏本体。";
    }

    // Calculate total size
    uint64_t total = 0;
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:macAppURL.path];
    NSString *rel;
    while ((rel = [en nextObject]) != nil) {
        NSDictionary *attrs = [fm attributesOfItemAtPath:[macAppURL.path stringByAppendingPathComponent:rel] error:nil];
        if ([attrs.fileType isEqualToString:NSFileTypeRegular]) {
            total += [attrs fileSize];
        }
    }
    info.totalBytes = total;
    return info;
}

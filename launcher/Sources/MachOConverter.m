#import "MachOConverter.h"
#include <mach-o/loader.h>
#include <mach-o/fat.h>
#include <string.h>

#ifndef PLATFORM_IOS
#define PLATFORM_IOS 2
#endif

static uint32_t ReadBE32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static uint64_t ReadBE64(const uint8_t *p) {
    return ((uint64_t)ReadBE32(p) << 32) | (uint64_t)ReadBE32(p + 4);
}

static NSError *MachOErr(NSString *msg) {
    return [NSError errorWithDomain:@"com.alicecradle.ios.macho"
                               code:100
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

BOOL AICMachOIsBinary(NSData *data) {
    if (data.length < 4) return NO;
    const uint8_t *raw = data.bytes;
    uint32_t le = *(const uint32_t *)raw;
    uint32_t be = ReadBE32(raw);
    return (le == MH_MAGIC_64 || be == FAT_MAGIC || be == FAT_MAGIC_64);
}

static BOOL FindARM64Slice(NSData *input, uint64_t *outOffset, uint64_t *outSize) {
    if (input.length < sizeof(struct mach_header_64)) return NO;
    const uint8_t *raw = input.bytes;
    uint32_t be = ReadBE32(raw);
    if (be == FAT_MAGIC || be == FAT_MAGIC_64) {
        uint32_t count = ReadBE32(raw + 4);
        uint64_t stride = (be == FAT_MAGIC) ? 20 : 32;
        if (count == 0 || count > 64 || 8 + (uint64_t)count * stride > input.length) return NO;
        for (uint32_t i = 0; i < count; i++) {
            const uint8_t *arch = raw + 8 + i * stride;
            uint32_t cpuType = ReadBE32(arch);
            uint32_t cpuSub = ReadBE32(arch + 4) & 0x00FFFFFF;
            if (cpuType == (uint32_t)CPU_TYPE_ARM64 && cpuSub == (uint32_t)CPU_SUBTYPE_ARM64_ALL) {
                uint64_t off = (be == FAT_MAGIC) ? ReadBE32(arch + 8) : ReadBE64(arch + 8);
                uint64_t len = (be == FAT_MAGIC) ? ReadBE32(arch + 12) : ReadBE64(arch + 16);
                if (off <= input.length && len <= input.length - off && len >= sizeof(struct mach_header_64)) {
                    if (outOffset) *outOffset = off;
                    if (outSize) *outSize = len;
                    return YES;
                }
            }
        }
        return NO;
    }
    const struct mach_header_64 *h = (const struct mach_header_64 *)raw;
    if (h->magic == MH_MAGIC_64 && h->cputype == CPU_TYPE_ARM64) {
        if (outOffset) *outOffset = 0;
        if (outSize) *outSize = input.length;
        return YES;
    }
    return NO;
}

BOOL AICMachOHasARM64Slice(NSData *data) {
    return FindARM64Slice(data, NULL, NULL);
}

// Map macOS system dylib/framework paths to our bundled iOS 27 shim libraries.
static NSString *RewriteDylibPath(NSString *orig) {
    if (!orig.length) return orig;

    // 1. Rewrite bundle-relative macOS paths (@executable_path/../ -> @executable_path/Mac/Contents/)
    if ([orig hasPrefix:@"@executable_path/../"]) {
        NSString *tail = [orig substringFromIndex:@"@executable_path/../".length];
        return [@"@executable_path/Mac/Contents/" stringByAppendingString:tail];
    }

    // 2. Direct macOS library -> bundled iOS 27 Shim mapping
    static NSDictionary<NSString *, NSString *> *shimMap = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shimMap = @{
            @"AppKit":              @"@rpath/libShim_AppKit.dylib",
            @"Cocoa":               @"@rpath/libShim_AppKit.dylib",
            @"CoreAudio":           @"@rpath/libShim_CoreAudio.dylib",
            @"AudioUnit":           @"@rpath/libShim_AudioUnit.dylib",
            @"CoreVideo":           @"@rpath/libShim_CoreVideo.dylib",
            @"CoreGraphics":        @"@rpath/libShim_CoreGraphics.dylib",
            @"Carbon":              @"@rpath/libShim_Carbon.dylib",
            @"CoreServices":        @"@rpath/libShim_CoreServices.dylib",
            @"IOKit":               @"@rpath/libShim_IOKit.dylib",
            @"Metal":               @"@rpath/libShim_Metal.dylib",
            @"Security":            @"@rpath/libShim_Security.dylib",
            @"SystemConfiguration": @"@rpath/libShim_SystemConfiguration.dylib",
            @"Foundation":          @"@rpath/libShim_Foundation.dylib",
        };
    });

    if ([orig isEqualToString:@"/usr/lib/libSystem.B.dylib"]) {
        return @"@rpath/libShim_libSystem.dylib";
    }

    // Check /System/Library/Frameworks/<Name>.framework/...
    if ([orig hasPrefix:@"/System/Library/Frameworks/"]) {
        NSString *rest = [orig substringFromIndex:@"/System/Library/Frameworks/".length];
        NSRange fwRange = [rest rangeOfString:@".framework"];
        if (fwRange.location != NSNotFound) {
            NSString *fwName = [rest substringToIndex:fwRange.location];
            NSString *mapped = shimMap[fwName];
            if (mapped) return mapped;
            // Flatten macOS Versions/A/Foo -> iOS Foo.framework/Foo
            return [NSString stringWithFormat:@"/System/Library/Frameworks/%@.framework/%@", fwName, fwName];
        }
    }

    // Flatten ApplicationServices sub-frameworks if referenced
    if ([orig containsString:@".framework/Versions/"]) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"([^/]+)\\.framework/Versions/[^/]+/\\1$" options:0 error:nil];
        NSString *flat = [re stringByReplacingMatchesInString:orig options:0 range:NSMakeRange(0, orig.length) withTemplate:@"$1.framework/$1"];
        if (flat.length > 0) return flat;
    }

    return orig;
}

static NSData *BuildDylibCommand(uint32_t cmd, const struct dylib *origDylib, NSString *newPath) {
    NSData *utf8 = [newPath dataUsingEncoding:NSUTF8StringEncoding];
    size_t hdrSize = sizeof(struct dylib_command);
    size_t total = (hdrSize + utf8.length + 1 + 7) & ~(size_t)7;
    NSMutableData *buf = [NSMutableData dataWithLength:total];
    struct dylib_command *dc = (struct dylib_command *)buf.mutableBytes;
    dc->cmd = cmd;
    dc->cmdsize = (uint32_t)total;
    dc->dylib = *origDylib;
    dc->dylib.name.offset = (uint32_t)hdrSize;
    memcpy((uint8_t *)buf.mutableBytes + hdrSize, utf8.bytes, utf8.length);
    return buf;
}

static NSData *BuildRPathCommand(NSString *rpath) {
    NSData *utf8 = [rpath dataUsingEncoding:NSUTF8StringEncoding];
    size_t hdrSize = sizeof(struct rpath_command);
    size_t total = (hdrSize + utf8.length + 1 + 7) & ~(size_t)7;
    NSMutableData *buf = [NSMutableData dataWithLength:total];
    struct rpath_command *rc = (struct rpath_command *)buf.mutableBytes;
    rc->cmd = LC_RPATH;
    rc->cmdsize = (uint32_t)total;
    rc->path.offset = (uint32_t)hdrSize;
    memcpy((uint8_t *)buf.mutableBytes + hdrSize, utf8.bytes, utf8.length);
    return buf;
}

NSData * _Nullable AICConvertMacMachOToIOS27(
    NSData *input,
    AICMachOOptions options,
    NSError * _Nullable * _Nullable error
) {
    uint64_t sliceOff = 0, sliceLen = 0;
    if (!FindARM64Slice(input, &sliceOff, &sliceLen)) {
        if (error) *error = MachOErr(@"Missing ARM64 Mach-O slice (Intel x86_64-only macOS builds are unsupported on iPhone).");
        return nil;
    }

    NSMutableData *out = [[input subdataWithRange:NSMakeRange((NSUInteger)sliceOff, (NSUInteger)sliceLen)] mutableCopy];
    uint8_t *bytes = out.mutableBytes;
    struct mach_header_64 *hdr = (struct mach_header_64 *)bytes;

    if (hdr->magic != MH_MAGIC_64 || hdr->cputype != CPU_TYPE_ARM64) {
        if (error) *error = MachOErr(@"Unexpected Mach-O header after ARM64 extraction.");
        return nil;
    }

    uint64_t origCmdEnd = sizeof(struct mach_header_64) + (uint64_t)hdr->sizeofcmds;
    if (origCmdEnd > out.length) {
        if (error) *error = MachOErr(@"Truncated Mach-O load commands.");
        return nil;
    }

    // Find earliest section file offset so we know header padding budget
    uint64_t firstSectionOff = out.length;
    uint64_t linkStart = 0, linkEnd = 0;
    {
        uint64_t pos = sizeof(struct mach_header_64);
        for (uint32_t i = 0; i < hdr->ncmds; i++) {
            if (pos + sizeof(struct load_command) > origCmdEnd) {
                if (error) *error = MachOErr(@"Corrupt load command table.");
                return nil;
            }
            struct load_command *lc = (struct load_command *)(bytes + pos);
            if (lc->cmdsize < 8 || (lc->cmdsize % 8) != 0 || pos + lc->cmdsize > origCmdEnd) {
                if (error) *error = MachOErr(@"Invalid load command size.");
                return nil;
            }
            if (lc->cmd == LC_SEGMENT_64) {
                struct segment_command_64 *seg = (struct segment_command_64 *)lc;
                if (!strncmp(seg->segname, "__LINKEDIT", 16)) {
                    linkStart = seg->fileoff;
                    linkEnd = seg->fileoff + seg->filesize;
                }
                struct section_64 *sects = (struct section_64 *)((uint8_t *)seg + sizeof(struct segment_command_64));
                for (uint32_t s = 0; s < seg->nsects; s++) {
                    if (sects[s].offset > 0 && sects[s].offset < firstSectionOff) {
                        firstSectionOff = sects[s].offset;
                    }
                }
            }
            pos += lc->cmdsize;
        }
    }

    // Rebuild load commands
    NSMutableData *newCmds = [NSMutableData dataWithCapacity:hdr->sizeofcmds + 512];
    NSMutableSet<NSString *> *existingRPaths = [NSMutableSet new];
    uint32_t newCount = 0;
    BOOL sawBuildVersion = NO;

    uint64_t pos = sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        struct load_command *lc = (struct load_command *)(bytes + pos);
        uint32_t cmd = lc->cmd;
        uint32_t sz = lc->cmdsize;

        if (cmd == LC_LOAD_DYLIB || cmd == LC_LOAD_WEAK_DYLIB || cmd == LC_REEXPORT_DYLIB || cmd == LC_LAZY_LOAD_DYLIB) {
            struct dylib_command *dc = (struct dylib_command *)lc;
            if (dc->dylib.name.offset < sz) {
                const char *cpath = (const char *)lc + dc->dylib.name.offset;
                NSString *origPath = [NSString stringWithUTF8String:cpath] ?: @"";
                NSString *mapped = RewriteDylibPath(origPath);
                [newCmds appendData:BuildDylibCommand(cmd, &dc->dylib, mapped)];
                newCount++;
            } else {
                [newCmds appendBytes:lc length:sz];
                newCount++;
            }
        } else if (cmd == LC_RPATH) {
            struct rpath_command *rc = (struct rpath_command *)lc;
            if (rc->path.offset < sz) {
                const char *crp = (const char *)lc + rc->path.offset;
                NSString *rp = [NSString stringWithUTF8String:crp] ?: @"";
                if ([rp hasPrefix:@"@executable_path/../"]) {
                    rp = [@"@executable_path/Mac/Contents/" stringByAppendingString:[rp substringFromIndex:@"@executable_path/../".length]];
                }
                [existingRPaths addObject:rp];
                [newCmds appendData:BuildRPathCommand(rp)];
                newCount++;
            }
        } else if (cmd == LC_BUILD_VERSION) {
            NSMutableData *bvData = [NSMutableData dataWithBytes:lc length:sz];
            struct build_version_command *bv = (struct build_version_command *)bvData.mutableBytes;
            bv->platform = PLATFORM_IOS;          // 2 = iOS
            bv->minos = (17U << 16);              // iOS 17.0 minimum
            bv->sdk = (27U << 16);                // iOS 27.0 SDK
            [newCmds appendData:bvData];
            newCount++;
            sawBuildVersion = YES;
        } else if (cmd == LC_VERSION_MIN_MACOSX) {
            // Upgrade legacy macOS min-version command to iOS 27 LC_BUILD_VERSION
            struct build_version_command bv = {0};
            bv.cmd = LC_BUILD_VERSION;
            bv.cmdsize = sizeof(struct build_version_command);
            bv.platform = PLATFORM_IOS;
            bv.minos = (17U << 16);
            bv.sdk = (27U << 16);
            bv.ntools = 0;
            [newCmds appendBytes:&bv length:sizeof(bv)];
            newCount++;
            sawBuildVersion = YES;
        } else {
            [newCmds appendBytes:lc length:sz];
            newCount++;
        }

        pos += sz;
    }

    if (!sawBuildVersion) {
        struct build_version_command bv = {0};
        bv.cmd = LC_BUILD_VERSION;
        bv.cmdsize = sizeof(struct build_version_command);
        bv.platform = PLATFORM_IOS;
        bv.minos = (17U << 16);
        bv.sdk = (27U << 16);
        bv.ntools = 0;
        [newCmds appendBytes:&bv length:sizeof(bv)];
        newCount++;
    }

    // Ensure @executable_path/Frameworks is always searchable for libShim_*.dylib
    NSArray<NSString *> *requiredRPaths = (options & AICMachOOptionAddLauncherRPaths)
        ? @[@"@executable_path/Frameworks", @"@executable_path/Mac/Contents/Frameworks", @"@loader_path/Frameworks"]
        : @[@"@executable_path/Frameworks"];
    for (NSString *rp in requiredRPaths) {
        if (![existingRPaths containsObject:rp]) {
            [newCmds appendData:BuildRPathCommand(rp)];
            [existingRPaths addObject:rp];
            newCount++;
        }
    }

    uint64_t newCmdEnd = sizeof(struct mach_header_64) + newCmds.length;
    if (newCmdEnd > firstSectionOff) {
        if (error) *error = MachOErr([NSString stringWithFormat:@"Mach-O header padding exceeded (%llu > %llu).", newCmdEnd, firstSectionOff]);
        return nil;
    }

    // Verify any expanded bytes beyond old header are zero padding
    if (newCmdEnd > origCmdEnd) {
        for (uint64_t k = origCmdEnd; k < newCmdEnd; k++) {
            if (bytes[k] != 0) {
                if (error) *error = MachOErr(@"Mach-O header expansion would overwrite non-zero bytes.");
                return nil;
            }
        }
    }

    memset(bytes + sizeof(struct mach_header_64), 0, (size_t)(MAX(origCmdEnd, newCmdEnd) - sizeof(struct mach_header_64)));
    memcpy(bytes + sizeof(struct mach_header_64), newCmds.bytes, newCmds.length);
    hdr->ncmds = newCount;
    hdr->sizeofcmds = (uint32_t)newCmds.length;

    // Optional Mono Zero-JIT helper: alias exact _mmap\0 strings inside __LINKEDIT to _smmp\0
    if ((options & AICMachOOptionAliasMonoMmapToSmmp) && linkEnd > linkStart && linkEnd <= out.length) {
        const char oldSym[] = "_mmap";
        const char newSym[] = "_smmp";
        size_t symLen = 5;
        for (uint64_t at = linkStart; at + symLen < linkEnd; at++) {
            // Ensure symbol boundary (preceded by NUL or non-ident byte, terminated by NUL)
            if (memcmp(bytes + at, oldSym, symLen) == 0 && bytes[at + symLen] == '\0') {
                uint8_t prev = (at > linkStart) ? bytes[at - 1] : 0;
                if (prev == '\0' || prev < 0x20) {
                    memcpy(bytes + at, newSym, symLen);
                    at += symLen;
                }
            }
        }
    }

    return out;
}

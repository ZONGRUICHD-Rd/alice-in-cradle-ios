#import "ZipArchive.h"
#include <zlib.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>

static uint16_t Rd16(const uint8_t *p) { return (uint16_t)p[0] | ((uint16_t)p[1] << 8); }
static uint32_t Rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint64_t Rd64(const uint8_t *p) {
    return (uint64_t)Rd32(p) | ((uint64_t)Rd32(p + 4) << 32);
}

static void Wr16(uint8_t *p, uint16_t v) { p[0] = v & 0xFF; p[1] = (v >> 8) & 0xFF; }
static void Wr32(uint8_t *p, uint32_t v) {
    p[0] = v & 0xFF; p[1] = (v >> 8) & 0xFF; p[2] = (v >> 16) & 0xFF; p[3] = (v >> 24) & 0xFF;
}
static void Wr64(uint8_t *p, uint64_t v) { Wr32(p, (uint32_t)(v & 0xFFFFFFFFULL)); Wr32(p + 4, (uint32_t)(v >> 32)); }

static NSError *ZipErr(NSString *msg) {
    return [NSError errorWithDomain:@"com.alicecradle.ios.zip"
                               code:200
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

// MARK: Streaming ZIP Extractor
BOOL AICExtractZipArchive(
    NSURL *zipURL,
    NSURL *destDirURL,
    void (^ _Nullable progress)(NSString *status, double fraction),
    NSError * _Nullable * _Nullable error
) {
    FILE *fp = fopen(zipURL.path.UTF8String, "rb");
    if (!fp) {
        if (error) *error = ZipErr(@"无法打开 ZIP 压缩包");
        return NO;
    }

    fseeko(fp, 0, SEEK_END);
    off_t fileSize = ftello(fp);
    if (fileSize < 22) {
        fclose(fp);
        if (error) *error = ZipErr(@"无效的 ZIP 文件（文件过小）");
        return NO;
    }

    // Search backwards for End of Central Directory (0x06054b50)
    off_t searchLen = MIN(fileSize, (off_t)(65535 + 22));
    uint8_t *tail = malloc((size_t)searchLen);
    if (!tail) { fclose(fp); if (error) *error = ZipErr(@"内存不足"); return NO; }
    fseeko(fp, fileSize - searchLen, SEEK_SET);
    fread(tail, 1, (size_t)searchLen, fp);

    off_t eocdRel = -1;
    for (off_t i = searchLen - 22; i >= 0; i--) {
        if (Rd32(tail + i) == 0x06054b50U) {
            eocdRel = i;
            break;
        }
    }
    if (eocdRel < 0) {
        free(tail);
        fclose(fp);
        if (error) *error = ZipErr(@"未找到 ZIP 中央目录结构");
        return NO;
    }

    uint64_t totalEntries = Rd16(tail + eocdRel + 10);
    uint64_t cdSize = Rd32(tail + eocdRel + 12);
    uint64_t cdOffset = Rd32(tail + eocdRel + 16);

    // Handle ZIP64 EOCD locator if needed
    if (eocdRel >= 20 && Rd32(tail + eocdRel - 20) == 0x07064b50U) {
        uint64_t z64Off = Rd64(tail + eocdRel - 12);
        uint8_t z64[56];
        if (z64Off + 56 <= (uint64_t)fileSize) {
            fseeko(fp, (off_t)z64Off, SEEK_SET);
            if (fread(z64, 1, 56, fp) == 56 && Rd32(z64) == 0x06064b50U) {
                totalEntries = Rd64(z64 + 32);
                cdSize = Rd64(z64 + 40);
                cdOffset = Rd64(z64 + 48);
            }
        }
    }
    free(tail);

    if (cdOffset + cdSize > (uint64_t)fileSize) {
        fclose(fp);
        if (error) *error = ZipErr(@"ZIP 中央目录偏移越界");
        return NO;
    }

    uint8_t *cdBuf = malloc((size_t)cdSize);
    if (!cdBuf) { fclose(fp); if (error) *error = ZipErr(@"内存不足（无法读取 ZIP 目录）"); return NO; }
    fseeko(fp, (off_t)cdOffset, SEEK_SET);
    fread(cdBuf, 1, (size_t)cdSize, fp);

    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtURL:destDirURL withIntermediateDirectories:YES attributes:nil error:nil];

    uint8_t *inChunk = malloc(65536);
    uint8_t *outChunk = malloc(65536);
    if (!inChunk || !outChunk) {
        free(inChunk); free(outChunk); free(cdBuf); fclose(fp);
        if (error) *error = ZipErr(@"内存不足");
        return NO;
    }

    uint64_t cursor = 0;
    BOOL ok = YES;
    for (uint64_t idx = 0; idx < totalEntries && cursor + 46 <= cdSize; idx++) {
        const uint8_t *ent = cdBuf + cursor;
        if (Rd32(ent) != 0x02014b50U) { ok = NO; break; }

        uint16_t method = Rd16(ent + 10);
        uint64_t compSize = Rd32(ent + 20);
        uint64_t uncompSize = Rd32(ent + 24);
        uint16_t nameLen = Rd16(ent + 28);
        uint16_t extraLen = Rd16(ent + 30);
        uint16_t commentLen = Rd16(ent + 32);
        uint32_t extAttr = Rd32(ent + 38);
        uint64_t localOff = Rd32(ent + 42);

        if (cursor + 46 + nameLen + extraLen + commentLen > cdSize) { ok = NO; break; }

        // Parse ZIP64 extra field (tag 0x0001) if any field is 0xFFFFFFFF
        const uint8_t *ex = ent + 46 + nameLen;
        uint16_t exPos = 0;
        while (exPos + 4 <= extraLen) {
            uint16_t tag = Rd16(ex + exPos);
            uint16_t dlen = Rd16(ex + exPos + 2);
            if (tag == 0x0001 && exPos + 4 + dlen <= extraLen) {
                const uint8_t *p = ex + exPos + 4;
                uint16_t rem = dlen;
                if (uncompSize == 0xFFFFFFFFU && rem >= 8) { uncompSize = Rd64(p); p += 8; rem -= 8; }
                if (compSize == 0xFFFFFFFFU && rem >= 8) { compSize = Rd64(p); p += 8; rem -= 8; }
                if (localOff == 0xFFFFFFFFU && rem >= 8) { localOff = Rd64(p); p += 8; rem -= 8; }
            }
            exPos += 4 + dlen;
        }

        NSString *relPath = [[NSString alloc] initWithBytes:(ent + 46) length:nameLen encoding:NSUTF8StringEncoding];
        cursor += 46 + nameLen + extraLen + commentLen;
        if (!relPath.length || [relPath containsString:@".."] || [relPath hasPrefix:@"__MACOSX/"]) continue;

        NSURL *targetURL = [destDirURL URLByAppendingPathComponent:relPath];
        if ([relPath hasSuffix:@"/"]) {
            [fm createDirectoryAtURL:targetURL withIntermediateDirectories:YES attributes:nil error:nil];
            continue;
        }

        [fm createDirectoryAtURL:targetURL.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];

        // Read local file header to find exact data start
        uint8_t lfh[30];
        fseeko(fp, (off_t)localOff, SEEK_SET);
        if (fread(lfh, 1, 30, fp) != 30 || Rd32(lfh) != 0x04034b50U) { ok = NO; break; }
        uint16_t lName = Rd16(lfh + 26);
        uint16_t lExtra = Rd16(lfh + 28);
        fseeko(fp, (off_t)(localOff + 30 + lName + lExtra), SEEK_SET);

        FILE *outFp = fopen(targetURL.path.UTF8String, "wb");
        if (!outFp) { ok = NO; break; }

        if (method == 0) {
            uint64_t left = compSize;
            while (left > 0) {
                size_t want = (size_t)MIN(left, 65536ULL);
                size_t got = fread(inChunk, 1, want, fp);
                if (got == 0) { ok = NO; break; }
                fwrite(inChunk, 1, got, outFp);
                left -= got;
            }
        } else if (method == 8) {
            z_stream zs = {0};
            if (inflateInit2(&zs, -MAX_WBITS) != Z_OK) { fclose(outFp); ok = NO; break; }
            uint64_t left = compSize;
            int zret = Z_OK;
            while (left > 0 && zret != Z_STREAM_END) {
                size_t want = (size_t)MIN(left, 65536ULL);
                size_t got = fread(inChunk, 1, want, fp);
                if (got == 0) { zret = Z_DATA_ERROR; break; }
                left -= got;
                zs.next_in = inChunk;
                zs.avail_in = (uInt)got;
                do {
                    zs.next_out = outChunk;
                    zs.avail_out = 65536;
                    zret = inflate(&zs, Z_NO_FLUSH);
                    if (zret != Z_OK && zret != Z_STREAM_END && zret != Z_BUF_ERROR) break;
                    size_t have = 65536 - zs.avail_out;
                    if (have > 0) fwrite(outChunk, 1, have, outFp);
                } while (zs.avail_out == 0);
            }
            inflateEnd(&zs);
            if (zret != Z_STREAM_END && zret != Z_OK) ok = NO;
        } else {
            ok = NO;
        }
        fclose(outFp);

        // Preserve Unix permissions (executable bits for binaries)
        mode_t mode = (mode_t)((extAttr >> 16) & 0x1FF);
        if (mode != 0) chmod(targetURL.path.UTF8String, mode);

        if (progress && (idx % 40 == 0 || idx + 1 == totalEntries)) {
            double frac = totalEntries > 0 ? ((double)(idx + 1) / (double)totalEntries) : 1.0;
            progress([NSString stringWithFormat:@"解压游戏资源 (%llu / %llu)...", idx + 1, totalEntries], frac);
        }
        if (!ok) break;
    }

    free(inChunk);
    free(outChunk);
    free(cdBuf);
    fclose(fp);
    if (!ok && error) *error = ZipErr(@"解压 ZIP 压缩包失败（可能包含不支持的压缩方式或已损坏）");
    return ok;
}

// MARK: Streaming ZIP64 IPA Writer
@interface AICZipEntry : NSObject
@property(nonatomic, copy) NSString *zipPath;
@property(nonatomic) uint32_t crc32;
@property(nonatomic) uint64_t compSize;
@property(nonatomic) uint64_t uncompSize;
@property(nonatomic) uint64_t localOffset;
@property(nonatomic) uint16_t method;
@property(nonatomic) uint32_t extAttr;
@end
@implementation AICZipEntry @end

BOOL AICCreateIPAFromAppBundle(
    NSURL *appBundleURL,
    NSURL *outputIPAURL,
    void (^ _Nullable progress)(NSString *status, double fraction),
    NSError * _Nullable * _Nullable error
) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *appName = appBundleURL.lastPathComponent;
    NSString *basePath = appBundleURL.path;

    // Collect all files deterministically
    NSMutableArray<NSString *> *relFiles = [NSMutableArray new];
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:basePath];
    NSString *rel;
    while ((rel = [en nextObject]) != nil) {
        NSString *full = [basePath stringByAppendingPathComponent:rel];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:full isDirectory:&isDir] && !isDir) {
            [relFiles addObject:rel];
        }
    }
    [relFiles sortUsingSelector:@selector(compare:)];

    FILE *outFp = fopen(outputIPAURL.path.UTF8String, "wb");
    if (!outFp) {
        if (error) *error = ZipErr(@"无法创建输出 IPA 文件");
        return NO;
    }

    uint8_t *inBuf = malloc(131072);
    uint8_t *outBuf = malloc(131072);
    if (!inBuf || !outBuf) {
        free(inBuf); free(outBuf); fclose(outFp);
        if (error) *error = ZipErr(@"内存不足");
        return NO;
    }

    NSMutableArray<AICZipEntry *> *entries = [NSMutableArray arrayWithCapacity:relFiles.count];
    uint64_t offset = 0;

    for (NSUInteger i = 0; i < relFiles.count; i++) {
        NSString *r = relFiles[i];
        NSString *full = [basePath stringByAppendingPathComponent:r];
        NSString *zipName = [NSString stringWithFormat:@"Payload/%@/%@", appName, r];
        NSData *nameData = [zipName dataUsingEncoding:NSUTF8StringEncoding];

        struct stat st = {0};
        stat(full.UTF8String, &st);
        uint32_t extAttr = ((uint32_t)(st.st_mode & 0xFFFF)) << 16;

        // Store already-compressed assets (png/ogg/mp4/resource/unity3d) without re-deflating for speed
        NSString *ext = r.pathExtension.lowercaseString;
        BOOL useStore = ([ext isEqualToString:@"resource"] || [ext isEqualToString:@"ress"] ||
                         [ext isEqualToString:@"png"] || [ext isEqualToString:@"ogg"] ||
                         [ext isEqualToString:@"mp4"] || [ext isEqualToString:@"unity3d"] ||
                         st.st_size == 0);
        uint16_t method = useStore ? 0 : 8;

        AICZipEntry *ent = [AICZipEntry new];
        ent.zipPath = zipName;
        ent.localOffset = offset;
        ent.method = method;
        ent.extAttr = extAttr;
        ent.uncompSize = (uint64_t)st.st_size;

        // Write Local File Header with Data Descriptor flag (bit 3) + ZIP64 version 45
        uint8_t lfh[30] = {0};
        Wr32(lfh + 0, 0x04034b50U);
        Wr16(lfh + 4, 45);
        Wr16(lfh + 6, 0x0008 | 0x0800); // Data descriptor + UTF-8
        Wr16(lfh + 8, method);
        Wr16(lfh + 26, (uint16_t)nameData.length);
        fwrite(lfh, 1, 30, outFp);
        fwrite(nameData.bytes, 1, nameData.length, outFp);
        offset += 30 + nameData.length;

        FILE *inFp = fopen(full.UTF8String, "rb");
        if (!inFp) { free(inBuf); free(outBuf); fclose(outFp); if (error) *error = ZipErr(@"读取源文件失败"); return NO; }

        uLong crc = crc32(0L, Z_NULL, 0);
        uint64_t compBytes = 0;

        if (method == 0) {
            size_t got;
            while ((got = fread(inBuf, 1, 131072, inFp)) > 0) {
                crc = crc32(crc, inBuf, (uInt)got);
                fwrite(inBuf, 1, got, outFp);
                compBytes += got;
            }
        } else {
            z_stream zs = {0};
            deflateInit2(&zs, Z_BEST_SPEED, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY);
            size_t got;
            int flush = Z_NO_FLUSH;
            do {
                got = fread(inBuf, 1, 131072, inFp);
                if (got > 0) crc = crc32(crc, inBuf, (uInt)got);
                flush = feof(inFp) ? Z_FINISH : Z_NO_FLUSH;
                zs.next_in = inBuf;
                zs.avail_in = (uInt)got;
                do {
                    zs.next_out = outBuf;
                    zs.avail_out = 131072;
                    deflate(&zs, flush);
                    size_t have = 131072 - zs.avail_out;
                    if (have > 0) {
                        fwrite(outBuf, 1, have, outFp);
                        compBytes += have;
                    }
                } while (zs.avail_out == 0);
            } while (flush != Z_FINISH);
            deflateEnd(&zs);
        }
        fclose(inFp);

        ent.crc32 = (uint32_t)crc;
        ent.compSize = compBytes;
        offset += compBytes;

        // Write ZIP64 Data Descriptor (24 bytes)
        uint8_t dd[24];
        Wr32(dd + 0, 0x08074b50U);
        Wr32(dd + 4, ent.crc32);
        Wr64(dd + 8, ent.compSize);
        Wr64(dd + 16, ent.uncompSize);
        fwrite(dd, 1, 24, outFp);
        offset += 24;

        [entries addObject:ent];
        if (progress && (i % 30 == 0 || i + 1 == relFiles.count)) {
            progress([NSString stringWithFormat:@"打包 IPA (%lu / %lu)...", (unsigned long)(i + 1), (unsigned long)relFiles.count],
                     (double)(i + 1) / (double)MAX(relFiles.count, 1));
        }
    }

    // Write Central Directory with ZIP64 extra records
    uint64_t cdStart = offset;
    for (AICZipEntry *ent in entries) {
        NSData *nameData = [ent.zipPath dataUsingEncoding:NSUTF8StringEncoding];
        uint8_t extra[28];
        Wr16(extra + 0, 0x0001);
        Wr16(extra + 2, 24);
        Wr64(extra + 4, ent.uncompSize);
        Wr64(extra + 12, ent.compSize);
        Wr64(extra + 20, ent.localOffset);

        uint8_t cd[46] = {0};
        Wr32(cd + 0, 0x02014b50U);
        Wr16(cd + 4, (3 << 8) | 45); // Unix + ZIP64
        Wr16(cd + 6, 45);
        Wr16(cd + 8, 0x0008 | 0x0800);
        Wr16(cd + 10, ent.method);
        Wr32(cd + 16, ent.crc32);
        Wr32(cd + 20, 0xFFFFFFFFU);
        Wr32(cd + 24, 0xFFFFFFFFU);
        Wr16(cd + 28, (uint16_t)nameData.length);
        Wr16(cd + 30, sizeof(extra));
        Wr32(cd + 38, ent.extAttr);
        Wr32(cd + 42, 0xFFFFFFFFU);

        fwrite(cd, 1, 46, outFp);
        fwrite(nameData.bytes, 1, nameData.length, outFp);
        fwrite(extra, 1, sizeof(extra), outFp);
        offset += 46 + nameData.length + sizeof(extra);
    }
    uint64_t cdSize = offset - cdStart;

    // ZIP64 EOCD Record (56 bytes)
    uint64_t z64EocdOff = offset;
    uint8_t z64[56] = {0};
    Wr32(z64 + 0, 0x06064b50U);
    Wr64(z64 + 4, 44);
    Wr16(z64 + 12, (3 << 8) | 45);
    Wr16(z64 + 14, 45);
    Wr64(z64 + 24, entries.count);
    Wr64(z64 + 32, entries.count);
    Wr64(z64 + 40, cdSize);
    Wr64(z64 + 48, cdStart);
    fwrite(z64, 1, 56, outFp);

    // ZIP64 EOCD Locator (20 bytes)
    uint8_t loc[20] = {0};
    Wr32(loc + 0, 0x07064b50U);
    Wr64(loc + 8, z64EocdOff);
    Wr32(loc + 16, 1);
    fwrite(loc, 1, 20, outFp);

    // Standard EOCD (22 bytes)
    uint8_t eocd[22] = {0};
    Wr32(eocd + 0, 0x06054b50U);
    Wr16(eocd + 8, 0xFFFF);
    Wr16(eocd + 10, 0xFFFF);
    Wr32(eocd + 12, 0xFFFFFFFFU);
    Wr32(eocd + 16, 0xFFFFFFFFU);
    fwrite(eocd, 1, 22, outFp);

    free(inBuf);
    free(outBuf);
    fclose(outFp);
    return YES;
}

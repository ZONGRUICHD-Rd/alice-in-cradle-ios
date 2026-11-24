#import "SaveManager.h"

@implementation AICSaveManager

+ (NSURL *)savesDirectoryURL {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:@"Saves/AliceInCradle"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [NSURL fileURLWithPath:dir isDirectory:YES];
}

+ (NSArray<NSString *> *)listSaveFiles {
    NSArray<NSString *> *items = [NSFileManager.defaultManager contentsOfDirectoryAtPath:[self savesDirectoryURL].path error:nil];
    NSMutableArray<NSString *> *out = [NSMutableArray new];
    for (NSString *name in items) {
        if (![name hasPrefix:@"."]) [out addObject:name];
    }
    [out sortUsingSelector:@selector(compare:)];
    return out;
}

+ (BOOL)importSaveFileAtURL:(NSURL *)fileURL error:(NSError * _Nullable * _Nullable)error {
    BOOL accessed = [fileURL startAccessingSecurityScopedResource];
    NSURL *dst = [[self savesDirectoryURL] URLByAppendingPathComponent:fileURL.lastPathComponent];
    [NSFileManager.defaultManager removeItemAtURL:dst error:nil];
    BOOL ok = [NSFileManager.defaultManager copyItemAtURL:fileURL toURL:dst error:error];
    if (accessed) [fileURL stopAccessingSecurityScopedResource];
    return ok;
}

@end

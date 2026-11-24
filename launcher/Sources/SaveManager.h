#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AICSaveManager : NSObject
+ (NSURL *)savesDirectoryURL;
+ (NSArray<NSString *> *)listSaveFiles;
+ (BOOL)importSaveFileAtURL:(NSURL *)fileURL error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END

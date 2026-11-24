#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AICScriptBackend) {
    AICScriptBackendUnknown = 0,
    AICScriptBackendMono = 1,
    AICScriptBackendIL2CPP = 2,
};

@interface AICGameInspection : NSObject
@property(nonatomic, strong) NSURL *macAppURL;
@property(nonatomic, copy) NSString *appName;
@property(nonatomic, copy) NSString *executableName;
@property(nonatomic, copy) NSString *gameVersion;
@property(nonatomic, copy) NSString *unityVersion;
@property(nonatomic) AICScriptBackend backend;
@property(nonatomic) BOOL hasARM64;
@property(nonatomic) NSUInteger managedDLLCount;
@property(nonatomic) uint64_t totalBytes;
@property(nonatomic, copy, nullable) NSString *warningMessage;
@end

// Locate a macOS .app bundle inside the selected folder (or return selectedURL if it is already a .app)
NSURL * _Nullable AICLocateMacAppBundle(NSURL *selectedURL);

// Inspect an imported AliceInCradle.app bundle (version-agnostic)
AICGameInspection * _Nullable AICInspectMacAppBundle(NSURL *macAppURL, NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END

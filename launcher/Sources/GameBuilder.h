#import <Foundation/Foundation.h>
#import "GameInspector.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AICRuntimeMode) {
    AICRuntimeModeZeroJITInterp = 0, // Mono Mode 8 (Zero-JIT interpreter) + _smmp alias
    AICRuntimeModeLiveContainerJIT = 1, // Mono Mode 0 (JIT enabled via LiveContainer / StikDebug)
    AICRuntimeModeIL2CPPNative = 2, // Native ARM64 IL2CPP (auto-selected when GameAssembly.dylib exists)
};

@interface AICBuildResult : NSObject
@property(nonatomic, strong) NSURL *outputIPAURL;
@property(nonatomic) NSUInteger convertedMachOCount;
@property(nonatomic) NSUInteger shimCount;
@property(nonatomic) uint64_t ipaSizeBytes;
@property(nonatomic, copy) NSString *summaryLog;
@end

// Convert an imported macOS AliceInCradle.app into an unsigned iOS 27 IPA ready for LiveContainer / signing.
AICBuildResult * _Nullable AICBuildGameIPA(
    AICGameInspection *inspection,
    AICRuntimeMode runtimeMode,
    NSString *outputBundleID,
    void (^ _Nullable progress)(NSString *status, double fraction),
    NSError * _Nullable * _Nullable error
);

// Locate exports directory (prefers LiveContainer shared exports if running inside LiveContainer)
NSURL *AICExportsDirectoryURL(void);

NS_ASSUME_NONNULL_END

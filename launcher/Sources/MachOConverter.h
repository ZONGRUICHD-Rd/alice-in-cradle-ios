#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_OPTIONS(NSUInteger, AICMachOOptions) {
    AICMachOOptionNone = 0,
    AICMachOOptionAddLauncherRPaths = 1 << 0,      // Add @executable_path/Frameworks & Mac/Contents/Frameworks
    AICMachOOptionAliasMonoMmapToSmmp = 1 << 1,    // Alias __LINKEDIT _mmap -> _smmp (strip MAP_JIT on data pages)
};

// Inspect whether raw file data is a Mach-O or Universal binary containing an ARM64 slice.
BOOL AICMachOIsBinary(NSData *data);
BOOL AICMachOHasARM64Slice(NSData *data);

// Convert a macOS ARM64 (or Universal) Mach-O binary into an iOS 27 ARM64 Mach-O binary:
//  - Extracts ARM64 slice if Universal/Fat
//  - Retags LC_BUILD_VERSION (or upgrades LC_VERSION_MIN_MACOSX) to PLATFORM_IOS (minos 17.0, sdk 27.0)
//  - Rewrites macOS framework dependencies to @rpath/libShim_<Name>.dylib
//  - Rewrites @executable_path/../ to @executable_path/Mac/Contents/
//  - Optionally aliases guarded __LINKEDIT _mmap records to _smmp for Mono Zero-JIT compatibility
NSData * _Nullable AICConvertMacMachOToIOS27(
    NSData *input,
    AICMachOOptions options,
    NSError * _Nullable * _Nullable error
);

NS_ASSUME_NONNULL_END

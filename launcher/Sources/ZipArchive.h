#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Native streaming ZIP extractor (supports STORED and DEFLATE via zlib)
BOOL AICExtractZipArchive(
    NSURL *zipURL,
    NSURL *destDirURL,
    void (^ _Nullable progress)(NSString *status, double fraction),
    NSError * _Nullable * _Nullable error
);

// Native streaming ZIP64 IPA writer (packs directory contents under Payload/<AppName>.app/...)
BOOL AICCreateIPAFromAppBundle(
    NSURL *appBundleURL,
    NSURL *outputIPAURL,
    void (^ _Nullable progress)(NSString *status, double fraction),
    NSError * _Nullable * _Nullable error
);

NS_ASSUME_NONNULL_END

// Foundation macOS-only compatibility shims (NSTask stub, NSUserNotification stub).
#import <Foundation/Foundation.h>

#define EXPORT __attribute__((visibility("default")))

EXPORT
@interface NSTask : NSObject
@property(copy) NSString *launchPath;
@property(copy) NSArray<NSString *> *arguments;
@property(copy) NSString *currentDirectoryPath;
@property(strong) id standardOutput;
@property(strong) id standardError;
@property(readonly) int terminationStatus;
@property(readonly, getter=isRunning) BOOL running;
- (void)launch;
- (BOOL)launchAndReturnError:(NSError **)error;
- (void)waitUntilExit;
- (void)terminate;
@end

@implementation NSTask
- (int)terminationStatus { return 1; }
- (BOOL)isRunning { return NO; }
- (void)launch {
    NSLog(@"AIC-SHIM NSTask ignored on iOS: %@ %@", self.launchPath, self.arguments);
}
- (BOOL)launchAndReturnError:(NSError **)error {
    if (error) {
        *error = [NSError errorWithDomain:@"com.alicecradle.ios.shim"
                                     code:1
                                 userInfo:@{NSLocalizedDescriptionKey: @"NSTask is unsupported on iOS"}];
    }
    return NO;
}
- (void)waitUntilExit {}
- (void)terminate {}
@end

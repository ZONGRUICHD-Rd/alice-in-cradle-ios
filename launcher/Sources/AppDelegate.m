#import <UIKit/UIKit.h>
#import "HomeController.h"

@interface AICLauncherAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation AICLauncherAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application; (void)launchOptions;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [AICHomeController new];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

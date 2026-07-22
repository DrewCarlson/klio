// Minimal iOS app host for the KLIO interpreter (headless proof).
//
// The interpreter is linked in as a static archive (libklio-ios-sim.a) and
// invoked via the exported C `klio_run`; iOS forbids spawning a separate `klio`
// executable, so the CLI runs in-process. On launch this runs a bundled Kotlin
// program and logs its output (visible via `simctl launch --console`), then
// exits. The dev-host app will instead keep running and render UI — this shell
// exists to prove the interpreter runs inside a real, installed .app.
#import <UIKit/UIKit.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

extern int klio_run(int argc, const char *const *argv);

@interface KlioAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation KlioAppDelegate
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Satisfy the app lifecycle with a bare window.
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor blackColor];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];

    // Redirect HOME-derived writes (stdlib image cache, temp) to the app sandbox.
    setenv("HOME", [NSHomeDirectory() UTF8String], 1);

    int rc;
    // UI render path: a baked base image + a Compose scene ship as resources.
    // Run the scene against the base (run-image) and render a PNG to the
    // sandbox, proving the Compose -> Skia -> pixels pipeline on device.
    NSString *base = [[NSBundle mainBundle] pathForResource:@"base" ofType:@"klio-image"];
    NSString *scene = [[NSBundle mainBundle] pathForResource:@"scene" ofType:@"kt"];
    if (base && scene) {
        NSString *outPng = [NSTemporaryDirectory() stringByAppendingPathComponent:@"render.png"];
        const char *argv[] = {"run-image", [base UTF8String], [scene UTF8String], [outPng UTF8String]};
        fflush(stdout);
        rc = klio_run(4, argv);
        fflush(stdout);
        fflush(stderr);
        NSData *png = [NSData dataWithContentsOfFile:outPng];
        BOOL ok = png.length >= 8 &&
                  memcmp(png.bytes, "\x89PNG\r\n\x1a\n", 8) == 0;
        NSLog(@"[klio-host] run-image rc=%d render %s bytes=%lu",
              rc, ok ? "PNG_OK" : "PNG_MISSING", (unsigned long)png.length);
        exit(rc);
    }

    NSString *prog = [[NSBundle mainBundle] pathForResource:@"program" ofType:@"kt"];
    const char *path = prog ? [prog UTF8String] : "program.kt";
    const char *argv[] = {"run", path};

    fflush(stdout);
    rc = klio_run(2, argv);
    fflush(stdout);
    fflush(stderr);
    NSLog(@"[klio-host] klio_run exit=%d", rc);

    // Headless run: exit so `simctl launch --console` returns for the harness.
    exit(rc);
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
                                 NSStringFromClass([KlioAppDelegate class]));
    }
}

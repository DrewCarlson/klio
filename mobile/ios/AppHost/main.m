// iOS app host for the KLIO interpreter.
//
// The interpreter is linked in as a static archive (libklio-ios-sim.a) and
// invoked via the exported C `klio_run`; iOS forbids spawning a separate `klio`
// executable, so the CLI runs in-process. Three launch paths, selected by which
// resources the bundle ships:
//   - on-screen: base.klio-image + window_scene.kt — install a Metal-backed view
//     as the render surface, run the windowed Compose scene (which registers a
//     per-frame callback and returns), then drive frames from CADisplayLink.
//   - offscreen: base.klio-image + scene.kt — render one Compose frame to a PNG
//     in the sandbox (proves the Compose -> Skia -> pixels pipeline headless).
//   - headless: program.kt — run a plain program and log its output, then exit.
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

extern int klio_run(int argc, const char *const *argv);
extern void klio_set_surface(void *layer, int w, int h, double scale);
extern void klio_render_frame(void);
extern int klio_frame_active(void);
extern void klio_dispatch_touch(int x, int y, int phase);

// A UIView whose backing layer is a CAMetalLayer: the resident Compose UI draws
// into its per-frame drawables through the statically-linked Skia Ganesh-Metal
// backend (klio_win_attach / klio_win_surface / klio_win_present). Touches on the
// view forward into the resident VM's pointer processor via klio_dispatch_touch.
@interface KlioMetalView : UIView
@end
@implementation KlioMetalView
+ (Class)layerClass { return [CAMetalLayer class]; }
- (void)forwardTouches:(NSSet<UITouch *> *)touches phase:(int)phase {
    UITouch *t = [touches anyObject];
    if (!t) return;
    CGPoint p = [t locationInView:self];  // points, the composition's coordinate space
    klio_dispatch_touch((int)p.x, (int)p.y, phase);
}
- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self forwardTouches:t phase:0]; }
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self forwardTouches:t phase:1]; }
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self forwardTouches:t phase:2]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self forwardTouches:t phase:3]; }
@end

@interface KlioAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@property (strong, nonatomic) KlioMetalView *metalView;
@property (strong, nonatomic) CADisplayLink *displayLink;
@property (assign, nonatomic) unsigned long frameCount;
@end

@implementation KlioAppDelegate

// One vsync: re-enter the resident VM to recompose and present the next frame.
// Log a heartbeat so a headless harness can confirm the loop keeps running
// (repeated re-entry into the resident VM did not crash).
- (void)onFrame:(CADisplayLink *)link {
    klio_render_frame();
    self.frameCount += 1;
    if (self.frameCount % 60 == 0) {
        NSLog(@"[klio-host] frames=%lu", self.frameCount);
    }
    // Headless touch self-test (KLIO_TOUCH_SELFTEST): the simulator has no tap
    // injection, so once the UI is running, synthesize one tap (down + up) at a
    // known point. A touch-reactive scene moves to it, proving the whole path:
    // UITouch -> klio_dispatch_touch -> resident VM -> pointer processor.
    if (self.frameCount == 120 && getenv("KLIO_TOUCH_SELFTEST")) {
        const char *xs = getenv("KLIO_TOUCH_X");
        const char *ys = getenv("KLIO_TOUCH_Y");
        int tx = xs ? atoi(xs) : 300;
        int ty = ys ? atoi(ys) : 640;
        NSLog(@"[klio-host] selftest touch x=%d y=%d", tx, ty);
        klio_dispatch_touch(tx, ty, 0);  // down
        klio_dispatch_touch(tx, ty, 2);  // up
    }
}

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor blackColor];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];

    // Redirect HOME-derived writes (stdlib image cache, temp) to the app sandbox.
    setenv("HOME", [NSHomeDirectory() UTF8String], 1);

    NSString *base = [[NSBundle mainBundle] pathForResource:@"base" ofType:@"klio-image"];

    // On-screen path: install a Metal-backed view as the surface, run the
    // windowed scene, then drive CADisplayLink if it opened a UI.
    NSString *winScene = [[NSBundle mainBundle] pathForResource:@"window_scene" ofType:@"kt"];
    if (base && winScene) {
        CGRect bounds = vc.view.bounds;
        CGFloat scale = [UIScreen mainScreen].scale;
        self.metalView = [[KlioMetalView alloc] initWithFrame:bounds];
        self.metalView.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [vc.view addSubview:self.metalView];
        CAMetalLayer *layer = (CAMetalLayer *)self.metalView.layer;
        layer.contentsScale = scale;

        klio_set_surface((__bridge void *)layer,
                         (int)bounds.size.width, (int)bounds.size.height, (double)scale);

        const char *argv[] = {"run-image", [base UTF8String], [winScene UTF8String]};
        fflush(stdout);
        int rc = klio_run(3, argv);
        fflush(stdout);
        fflush(stderr);
        if (klio_frame_active()) {
            NSLog(@"[klio-host] on-screen: run-image rc=%d, driving CADisplayLink", rc);
            self.displayLink = [CADisplayLink displayLinkWithTarget:self
                                                           selector:@selector(onFrame:)];
            [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop]
                                   forMode:NSRunLoopCommonModes];
            return YES;
        }
        NSLog(@"[klio-host] on-screen scene registered no frame callback (rc=%d)", rc);
        exit(rc);
    }

    // Offscreen path: render one Compose frame to a PNG in the sandbox.
    NSString *scene = [[NSBundle mainBundle] pathForResource:@"scene" ofType:@"kt"];
    if (base && scene) {
        NSString *outPng = [NSTemporaryDirectory() stringByAppendingPathComponent:@"render.png"];
        const char *argv[] = {"run-image", [base UTF8String], [scene UTF8String], [outPng UTF8String]};
        fflush(stdout);
        int rc = klio_run(4, argv);
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
    int rc = klio_run(2, argv);
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

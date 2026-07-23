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
extern int klio_frame_needs_render(void);
extern void klio_dispatch_touches(int count, const int *ids, const int *xs,
                                  const int *ys, const int *downs, int phase);
extern void klio_dispatch_scroll(int x, int y, int dx, int dy);
extern void klio_set_keyboard_handler(void (*show)(void), void (*hide)(void));
extern void klio_dispatch_text(const char *bytes, int len);
extern void klio_dispatch_key(int kind);

// A UIView whose backing layer is a CAMetalLayer: the resident Compose UI draws
// into its per-frame drawables through the statically-linked Skia Ganesh-Metal
// backend (klio_win_attach / klio_win_surface / klio_win_present). Touches on the
// view forward a snapshot of every active finger into the resident VM's pointer
// processor via klio_dispatch_touches, so multi-finger gestures resolve. The
// view also conforms to UIKeyInput so Compose text fields drive the soft
// keyboard: focusing one makes the view first responder (keyboard shows), and
// typed text / backspace / return route back through klio_dispatch_text/_key.
@interface KlioMetalView : UIView <UIKeyInput>
@end
@implementation KlioMetalView
+ (Class)layerClass { return [CAMetalLayer class]; }
- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)hasText { return YES; }
- (void)insertText:(NSString *)text {
    if ([text isEqualToString:@"\n"]) { klio_dispatch_key(2); return; }  // return -> ime action
    const char *utf8 = [text UTF8String];
    if (utf8) klio_dispatch_text(utf8, (int)strlen(utf8));
}
- (void)deleteBackward { klio_dispatch_key(1); }
- (void)dispatchEvent:(UIEvent *)event phase:(int)phase {
    NSArray<UITouch *> *all = [[event allTouches] allObjects];
    int ids[16], xs[16], ys[16], downs[16];
    int n = 0;
    for (UITouch *t in all) {
        if (n >= 16) break;
        CGPoint p = [t locationInView:self];  // points, the composition's space
        BOOL down = (t.phase != UITouchPhaseEnded && t.phase != UITouchPhaseCancelled);
        // UITouch object identity is stable across a finger's lifecycle; use its
        // low pointer bits as a stable per-pointer id.
        ids[n] = (int)((intptr_t)t & 0x3fffffff);
        xs[n] = (int)p.x;
        ys[n] = (int)p.y;
        downs[n] = down ? 1 : 0;
        n++;
    }
    klio_dispatch_touches(n, ids, xs, ys, downs, phase);
}
- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self dispatchEvent:e phase:0]; }
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self dispatchEvent:e phase:1]; }
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self dispatchEvent:e phase:2]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self dispatchEvent:e phase:3]; }
@end

// The resident VM calls these (via the registered keyboard handler) when a
// Compose text field gains/loses focus. Making the Metal view first responder
// shows/hides the soft keyboard.
static KlioMetalView *gMetalView = nil;
static void klio_kb_show(void) { [gMetalView becomeFirstResponder]; }
static void klio_kb_hide(void) { [gMetalView resignFirstResponder]; }

@interface KlioAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@property (strong, nonatomic) KlioMetalView *metalView;
@property (strong, nonatomic) CADisplayLink *displayLink;
@property (assign, nonatomic) unsigned long frameCount;
@property (assign, nonatomic) CGPoint lastScroll;
@end

@implementation KlioAppDelegate

// One vsync: re-enter the resident VM to recompose and present the next frame.
// Log a heartbeat so a headless harness can confirm the loop keeps running
// (repeated re-entry into the resident VM did not crash).
- (void)onFrame:(CADisplayLink *)link {
    // Skip the VM re-entry while the resident VM reports nothing pending (a
    // static scene between changes); a periodic pump every 12 frames still
    // re-enters so time-driven work not tied to the render flag keeps running.
    if (klio_frame_needs_render() || self.frameCount % 12 == 0) {
        klio_render_frame();
    }
    self.frameCount += 1;
    if (self.frameCount % 60 == 0) {
        NSLog(@"[klio-host] frames=%lu", self.frameCount);
    }
    // Headless input self-test (KLIO_TOUCH_SELFTEST): the simulator has no tap
    // injection, so synthesize input once the UI is running. A scroll slides the
    // scene's bar; two simultaneous pressed pointers draw a circle each — proving
    // the scroll + multi-touch paths end to end (event -> resident VM -> pointer
    // processor).
    if (getenv("KLIO_TOUCH_SELFTEST")) {
        if (self.frameCount == 120) {
            NSLog(@"[klio-host] selftest scroll dy=300");
            klio_dispatch_scroll(200, 400, 0, 300);
        }
        if (self.frameCount == 180) {
            int ids[2] = {101, 202};
            int xs[2] = {110, 290};
            int ys[2] = {680, 680};
            int downs[2] = {1, 1};
            NSLog(@"[klio-host] selftest touch: 2 pointers");
            klio_dispatch_touches(2, ids, xs, ys, downs, 0);
        }
        if (self.frameCount == 220) {
            // Platform keyboard show (what klio_kb_show does when a Compose text
            // field focuses). becomeFirstResponder==YES means the view is ready
            // to receive text; the soft keyboard slides up unless the simulator
            // has a hardware keyboard connected (which suppresses it).
            BOOL fr = [self.metalView becomeFirstResponder];
            NSLog(@"[klio-host] selftest keyboard: firstResponder=%d", (int)fr);
        }
    }
}

// Indirect scroll (wheel / trackpad) -> Compose Scroll events. Feed the per-step
// delta (in points) at the cursor location.
- (void)onScroll:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) self.lastScroll = CGPointZero;
    CGPoint t = [g translationInView:self.metalView];
    CGPoint loc = [g locationInView:self.metalView];
    int dx = (int)(t.x - self.lastScroll.x);
    int dy = (int)(t.y - self.lastScroll.y);
    self.lastScroll = t;
    if (dx != 0 || dy != 0) klio_dispatch_scroll((int)loc.x, (int)loc.y, dx, dy);
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
        // Indirect scroll (wheel / trackpad) as Compose Scroll events. A pan
        // recognizer with 0 touches only fires for indirect scroll, so finger
        // drags still flow through the touch handlers (direct manipulation).
        UIPanGestureRecognizer *scrollPan =
            [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onScroll:)];
        scrollPan.allowedScrollTypesMask = UIScrollTypeMaskAll;
        scrollPan.maximumNumberOfTouches = 0;
        [self.metalView addGestureRecognizer:scrollPan];
        CAMetalLayer *layer = (CAMetalLayer *)self.metalView.layer;
        layer.contentsScale = scale;

        // Let the resident VM drive the soft keyboard for Compose text fields.
        gMetalView = self.metalView;
        klio_set_keyboard_handler(klio_kb_show, klio_kb_hide);

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

# Mobile targets (iOS + Android)

Goal: run KLIO on real and emulated Android + iOS devices, extend packaging to
build mobile apps, and provide a React-Native-like develop-and-run loop. The
interpreter is already portable and its JIT already cross-compiles for aarch64
iOS/Android; the missing pieces are sandbox adaptation, mobile render surfaces,
mobile app packaging, and device orchestration.

This doc is the steering plan. It supersedes the deferred "Phase 4 mobile" note
in `MULTIPLATFORM.md` and reuses that doc's `target` source-set axis
(`common`/`desktop`/`android`/`ios`) rather than inventing a parallel one.

## Target triples

| Logical target | Zig triple | Device |
|----------------|-----------|--------|
| `ios-arm64` | `aarch64-ios` (device) | real iPhone/iPad |
| `ios-sim-arm64` | `aarch64-ios-simulator` | iOS Simulator on Apple Silicon |
| `android-arm64` | `aarch64-linux-android` | arm64 device / AVD `Pixel_3a_API_33_arm64-v8a` |
| `android-x64` | `x86_64-linux-android` | x86_64 emulator |

Toolchain confirmed present: Zig 0.16 (`ios`+`android` ABIs), iOS SDK 26.2 +
simulators + `xcrun`/`simctl`, Android SDK/NDK 28.0 (+25.1) + `adb` + emulator +
AVD, JDK `keytool`/`java`.

## Layer 1 — runtime portability (decision-independent; start here)

The interpreter core touches the OS only through a bounded set of resources.
Make it run headless on sim + emulator with deterministic output.

1. **Interpreter profile on iOS device.** `fast` defaults JIT on
   (`src/runtime/perf.zig:109-140`). On `os.tag == .ios and abi != .simulator`
   default to `safe`/`off` (no `MAP_JIT`). Simulator keeps `fast`. Android keeps
   fallback (SELinux `execmem` may deny `mprotect(PROT_EXEC)` → `ProtectFailed`
   → interpreter). No structural change; codegen stays compiled but uncalled.
2. **Target branches.** Add `.ios` / `abi == .android` arms where only
   `==.macos` / bare `.linux`/`.macos` exist: main-thread gating
   (`src/cli/commands.zig:974`), `malloc_zone_pressure_relief`
   (`src/main.zig:11`), `selfExePathZ` (`src/cli/bundle_boot.zig:132-146`,
   iOS via `_NSGetExecutablePath` — already used at `stdlib_image.zig:138`).
3. **Sandbox path redirect.** Introduce a resolved app-writable base
   (`KLIO_HOME`/`KLIO_CACHE_DIR`, defaulting to the app sandbox on device):
   - stdlib image cache `~/.klio/cache` (`src/cli/stdlib_image.zig:112-123`) —
     degrades gracefully (embedded stdlib source, slow cold start) but wire it.
   - temp dir hardcoded `/tmp` (`src/kotlinx_io/kotlinx_io.zig:339-341`).
   - zoneinfo `/usr/share/zoneinfo` (`src/kotlinx_datetime/kotlinx_datetime.zig:266`)
     — bundle a tzdata blob.
   - fonts `/usr/share/fonts` (`src/compose_ui/skia_shim.cpp`) — ship in-app (UI only).
4. **RSS watchdog.** 6 GiB default + `abort()` (`src/runtime/safety.zig`) is
   above iOS jetsam and hard-kills the app; cap low on mobile, prefer not to
   `abort()` an app process. `currentRssKb` mach path already works on iOS.
5. **stdout/stderr.** fd 1/2 vanish in an app; add an `Output` sink that routes
   program output to the system log / dev host (for the run loop below).
6. **Cross build wiring.** `build.zig` `standardTargetOptions` already cross-
   compiles; build-time tools force host (`build.zig:470-497`). Produce the
   interpreter as (a) a CLI executable for the simulator/emulator smoke path and
   (b) a static/embeddable lib for the app hosts (iOS static, Android `.so`).

**Gate:** a headless Kotlin program prints byte-identical output run via `simctl
spawn` (iOS sim) and `adb`-pushed binary (Android emulator) vs `klio run` on host.

## Layer 2 — mobile render surface (Compose UI)

Everything above the shim C ABI is reused verbatim (the Kotlin `androidx.compose`
engine, `src/compose_ui/compose_ui.zig` intrinsics, `KlioCanvas`, skparagraph,
`PointerInputEventProcessor`). Work is confined to the shim + loop inversion.

Three cross-cutting pieces (both platforms):
- **Skia archives** for mobile: extend `scripts/fetch-skia.sh` + `skiaLibInfo`
  (`build.zig:1037-1060`) + `skiaLibName` with iOS/Android tuples (JetBrains
  skia-pack ships them). Android wants the GLES/Vulkan Ganesh backend.
- **Loop inversion:** today the VM drives and blocks on `winPoll`
  (`KlioWindow.kt:124-157`). Mobile is OS-driven (iOS `CADisplayLink`, Android
  `Choreographer`): add a `klio_win_set_frame_cb` that calls into the VM to
  render one frame. The existing `klio_win_set_resize_cb` trampoline
  (`compose_ui.zig:629-633`) already proves the shim→Zig→Kotlin callback path.
- **Multi-touch:** widen the packed single-pointer `(type<<32)|(x<<16)|y` event
  (`compose_ui.zig:659-662`) to per-touch identity; extend `dispatchWindowPointer`
  to allocate distinct `PointerId`s.

**iOS (shorter lift, ~70-80% reuse):** the macOS `CAMetalLayer` + `MTLDevice` +
`GrDirectContexts::MakeMetal` + per-frame `nextDrawable` bring-up
(`skia_shim.cpp:1866-2137`) is UIKit-agnostic. New: `klio_win_attach(caMetalLayer)`
replacing `NSWindow` creation; `UITouch` phase translation; `CADisplayLink` frame
cb; ship shim as a static lib / signed framework (iOS bans dlopen of a runtime-
extracted dylib — the `shim_extract.zig` cache path is a device blocker for UI).

**Android (larger lift):** new GLES3/Vulkan Ganesh swapchain from `ANativeWindow`
(current EGL is surfaceless-offscreen only), NDK `clang++` build linking
`libGLESv3`/`libvulkan`/`libandroid`/`liblog`, `Choreographer` frame cb,
`MotionEvent` translation, `SurfaceView`/`NativeActivity` host.

## Layer 3 — mobile packaging (extend `bundle`)

The desktop bundle model (append payload to the runnable stub, self-probe via
`/proc/self/exe`, `src/cli/bundle_boot.zig`) **does not port**: a `.app`/`.apk`
is a structured tree, and on-device the interpreter is a native lib inside the
package, not the launched executable. New packaging path:

- **Package-tree emitters** (not single-file surgery):
  - iOS `.app`/`.ipa`: `Info.plist` + entitlements + `embedded.mobileprovision`
    + the interpreter binary + the baked program image as a resource + Skia
    framework + fonts/tzdata. Real `codesign` with an identity + profile
    (ad-hoc `macho_sign.zig` won't install on device; sim allows ad-hoc).
  - Android `.apk`: `AndroidManifest.xml` + `NativeActivity`/JNI host + `lib/<abi>/`
    (interpreter `.so` + Skia `.so`) + `assets/` (program image, tzdata, fonts) +
    aapt2 resource table; `apksigner` v2/v3 (`keytool` debug keystore for dev).
- **Payload delivery:** the interpreter reads the baked `.klio-image` from a
  known package-relative path (iOS bundle resources, Android `assets/`), replacing
  the self-append/tail-probe. Reuse the existing image format + `BundleManifest`
  (`src/pack/bundle_format.zig`) minus the trailer/self-exe mechanics.
- **Target vocabulary:** add ios/android to `target_names` + `hostTarget`
  (`bundle.zig:163-174`), `stub_fetch` naming, `stubs-manifest.json`, release CI.

Surface: `klio bundle <dir> --target ios-sim-arm64 -o App.app` etc. (project dir
already resolves `[application]` name/icon/main via `src/cli/project.zig`).

## Layer 4 — fast run / RN-like DX

The develop-and-run loop. Design goal: sub-second iteration after first install.

Two candidate architectures (see open decisions):
- **Dev-host model (Expo-Go-like, recommended):** a prebuilt persistent
  "KlioDev" host app installed once on sim/device. `klio mobile run <dir>` bakes
  only the program `.klio-image`, pushes it (simctl/adb/local socket), the host
  reloads and re-renders. Hot reload = re-push image + recompose. No re-sign/
  re-install per edit.
- **Rebuild model:** cross-compile + package + install a fresh signed app each
  run. Simpler, correct, slow per iteration.

Orchestration glue (simctl/xcodebuild/xcrun, adb/gradle/emulator, the reload
socket) is heavy and platform-specific. Candidate homes: a separate `klio-mobile`
binary layered on core `klio` (the user's suggested shape), vs a `klio mobile *`
subcommand family. Packaging (Layer 3) stays in core `klio`.

## Testing strategy

- Headless correctness first: the offscreen pixel gate (`bundle_ui`,
  `src/itests/bundle_ui.zig`) runs with no window — drive it under `simctl spawn`
  / `adb shell` for on-device-VM correctness without any UI work.
- Per-layer: unit tests (Zig `test{}`), an itest that cross-compiles + runs a
  headless program on the booted sim + emulator asserting deterministic output,
  then a UI pixel-hash gate once the surface lands.
- Keep the harness+sweep loop for interpreter correctness; add a mobile smoke
  itest gated on sim/emulator availability (skips cleanly when absent, like
  `bundle_ui` skips without the shim).

## Decisions (locked)

1. **Platform order: iOS first**, then Android.
2. **First milestone: headless runtime** on the sim/emulator (deterministic
   stdout, no UI) before any render surface.
3. **Runner architecture: dev-host app (Expo-Go-like).** A persistent host app
   installed once; each run pushes only the baked program image and hot-reloads.
4. **Command surface: separate `klio-mobile` binary** for device orchestration
   (simctl/adb/xcodebuild/gradle + hot-reload server); app packaging stays in
   core `klio bundle --target ios*/android*`.

## Progress

### P1 iOS-simulator headless — interpreter runs (DONE, core)

`zig build -Dtarget=aarch64-ios-simulator -Doptimize=ReleaseFast` produces a
working `klio` that runs Kotlin on the booted simulator via `simctl spawn`, with
output byte-identical to a host `klio run`. Proven with a fib/collections/map
smoke program.

Landed:
- **Apple SDK wiring without a global sysroot** (`build.zig` `resolveAppleSdk` /
  `wireAppleSdk`). Zig cannot auto-detect the iOS SDK, and a global `--sysroot`
  would poison the native host tools (`stdlib-embed-gen`). Instead the SDK
  (`xcrun`, or `-Dapple-sdk`) is attached as `-isystem <sdk>/usr/include` +
  `-L <sdk>/usr/lib` + framework path onto the target module universe, target
  zstd, and the klio executables only. Host tools stay native.
- **Mobile panic + symbolizer elision.** Mobile app targets cannot symbolize
  their own image (the iOS-sim SDK omits `__dyld_get_image_header_containing_address`
  from its tbd, and an app has nowhere to print a trace). `main.zig` installs a
  minimal `FullPanic` on mobile; `runtime/trace.zig` wraps the stack-trace dumps
  and comptime-drops `SelfInfo` on mobile; the seven dump sites, `prof.maybeReport`,
  `attachSegfaultHandler`, and the `DebugAllocator` diagnostic allocator modes are
  all gated off for mobile. Desktop behavior unchanged.
- **`is_mobile_target`** predicate = `os.tag == .ios or (linux and android abi)`.

Not yet needed for the sim smoke (sim sees the host FS + HOME), required for the
packaged app / device — deferred to the packaging phase: sandbox path redirect
(`~/.klio` cache, `/tmp`, zoneinfo, fonts), RSS-cap/abort tuning, in-app stdout
sink, `selfExePathZ` iOS branch.

Locked in by `scripts/mobile-smoke.sh` (builds + runs on the sim, asserts vs
baseline, skips cleanly without xcrun).

### P2 iOS app packaging — interpreter runs inside a real .app (DONE, headless proof)

The interpreter now runs in-process inside a genuine installed iOS app on the
simulator (`UIApplicationMain` lifecycle), not just via `simctl spawn`. A bundled
Kotlin program's output shows in the app console and matches the baseline.
Locked in by `scripts/ios-app-smoke.sh`.

Landed:
- **C-ABI entry.** `cli.run` split into `run` (native argv) + `runArgv`
  (pre-built argv); `src/mobile_lib.zig` exports `klio_run(argc, argv)` which
  synthesizes `{"klio","run",path}` and calls `runArgv` on a process-lifetime
  arena. Profile: `fast` (JIT) on the simulator, `safe` (interpreter) on device.
- **Static interpreter library.** `zig build mobile-lib -Dtarget=<mobile triple>`
  produces `libklio-<suffix>.a` (shares the target module universe → embedded
  stdlib pack, Apple SDK wiring). `bundle_compiler_rt`/`bundle_ubsan_rt` set so
  the archive carries Zig's builtins for a foreign (clang/NDK) link; the target
  `libzstd.a` is installed alongside for the app link.
- **iOS app host.** `mobile/ios/AppHost/{main.m,Info.plist}` — a minimal ObjC
  shell (`UIApplicationMain` + delegate) that redirects `HOME` to the app
  sandbox, runs the bundled program via `klio_run`, logs output, and exits.
  Assembled + ad-hoc-signed + installed + launched by `scripts/ios-app-smoke.sh`.

Next: generalize the hand-assembled `.app` into `klio bundle --target ios-sim`
(and reuse the baked `.klio-image` instead of shipping `.kt` source); then the
render surface (P3) and the dev-host + fast run loop (P4).

## Phase map (initial)

- **P1** Runtime portability + headless run on sim + emulator (Layer 1). Decision-independent. *(iOS sim: done; Android: pending.)*
- **P2** Packaging skeleton for the chosen first platform: emit a launchable
  (headless) app that runs a baked program image from package resources (Layer 3, partial).
- **P3** Render surface for the first platform (Layer 2): Compose UI on screen.
- **P4** Dev-host + fast run loop (Layer 4) + hot reload.
- **P5** Second platform parity across P2–P4.
- **P6** Signing/store polish, docs, examples, CI gates.

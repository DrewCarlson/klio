// Minimal native host for the KLIO interpreter on Android (headless).
//
// Links the interpreter static archive (libklio-android.a) built by zig and
// invokes the exported C `klio_run`. Built with the NDK toolchain (bionic libc)
// and run via `adb shell` from /data/local/tmp; the on-device app host (an APK
// with a SurfaceView) lands in a later step.
extern int klio_run(int argc, const char *const *argv);

// ARM64 bionic requires the executable's TLS segment to be 64-byte aligned, but
// zig emits its thread-locals at alignment 8. A single over-aligned thread-local
// here raises the whole PT_TLS segment's alignment so the bionic loader accepts
// the executable (otherwise it aborts at startup: "TLS segment is underaligned").
__attribute__((aligned(64))) static _Thread_local volatile char klio_tls_align[64];

int main(int argc, char **argv) {
    klio_tls_align[0] = 0;  // keep the alignment anchor from being stripped
    // Forward argv[1..] (e.g. {"run", "<path>"}); klio_run prepends its own name.
    return klio_run(argc - 1, (const char *const *)(argv + 1));
}

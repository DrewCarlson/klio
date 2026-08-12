/* klio_rt — the C ABI of the klio Kotlin runtime (stage 1: bootstrap).
 * Link against libklio_rt.a (zig build klio-rt). */
#ifndef KLIO_RT_H
#define KLIO_RT_H

#ifdef __cplusplus
extern "C" {
#endif

/* Runs the Kotlin program at `path` exactly as `klio run <path>` would.
 * Returns the process exit code (0 success, nonzero on diagnostics or a
 * runtime error). */
int klio_rt_run_file(const char *path);

/* The library's ABI version (this header describes version 1). */
int klio_rt_abi_version(void);

#ifdef __cplusplus
}
#endif

#endif /* KLIO_RT_H */

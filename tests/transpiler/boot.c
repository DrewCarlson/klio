/* Stage-1 proof: a plain C host drives the klio runtime end to end
 * through the C ABI (plans/c-transpiler-plan.md). */
#include <stdio.h>
#include <klio_rt.h>

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <program.kt>\n", argv[0]);
        return 2;
    }
    printf("[boot.c] klio_rt abi v%d\n", klio_rt_abi_version());
    int rc = klio_rt_run_file(argv[1]);
    printf("[boot.c] program exit %d\n", rc);
    return rc;
}

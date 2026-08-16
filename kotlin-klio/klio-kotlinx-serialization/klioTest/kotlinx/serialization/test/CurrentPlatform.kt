/*
 * klio-authored platform actual for kotlinx.serialization's commonTest
 * support surface. Upstream declares `expect val currentPlatform` in
 * core/commonTest and supplies an actual per target; without one the whole
 * helper file yields nothing, so `isNative`/`isJvm`/`isJs`/`isWasm` — which
 * the tests branch on — resolve to nothing and every test using them fails
 * on the support surface rather than on serialization behavior.
 *
 * klio reports NATIVE, mirroring upstream's nativeTest actual: the tests
 * gate reflection-based serializer lookup behind `isJvm()`, and klio has no
 * such reflection, so the native classification is the one whose skips match
 * what klio can actually do.
 */

package kotlinx.serialization.test

public actual val currentPlatform: Platform = Platform.NATIVE

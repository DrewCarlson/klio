/*
 * KLIO actual for `kotlin.random.Random.Default`. KLIO has no host RNG to
 * delegate to, so the default platform random is a seeded `XorWowRandom`
 * (the same generator `Random(seed)` builds). The seed is fixed: KLIO's
 * `Random.Default` is a real PRNG with good distribution, just reproducible
 * across runs.
 */
package kotlin.random

internal actual fun defaultPlatformRandom(): Random = Random(0x5DEECE66DL)

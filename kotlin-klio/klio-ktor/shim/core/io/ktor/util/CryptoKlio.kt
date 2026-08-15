/*
 * klio actuals for the pure-Kotlin ktor-utils crypto surface. The upstream
 * posix actuals reach cinterop (`secureRandom` over getrandom/urandom); klio
 * backs the nonce generator with the stdlib PRNG and reuses the common
 * `Sha1` implementation for `sha1`.
 */

package io.ktor.util

import kotlin.random.Random

public actual suspend fun generateNonceSuspend(length: Int): String = generateNonceBlocking(length)

public actual fun generateNonceBlocking(length: Int): String {
    val digits = "0123456789abcdef"
    return buildString(length) {
        repeat(length) { append(digits[Random.nextInt(16)]) }
    }
}

public actual fun sha1(bytes: ByteArray): ByteArray = Sha1().digest(bytes)

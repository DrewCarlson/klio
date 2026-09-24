/*
 * klio actuals for the pure-Kotlin ktor-utils crypto surface. The upstream
 * posix actuals reach cinterop (`secureRandom` over getrandom/urandom); klio
 * backs the nonce generator with the stdlib PRNG and reuses the common
 * `Sha1` implementation for `sha1`. `Digest` answers as the JVM's does, over
 * `MessageDigest`: the host computes the algorithms the JVM provides, and
 * any other name is a `NoSuchAlgorithmException`.
 */

package io.ktor.util

import java.security.NoSuchAlgorithmException
import kotlin.random.Random

public actual suspend fun generateNonceSuspend(length: Int): String = generateNonceBlocking(length)

public actual fun generateNonceBlocking(length: Int): String {
    val digits = "0123456789abcdef"
    return buildString(length) {
        repeat(length) { append(digits[Random.nextInt(16)]) }
    }
}

public actual fun sha1(bytes: ByteArray): ByteArray = Sha1().digest(bytes)

public actual fun Digest(name: String): Digest {
    __kktor_digest(name, ByteArray(0), 0) ?: throw NoSuchAlgorithmException("$name MessageDigest not available")
    return KlioDigest(name)
}

/** The JVM's `MessageDigest.digest()`: the digest of what was added, then a reset. */
private class KlioDigest(private val name: String) : Digest {
    private var bytes = ByteArray(64)
    private var size = 0

    override fun plusAssign(bytes: ByteArray) {
        if (size + bytes.size > this.bytes.size) {
            this.bytes = this.bytes.copyOf(maxOf(this.bytes.size * 2, size + bytes.size))
        }
        bytes.copyInto(this.bytes, size)
        size += bytes.size
    }

    override fun reset() {
        size = 0
    }

    override suspend fun build(): ByteArray {
        val out = __kktor_digest(name, bytes, size)!!
        size = 0
        return out
    }
}

/**
 * The digest of `bytes[0, length)` under the JVM `MessageDigest` algorithm
 * `name`, or null where the JVM provides none. The host binding
 * `io.ktor.util.__kktor_digest` (src/ktor_client/ktor_client.zig) shadows
 * this body.
 */
internal fun __kktor_digest(name: String, bytes: ByteArray, length: Int): ByteArray? =
    error("intrinsic io.ktor.util.__kktor_digest not installed")

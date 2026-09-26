/*
 * The JVM's `java.security.MessageDigest` surface ktor's JVM-only digest
 * authentication uses (`getInstance`, `update`, `digest`, `reset`,
 * `algorithm`, `isEqual`), over the host digests behind `io.ktor.util.Digest`:
 * every algorithm the JVM's SUN provider offers, under the same names.
 */
package klio.security

import io.ktor.util.__kktor_digest

public class MessageDigest private constructor(public val algorithm: String) {
    private var bytes = ByteArray(64)
    private var size = 0

    public fun update(input: Byte) {
        ensure(1)
        bytes[size++] = input
    }

    public fun update(input: ByteArray) {
        update(input, 0, input.size)
    }

    public fun update(input: ByteArray, offset: Int, length: Int) {
        require(offset >= 0 && length >= 0 && offset + length <= input.size) { "Bad offset or length" }
        ensure(length)
        input.copyInto(bytes, size, offset, offset + length)
        size += length
    }

    /** The digest of everything added since the last reset; the digest then resets. */
    public fun digest(): ByteArray {
        val out = __kktor_digest(algorithm, bytes, size)!!
        size = 0
        return out
    }

    /** Adds [input], then digests. */
    public fun digest(input: ByteArray): ByteArray {
        update(input)
        return digest()
    }

    public fun reset() {
        size = 0
    }

    public fun getDigestLength(): Int = __kktor_digest(algorithm, ByteArray(0), 0)!!.size

    override fun toString(): String = "$algorithm Message Digest from klio"

    private fun ensure(extra: Int) {
        if (size + extra > bytes.size) bytes = bytes.copyOf(maxOf(bytes.size * 2, size + extra))
    }

    public companion object {
        /** The digest for [algorithm], or a [NoSuchAlgorithmException] as on the JVM. */
        public fun getInstance(algorithm: String): MessageDigest {
            __kktor_digest(algorithm, ByteArray(0), 0)
                ?: throw NoSuchAlgorithmException("$algorithm MessageDigest not available")
            return MessageDigest(algorithm)
        }

        /** Whether two digests are equal, in time that depends only on their lengths. */
        public fun isEqual(digestA: ByteArray?, digestB: ByteArray?): Boolean {
            if (digestA === digestB) return true
            if (digestA == null || digestB == null) return false
            var diff = digestA.size xor digestB.size
            for (i in digestA.indices) {
                diff = diff or (digestA[i].toInt() xor (if (i < digestB.size) digestB[i].toInt() else 0))
            }
            return diff == 0
        }
    }
}

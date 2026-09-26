// The JVM oracle for src/ktor_client/zdeflate.zig: compresses the inputs
// `corpusInputs` builds with java.util.zip.Deflater(level, nowrap = true)
// the way ktor's encoders drive it, and prints one Zig table row per case
// (the compressed length and its SHA-256). zdeflate.zig's test rebuilds the
// same inputs and compares.
//
//   kotlinc deflate_oracle.kt -include-runtime -d oracle.jar
//   java -jar oracle.jar > deflate_oracle.zig.txt
//
// The rows are pasted into `jvm_cases` in zdeflate.zig.

import java.security.MessageDigest
import java.util.zip.Deflater

/// The LCG both sides use: seed' = seed * 1103515245 + 12345 (mod 2^32).
class Lcg(var seed: Int) {
    fun next(): Int {
        seed = seed * 1103515245 + 12345
        return (seed ushr 16) and 0x7fff
    }
}

val words = listOf(
    "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "ktor",
    "klio", "deflate", "window", "match", "length", "distance", "huffman",
    "tree", "block", "stored", "static", "dynamic", "literal", "symbol", "a",
    "of", "and", "to", "in", "is", "that", "for", "it", "as", "with", "on",
)

fun text(size: Int, seed: Int): ByteArray {
    val r = Lcg(seed)
    val sb = StringBuilder()
    while (sb.length < size) {
        sb.append(words[r.next() % words.size])
        sb.append(if (r.next() % 13 == 0) '\n' else ' ')
    }
    return sb.substring(0, size).encodeToByteArray()
}

fun binary(size: Int, seed: Int): ByteArray {
    val r = Lcg(seed)
    return ByteArray(size) { (r.next() and 0xff).toByte() }
}

/// Runs of one byte and repeats of short patterns at every distance class.
fun runs(size: Int, seed: Int): ByteArray {
    val r = Lcg(seed)
    val out = ByteArray(size)
    var i = 0
    while (i < size) {
        val kind = r.next() % 3
        val len = 1 + r.next() % 600
        val period = 1 + r.next() % 40
        val base = r.next()
        for (k in 0 until len) {
            if (i >= size) break
            out[i] = when (kind) {
                0 -> base.toByte()
                1 -> ((base + k % period) and 0xff).toByte()
                else -> (r.next() and 0xff).toByte()
            }
            i++
        }
    }
    return out
}

fun counting(size: Int): ByteArray = ByteArray(size) { it.toByte() }

fun corpusInputs(): List<Pair<String, ByteArray>> = listOf(
    "empty" to ByteArray(0),
    "one" to byteArrayOf(42),
    "three" to "abc".encodeToByteArray(),
    "counting500" to counting(500),
    "counting70k" to counting(70_000),
    "text120k" to text(120_000, 1),
    "binary70k" to binary(70_000, 2),
    "runs100k" to runs(100_000, 3),
)

/// One ktor-style run: each chunk is set as input and deflated with NO_FLUSH
/// until the deflater needs input, then flushed with `mode` (NO_FLUSH, or
/// SYNC_FLUSH/FULL_FLUSH until a call writes nothing), and at the end the
/// stream is finished the same way.
fun compress(level: Int, data: ByteArray, chunk: Int, outSize: Int, mode: Int): ByteArray {
    val d = Deflater(level, true)
    val buf = ByteArray(outSize)
    val out = java.io.ByteArrayOutputStream()
    var i = 0
    while (i < data.size) {
        val n = minOf(chunk, data.size - i)
        d.setInput(data, i, n)
        i += n
        while (!d.needsInput()) out.write(buf, 0, d.deflate(buf, 0, buf.size, Deflater.NO_FLUSH))
        if (mode != Deflater.NO_FLUSH) {
            while (true) {
                val w = d.deflate(buf, 0, buf.size, mode)
                out.write(buf, 0, w)
                if (w == 0) break
            }
        }
    }
    d.finish()
    while (!d.finished()) out.write(buf, 0, d.deflate(buf, 0, buf.size, Deflater.NO_FLUSH))
    d.end()
    return out.toByteArray()
}

fun main() {
    val sha = MessageDigest.getInstance("SHA-256")
    fun hex(b: ByteArray) = b.joinToString("") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }
    for ((name, data) in corpusInputs()) {
        for (level in -1..9) {
            val variants = mutableListOf(
                Triple(1 shl 30, 4096, Deflater.NO_FLUSH),
                Triple(4096, 4096, Deflater.NO_FLUSH),
                Triple(4096, 4096, Deflater.SYNC_FLUSH),
                Triple(16384, 4096, Deflater.FULL_FLUSH),
            )
            if (data.size <= 70_000 && (level == 0 || level == 6)) {
                variants += Triple(1000, 1, Deflater.NO_FLUSH)
                variants += Triple(1 shl 30, 100_000, Deflater.NO_FLUSH)
                variants += Triple(777, 300, Deflater.SYNC_FLUSH)
            }
            for ((chunk, outSize, mode) in variants) {
                val c = compress(level, data, chunk, outSize, mode)
                println("    .{ .input = \"$name\", .level = $level, .chunk = $chunk, .out = $outSize, .mode = $mode, .len = ${c.size}, .sha = \"${hex(sha.digest(c))}\" },")
            }
        }
    }
}

// Run with: klio run --feature io.ktor/utils examples/ktor_digest.kt
// ktor's `Digest(name)` is the JVM's `MessageDigest` for that name: every
// algorithm the JVM provides, under its standard name, an alias or an OID,
// ignoring case. `build()` returns the digest of what was added and starts
// over, and a name the JVM does not know throws `NoSuchAlgorithmException`.
import io.ktor.util.Digest
import java.security.NoSuchAlgorithmException
import kotlinx.coroutines.runBlocking

fun hex(bytes: ByteArray): String = bytes.joinToString("") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }

fun main(): Unit = runBlocking {
    val d = Digest("SHA-256")
    d += "a".encodeToByteArray()
    println(hex(d.build()))
    println(hex(d.build()))
    d += "a".encodeToByteArray()
    d.reset()
    d += "b".encodeToByteArray()
    println(hex(d.build()))

    for (name in listOf("MD5", "sha1", "SHA-512/256", "SHA3-256", "md2", "OID.2.16.840.1.101.3.4.2.2")) {
        val x = Digest(name)
        x += "abc".encodeToByteArray()
        println("$name ${hex(x.build())}")
    }

    val chunked = Digest("SHA-1")
    repeat(100) { chunked += "0123456789".encodeToByteArray() }
    println(hex(chunked.build()))

    try {
        Digest("SHA-2")
    } catch (e: NoSuchAlgorithmException) {
        println(e)
    }
}

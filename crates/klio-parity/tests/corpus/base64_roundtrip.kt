import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

@OptIn(ExperimentalEncodingApi::class)
fun main() {
    // A multi-group input drives the encode loop (which caps groups with
    // `minOf`) across several full 3-byte groups plus a 1- and 2-byte tail.
    for (s in listOf("", "a", "ab", "abc", "abcd", "abcde", "the quick brown fox")) {
        val e = Base64.encode(s.encodeToByteArray())
        val back = Base64.decode(e).decodeToString()
        println("$s -> $e -> ${back == s}")
    }

    val bytes = ByteArray(12) { (it * 17 - 100).toByte() }
    val enc = Base64.encode(bytes)
    println(enc)
    println(Base64.decode(enc).joinToString(",") { it.toString() })
    println(bytes.joinToString(",") { it.toString() })
    println(Base64.UrlSafe.encode(bytes))
}

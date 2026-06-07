import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

// Base64 encoding/decoding through the stdlib `kotlin.io.encoding.Base64`,
// whose encode/decode algorithms live in commonMain and bottom out in
// klio's platform actuals. Exercises the default, URL-safe, and padding
// variants plus a full round-trip.
@OptIn(ExperimentalEncodingApi::class)
fun main() {
    val message = "Kotlin on klio!"
    val bytes = message.encodeToByteArray()

    val encoded = Base64.encode(bytes)
    println(encoded)
    println(Base64.decode(encoded).decodeToString())
    println(Base64.decode(encoded).decodeToString() == message)

    // URL-safe alphabet uses '-' and '_' instead of '+' and '/'.
    val raw = byteArrayOf(-5, -1, 0, 62, 63)
    println(Base64.encode(raw))
    println(Base64.UrlSafe.encode(raw))

    // Padding option: ABSENT drops the trailing '=' characters.
    val odd = byteArrayOf(1, 2)
    println(Base64.encode(odd))
    println(Base64.withPadding(Base64.PaddingOption.ABSENT).encode(odd))

    // A basic-auth credential header, the common real-world use.
    val credential = "aladdin:opensesame"
    println("Basic " + Base64.encode(credential.encodeToByteArray()))
}

// Run with: klio run --feature kotlinx.serialization/json examples/reified_serializer_from_infix_sibling.kt
// A zero-argument reified `serializer()` beside a generic call whose type
// arguments come from an infix argument solves `T` WITH those arguments:
// `mapOf(1 to 2)` is a `Map<Int, Int>` because `1 to 2` is a `Pair<Int, Int>`,
// so the sibling hands `serializer<Map<Int, Int>>()` its map serializer
// instead of a raw `Map` classifier.
import kotlinx.serialization.*
import kotlinx.serialization.json.*

fun <T> encode(s: KSerializer<T>, v: T): String = Json.encodeToString(s, v)

fun main() {
    println(encode(serializer(), mapOf(1 to 2)))
    println(encode(serializer(), mapOf("a" to listOf(1, 2))))
    println(encode(serializer(), listOf(1 to "x")))
    println(encode(serializer(), 3 to 4.5))
}

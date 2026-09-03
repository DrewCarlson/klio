// Run with: klio run --feature kotlinx.serialization/json examples/reified_serializer_from_sibling.kt
// A zero-argument reified call (`serializer()`) whose type argument is
// inferred from a SIBLING argument: the helper's `data: T` slot binds `T` from
// the constructor call beside it, and `serializer: KSerializer<T>` takes that
// `T` — through a top-level generic helper, an inherited member helper, and an
// inline reified helper.
import kotlinx.serialization.*
import kotlinx.serialization.json.*

@Serializable
data class Box(val i: Int)

@Serializable
data class Holder(val a: Box?, val name: String = "h")

fun <T> roundTrip(serializer: KSerializer<T>, data: T): String {
    val text = Json.encodeToString(serializer, data)
    val back = Json.decodeFromString(serializer, text)
    return "$text -> $back"
}

open class Checks {
    fun <T> check(serializer: KSerializer<T>, data: T, expected: String) {
        val s = Json.encodeToString(serializer, data)
        println("member: $s ${if (s == expected) "OK" else "MISMATCH"}")
    }
}

class Suite : Checks() {
    fun run() = check(serializer(), Holder(Box(7)), """{"a":{"i":7}}""")
}

inline fun <reified T> checkInline(serializer: KSerializer<T>, data: T, expected: String) {
    val s = Json.encodeToString(serializer, data)
    println("inline: $s ${if (s == expected) "OK" else "MISMATCH"}")
}

fun main() {
    println("top: " + roundTrip(serializer(), Holder(Box(42))))
    println("top: " + roundTrip(serializer(), Box(1)))
    Suite().run()
    checkInline(serializer(), Holder(null, "n"), """{"a":null,"name":"n"}""")
}

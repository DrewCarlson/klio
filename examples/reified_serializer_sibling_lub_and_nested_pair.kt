// Run with: klio run --feature kotlinx.serialization/json examples/reified_serializer_sibling_lub_and_nested_pair.kt
// A zero-argument reified `serializer()` beside a sibling whose type needs
// inference across elements: `listOf(A(1), B, C("x"))` over a sealed interface
// is a `List<I>` (the least upper bound), and `Pair(42, Pair("a", "b"))`
// instantiates the nested constructor as `Pair<Int, Pair<String, String>>`.
import kotlinx.serialization.*
import kotlinx.serialization.json.*

@Serializable sealed interface Msg
@Serializable sealed class Reply : Msg {
    @Serializable @SerialName("Num") data class Num(val i: Int) : Reply()
    @Serializable @SerialName("Text") data class Text(val s: String) : Reply()
}
@Serializable @SerialName("Silence") object Silence : Msg

fun <T> encode(s: KSerializer<T>, v: T): String = Json.encodeToString(s, v)

fun main() {
    val messages = listOf(Reply.Num(10), Silence, Reply.Text("foo"))
    println(encode(serializer(), messages))
    println(encode(serializer(), Pair(42, Pair("a", "b"))))
    println(encode(serializer(), listOf(Reply.Num(1), Reply.Text("t"))))
}

// Run with: klio run --feature kotlinx.serialization/json examples/reified_serializer_inherited_helper_default_param.kt
// A zero-argument reified `serializer()` handed to an INHERITED generic
// helper with a defaulted trailing parameter, called bare from a subclass
// lambda (`parametrizedTest { assertJsonFormAndRestored(serializer(), data,
// expected) }`): the helper's receiver slot and its default do not count
// against the written arguments, so `T` still solves from `data`.
import kotlinx.serialization.*
import kotlinx.serialization.json.*

abstract class JsonTestBase {
    protected val default = Json { encodeDefaults = true }
    fun parametrizedTest(test: (Boolean) -> Unit) { test(true); test(false) }
    fun <T> assertJsonFormAndRestored(serializer: KSerializer<T>, data: T, expectedString: String, json: Json = default) {
        val s = json.encodeToString(serializer, data)
        println("$s ${if (s == expectedString) "matches" else "differs from"} $expectedString")
        println(json.decodeFromString(serializer, s) == data)
    }
}

@Serializable sealed interface Msg
@Serializable sealed class Reply : Msg {
    @Serializable @SerialName("Num") data class Num(val i: Int) : Reply()
}
@Serializable @SerialName("Silence") object Silence : Msg

class Tests : JsonTestBase() {
    fun testIntegerKeyInTopLevelMap() = parametrizedTest {
        assertJsonFormAndRestored(serializer(), mapOf(1 to 2), """{"1":2}""")
    }
    fun testSealedInterface() {
        val messages = listOf(Reply.Num(10), Silence)
        assertJsonFormAndRestored(serializer(), messages, """[{"type":"Num","i":10},{"type":"Silence"}]""")
    }
    fun testPair() = parametrizedTest { _ ->
        assertJsonFormAndRestored(serializer(), Pair(42, Pair("a", "b")), """{"first":42,"second":{"first":"a","second":"b"}}""")
    }
}

fun main() { val t = Tests(); t.testIntegerKeyInTopLevelMap(); t.testSealedInterface(); t.testPair() }

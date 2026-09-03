// Run with: klio run --feature kotlinx.serialization/json examples/explicit_type_arg_local_reified.kt
// A local initialized by a reified call with an EXPLICIT type argument
// (`val decoded = json.decodeFromString<List<Level>>(input, mode)`, a member
// extension returning bare `T`) is typed `List<Level>`, type arguments
// included, so a later reified `encodeToString(decoded, mode)` re-solves the
// list's element serializer instead of a raw polymorphic `List`.
import kotlinx.serialization.*
import kotlinx.serialization.json.*

abstract class JsonTestBase {
    inline fun <reified T> Json.decodeFromString(source: String, mode: Boolean): T =
        decodeFromString(serializersModule.serializer(), source)
    inline fun <reified T> Json.encodeToString(value: T, mode: Boolean): String =
        encodeToString(serializersModule.serializer(), value)
    fun modes(test: (Boolean) -> Unit) { test(true); test(false) }
}

class RoundTrip : JsonTestBase() {
    @Serializable
    enum class Level { ALL_CAPS, @SerialName("SERIAL_NAME") hasSerialName }
    val json = Json { decodeEnumsCaseInsensitive = true }

    fun run() = modes { mode ->
        val decoded = json.decodeFromString<List<Level>>("""["all_caps","serial_name"]""", mode)
        println(decoded == listOf(Level.ALL_CAPS, Level.hasSerialName))
        println(json.encodeToString(decoded, mode))
        val nested = json.decodeFromString<Map<String, List<Level>>>("""{"k":["ALL_CAPS"]}""", mode)
        println(json.encodeToString(nested, mode))
    }
}

fun main() { RoundTrip().run() }

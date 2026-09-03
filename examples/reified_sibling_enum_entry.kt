// Run with: klio run --feature kotlinx.serialization/json examples/reified_sibling_enum_entry.kt
// An enum ENTRY (`Level.LOW`, `Level.hasSerialName`) is a value of its enum,
// nested enums included, so a reified call beside it solves `T` as that enum:
// `assertEquals(Level.LOW, json.decodeFromString("\"MINIMAL\"", mode))` decodes
// the string as `Level` through the test base's reified helper.
import kotlinx.serialization.*
import kotlinx.serialization.json.*
import kotlin.test.assertEquals

abstract class JsonTestBase {
    inline fun <reified T> Json.decodeFromString(source: String, mode: Boolean): T =
        decodeFromString(serializersModule.serializer(), source)
    fun coercingModes(test: (Json, Boolean, String) -> Unit) {
        val json = Json { decodeEnumsCaseInsensitive = true }
        test(json, true, "streaming"); test(json, false, "tree")
    }
}

class EnumNamesTest : JsonTestBase() {
    @Serializable
    enum class Level { @JsonNames("minimal", "floor") LOW, @SerialName("HIGH_LEVEL") hasSerialName }

    fun run() {
        coercingModes { json, mode, msg ->
            assertEquals(Level.LOW, json.decodeFromString("\"MINIMAL\"", mode), msg)
            assertEquals(Level.hasSerialName, json.decodeFromString("\"high_level\"", mode), msg)
            println("$msg: ok")
        }
    }
}

fun main() { EnumNamesTest().run() }

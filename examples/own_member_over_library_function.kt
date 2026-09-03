// Run with: klio run --feature kotlinx.serialization/json examples/own_member_over_library_function.kt
// A class member named like a library top-level function (`Json`) wins the
// bare call inside the class when it is applicable, per Kotlin scope order:
// the member's receiver-lambda parameter gives the trailing lambda its
// receiver (`PolymorphicModuleBuilder`), while the one-argument `Json { … }`
// inside the member still reaches the library builder.
import kotlinx.serialization.*
import kotlinx.serialization.json.*
import kotlinx.serialization.modules.*

@Serializable
data class Note(val text: String)

class Registrar {
    fun run() {
        println(Json(false) { subclass(Note.serializer()) })
        println(Json(true) { subclass(Note.serializer()) })
        try {
            Json(false) { subclass(Int::class) }
            println("primitive accepted")
        } catch (e: IllegalArgumentException) {
            println("primitive rejected without array polymorphism")
        }
    }

    private fun Json(arrays: Boolean, builder: PolymorphicModuleBuilder<Any>.() -> Unit): String {
        val json = Json {
            useArrayPolymorphism = arrays
            serializersModule = SerializersModule { polymorphic(Any::class) { builder() } }
        }
        return json.encodeToString(PolymorphicSerializer(Any::class), Note("hi"))
    }
}

fun main() { Registrar().run() }

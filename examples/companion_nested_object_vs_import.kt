// Run with: klio run --feature kotlinx.serialization/json examples/companion_nested_object_vs_import.kt
// A classifier nested in a companion object is addressed through the class
// (`A.Serializer`) or the companion (`A.Companion.Serializer`) and resolves to
// the user's declaration even when a star import brings a same-named class
// into scope (`kotlinx.serialization.Serializer`, an annotation class): the
// qualifier's own nested declarations outrank an imported simple name.
import kotlinx.serialization.*
import kotlinx.serialization.json.*

interface A {
    companion object {
        object Serializer { fun hi() = "hi-from-object" }
        val marker = "companion-val"
    }
}

@Serializable(with = AnyValue.Companion.Serializer::class)
sealed interface AnyValue {
    @JvmInline @Serializable
    value class Single(val value: String) : AnyValue

    companion object {
        object Serializer : JsonContentPolymorphicSerializer<AnyValue>(AnyValue::class) {
            override fun selectDeserializer(element: JsonElement): DeserializationStrategy<AnyValue> = Single.serializer()
        }
    }
}

fun main() {
    println(A.Companion.Serializer.hi())
    println(A.Serializer.hi())
    println(A.Companion.marker)
    val v: AnyValue = AnyValue.Single("foo")
    val text = Json.encodeToString(AnyValue.serializer(), v)
    println(text)
    println(Json.decodeFromString(AnyValue.serializer(), text) == v)
}

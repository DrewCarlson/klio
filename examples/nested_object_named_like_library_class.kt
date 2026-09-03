// Run with: klio run --feature kotlinx.serialization/json examples/nested_object_named_like_library_class.kt
// A nested serializer object named like a library class
// (`ContextualSerializer` beside kotlinx's own `ContextualSerializer`) is the
// declaration in scope: the reified `contextual(serializer)` reads `T` from
// ITS `KSerializer<Payload>` supertype, not from the library class.
import kotlinx.serialization.*
import kotlinx.serialization.descriptors.*
import kotlinx.serialization.encoding.*
import kotlinx.serialization.json.*
import kotlinx.serialization.modules.*

class Registry {
    data class Payload(val text: String)

    object ContextualSerializer : KSerializer<Payload> {
        override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("Payload", PrimitiveKind.STRING)
        override fun serialize(encoder: Encoder, value: Payload) = encoder.encodeString(value.text)
        override fun deserialize(decoder: Decoder): Payload = Payload(decoder.decodeString())
    }

    @Serializable
    data class Holder(@Contextual val nullable: Payload?, @Contextual val nonNullable: Payload)

    fun run() {
        val json = Json { serializersModule = SerializersModule { contextual(ContextualSerializer) } }
        println(json.encodeToString(Holder.serializer(), Holder(null, Payload("foo"))))
        val s = json.encodeToString(Holder.serializer(), Holder(Payload("foo"), Payload("bar")))
        println(s)
        println(json.decodeFromString(Holder.serializer(), s))
    }
}

fun main() { Registry().run() }

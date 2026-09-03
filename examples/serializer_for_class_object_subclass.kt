// Run with: klio run --feature kotlinx.serialization/json examples/serializer_for_class_object_subclass.kt
// A bodiless `@Serializer(forClass = X::class)` object IS a `KSerializer<X>`:
// handed to the reified `subclass(serializer)` it solves `T = X` from that
// supertype, and the object registers `X` for polymorphic encoding.
import kotlinx.serialization.*
import kotlinx.serialization.builtins.*
import kotlinx.serialization.json.*
import kotlinx.serialization.modules.*

@Serializable
@SerialName("Payload")
data class Payload(val s: String)

@Serializer(forClass = Payload::class)
object PayloadSerializer

fun main() {
    val module = SerializersModule { polymorphic(Any::class) { subclass(PayloadSerializer) } }
    val json = Json {
        useArrayPolymorphism = true
        serializersModule = serializersModuleOf(Payload::class, PayloadSerializer) + module
    }
    val map = mapOf<String, Any>("Payload" to Payload("data"))
    val serializer = MapSerializer(String.serializer(), PolymorphicSerializer(Any::class))
    println(json.encodeToString(serializer, map))
    println(PayloadSerializer.descriptor.serialName)
    println(json.decodeFromString(PayloadSerializer, """{"s":"back"}"""))
}

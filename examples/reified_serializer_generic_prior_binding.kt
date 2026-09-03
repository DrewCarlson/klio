// Run with: klio run --feature kotlinx.serialization/json examples/reified_serializer_generic_prior_binding.kt
// A reified `T` already solved WITH type arguments from a `value: T` slot
// (`Box<Data>`) keeps them when a later `serializer: KSerializer<T>` slot is
// spelled as `Box.serializer(...)`: the receiver spelling only qualifies the
// class, so `Json.encodeToString(value)` still finds the serializer of
// `Box<Data>`, not of a raw `Box`.
import kotlinx.serialization.*
import kotlinx.serialization.descriptors.*
import kotlinx.serialization.encoding.*
import kotlinx.serialization.json.*

@Serializable(with = DataSerializer::class)
data class Data(val i: Int)

object DataSerializer : KSerializer<Data> {
    override val descriptor = PrimitiveSerialDescriptor("DataSerializer", PrimitiveKind.INT)
    override fun deserialize(decoder: Decoder): Data = Data(decoder.decodeInt())
    override fun serialize(encoder: Encoder, value: Data) { encoder.encodeInt(value.i) }
}

@Serializable(with = BoxSerializer::class)
data class Box<T>(val t: T)

class BoxSerializer(val inner: KSerializer<Any>) : KSerializer<Box<Any>> {
    override val descriptor = PrimitiveSerialDescriptor("BoxSerializer", PrimitiveKind.INT)
    override fun deserialize(decoder: Decoder): Box<Any> = Box(inner.deserialize(decoder))
    override fun serialize(encoder: Encoder, value: Box<Any>) { inner.serialize(encoder, value.t) }
}

inline fun <reified T : Any> roundTrip(value: T, expected: String, serializer: KSerializer<T>) {
    val implicit = Json.encodeToString(value)
    val explicit = Json.encodeToString(serializer, value)
    println("${T::class.simpleName}: implicit=$implicit explicit=$explicit match=${implicit == expected}")
    println("decoded=${Json.decodeFromString<T>(implicit)}")
}

fun main() {
    roundTrip(Box<Data>(Data(6)), "6", Box.serializer(Data.serializer()))
    roundTrip(Data(7), "7", Data.serializer())
}

// Run with: klio run --feature kotlinx.serialization/json examples/serializable_local_with_and_polymorphic_param.kt
// Two generated-serializer shapes: a LOCAL `@Serializable(with = X::class)`
// class (its companion's `serializer()` names the custom serializer directly —
// a local class has no top-level factory to reach), and a `@Polymorphic`
// element whose type is a TYPE PARAMETER (`V`), which serializes over the
// parameter's bound (`Any`) — the base the caller's module registers under.
import kotlinx.serialization.*
import kotlinx.serialization.descriptors.*
import kotlinx.serialization.encoding.*
import kotlinx.serialization.json.*
import kotlinx.serialization.modules.*

object NullSerializer : KSerializer<Any?> {
    override val descriptor: SerialDescriptor = buildSerialDescriptor("tmp", PrimitiveKind.INT)
    override fun serialize(encoder: Encoder, value: Any?) { encoder.encodeNull() }
    override fun deserialize(decoder: Decoder): Any? = decoder.decodeNull()
}

class Locals {
    fun roundTripLocal(): String {
        @Serializable(with = NullSerializer::class)
        data class Local(val i: Int)
        val origin: Local? = null
        val text = Json.encodeToString(origin)
        val back: Local? = Json.decodeFromString(text)
        return "$text -> ${back == origin}"
    }
}

@Serializable
data class ValueHolder<V : Any>(@Polymorphic val value: V)

data class VImpl(val a: String)

object VImplSerializer : KSerializer<VImpl> {
    override val descriptor: SerialDescriptor = buildClassSerialDescriptor("VImpl") { element("a", String.serializer().descriptor) }
    override fun serialize(encoder: Encoder, value: VImpl) {
        (encoder as JsonEncoder).encodeJsonElement(JsonObject(mapOf("a" to JsonPrimitive(value.a))))
    }
    override fun deserialize(decoder: Decoder): VImpl {
        val obj = (decoder as JsonDecoder).decodeJsonElement() as JsonObject
        return VImpl((obj["a"] as JsonPrimitive).content)
    }
}

fun main() {
    println(Locals().roundTripLocal())
    val json = Json { serializersModule = SerializersModule { polymorphic(Any::class, VImpl::class, VImplSerializer) } }
    val holder = ValueHolder(VImpl("aaa"))
    val text = json.encodeToString(ValueHolder.serializer(VImplSerializer), holder)
    println(text)
    println(json.decodeFromString(ValueHolder.serializer(VImplSerializer), text) == holder)
}

// Run with: klio run --feature kotlinx.serialization/json examples/contextual_generic_type_args.kt
// A `@Contextual` property of a GENERIC type (`CheckedData<String>`) hands
// the type-argument serializers to the module's contextual provider, so a
// provider written over `args` (`contextual(CheckedData::class) { args ->
// CheckedDataSerializer(args[0]) }`) receives `String.serializer()`.
import kotlinx.serialization.*
import kotlinx.serialization.builtins.*
import kotlinx.serialization.descriptors.*
import kotlinx.serialization.encoding.*
import kotlinx.serialization.json.*
import kotlinx.serialization.modules.*

class Tagged<T : Any>(val value: T, val tag: String) {
    override fun equals(other: Any?): Boolean = other is Tagged<*> && other.value == value && other.tag == tag
    override fun hashCode(): Int = value.hashCode() * 31 + tag.hashCode()
    override fun toString(): String = "Tagged($value, $tag)"
}

class TaggedSerializer<T : Any>(private val inner: KSerializer<T>) : KSerializer<Tagged<T>> {
    override val descriptor: SerialDescriptor = buildClassSerialDescriptor("Tagged") {
        element("value", inner.descriptor)
        element("tag", String.serializer().descriptor)
    }
    override fun serialize(encoder: Encoder, value: Tagged<T>) {
        val out = encoder.beginStructure(descriptor)
        out.encodeSerializableElement(descriptor, 0, inner, value.value)
        out.encodeStringElement(descriptor, 1, value.tag)
        out.endStructure(descriptor)
    }
    override fun deserialize(decoder: Decoder): Tagged<T> {
        val inp = decoder.beginStructure(descriptor)
        lateinit var v: T
        var tag = ""
        while (true) {
            when (val i = inp.decodeElementIndex(descriptor)) {
                CompositeDecoder.DECODE_DONE -> break
                0 -> v = inp.decodeSerializableElement(descriptor, i, inner)
                1 -> tag = inp.decodeStringElement(descriptor, i)
                else -> throw SerializationException("Unknown index $i")
            }
        }
        inp.endStructure(descriptor)
        return Tagged(v, tag)
    }
}

@Serializable
data class Holder(@Contextual val text: Tagged<String>, @Contextual val count: Tagged<Int>)

fun main() {
    val module = SerializersModule {
        @Suppress("UNCHECKED_CAST")
        contextual(Tagged::class) { args -> TaggedSerializer(args[0] as KSerializer<Any>) }
    }
    val json = Json { serializersModule = module }
    val holder = Holder(Tagged("hello", "greeting"), Tagged(3, "times"))
    val encoded = json.encodeToString(Holder.serializer(), holder)
    println(encoded)
    println(json.decodeFromString(Holder.serializer(), encoded) == holder)
}

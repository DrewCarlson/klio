// Run with: klio run --feature kotlinx.serialization/json examples/serializable_typealias_type_use.kt
// `@Serializable(S::class)` written on a property's TYPE, or carried by a
// `typealias` target (`typealias BS = @Serializable(S::class) B`), selects the
// serializer exactly as the annotation on the property does; the plain
// declaration keeps its own serializer.
import kotlinx.serialization.*
import kotlinx.serialization.descriptors.*
import kotlinx.serialization.encoding.*
import kotlinx.serialization.json.*

@Serializable
data class Plain(val s: String)

object Marked : KSerializer<Plain> {
    override val descriptor: SerialDescriptor get() = PrimitiveSerialDescriptor("Marked", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: Plain) { encoder.encodeString(value.s + "#") }
    override fun deserialize(decoder: Decoder): Plain = Plain(decoder.decodeString().removeSuffix("#"))
}

typealias MarkedPlain = @Serializable(Marked::class) Plain

@Serializable
data class Holder(
    val plain: Plain,
    @Serializable(Marked::class) val onProperty: Plain,
    val onType: @Serializable(Marked::class) Plain,
    val viaAlias: MarkedPlain,
    val nullableAlias: MarkedPlain?,
)

fun main() {
    val h = Holder(Plain("a"), Plain("b"), Plain("c"), Plain("d"), null)
    val s = Json.encodeToString(Holder.serializer(), h)
    println(s)
    println(Json.decodeFromString(Holder.serializer(), s) == h)
}

// klio's replacement for the compiler-plugin / reified-generic
// builtin serializer lookup. Upstream's `serializer<T>()` and the
// per-primitive `Int.serializer()` factories live in files that use
// `inline fun <reified T>` with generic bounds klio's parser does not
// yet accept (Serializers.kt, BuiltinSerializers.kt). This file
// supplies the small consumer-facing surface from them: primitive
// `KSerializer`s with proper `PrimitiveKind` descriptors and a
// reified `serializer<T>()` that resolves a builtin for primitives /
// String or falls back to the reflective serializer for an arbitrary
// `@Serializable` class.

package kotlinx.serialization

import kotlin.reflect.KClass
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder

internal object IntKSerializer : KSerializer<Int> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("kotlin.Int", PrimitiveKind.INT)
    override fun serialize(encoder: Encoder, value: Int) = encoder.encodeInt(value)
    override fun deserialize(decoder: Decoder): Int = decoder.decodeInt()
}

internal object LongKSerializer : KSerializer<Long> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("kotlin.Long", PrimitiveKind.LONG)
    override fun serialize(encoder: Encoder, value: Long) = encoder.encodeLong(value)
    override fun deserialize(decoder: Decoder): Long = decoder.decodeLong()
}

internal object ShortKSerializer : KSerializer<Short> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("kotlin.Short", PrimitiveKind.SHORT)
    override fun serialize(encoder: Encoder, value: Short) = encoder.encodeShort(value)
    override fun deserialize(decoder: Decoder): Short = decoder.decodeShort()
}

internal object ByteKSerializer : KSerializer<Byte> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("kotlin.Byte", PrimitiveKind.BYTE)
    override fun serialize(encoder: Encoder, value: Byte) = encoder.encodeByte(value)
    override fun deserialize(decoder: Decoder): Byte = decoder.decodeByte()
}

internal object DoubleKSerializer : KSerializer<Double> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("kotlin.Double", PrimitiveKind.DOUBLE)
    override fun serialize(encoder: Encoder, value: Double) = encoder.encodeDouble(value)
    override fun deserialize(decoder: Decoder): Double = decoder.decodeDouble()
}

internal object FloatKSerializer : KSerializer<Float> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("kotlin.Float", PrimitiveKind.FLOAT)
    override fun serialize(encoder: Encoder, value: Float) = encoder.encodeFloat(value)
    override fun deserialize(decoder: Decoder): Float = decoder.decodeFloat()
}

internal object BooleanKSerializer : KSerializer<Boolean> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("kotlin.Boolean", PrimitiveKind.BOOLEAN)
    override fun serialize(encoder: Encoder, value: Boolean) = encoder.encodeBoolean(value)
    override fun deserialize(decoder: Decoder): Boolean = decoder.decodeBoolean()
}

internal object CharKSerializer : KSerializer<Char> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("kotlin.Char", PrimitiveKind.CHAR)
    override fun serialize(encoder: Encoder, value: Char) = encoder.encodeChar(value)
    override fun deserialize(decoder: Decoder): Char = decoder.decodeChar()
}

internal object StringKSerializer : KSerializer<String> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("kotlin.String", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: String) = encoder.encodeString(value)
    override fun deserialize(decoder: Decoder): String = decoder.decodeString()
}

// Builtin lookup by simple class name. Used by both the reified
// `serializer<T>()` and the explicit `Int.serializer()`-style
// factories. Returns the reflective serializer when no builtin
// applies (any `@Serializable` class).
internal fun __klsx_builtinByName(name: String?): KSerializer<*>? = when (name) {
    "Int" -> IntKSerializer
    "Long" -> LongKSerializer
    "Short" -> ShortKSerializer
    "Byte" -> ByteKSerializer
    "Double" -> DoubleKSerializer
    "Float" -> FloatKSerializer
    "Boolean" -> BooleanKSerializer
    "Char" -> CharKSerializer
    "String" -> StringKSerializer
    else -> null
}

@Suppress("UNCHECKED_CAST")
public inline fun <reified T> serializer(): KSerializer<T> {
    val kc = T::class
    val builtin = __klsx_builtinByName(kc.simpleName)
    if (builtin != null) return builtin as KSerializer<T>
    return ReflectiveKSerializer(kc) as KSerializer<T>
}

// Explicit primitive factories (`Int.serializer()` etc). The
// interpreter routes a `serializer()` call on a primitive companion
// here via the kotlinx.serialization binding table.
public fun __klsx_primitiveSerializer(name: String?): KSerializer<*> {
    val s = __klsx_builtinByName(name)
    if (s != null) return s
    error("no builtin serializer for $name")
}

// klio's compiler-plugin replacement for kotlinx-serialization.
//
// kotlinx-serialization's plugin synthesizes a KSerializer for every
// @Serializable class. klio has no compiler plugin; instead the
// interpreter routes `T.serializer()` / `Companion.serializer()` (when
// no hand-written or `with=` serializer exists) to a fresh
// `ReflectiveKSerializer` built over the target KClass. It serializes
// the primary-constructor properties in declaration order, reflecting
// names + values through the host helpers in src/lib.rs.
//
// Element values flow through `DynamicValueSerializer`, which uses the
// generic `AbstractEncoder.encodeValue` / `AbstractDecoder.decodeValue`
// hooks (consumed verbatim from upstream commonMain) so the round-trip
// is type-preserving for any format built on those base classes.
// Supported element shapes: Int / Long / Short / Byte / Double /
// Float / Boolean / Char / String, their nullable forms, and nested
// @Serializable classes (recursively, via the same reflective path).
// Lists and Maps round-trip as their element/entry values.

package kotlinx.serialization

import kotlin.reflect.KClass
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.SerialKind
import kotlinx.serialization.descriptors.StructureKind
import kotlinx.serialization.encoding.AbstractDecoder
import kotlinx.serialization.encoding.AbstractEncoder
import kotlinx.serialization.encoding.CompositeDecoder
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder

internal fun __klsx_ctorParamNames(kClass: Any?): List<String> =
    error("intrinsic kotlinx.serialization.__klsx_ctorParamNames not installed")

internal fun __klsx_get(obj: Any?, name: String): Any? =
    error("intrinsic kotlinx.serialization.__klsx_get not installed")

internal fun __klsx_construct(kClass: Any?, args: List<Any?>): Any? =
    error("intrinsic kotlinx.serialization.__klsx_construct not installed")

// A minimal SerialDescriptor over a fixed element-name list. Kind is
// StructureKind.CLASS. The reflective path is type-erased (element values
// flow through DynamicValueSerializer at encode/decode time), so it cannot
// name the concrete per-element type; `getElementDescriptor` returns a
// neutral 0-element descriptor. It must NOT return `this` — a consumer that
// walks element descriptors (e.g. a descriptor-equality test) would then
// recurse without bound.
internal class ReflectiveDescriptor(
    override val serialName: String,
    private val names: List<String>
) : SerialDescriptor {
    override val kind: SerialKind get() = StructureKind.CLASS
    override val elementsCount: Int get() = names.size
    override fun getElementName(index: Int): String = names[index]
    override fun getElementIndex(name: String): Int = names.indexOf(name)
    override fun getElementAnnotations(index: Int): List<Annotation> = emptyList()
    override fun getElementDescriptor(index: Int): SerialDescriptor = ReflectiveElementDescriptor
    override fun isElementOptional(index: Int): Boolean = false
    override fun toString(): String = "ReflectiveDescriptor($serialName)"
}

// The neutral, terminal element descriptor the type-erased reflective path
// hands back for every element: zero elements, so a recursive descriptor walk
// terminates instead of looping through `this`.
internal object ReflectiveElementDescriptor : SerialDescriptor {
    override val serialName: String get() = "kotlinx.serialization.Dynamic"
    override val kind: SerialKind get() = StructureKind.CLASS
    override val elementsCount: Int get() = 0
    override fun getElementName(index: Int): String = throw IndexOutOfBoundsException()
    override fun getElementIndex(name: String): Int = -1
    override fun getElementAnnotations(index: Int): List<Annotation> = emptyList()
    override fun getElementDescriptor(index: Int): SerialDescriptor = throw IndexOutOfBoundsException()
    override fun isElementOptional(index: Int): Boolean = false
    override fun toString(): String = "ReflectiveElementDescriptor"
}

// Serializes any single element by routing through the format's
// generic untyped hooks. The in-test (and any AbstractEncoder-based)
// format keeps the real value, so decode returns it unchanged.
public object DynamicValueSerializer : KSerializer<Any?> {
    override val descriptor: SerialDescriptor =
        ReflectiveDescriptor("kotlinx.serialization.Dynamic", emptyList())

    override fun serialize(encoder: Encoder, value: Any?) {
        if (value == null) {
            encoder.encodeNull()
            return
        }
        val ae = encoder as AbstractEncoder
        ae.encodeValue(value)
    }

    override fun deserialize(decoder: Decoder): Any? {
        val ad = decoder as AbstractDecoder
        return ad.decodeValue()
    }
}

public class ReflectiveKSerializer(private val kClass: Any?) : KSerializer<Any?> {
    private val names: List<String> = __klsx_ctorParamNames(kClass)

    override val descriptor: SerialDescriptor =
        ReflectiveDescriptor(__klsx_serialName(kClass), names)

    override fun serialize(encoder: Encoder, value: Any?) {
        val c = encoder.beginStructure(descriptor)
        var i = 0
        while (i < names.size) {
            val v = __klsx_get(value, names[i])
            c.encodeSerializableElement(descriptor, i, DynamicValueSerializer, v)
            i = i + 1
        }
        c.endStructure(descriptor)
    }

    override fun deserialize(decoder: Decoder): Any? {
        val c = decoder.beginStructure(descriptor)
        val args = ArrayList<Any?>()
        var i = 0
        while (i < names.size) {
            args.add(null)
            i = i + 1
        }
        // Read elements through the format's generic untyped hook
        // directly. We deliberately avoid
        // `CompositeDecoder.decodeSerializableElement` /
        // `decodeSerializableValue`: in upstream's AbstractDecoder the
        // two-arg `decodeSerializableValue(deserializer, previousValue
        // = null)` overload tail-calls the one-arg overload, a pattern
        // klio's overload resolution cannot disambiguate (it re-picks
        // the defaulted two-arg form). `decodeValue()` is the stable
        // path AbstractDecoder exposes for untyped reads.
        val ad = c as AbstractDecoder
        while (true) {
            val index = ad.decodeElementIndex(descriptor)
            if (index == CompositeDecoder.DECODE_DONE) break
            if (index >= 0 && index < names.size) {
                args[index] = if (ad.decodeNotNullMark()) ad.decodeValue() else ad.decodeNull()
            } else {
                break
            }
        }
        ad.endStructure(descriptor)
        return __klsx_construct(kClass, args)
    }
}

internal fun __klsx_serialName(kClass: Any?): String {
    if (kClass is KClass<*>) {
        val q = kClass.qualifiedName
        if (q != null) return q
        val s = kClass.simpleName
        if (s != null) return s
    }
    return "kotlinx.serialization.Reflective"
}

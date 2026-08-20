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
import kotlinx.serialization.internal.EnumSerializer
import kotlinx.serialization.internal.ObjectSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.SerialKind
import kotlinx.serialization.descriptors.nullable
import kotlinx.serialization.descriptors.StructureKind
import kotlinx.serialization.encoding.AbstractDecoder
import kotlinx.serialization.encoding.AbstractEncoder
import kotlinx.serialization.encoding.CompositeDecoder
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder

internal fun __klsx_ctorParamNames(kClass: Any?): List<String> =
    error("intrinsic kotlinx.serialization.__klsx_ctorParamNames not installed")

internal fun __klsx_classSerialNameOverride(kClass: Any?): String? =
    error("intrinsic kotlinx.serialization.__klsx_classSerialNameOverride not installed")

internal fun __klsx_ctorParamSerialNames(kClass: Any?): List<String> =
    error("intrinsic kotlinx.serialization.__klsx_ctorParamSerialNames not installed")

internal fun __klsx_get(obj: Any?, name: String): Any? =
    error("intrinsic kotlinx.serialization.__klsx_get not installed")

internal fun __klsx_construct(kClass: Any?, args: List<Any?>): Any? =
    error("intrinsic kotlinx.serialization.__klsx_construct not installed")

internal fun __klsx_ctorParamTypes(kClass: Any?): List<String> =
    error("intrinsic kotlinx.serialization.__klsx_ctorParamTypes not installed")

internal fun __klsx_ctorParamOptional(kClass: Any?): List<Boolean> =
    error("intrinsic kotlinx.serialization.__klsx_ctorParamOptional not installed")

internal fun __klsx_isSerializable(kClass: Any?): Boolean =
    error("intrinsic kotlinx.serialization.__klsx_isSerializable not installed")

internal fun __klsx_isEnum(kClass: Any?): Boolean =
    error("intrinsic kotlinx.serialization.__klsx_isEnum not installed")

internal fun __klsx_enumValues(kClass: Any?): List<Any?> =
    error("intrinsic kotlinx.serialization.__klsx_enumValues not installed")

// One generated serializer per declaration, as the plugin's generated
// `Companion.serializer()` provides: `serializer()` called twice on the same
// class must return the same instance.
private val __klsx_generated = HashMap<KClass<*>, KSerializer<Any>>()

// The serializer the compiler plugin would have generated for a
// `@Serializable` declaration, built from the declaration's runtime shape:
// an `object` serializes as an empty structure, an `enum class` by entry
// index, a `sealed` class dispatches over its subclasses, an open hierarchy
// root is polymorphic, and a plain class walks its primary-constructor
// properties reflectively. A declaration that never opted in returns null,
// which is what upstream's `serializerOrNull()` contract requires.
@Suppress("UNCHECKED_CAST")
internal fun __klsx_generatedSerializer(kClass: KClass<*>): KSerializer<Any>? {
    if (!__klsx_isSerializable(kClass)) return null
    __klsx_generated[kClass]?.let { return it }
    val built = __klsx_buildSerializer(kClass)
    __klsx_generated[kClass] = built
    return built
}

@Suppress("UNCHECKED_CAST")
private fun __klsx_buildSerializer(kClass: KClass<*>): KSerializer<Any> {
    val serialName = __klsx_serialName(kClass)
    val objectInstance = kClass.objectInstance
    if (objectInstance != null) {
        return ObjectSerializer(serialName, objectInstance) as KSerializer<Any>
    }
    if (__klsx_isEnum(kClass)) {
        return EnumSerializer(serialName, __klsx_enumValues(kClass).toTypedArray()) as KSerializer<Any>
    }
    if (kClass.isSealed) {
        val subclasses = ArrayList<KClass<*>>()
        val subSerializers = ArrayList<KSerializer<Any>>()
        for (sub in kClass.sealedSubclasses) {
            val s = __klsx_generatedSerializer(sub) ?: continue
            subclasses.add(sub)
            subSerializers.add(s)
        }
        return SealedClassSerializer(
            serialName,
            kClass as KClass<Any>,
            subclasses.toTypedArray() as Array<KClass<out Any>>,
            subSerializers.toTypedArray() as Array<KSerializer<out Any>>
        ) as KSerializer<Any>
    }
    if (kClass.isAbstract) {
        return PolymorphicSerializer(kClass as KClass<Any>) as KSerializer<Any>
    }
    return ReflectiveKSerializer(kClass) as KSerializer<Any>
}

// A minimal SerialDescriptor over a fixed element-name list. Kind is
// StructureKind.CLASS. The reflective path is type-erased (element values
// flow through DynamicValueSerializer at encode/decode time), so it cannot
// name the concrete per-element type; `getElementDescriptor` returns a
// neutral 0-element descriptor. It must NOT return `this` — a consumer that
// walks element descriptors (e.g. a descriptor-equality test) would then
// recurse without bound.
internal class ReflectiveDescriptor(
    override val serialName: String,
    private val names: List<String>,
    // Rendered declared type per element, and whether the element has a
    // default. Both come from the class's primary constructor; an empty
    // list means the caller had no shape to give (the `Dynamic` descriptor),
    // in which case every element falls back to the neutral answers.
    private val types: List<String> = emptyList(),
    private val optionals: List<Boolean> = emptyList()
) : SerialDescriptor {
    override val kind: SerialKind get() = StructureKind.CLASS
    override val elementsCount: Int get() = names.size
    override fun getElementName(index: Int): String = names[index]
    override fun getElementIndex(name: String): Int = names.indexOf(name)
    override fun getElementAnnotations(index: Int): List<Annotation> = emptyList()

    // A primary-constructor parameter with a default is exactly kotlinx's
    // notion of an optional element: a decoder may leave it absent.
    override fun isElementOptional(index: Int): Boolean =
        if (index < optionals.size) optionals[index] else false

    // Name the element's real descriptor where the declared type maps to a
    // primitive. Anything else stays neutral rather than guessing: the
    // reflective encode/decode path is type-erased, so claiming a structure
    // it cannot actually produce would be worse than admitting ignorance.
    override fun getElementDescriptor(index: Int): SerialDescriptor {
        if (index >= types.size) return ReflectiveElementDescriptor
        return descriptorForDeclaredType(types[index])
    }

    override fun toString(): String = "ReflectiveDescriptor($serialName)"
}

// Map a rendered declared type (`"Int"`, `"String?"`) to the descriptor the
// plugin would have named for that element. Unknown or generic types get the
// neutral descriptor.
internal fun descriptorForDeclaredType(declared: String): SerialDescriptor {
    val nullable = declared.endsWith("?")
    val base = if (nullable) declared.substring(0, declared.length - 1) else declared
    // The builtin serializers' own descriptors. Minting a fresh
    // `PrimitiveSerialDescriptor` here instead is rejected outright:
    // `checkNameIsNotAPrimitive` forbids reusing a primitive's serial name for
    // a new descriptor ("For serial name kotlin.String there already exists
    // StringSerializer"), so every element of a primitive type threw.
    val d = when (base) {
        "Int", "kotlin.Int" -> Int.serializer().descriptor
        "Long", "kotlin.Long" -> Long.serializer().descriptor
        "Short", "kotlin.Short" -> Short.serializer().descriptor
        "Byte", "kotlin.Byte" -> Byte.serializer().descriptor
        "Float", "kotlin.Float" -> Float.serializer().descriptor
        "Double", "kotlin.Double" -> Double.serializer().descriptor
        "Boolean", "kotlin.Boolean" -> Boolean.serializer().descriptor
        "Char", "kotlin.Char" -> Char.serializer().descriptor
        "String", "kotlin.String" -> String.serializer().descriptor
        else -> return ReflectiveElementDescriptor
    }
    return if (nullable) d.nullable else d
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
        ReflectiveDescriptor(
            __klsx_serialName(kClass),
            // The descriptor reports WIRE names (`@SerialName`); `names` stays
            // the declared names that address the instance itself.
            __klsx_ctorParamSerialNames(kClass),
            __klsx_ctorParamTypes(kClass),
            __klsx_ctorParamOptional(kClass)
        )

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
    // `@SerialName` on the class replaces the qualified-name default.
    val override = __klsx_classSerialNameOverride(kClass)
    if (override != null) return override
    if (kClass is KClass<*>) {
        val q = kClass.qualifiedName
        if (q != null) return q
        val s = kClass.simpleName
        if (s != null) return s
    }
    return "kotlinx.serialization.Reflective"
}

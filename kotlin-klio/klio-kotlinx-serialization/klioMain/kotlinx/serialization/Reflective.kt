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
import kotlinx.serialization.internal.EnumDescriptor
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

internal fun __klsx_classAnnotations(kClass: Any?): List<Annotation> =
    error("intrinsic kotlinx.serialization.__klsx_classAnnotations not installed")

internal fun __klsx_paramAnnotations(kClass: Any?, index: Int): List<Annotation> =
    error("intrinsic kotlinx.serialization.__klsx_paramAnnotations not installed")

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

internal fun __klsx_typeParamNames(kClass: Any?): List<String> =
    error("intrinsic kotlinx.serialization.__klsx_typeParamNames not installed")

internal fun __klsx_ctorParamClasses(kClass: Any?): List<Any?> =
    error("intrinsic kotlinx.serialization.__klsx_ctorParamClasses not installed")

internal fun __klsx_ctorParamOptional(kClass: Any?): List<Boolean> =
    error("intrinsic kotlinx.serialization.__klsx_ctorParamOptional not installed")

// Serialized BODY properties (backing-field, non-delegated, non-@Transient),
// in declaration order — the elements the plugin appends after the
// primary-constructor properties.
internal fun __klsx_bodyPropNames(kClass: Any?): List<String> =
    error("intrinsic kotlinx.serialization.__klsx_bodyPropNames not installed")

internal fun __klsx_bodyPropSerialNames(kClass: Any?): List<String> =
    error("intrinsic kotlinx.serialization.__klsx_bodyPropSerialNames not installed")

internal fun __klsx_bodyPropTypes(kClass: Any?): List<String> =
    error("intrinsic kotlinx.serialization.__klsx_bodyPropTypes not installed")

internal fun __klsx_bodyPropHasInit(kClass: Any?): List<Boolean> =
    error("intrinsic kotlinx.serialization.__klsx_bodyPropHasInit not installed")

internal fun __klsx_setField(instance: Any?, name: String, value: Any?): Unit =
    error("intrinsic kotlinx.serialization.__klsx_setField not installed")

internal fun __klsx_isSerializable(kClass: Any?): Boolean =
    error("intrinsic kotlinx.serialization.__klsx_isSerializable not installed")

internal fun __klsx_isEnum(kClass: Any?): Boolean =
    error("intrinsic kotlinx.serialization.__klsx_isEnum not installed")

// The serializer a declaration names for itself with `@Serializable(with =
// Custom::class)`. Null when it names none. An `object Custom` answers its
// singleton; a class answers the class, for the caller to construct.
internal fun __klsx_customSerializer(kClass: Any?): Any? =
    error("intrinsic kotlinx.serialization.__klsx_customSerializer not installed")

internal fun __klsx_enumValues(kClass: Any?): List<Any?> =
    error("intrinsic kotlinx.serialization.__klsx_enumValues not installed")

internal fun __klsx_enumEntryAnnotations(kClass: Any?, index: Int): List<Annotation> =
    error("intrinsic kotlinx.serialization.__klsx_enumEntryAnnotations not installed")

internal fun __klsx_enumEntrySerialNames(kClass: Any?): List<String> =
    error("intrinsic kotlinx.serialization.__klsx_enumEntrySerialNames not installed")

// One generated serializer per declaration, as the plugin's generated
// `Companion.serializer()` provides: `serializer()` called twice on the same
// class must return the same instance.
private val __klsx_generated = HashMap<KClass<*>, KSerializer<Any>>()

// Serializers built for `@Serializer(forClass = C::class)` declarations, kept
// apart from `__klsx_generated`: these are C's GENERATED shape whatever C
// names with `@Serializable(with = …)`, which is usually the very declaration
// asking for this.
private val __klsx_reflective = HashMap<KClass<*>, KSerializer<Any>>()

// The body the plugin writes into a `@Serializer(forClass = C::class)`
// declaration: C's generated serializer, built from C's runtime shape.
// Unlike `__klsx_generatedSerializer` this does not consult C's own
// `@Serializable(with = …)` — that names this declaration right back — and
// does not require C to be `@Serializable` at all, since the annotation is
// itself the request to generate.
@Suppress("UNCHECKED_CAST")
internal fun __klsx_reflectiveSerializer(kClass: KClass<*>): KSerializer<Any>? {
    __klsx_reflective[kClass]?.let { return it }
    val built = __klsx_buildSerializer(kClass)
    __klsx_reflective[kClass] = built
    return built
}

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
    // `@Serializable(with = Custom::class)` hands the whole job to `Custom`;
    // the plugin's `serializer()` returns that declaration itself, so the
    // identity a test asserts is the named object's.
    val named = __klsx_customSerializer(kClass)
    if (named != null) {
        // A `@Serializer(forClass = …)` declaration has no written supertype
        // — the plugin gives it one — so this cannot test `is KSerializer`.
        @Suppress("UNCHECKED_CAST")
        val custom = named as KSerializer<Any>
        __klsx_generated[kClass] = custom
        return custom
    }
    val built = __klsx_buildSerializer(kClass)
    __klsx_generated[kClass] = built
    return built
}

// The generic form the plugin generates for `@Serializable class Foo<T>`:
// `Foo.serializer(tSerializer)`. The arguments stand, in order, for the
// declaration's type parameters, and they are what lets the descriptor name a
// real element descriptor where the declared type is a type parameter.
//
// Two calls with the same arguments must produce EQUAL descriptors (and two
// with different arguments unequal ones), which is a property of the
// descriptor rather than of the instance, so this mints a fresh serializer
// each time rather than caching by argument list.
@Suppress("UNCHECKED_CAST")
internal fun __klsx_generatedSerializerGeneric(
    kClass: KClass<*>,
    typeArgs: List<KSerializer<Any?>>
): KSerializer<Any>? {
    if (!__klsx_isSerializable(kClass)) return null
    if (typeArgs.isEmpty()) return __klsx_generatedSerializer(kClass)
    // Only the plain-class shape carries elements the arguments can describe;
    // every other shape ignores its type arguments exactly as the plugin does.
    if (kClass.objectInstance != null || __klsx_isEnum(kClass) || kClass.isSealed || kClass.isAbstract) {
        return __klsx_generatedSerializer(kClass)
    }
    return ReflectiveKSerializer(kClass, typeArgs) as KSerializer<Any>
}

@Suppress("UNCHECKED_CAST")
private fun __klsx_buildSerializer(kClass: KClass<*>): KSerializer<Any> {
    val serialName = __klsx_serialName(kClass)
    // Every shape below reports the declaration's `@SerialInfo` annotations on
    // its descriptor, which is what the plugin passes to each of these.
    val declAnnotations = __klsx_classAnnotations(kClass).toTypedArray()
    val objectInstance = kClass.objectInstance
    if (objectInstance != null) {
        return ObjectSerializer(serialName, objectInstance, declAnnotations) as KSerializer<Any>
    }
    if (__klsx_isEnum(kClass)) {
        // The entry wire names and the `@SerialInfo` annotations on the class
        // and on each entry are exactly what the plugin passes here.
        val values = __klsx_enumValues(kClass).toTypedArray()
        val wire = __klsx_enumEntrySerialNames(kClass)
        val classAnnotations = __klsx_classAnnotations(kClass)
        val entryAnnotations = ArrayList<List<Annotation>>()
        var annotated = false
        var i = 0
        while (i < values.size) {
            val anns = __klsx_enumEntryAnnotations(kClass, i)
            if (anns.isNotEmpty()) annotated = true
            entryAnnotations.add(anns)
            i = i + 1
        }
        if (!annotated && classAnnotations.isEmpty()) {
            return EnumSerializer(serialName, values) as KSerializer<Any>
        }
        // Same shape as upstream's `createAnnotatedEnumSerializer`, built here
        // because the entry names and annotations come from the declaration
        // rather than from plugin-emitted arrays.
        val descriptor = EnumDescriptor(serialName, values.size)
        for (a in classAnnotations) descriptor.pushClassAnnotation(a)
        i = 0
        while (i < values.size) {
            descriptor.addElement(if (i < wire.size) wire[i] else "$i")
            for (a in entryAnnotations[i]) descriptor.pushAnnotation(a)
            i = i + 1
        }
        return EnumSerializer(serialName, values, descriptor) as KSerializer<Any>
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
            subSerializers.toTypedArray() as Array<KSerializer<out Any>>,
            declAnnotations
        ) as KSerializer<Any>
    }
    if (kClass.isAbstract) {
        return PolymorphicSerializer(kClass as KClass<Any>, declAnnotations) as KSerializer<Any>
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
    private val optionals: List<Boolean> = emptyList(),
    private val owner: Any? = null,
    // The declaration's type-parameter names paired with the serializer given
    // for each, when the descriptor was built by a generic `serializer(...)`.
    private val typeParamNames: List<String> = emptyList(),
    private val typeArgs: List<KSerializer<Any?>> = emptyList(),
    // The class each element's declared type names, where it names one. An
    // element declared as another `@Serializable` class reports that class's
    // own descriptor, which is where its annotations and elements live.
    private val elementClasses: List<Any?> = emptyList()
) : SerialDescriptor {
    override val kind: SerialKind get() = StructureKind.CLASS
    override val elementsCount: Int get() = names.size
    override fun getElementName(index: Int): String = names[index]
    override fun getElementIndex(name: String): Int = names.indexOf(name)
    // kotlinx reports the `@SerialInfo` annotations written on the class and
    // on each property. `owner` is the class the descriptor was built from;
    // a descriptor with no owner (the neutral `Dynamic` one) has none.
    override val annotations: List<Annotation>
        get() = if (owner == null) emptyList() else __klsx_classAnnotations(owner)

    override fun getElementAnnotations(index: Int): List<Annotation> =
        if (owner == null) emptyList() else __klsx_paramAnnotations(owner, index)

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
        val declared = types[index]
        // An element declared as one of the type parameters is described by
        // the serializer the call supplied for it.
        val nullable = declared.endsWith("?")
        val base = if (nullable) declared.substring(0, declared.length - 1) else declared
        val at = typeParamNames.indexOf(base)
        if (at >= 0 && at < typeArgs.size) {
            val d = typeArgs[at].descriptor
            return if (nullable) d.nullable else d
        }
        if (index < elementClasses.size) {
            val cls = elementClasses[index]
            if (cls is KClass<*>) {
                val s = __klsx_generatedSerializer(cls)
                if (s != null) {
                    val d = s.descriptor
                    return if (nullable) d.nullable else d
                }
            }
        }
        return descriptorForDeclaredType(declared)
    }

    // kotlinx's descriptor equality: same serial name, same type arguments,
    // and element-wise agreement on each element's serial name and kind. It
    // stops at the element's name/kind rather than recursing, which is what
    // lets a self-referential class compare at all. A descriptor built any
    // other way is never equal to a generated one, even under the same name.
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is ReflectiveDescriptor) return false
        if (serialName != other.serialName) return false
        if (typeArgDescriptors() != other.typeArgDescriptors()) return false
        if (elementsCount != other.elementsCount) return false
        var i = 0
        while (i < elementsCount) {
            val a = getElementDescriptor(i)
            val b = other.getElementDescriptor(i)
            if (a.serialName != b.serialName) return false
            if (a.kind != b.kind) return false
            i = i + 1
        }
        return true
    }

    override fun hashCode(): Int {
        var result = serialName.hashCode()
        result = result * 31 + typeArgDescriptors().hashCode()
        var i = 0
        while (i < elementsCount) {
            val e = getElementDescriptor(i)
            result = result * 31 + e.serialName.hashCode()
            result = result * 31 + e.kind.toString().hashCode()
            i = i + 1
        }
        return result
    }

    private fun typeArgDescriptors(): List<SerialDescriptor> = typeArgs.map { it.descriptor }

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

public class ReflectiveKSerializer(
    private val kClass: Any?,
    private val typeArgs: List<KSerializer<Any?>> = emptyList()
) : KSerializer<Any?> {
    private val ctorNames: List<String> = __klsx_ctorParamNames(kClass)
    // Serialized body properties follow the constructor properties, exactly
    // as the plugin appends them. Decoded body values are written to the
    // BACKING FIELD after construction — but only for properties with their
    // own initializer (or `lateinit`): one assigned only in an `init` block
    // keeps the init block's value, matching the generated deserializer's
    // write-then-init order.
    private val bodyNames: List<String> = __klsx_bodyPropNames(kClass)
    private val bodyHasInit: List<Boolean> = __klsx_bodyPropHasInit(kClass)
    private val names: List<String> = ctorNames + bodyNames
    private val elementTypes: List<String> = __klsx_ctorParamTypes(kClass) + __klsx_bodyPropTypes(kClass)

    override val descriptor: SerialDescriptor =
        ReflectiveDescriptor(
            __klsx_serialName(kClass),
            // The descriptor reports WIRE names (`@SerialName`); `names` stays
            // the declared names that address the instance itself.
            __klsx_ctorParamSerialNames(kClass) + __klsx_bodyPropSerialNames(kClass),
            __klsx_ctorParamTypes(kClass) + __klsx_bodyPropTypes(kClass),
            __klsx_ctorParamOptional(kClass) + bodyHasInit,
            kClass,
            __klsx_typeParamNames(kClass),
            typeArgs,
            __klsx_ctorParamClasses(kClass) + bodyNames.map { null }
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
        val seen = ArrayList<Boolean>()
        i = 0
        while (i < names.size) {
            seen.add(false)
            i = i + 1
        }
        while (true) {
            val index = ad.decodeElementIndex(descriptor)
            if (index == CompositeDecoder.DECODE_DONE) break
            if (index >= 0 && index < names.size) {
                // A primitively-typed element decodes through its TYPED hook
                // (`decodeStringElement` -> `decodeString`), which is the
                // surface an AbstractDecoder-based format actually overrides;
                // `decodeValue()` alone throws on a format that only
                // implements the typed hooks.
                val t = elementTypes[index].removeSuffix("?")
                args[index] = when (t) {
                    "String", "kotlin.String" -> ad.decodeStringElement(descriptor, index)
                    "Int", "kotlin.Int" -> ad.decodeIntElement(descriptor, index)
                    "Long", "kotlin.Long" -> ad.decodeLongElement(descriptor, index)
                    "Short", "kotlin.Short" -> ad.decodeShortElement(descriptor, index)
                    "Byte", "kotlin.Byte" -> ad.decodeByteElement(descriptor, index)
                    "Boolean", "kotlin.Boolean" -> ad.decodeBooleanElement(descriptor, index)
                    "Double", "kotlin.Double" -> ad.decodeDoubleElement(descriptor, index)
                    "Float", "kotlin.Float" -> ad.decodeFloatElement(descriptor, index)
                    "Char", "kotlin.Char" -> ad.decodeCharElement(descriptor, index)
                    else -> if (ad.decodeNotNullMark()) ad.decodeValue() else ad.decodeNull()
                }
                seen[index] = true
            } else {
                break
            }
        }
        ad.endStructure(descriptor)
        val instance = __klsx_construct(kClass, args.subList(0, ctorNames.size))
        var j = 0
        while (j < bodyNames.size) {
            val idx = ctorNames.size + j
            if (seen[idx] && bodyHasInit[j]) {
                __klsx_setField(instance, bodyNames[j], args[idx])
            }
            j = j + 1
        }
        return instance
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

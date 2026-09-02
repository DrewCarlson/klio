// klio actuals for the internal `expect`s in upstream's Platform.common.kt.
//
// klio reports itself as the Native platform (see klioTest/CurrentPlatform.kt),
// so these mirror `nativeMain/src/kotlinx/serialization/internal/Platform.kt`:
// no associated-object lookup, uncached serializer caches, and `isInterface`
// answering false — which is what the upstream tests' platform guards expect.

package kotlinx.serialization.internal

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerializationException
import kotlinx.serialization.__klsx_generatedSerializer
import kotlinx.serialization.__klsx_generatedSerializerGeneric
import kotlinx.serialization.__klsx_isInterfaceClass
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.builtins.*
import kotlin.reflect.KClass
import kotlin.reflect.KType
import kotlin.time.Duration
import kotlin.time.Instant
import kotlin.uuid.ExperimentalUuidApi
import kotlin.uuid.Uuid
import kotlin.time.ExperimentalTime

// The builtin serializer table upstream's `Primitives.kt` reads through
// `initBuiltins()`: the same entries as the native platform.
@OptIn(ExperimentalUnsignedTypes::class, ExperimentalUuidApi::class, ExperimentalSerializationApi::class, ExperimentalTime::class)
internal actual fun initBuiltins(): Map<KClass<*>, KSerializer<*>> = mapOf(
    String::class to String.serializer(),
    Char::class to Char.serializer(),
    CharArray::class to CharArraySerializer(),
    Double::class to Double.serializer(),
    DoubleArray::class to DoubleArraySerializer(),
    Float::class to Float.serializer(),
    FloatArray::class to FloatArraySerializer(),
    Long::class to Long.serializer(),
    LongArray::class to LongArraySerializer(),
    ULong::class to ULong.serializer(),
    ULongArray::class to ULongArraySerializer(),
    Int::class to Int.serializer(),
    IntArray::class to IntArraySerializer(),
    UInt::class to UInt.serializer(),
    UIntArray::class to UIntArraySerializer(),
    Short::class to Short.serializer(),
    ShortArray::class to ShortArraySerializer(),
    UShort::class to UShort.serializer(),
    UShortArray::class to UShortArraySerializer(),
    Byte::class to Byte.serializer(),
    ByteArray::class to ByteArraySerializer(),
    UByte::class to UByte.serializer(),
    UByteArray::class to UByteArraySerializer(),
    Boolean::class to Boolean.serializer(),
    BooleanArray::class to BooleanArraySerializer(),
    Unit::class to Unit.serializer(),
    Nothing::class to NothingSerializer(),
    Duration::class to Duration.serializer(),
    Instant::class to Instant.serializer(),
    Uuid::class to Uuid.serializer()
)

internal actual fun <T> Array<T>.getChecked(index: Int): T = get(index)

internal actual fun BooleanArray.getChecked(index: Int): Boolean = get(index)

internal actual fun KClass<*>.platformSpecificSerializerNotRegistered(): Nothing {
    throw SerializationException(
        notRegisteredMessage() +
            "To get enum serializer on Kotlin/Native, it should be annotated with @Serializable annotation.\n" +
            "To get interface serializer on Kotlin/Native, use PolymorphicSerializer() constructor function.\n"
    )
}

// klio's `findAssociatedObject`: the generated companion `serializer(...)`
// reached through its KClass (see Generated.kt), with the type-argument
// serializers of a generic class passed through.
@Suppress("UNCHECKED_CAST")
internal actual fun <T : Any> KClass<T>.constructSerializerForGivenTypeArgs(vararg args: KSerializer<Any?>): KSerializer<T>? {
    if (args.isEmpty()) {
        @Suppress("UNCHECKED_CAST")
        return __klsx_generatedSerializer(this) as KSerializer<T>?
    }
    val list = ArrayList<KSerializer<Any?>>()
    for (a in args) list.add(a)
    @Suppress("UNCHECKED_CAST")
    return __klsx_generatedSerializerGeneric(this, list) as KSerializer<T>?
}

// The plugin-generated `Companion.serializer()`, reached through the KClass.
@Suppress("UNCHECKED_CAST")
internal actual fun <T : Any> KClass<T>.compiledSerializerImpl(): KSerializer<T>? =
    __klsx_generatedSerializer(this) as KSerializer<T>?

internal actual fun <T : Any> KClass<T>.isInterface(): Boolean = __klsx_isInterfaceClass(this)

internal actual fun <T> createCache(factory: (KClass<*>) -> KSerializer<T>?): SerializerCache<T> {
    return object : SerializerCache<T> {
        override fun get(key: KClass<Any>): KSerializer<T>? = factory(key)
    }
}

internal actual fun <T> createParametrizedCache(factory: (KClass<Any>, List<KType>) -> KSerializer<T>?): ParametrizedSerializerCache<T> {
    return object : ParametrizedSerializerCache<T> {
        override fun get(key: KClass<Any>, types: List<KType>): Result<KSerializer<T>?> =
            kotlin.runCatching { factory(key, types) }
    }
}

internal actual fun <T : Any, E : T?> ArrayList<E>.toNativeArrayImpl(eClass: KClass<T>): Array<E> {
    @Suppress("UNCHECKED_CAST")
    val result = arrayOfNulls<Any>(size) as Array<E>
    var index = 0
    for (element in this) {
        result[index] = element
        index += 1
    }
    return result
}

internal actual fun isReferenceArray(rootClass: KClass<Any>): Boolean = rootClass == Array::class

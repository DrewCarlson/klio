// klio actuals for the internal `expect`s in upstream's Platform.common.kt.
//
// klio reports itself as the Native platform (see klioTest/CurrentPlatform.kt),
// so these mirror `nativeMain/src/kotlinx/serialization/internal/Platform.kt`:
// no associated-object lookup, uncached serializer caches, and `isInterface`
// answering false — which is what the upstream tests' platform guards expect.

package kotlinx.serialization.internal

import kotlinx.serialization.KSerializer
import kotlinx.serialization.ReflectiveKSerializer
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.serializer
import kotlin.reflect.KClass
import kotlin.reflect.KType

// The builtin serializer table upstream's `Primitives.kt` reads through
// `initBuiltins()`. klio's stdlib has no unsigned-array / Uuid surface, so
// this covers the primitives, `Unit` and `Nothing` — the entries the
// descriptor-name guard and `builtinSerializerOrNull` are asked about.
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
    Int::class to Int.serializer(),
    IntArray::class to IntArraySerializer(),
    Short::class to Short.serializer(),
    ShortArray::class to ShortArraySerializer(),
    Byte::class to Byte.serializer(),
    ByteArray::class to ByteArraySerializer(),
    Boolean::class to Boolean.serializer(),
    BooleanArray::class to BooleanArraySerializer(),
    Unit::class to Unit.serializer(),
    Nothing::class to NothingSerializer()
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

// klio has no `findAssociatedObject` and no compiler plugin: a generated
// serializer is produced by the interpreter's reflective route instead, so
// there is nothing to look up here.
internal actual fun <T : Any> KClass<T>.constructSerializerForGivenTypeArgs(vararg args: KSerializer<Any?>): KSerializer<T>? =
    null

internal actual fun <T : Any> KClass<T>.compiledSerializerImpl(): KSerializer<T>? = null

internal actual fun <T : Any> KClass<T>.isInterface(): Boolean = false

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

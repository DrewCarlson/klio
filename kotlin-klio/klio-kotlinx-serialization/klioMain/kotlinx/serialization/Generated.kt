// klio's compiler-plugin replacement for kotlinx-serialization.
//
// kotlinx-serialization's plugin synthesizes a KSerializer for every
// @Serializable class. klio generates the same declarations at lowering
// time (src/serialization_pass): the class's companion `serializer(...)`
// and the `<Name>$serializer` object/class implementing GeneratedSerializer
// over a PluginGeneratedSerialDescriptor. What remains here is the LOOKUP
// the platform actuals need — the equivalent of Kotlin/Native's
// findAssociatedObject: reach a class's companion `serializer(...)` from
// its KClass.

package kotlinx.serialization

import kotlin.reflect.KClass

internal fun __klsx_companionSerializer(kClass: Any?, args: List<Any?>): Any? =
    error("intrinsic kotlinx.serialization.__klsx_companionSerializer not installed")

internal fun __klsx_isInterfaceClass(kClass: Any?): Boolean =
    error("intrinsic kotlinx.serialization.__klsx_isInterfaceClass not installed")

/// The generated serializer for `kClass`, or null when the class carries
/// none (not @Serializable, or a shape the generator does not produce).
@Suppress("UNCHECKED_CAST")
internal fun __klsx_generatedSerializer(kClass: KClass<*>): KSerializer<Any>? =
    __klsx_companionSerializer(kClass, emptyList()) as KSerializer<Any>?

@Suppress("UNCHECKED_CAST")
internal fun __klsx_generatedSerializerGeneric(kClass: KClass<*>, args: List<KSerializer<Any?>>): KSerializer<Any>? =
    __klsx_companionSerializer(kClass, args) as KSerializer<Any>?

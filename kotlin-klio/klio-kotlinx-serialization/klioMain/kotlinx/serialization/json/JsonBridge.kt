// klio bridge for a caller that resolves the target type at runtime instead
// of through a reified parameter: ktor's ContentNegotiation shims receive
// the requested response type as a `TypeInfo` and decode by its `KClass`.
// Retires with the shims (plans/serialization-surface-campaign.md Task 3).

package kotlinx.serialization.json

import kotlin.reflect.KClass
import kotlinx.serialization.SerializationException
import kotlinx.serialization.serializerOrNull

public fun Json.decodeToClass(string: String, kClass: KClass<*>): Any? {
    val serializer = kClass.serializerOrNull()
        ?: throw SerializationException("Serializer for class '${kClass.simpleName}' is not found.")
    return decodeFromString(serializer, string)
}

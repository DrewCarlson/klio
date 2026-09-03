// Run with: klio run --feature kotlinx.serialization/json examples/instant_component_serializer.kt
// The library's `InstantComponentSerializer` (an `object` in
// kotlinx.serialization.builtins) encodes a `kotlin.time.Instant` as its
// second and nanosecond components, at top level and as a property's
// `@Serializable(with = …)` — a pack object named in `with =` is referenced,
// never constructed.
import kotlinx.serialization.*
import kotlinx.serialization.builtins.*
import kotlinx.serialization.json.*
import kotlin.time.Instant

@Serializable
data class Event(val name: String, @Serializable(with = InstantComponentSerializer::class) val at: Instant)

fun main() {
    val at = Instant.fromEpochSeconds(1_234_567_890, 42)
    val direct = Json.encodeToString(InstantComponentSerializer, at)
    println(direct)
    println(Json.decodeFromString(InstantComponentSerializer, direct) == at)
    val event = Event("launch", at)
    val text = Json.encodeToString(Event.serializer(), event)
    println(text)
    println(Json.decodeFromString(Event.serializer(), text) == event)
}

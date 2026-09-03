// Run with: klio run --feature kotlinx.serialization/json examples/serializable_local_class_scope.kt
// A `@Serializable` class declared LOCALLY inside a member function resolves
// the types it references against the enclosing class too: `List<E>` reaches
// the nested enum `Holder.E`, so its elements decode as enum names (here with
// case-insensitive matching and an alternative `@JsonNames` spelling), not as
// objects.
import kotlinx.serialization.*
import kotlinx.serialization.json.*

class Holder {
    @Serializable
    enum class E { VALUE_A, @JsonNames("alternative") VALUE_B }

    fun decode(): List<E> {
        val json = Json { decodeEnumsCaseInsensitive = true }
        @Serializable
        data class Outer(val enums: List<E>)
        return json.decodeFromString<Outer>("""{"enums":["Value_A", "alternative", "value_b"]}""").enums
    }
}

fun main() {
    println(Holder().decode())
}

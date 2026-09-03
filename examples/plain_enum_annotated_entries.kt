// Run with: klio run --feature kotlinx.serialization/json examples/plain_enum_annotated_entries.kt
// An enum WITHOUT `@Serializable` serializes in place, and its entries keep
// their serial annotations (`@JsonNames`, `@SerialName`): a property of that
// enum type decodes the alternative names, case-insensitively when asked.
import kotlinx.serialization.*
import kotlinx.serialization.json.*

enum class Level { VALUE_A, @JsonNames("ALTERNATIVE") VALUE_B, @SerialName("top") HIGH }

@Serializable
data class Outer(val levels: List<Level>)

fun main() {
    val j = Json { decodeEnumsCaseInsensitive = true }
    println(j.decodeFromString<Outer>("""{"levels":["value_A", "alternative", "TOP"]}""").levels)
    println(Json.encodeToString(Outer(listOf(Level.VALUE_B, Level.HIGH))))
}

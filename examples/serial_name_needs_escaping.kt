// Run with: klio run --feature kotlinx.serialization/json examples/serial_name_needs_escaping.kt
//
// A serial name that is not a plain identifier (an escaped quote, a
// backslash, a dollar sign, an emoji) still names the JSON key: the
// generated serializer carries the name exactly as the annotation wrote it.

import kotlinx.serialization.*
import kotlinx.serialization.json.*

@Serializable
data class Keys(
    @SerialName("\"") val quote: String,
    @SerialName("back\\slash") val slash: String,
    @SerialName("\$price") val dollar: String,
    @SerialName("🤔?") val thinking: String,
    @SerialName("tab\tsep") val tab: String,
)

@Serializable
@SerialName("outer \"quoted\" name")
data class Named(val v: Int)

fun main() {
    val data = Keys("1", "2", "3", "4", "5")
    val json = Json.encodeToString(Keys.serializer(), data)
    println(json)
    println(Json.decodeFromString(Keys.serializer(), json) == data)
    println(Keys.serializer().descriptor.getElementName(0) == "\"")
    println(Named.serializer().descriptor.serialName)
    val s = """{"\"":"a","back\\slash":"b","${'$'}price":"c","🤔?":"d","tab\tsep":"e"}"""
    println(Json.decodeFromString<Keys>(s))
}

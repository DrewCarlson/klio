// @SerialName wire-name renaming through kotlinx.serialization's Json,
// under every placement kotlinc honors: no use-site target (the LV 2.4
// defaulting puts it on the property anchor — SerialName is
// @Target(PROPERTY, CLASS)), explicit @property:, and the @all:
// meta-target (which expands to the property anchor alone here).
//
// Run with: klio run --feature kotlinx.serialization/json examples/serial_names.kt

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class Person(val name: String, @SerialName("years") val age: Int)

@Serializable
data class Handle(@property:SerialName("first_name") val firstName: String)

@Serializable
data class Alias(@all:SerialName("nick") val nickname: String)

fun main() {
    // Encode emits the renamed key; the property name never leaks.
    val amy = Person("amy", 31)
    val wire = Json.encodeToString(amy)
    println(wire)

    // Decode reads the renamed key back into the property.
    val back = Json.decodeFromString<Person>(wire)
    println(back)
    println(back == amy)

    // Explicit @property: target.
    println(Json.encodeToString(Handle("bo")))
    println(Json.decodeFromString<Handle>("""{"first_name":"kay"}"""))

    // @all: meta-target.
    println(Json.encodeToString(Alias("zed")))
    println(Json.decodeFromString<Alias>("""{"nick":"rem"}"""))
}

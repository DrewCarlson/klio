// Run with: klio run --feature kotlinx.serialization/json examples/serial_encode_defaults.kt
// A property holding its default is not encoded unless `encodeDefaults` or
// `@EncodeDefault` asks for it: also a property named `value` or
// `encoder`, whose default may read another property, and one a sealed
// superclass declares with an initializer.
import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable
private data class Data(val value: Int = 7)

@Serializable
data class Named(val value: Int = 7, val encoder: String = "e", val next: Int = value + 1)

@Serializable
data class B(val s: String? = "foo", val i: Int)

@Serializable
private sealed class F {
    val s: String? = null
}

@Serializable
private data class G(val i: Int) : F()

@OptIn(ExperimentalSerializationApi::class)
fun main() {
    println(Json.encodeToString(Data()))
    println(Json.encodeToString(Data(8)))
    println(Json { encodeDefaults = true }.encodeToString(Data()))
    println(Json.encodeToString(Named()))
    println(Json.encodeToString(Named(value = 1)))
    println(Json.encodeToString(Named(value = 1, next = 2)))
    println(Json.decodeFromString<Named>("{\"value\":3}"))
    println(Json.encodeToString(B(i = 3)))
    println(Json.encodeToString(B(s = "bar", i = 3)))
    println(Json.encodeToString(B(s = null, i = 3)))
    @Serializable data class A(val i: Int = 3)
    println(Json.encodeToString(A()))
    @Serializable data class D(val i: Int = 3, @EncodeDefault(EncodeDefault.Mode.ALWAYS) val s: String? = "foo")
    println(Json.encodeToString(D(i = 5)))
    println(Json.encodeToString<F>(G(i = 3)))
    println(Json.encodeToString(G(i = 3)))
    println(Json.decodeFromString<G>("{\"i\":4}"))
}

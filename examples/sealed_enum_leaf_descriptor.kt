// Run with: klio run --feature kotlinx.serialization/json examples/sealed_enum_leaf_descriptor.kt
// An enum implementing a sealed interface is a leaf of the sealed hierarchy
// without `@Serializable` (the plugin builds its serializer in place), and
// the sealed descriptor lists its subclasses ordered by serial name — so a
// diamond of sealed interfaces reports `[E, X, Y]` for leaves declared X, Y, E.
import kotlinx.serialization.*
import kotlinx.serialization.json.*

@Serializable sealed interface A
@Serializable sealed interface B : A
@Serializable sealed interface C : A
@Serializable @SerialName("X") data class X(val i: Int) : B, C
@Serializable @SerialName("Y") object Y : B, C
@SerialName("E") enum class E : B, C { Q, W }

@Serializable
data class Carrier(val a: A, val b: B, val c: C)

fun main() {
    val subclasses = A.serializer().descriptor.getElementDescriptor(1).elementDescriptors.map { it.serialName }
    println(subclasses)
    val carrier = Carrier(X(1), X(2), Y)
    val text = Json.encodeToString(Carrier.serializer(), carrier)
    println(text)
    println(Json.decodeFromString(Carrier.serializer(), text) == carrier)
}

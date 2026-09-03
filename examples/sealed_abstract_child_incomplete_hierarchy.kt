// Run with: klio run --feature kotlinx.serialization/json examples/sealed_abstract_child_incomplete_hierarchy.kt
// A sealed hierarchy lists its DIRECT subclasses: a sealed child flattens
// in, while an abstract `@Serializable` child stays a leaf with its
// polymorphic serializer. `subclassesOfSealed` therefore rejects the open
// child as an incomplete hierarchy, and the fully sealed sibling registers.
import kotlinx.serialization.*
import kotlinx.serialization.json.*
import kotlinx.serialization.modules.*

abstract class Base

@Serializable
sealed class Closed : Base() {
    @Serializable @SerialName("Leaf") data class Leaf(val n: Int) : Closed()
    @Serializable @SerialName("Inner") sealed class Inner : Closed()
    @Serializable @SerialName("Deep") data class Deep(val s: String) : Inner()
}

@Serializable
sealed class Open : Base() {
    @Serializable @SerialName("OpenLeaf") data class OpenLeaf(val n: Int) : Open()
    @Serializable abstract class Loose : Open()
    @Serializable @SerialName("LooseChild") data class LooseChild(val s: String) : Loose()
}

fun main() {
    val closed = Json { serializersModule = SerializersModule { polymorphic(Base::class) { subclassesOfSealed<Closed>() } } }
    println(closed.encodeToString(PolymorphicSerializer(Base::class), Closed.Deep("x")))
    try {
        Json { serializersModule = SerializersModule { polymorphic(Base::class) { subclassesOfSealed<Open>() } } }
        println("registered open hierarchy")
    } catch (e: IllegalArgumentException) {
        println("rejected: ${e.message?.substringAfter("(")?.substringBefore(")")} incomplete=${e.message?.contains("incomplete hierarchy")}")
    }
}

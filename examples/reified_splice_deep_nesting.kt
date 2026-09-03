// Run with: klio run --feature kotlinx.serialization/json examples/reified_splice_deep_nesting.kt
// A reified inline callee several inline levels deep still splices with its
// own `T`: `subclassesOfSealed<Open>()` inside `assertFailsWith<IAE> { Json {
// SerializersModule { polymorphic(...) { ... } } } }` reads `Open`, not the
// outer `IllegalArgumentException`, so the incomplete hierarchy is reported.
import kotlinx.serialization.*
import kotlinx.serialization.json.*
import kotlinx.serialization.modules.*
import kotlin.test.assertFailsWith

abstract class Base

@Serializable
sealed class Open : Base() {
    @Serializable data class Leaf(val n: Int) : Open()
    @Serializable abstract class Loose : Open()
    @Serializable @SerialName("LooseChild") data class LooseChild(val s: String) : Loose()
}

fun main() {
    val e = assertFailsWith<IllegalArgumentException> {
        Json { serializersModule = SerializersModule { polymorphic(Base::class) { subclassesOfSealed<Open>() } } }
    }
    println("mentions Open: ${e.message?.contains("Open")}, incomplete: ${e.message?.contains("incomplete hierarchy")}")
}

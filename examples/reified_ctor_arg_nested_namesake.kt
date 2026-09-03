// Run with: klio run --feature kotlinx.serialization/json examples/reified_ctor_arg_nested_namesake.kt
// A constructor-call argument to a reified function binds `T` to the class
// resolved IN SCOPE: `Json.encodeToString(Box(1))` inside `Outer` names
// `Outer.Box` (whose custom serializer throws), not the top-level `Box` or
// another class's nested `Box` that share the simple name.
import kotlinx.serialization.*
import kotlinx.serialization.descriptors.*
import kotlinx.serialization.encoding.*
import kotlinx.serialization.json.*

@Serializable
class Box(val x: Int)

class Elsewhere {
    @Serializable
    class Box(val y: String)
    fun encode(): String = Json.encodeToString(Box("nested"))
}

class Outer {
    @Serializable(with = BoxSerializer::class)
    class Box(val i: Int)

    object BoxSerializer : KSerializer<Box> {
        override val descriptor: SerialDescriptor = buildClassSerialDescriptor("Box") { element<Int>("i") }
        override fun serialize(encoder: Encoder, value: Box) { encoder.encodeStructure(descriptor) { throw ArithmeticException("custom serializer ran") } }
        override fun deserialize(decoder: Decoder): Box { decoder.decodeStructure(descriptor) { throw ArithmeticException("custom serializer ran") } }
    }

    fun encode(): String = try { Json.encodeToString(Box(1)) } catch (e: ArithmeticException) { e.message ?: "?" }
}

fun main() {
    println(Json.encodeToString(Box(7)))
    println(Elsewhere().encode())
    println(Outer().encode())
}

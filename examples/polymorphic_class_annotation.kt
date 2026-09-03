// Run with: klio run --feature kotlinx.serialization/json examples/polymorphic_class_annotation.kt
// `@Polymorphic` on a CLASS declaration makes every property of that type
// serialize polymorphically, exactly as the annotation on the property does:
// an open class so annotated encodes its runtime subclass with the type tag,
// while the same shape without the annotation encodes statically.
import kotlinx.serialization.*
import kotlinx.serialization.json.*
import kotlinx.serialization.modules.*

@Polymorphic
@Serializable
@SerialName("Shape")
open class Shape { open val sides: Int = 0 }

@Serializable
@SerialName("Square")
class Square(val size: Int) : Shape() { override val sides: Int get() = 4 }

@Serializable
@SerialName("Plain")
open class Plain(val label: String)

@Serializable
class Tagged(val name: String) : Plain("tagged")

@Serializable
data class Scene(val shape: Shape, val plain: Plain)

fun main() {
    val module = SerializersModule {
        polymorphic(Shape::class) { subclass(Square.serializer()) }
    }
    val json = Json { serializersModule = module; useArrayPolymorphism = true; encodeDefaults = true }
    val scene = Scene(Square(3), Tagged("t"))
    val encoded = json.encodeToString(Scene.serializer(), scene)
    println(encoded)
    val back = json.decodeFromString(Scene.serializer(), encoded)
    println("${back.shape::class.simpleName} sides=${back.shape.sides} plain=${back.plain.label}")
}

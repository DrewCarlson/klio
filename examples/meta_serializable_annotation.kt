// `@MetaSerializable` lifts an annotation into a `@Serializable` marker: a
// class annotated with the meta-annotated annotation is serializable exactly
// as if it wrote `@Serializable`, and the annotation itself (arguments
// included, class literals too) is retained on the descriptor.
//
// Run with: klio run examples/meta_serializable_annotation.kt

import kotlinx.serialization.MetaSerializable
import kotlinx.serialization.serializer
import kotlin.reflect.KClass

@MetaSerializable
@Target(AnnotationTarget.CLASS, AnnotationTarget.PROPERTY)
annotation class Schema(val version: Int, val root: KClass<*>)

@Schema(3, String::class)
class Payload(val body: String, val size: Int)

fun main() {
    val s = serializer<Payload>()
    val d = s.descriptor
    println("name     = " + d.serialName)
    println("elements = " + d.elementsCount)
    val schema = d.annotations.filterIsInstance<Schema>().first()
    println("version  = " + schema.version)
    println("root     = " + schema.root)
}

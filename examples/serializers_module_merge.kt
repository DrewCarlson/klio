// Combining two `SerializersModule`s copies each registration through
// `SerializersModuleCollector`. The collector's `contextual(kClass, serializer)`
// has a DEFAULT body that forwards to the provider overload, so a builder that
// overrides it must run its own body — otherwise every copied serializer is
// re-registered as an anonymous provider and two modules holding the same
// serializer collide.
//
// Run with: klio run examples/serializers_module_merge.kt

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.serializer
import kotlinx.serialization.modules.SerializersModule
import kotlinx.serialization.modules.overwriteWith
import kotlinx.serialization.modules.plus
import kotlinx.serialization.modules.serializersModuleOf

@Serializable
class Point(val x: Int, val y: Int)

@Serializable
class Tag(val name: String)

fun main() {
    val points = SerializersModule { contextual(Point::class, Point.serializer()) }
    val tags = SerializersModule { contextual(Tag::class, Tag.serializer()) }

    val both = points + tags
    println("point = " + both.getContextual(Point::class)?.descriptor?.serialName)
    println("tag   = " + both.getContextual(Tag::class)?.descriptor?.serialName)

    // The same serializer registered twice is the same registration, not a
    // conflict: the copy must arrive as a serializer, not as a fresh provider.
    val again = points + points
    println("again = " + again.getContextual(Point::class)?.descriptor?.serialName)

    val overwritten = points overwriteWith serializersModuleOf(Point::class, Point.serializer())
    println("over  = " + overwritten.getContextual(Point::class)?.descriptor?.serialName)
}

// `@Serializer(forClass = C::class)` asks the kotlinx plugin to write the
// declaration's whole body from `C`: its descriptor and its `serialize` /
// `deserialize` are `C`'s own. A declaration marked that way therefore serves
// as `C`'s serializer everywhere a serializer is expected.
//
// Run with: klio run examples/serializer_for_class.kt

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.Serializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.modules.SerializersModule
import kotlinx.serialization.modules.polymorphic
import kotlinx.serialization.modules.subclass
import kotlinx.serialization.modules.serializersModuleOf

@Serializable
class Config(val host: String, val port: Int)

@Serializer(forClass = Config::class)
object ConfigSerializer : KSerializer<Config>

interface Message

fun main() {
    println("name     = " + ConfigSerializer.descriptor.serialName)
    println("elements = " + ConfigSerializer.descriptor.elementsCount)
    println("first    = " + ConfigSerializer.descriptor.getElementName(0))

    val module = serializersModuleOf(Config::class, ConfigSerializer)
    println("same     = " + (module.getContextual(Config::class) === ConfigSerializer))

    // A polymorphic registration through the reified `subclass(serializer)`
    // reads the subclass off the serializer's own type argument.
    val ints = object : KSerializer<Int> by Int.serializer() {}
    val poly = SerializersModule {
        polymorphic(Any::class) { subclass(ints) }
    }
    println("byValue  = " + (poly.getPolymorphic(Any::class, 42) === ints))
    println("byName   = " + (poly.getPolymorphic(Any::class, "kotlin.Int") === ints))
}

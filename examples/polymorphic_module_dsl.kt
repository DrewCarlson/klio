// The polymorphic module DSL's reified `subclass` overloads: a class literal
// selects `subclass(clazz)` (its `T` read off the literal), a companion
// serializer factory selects `subclass(serializer)` (its `T` read off the
// factory's receiver), and both register under the base with the value and
// the serial name reachable. A plain interface serializes OPEN; a class
// annotated `@Polymorphic` is forced OPEN over its own generated serializer.
//
// Run with: klio run examples/polymorphic_module_dsl.kt

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Polymorphic
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PolymorphicKind
import kotlinx.serialization.modules.SerializersModule
import kotlinx.serialization.modules.polymorphic
import kotlinx.serialization.modules.subclass
import kotlinx.serialization.serializer

interface Plain

@Serializable
@Polymorphic
sealed interface Forced

@Serializable
open class PolyBase(val id: Int) : Forced

@Serializable
data class PolyDerived(val s: String) : PolyBase(1), Plain

@Serializable
class Holder(val p: Plain, val f: Forced)

fun main() {
    val module = SerializersModule {
        polymorphic(Any::class) {
            subclass(PolyBase::class)
            subclass(PolyDerived.serializer())
        }
    }
    println("base    = " + (module.getPolymorphic(Any::class, PolyBase(10)) != null))
    println("derived = " + (module.getPolymorphic(Any::class, PolyDerived("x")) != null))
    println("byName  = " + (module.getPolymorphic(Any::class, serializedClassName = "PolyDerived") != null))

    val d = serializer<Holder>().descriptor
    println("plain   = " + (d.getElementDescriptor(0).kind == PolymorphicKind.OPEN))
    println("forced  = " + (d.getElementDescriptor(1).kind == PolymorphicKind.OPEN))
}

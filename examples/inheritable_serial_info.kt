// `@SerialInfo` marks an annotation the descriptor reports for the declaration
// it is written on. `@InheritableSerialInfo` marks one the descriptor ALSO
// reports when a supertype carries it — through a superclass, an interface, or
// a whole sealed hierarchy — and reports once however many supertypes agree.
//
// Run with: klio run examples/inheritable_serial_info.kt

import kotlinx.serialization.*

@InheritableSerialInfo
annotation class Discriminator(val value: String)

@SerialInfo
annotation class Local(val value: String)

@Discriminator("a")
interface Tagged

@Discriminator("a")
interface AlsoTagged

@Discriminator("a")
@Serializable
abstract class Base : Tagged

@Serializable
sealed class Middle : Base(), AlsoTagged

@Serializable
class FromSealed : Middle()

@Serializable
class FromAbstract : Base()

@Serializable
class FromInterfaces : Tagged, AlsoTagged

// A non-inheritable annotation stays on the declaration that carries it.
@Local("own")
@Serializable
class WithLocal : Base()

@Serializable
class Untagged(val n: Int)

fun annotationsOf(s: KSerializer<*>): List<Annotation> = s.descriptor.annotations

fun names(s: KSerializer<*>): String =
    annotationsOf(s).map { it::class.simpleName }.sorted().toString()

fun discriminators(s: KSerializer<*>): String =
    annotationsOf(s).filterIsInstance<Discriminator>().map { it.value }.toString()

fun main() {
    println("sealed     = " + discriminators(FromSealed.serializer()))
    println("abstract   = " + discriminators(FromAbstract.serializer()))
    println("interfaces = " + discriminators(FromInterfaces.serializer()))
    // Reported once, not once per supertype that carries it.
    println("count      = " + annotationsOf(FromSealed.serializer())
        .filterIsInstance<Discriminator>().size)

    // An own `@SerialInfo` annotation and an inherited one coexist.
    println("withLocal  = " + names(WithLocal.serializer()))
    println("localValue = " + annotationsOf(WithLocal.serializer())
        .filterIsInstance<Local>().map { it.value })

    // A declaration outside the hierarchy inherits nothing.
    println("untagged   = " + annotationsOf(Untagged.serializer()).size)
}

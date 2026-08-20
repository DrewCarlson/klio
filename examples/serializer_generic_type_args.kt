// A `@Serializable` class with type parameters gets a `serializer(...)` that
// takes one serializer per type argument. Those arguments decide the descriptor
// each type-parameter-typed element reports, and two descriptors are equal
// exactly when their serial names, type arguments and elements agree.
//
// Run with: klio run examples/serializer_generic_type_args.kt

import kotlinx.serialization.*
import kotlinx.serialization.builtins.*
import kotlinx.serialization.descriptors.*

@Serializable
class Box<T>(val value: T)

@Serializable
@SerialName("Pair2")
class Pair2<A, B>(val first: A, val second: B)

@Serializable
class Holder<T>(val items: List<T>)

@Serializable
class Plain(val n: Int, val s: String)

fun main() {
    val boxInt = Box.serializer(Int.serializer()).descriptor
    val boxInt2 = Box.serializer(Int.serializer()).descriptor
    val boxStr = Box.serializer(String.serializer()).descriptor

    println("name       = " + boxInt.serialName)
    println("elements   = " + boxInt.elementsCount)
    println("elem name  = " + boxInt.getElementName(0))
    println("elem int   = " + boxInt.getElementDescriptor(0).serialName)
    println("elem str   = " + boxStr.getElementDescriptor(0).serialName)

    // Same type argument, separate calls: equal descriptors.
    println("same args  = " + (boxInt == boxInt2))
    println("hash match = " + (boxInt.hashCode() == boxInt2.hashCode()))
    println("diff args  = " + (boxInt == boxStr))

    // Two type parameters, matched positionally.
    val p = Pair2.serializer(Int.serializer(), String.serializer()).descriptor
    println("pair name  = " + p.serialName)
    println("pair elems = " + p.getElementDescriptor(0).serialName + "," + p.getElementDescriptor(1).serialName)
    println("pair flip  = " + (p == Pair2.serializer(String.serializer(), Int.serializer()).descriptor))

    // An element whose declared type only MENTIONS the type parameter is not
    // itself described by the argument, but the argument still separates the
    // two descriptors.
    val hInt = Holder.serializer(Int.serializer()).descriptor
    val hStr = Holder.serializer(String.serializer()).descriptor
    println("holder eq  = " + (hInt == hStr))
    println("holder self= " + (hInt == Holder.serializer(Int.serializer()).descriptor))

    // A class with no type parameters keeps the plain zero-argument form, and
    // its serializer stays a single cached instance.
    val a = Plain.serializer()
    val b = Plain.serializer()
    println("plain same = " + (a === b))
    println("plain name = " + a.descriptor.serialName)
    println("plain elems= " + a.descriptor.getElementDescriptor(0).serialName + "," +
        a.descriptor.getElementDescriptor(1).serialName)
    println("cross eq   = " + (a.descriptor == boxInt))
}

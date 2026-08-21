import kotlinx.serialization.*
import kotlinx.serialization.builtins.*
import kotlinx.serialization.descriptors.*

@Serializable
class TypeParamUsedOnce<T>(val t: T)

@Serializable
class TypeParamInList<T>(val l: List<T>)

fun main() {
    val a = TypeParamUsedOnce.serializer(Int.serializer()).descriptor
    val b = TypeParamUsedOnce.serializer(Int.serializer()).descriptor
    val c = TypeParamUsedOnce.serializer(String.serializer()).descriptor
    println("a==b " + (a == b))
    println("a==c " + (a == c))
    println("a " + a + " elem0=" + a.getElementDescriptor(0).serialName)
    println("c elem0=" + c.getElementDescriptor(0).serialName)

    val d = TypeParamInList.serializer(Int.serializer()).descriptor
    val e = TypeParamInList.serializer(String.serializer()).descriptor
    println("d==e " + (d == e))
}

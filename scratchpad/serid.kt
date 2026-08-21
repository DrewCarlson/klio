import kotlinx.serialization.*
import kotlinx.serialization.modules.*

@Serializable
class A(val i: Int)

fun main() {
    val s1 = A.serializer()
    val s2 = A.serializer()
    println("same = " + (s1 === s2) + " eq = " + (s1 == s2))
    val m1 = serializersModuleOf(A::class, A.serializer())
    val m2 = serializersModuleOf(A::class, A.serializer())
    val agg = m1 + m2
    println("agg = " + agg.getContextual(A::class))
}

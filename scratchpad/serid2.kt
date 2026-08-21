import kotlinx.serialization.*
import kotlinx.serialization.modules.*

@Serializable
class A(val i: Int)

fun main() {
    val m1 = SerializersModule { contextual(A::class, A.serializer()) }
    val m2 = SerializersModule { contextual(A::class, A.serializer()) }
    println("direct ok")
    val agg = m1 + m2
    println("agg = " + agg.getContextual(A::class))
}

import kotlinx.serialization.*

@SerialInfo annotation class P(val value: String)
@SerialInfo annotation class Q(val value: String)

@P("p") @Q("q") @Serializable class T(val n: Int)

fun main() {
    val anns = T.serializer().descriptor.annotations
    println("all = " + anns.map { it::class.simpleName })
    println("P   = " + anns.filterIsInstance<P>().map { it.value })
    println("Q   = " + anns.filterIsInstance<Q>().map { it.value })
    println("isP = " + anns.map { it is P })
    println("isQ = " + anns.map { it is Q })
}

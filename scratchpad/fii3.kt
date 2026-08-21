import kotlinx.serialization.*
@SerialInfo annotation class P(val value: String)
@SerialInfo annotation class Q(val value: String)
@P("p") @Q("q") @Serializable class T(val n: Int)

fun main() {
    val anns: List<Annotation> = T.serializer().descriptor.annotations
    println("manual = " + anns.filter { it is P }.map { (it as P).value })
    println("fii    = " + anns.filterIsInstance<P>().map { it.value })
    val plain: List<Any> = anns
    println("plainF = " + plain.filterIsInstance<P>().size)
    val direct = listOf<Any>(P("x"), Q("y"))
    println("direct = " + direct.filterIsInstance<P>().size)
}

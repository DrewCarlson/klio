interface WithT {
    fun frac(minLength: Int = 1, maxLength: Int = 9)
    fun frac(fixedLength: Int) { frac(fixedLength, fixedLength) }
}
interface AbstractWithT : WithT {
    val sink: StringBuilder
    override fun frac(minLength: Int, maxLength: Int) { sink.append("[$minLength,$maxLength]") }
}
class Builder(override val sink: StringBuilder) : AbstractWithT

fun build(block: WithT.() -> Unit): String {
    val sb = StringBuilder()
    Builder(sb).block()
    return sb.toString()
}

fun main() {
    println("1 = " + build { frac(3) })
    println("2 = " + build { frac(fixedLength = 3) })
    println("3 = " + build { frac(3) })
    println("4 = " + build { frac(1, 9) })
}

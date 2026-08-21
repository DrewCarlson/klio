interface FormatBuilder<T, Self : FormatBuilder<T, Self>> {
    fun createEmpty(): Self
    fun add(s: String)
}

interface DateTimeFormatBuilder {
    interface WithTime : DateTimeFormatBuilder {
        fun frac(minLength: Int = 1, maxLength: Int = 9)
        fun frac(fixedLength: Int) { frac(fixedLength, fixedLength) }
    }
}

interface AbstractWithTimeBuilder : DateTimeFormatBuilder.WithTime, FormatBuilder<String, AbstractWithTimeBuilder> {
    val sink: StringBuilder
    override fun frac(minLength: Int, maxLength: Int) { sink.append("[$minLength,$maxLength]") }
    override fun add(s: String) { sink.append(s) }
}

class B2(override val sink: StringBuilder) : AbstractWithTimeBuilder {
    override fun createEmpty(): AbstractWithTimeBuilder = B2(StringBuilder())
}

fun build(block: DateTimeFormatBuilder.WithTime.() -> Unit): String {
    val sb = StringBuilder()
    B2(sb).block()
    return sb.toString()
}

fun main() {
    println("1 = " + build { frac(3) })
    println("2 = " + build { frac(fixedLength = 3) })
    println("3 = " + build { frac(3) })
}

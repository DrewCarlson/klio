class Holder(val n: Int) {
    inline fun eachInline(block: (Int) -> Unit) { for (i in 0 until n) block(i) }
    fun eachPlain(block: (Int) -> Unit) { for (i in 0 until n) block(i) }

    fun inlineInWith(): String {
        val sb = StringBuilder()
        with(sb) { eachInline { sb.append(it) } }
        return sb.toString()
    }
    fun plainInWith(): String {
        val sb = StringBuilder()
        with(sb) { eachPlain { sb.append(it) } }
        return sb.toString()
    }
    fun inlineBare(): String {
        val sb = StringBuilder()
        eachInline { sb.append(it) }
        return sb.toString()
    }
    fun inlineInApply(): String {
        val sb = StringBuilder()
        sb.apply { eachInline { sb.append(it) } }
        return sb.toString()
    }
}

fun main() {
    val h = Holder(4)
    println("inlineBare    = '" + h.inlineBare() + "'  (expect 0123)")
    println("plainInWith   = '" + h.plainInWith() + "'  (expect 0123)")
    println("inlineInApply = '" + h.inlineInApply() + "'  (expect 0123)")
    println("inlineInWith  = '" + h.inlineInWith() + "'  (expect 0123)")
}

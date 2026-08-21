class Holder {
    private fun List<String>.tag(): String = "<" + joinToString(",") + ">"

    fun <T> passthrough(x: T): T = x
    fun viaGeneric(): String {
        val g = passthrough(listOf("a", "b"))
        return g.tag()
    }
    fun viaAnyNoCast(a: Any): String {
        if (a is List<*>) {
            @Suppress("UNCHECKED_CAST")
            return (a as List<String>).tag()
        }
        return "-"
    }
    fun viaNullable(l: List<String>?): String = l!!.tag()
}

fun main() {
    val h = Holder()
    println("generic  = " + h.viaGeneric())
    println("smartcast= " + h.viaAnyNoCast(listOf("z")))
    println("nullable = " + h.viaNullable(listOf("n")))
}

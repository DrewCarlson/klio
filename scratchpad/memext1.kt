class Holder(val items: List<String>) {
    private fun List<String>.getFirstUpper(): String = first().uppercase()
    private fun List<String>.tagged(p: String): String = p + joinToString("-")

    fun run(): String {
        val a = items.getFirstUpper()
        val b = listOf("x", "y").getFirstUpper()
        val c = items.tagged("t:")
        return "$a $b $c"
    }

    private fun indirect(l: List<String>): String = l.getFirstUpper()
    fun runIndirect(): String = indirect(items)
}

fun main() {
    val h = Holder(listOf("ab", "cd"))
    println(h.run())
    println(h.runIndirect())
}

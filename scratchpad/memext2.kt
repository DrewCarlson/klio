class Holder {
    private fun List<String>.getCustom(): String = "[" + joinToString(",") + "]"

    fun viaArray(a: Array<String>): String = a.asList().getCustom()
    fun viaEmpty(): String = emptyList<String>().getCustom()
    fun viaListOf(): String = listOf("a").getCustom()
    fun viaField(l: List<String>): String = l.getCustom()
}

class Box(val anns: List<String>)

fun main() {
    val h = Holder()
    println("listOf = " + h.viaListOf())
    println("empty  = " + h.viaEmpty())
    println("array  = " + h.viaArray(arrayOf("p", "q")))
    println("box    = " + h.viaField(Box(arrayOf("z").asList()).anns))
}

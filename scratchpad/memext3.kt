@Target(AnnotationTarget.CLASS)
annotation class CA(val value: String)

class Holder {
    private fun List<Annotation>.getCustom(): String = "n=" + size
    private fun List<String>.getPlain(): String = "s=" + size

    fun runAnn(l: List<Annotation>): String = l.getCustom()
    fun runStr(l: List<String>): String = l.getPlain()
}

fun main() {
    val h = Holder()
    println("str = " + h.runStr(listOf("a")))
    println("ann = " + h.runAnn(emptyList()))
    println("cls = " + emptyList<Annotation>()::class.simpleName)
    println("cls2 = " + listOf("a")::class.simpleName)
}

interface Src { val items: List<String> }
class RealSrc(override val items: List<String>) : Src

class Holder {
    private fun List<String>.tag(): String = "<" + joinToString(",") + ">"

    fun viaInterface(s: Src): String = s.items.tag()
    fun viaLocal(): String {
        val l: List<String> = listOf("a")
        return l.tag()
    }
    fun viaAny(a: Any): String = (a as List<String>).tag()
}

fun main() {
    val h = Holder()
    println("local = " + h.viaLocal())
    println("iface = " + h.viaInterface(RealSrc(listOf("p", "q"))))
    println("any   = " + h.viaAny(listOf("z")))
}

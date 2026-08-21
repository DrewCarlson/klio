import kotlin.math.abs

class T4 {
    fun typed(): String {
        fun Int.pad() = toString().padStart(2, '0')
        val h: Int = abs(-5)
        return h.pad()
    }
    fun untyped(): String {
        fun Int.pad() = toString().padStart(2, '0')
        val h = abs(-5)
        return h.pad()
    }
    fun direct(): String {
        fun Int.pad() = toString().padStart(2, '0')
        return abs(-5).pad()
    }
    fun viaOther(): String {
        fun Int.pad() = toString().padStart(2, '0')
        val h = "12".length
        return h.pad()
    }
}
fun main() {
    val t = T4()
    println("typed   = " + t.typed())
    println("untyped = " + t.untyped())
    println("direct  = " + t.direct())
    println("viaOther= " + t.viaOther())
}

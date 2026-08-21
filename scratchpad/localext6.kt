import kotlin.math.abs

class T3 {
    private val range = (-3661..3661 step 1831)

    fun run1(): String {
        fun Int.pad() = toString().padStart(2, '0')
        var out = ""
        for (total in range) out += "${total.pad()};"
        return out
    }

    fun run2(): String {
        fun Int.pad() = toString().padStart(2, '0')
        var out = ""
        for (total in range) {
            val hours = abs(total / 3600)
            out += "${hours.pad()};"
        }
        return out
    }

    fun run3(): String {
        fun Int.pad() = toString().padStart(2, '0')
        fun sink(s: String, flag: Boolean = false) { }
        var out = ""
        for (total in range) {
            sink("${total.pad()}", flag = total != 0)
            out += "."
        }
        return out
    }
}

fun main() {
    val t = T3()
    println("1=" + t.run1())
    println("2=" + t.run2())
    println("3=" + t.run3())
}

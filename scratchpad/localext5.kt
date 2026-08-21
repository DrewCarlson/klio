class T {
    val range = listOf(1, 22)

    fun a(): String {
        fun Int.pad() = toString().padStart(2, '0')
        return 5.pad()
    }

    fun b(): String {
        fun Int.pad() = toString().padStart(2, '0')
        return range.joinToString(",") { it.pad() }
    }

    fun c(): String {
        fun Int.pad() = toString().padStart(2, '0')
        var s = ""
        for (x in range) s += "${x.pad()};"
        return s
    }

    fun d(): String {
        fun Int.pad() = toString().padStart(2, '0')
        fun use(n: Int): String = "${n.pad()}"
        return use(7)
    }
}

fun main() {
    val t = T()
    println("a=" + t.a())
    println("b=" + t.b())
    println("c=" + t.c())
    println("d=" + t.d())
}

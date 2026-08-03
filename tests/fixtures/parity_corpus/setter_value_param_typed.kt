class Gauge {
    var level: Int = 1
        set(value) {
            if (value <= 0) throw IllegalArgumentException("bad $value")
            field = value + value.countTrailingZeroBits()
        }

    var label: String = "x"
        set(value) {
            field = value.uppercase()
        }
}

fun main() {
    val g = Gauge()
    g.level = 4
    println(g.level)
    g.label = "hi"
    println(g.label)
    try {
        g.level = 0
    } catch (e: IllegalArgumentException) {
        println(e.message)
    }
}

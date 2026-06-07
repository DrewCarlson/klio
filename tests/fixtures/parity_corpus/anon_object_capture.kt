fun build(): Int {
    val base = 100
    val o = object {
        fun shifted(by: Int): Int = base + by
    }
    return o.shifted(5)
}

fun main() {
    println(build())
}

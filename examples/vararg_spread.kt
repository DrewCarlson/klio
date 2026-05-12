fun total(vararg ns: Int): Int {
    var s = 0
    for (n in ns) {
        s += n
    }
    return s
}

fun main() {
    val rest = IntArray(3) { it + 3 }
    println(total(1, 2, *rest, 6))
}

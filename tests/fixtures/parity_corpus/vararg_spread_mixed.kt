fun show(vararg ns: Int) {
    var sum = 0
    for (n in ns) {
        sum += n
    }
    println(sum)
    println(ns.size)
}

fun main() {
    val middle = IntArray(2) { it + 3 }
    show(1, 2, *middle, 5)
}

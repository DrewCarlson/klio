fun show(vararg ns: Int) {
    var sum = 0
    for (n in ns) {
        sum += n
    }
    println(sum)
    println(ns.size)
}

fun main() {
    val arr = IntArray(3) { it + 3 }
    show(*arr)
}

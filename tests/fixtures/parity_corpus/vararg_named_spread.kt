fun show(x: Int, vararg ns: Int) {
    print(x)
    for (n in ns) {
        print(":")
        print(n)
    }
    println()
}

fun main() {
    val a: IntArray = IntArray(2) { it + 2 }
    show(x = 1, ns = *a)
}

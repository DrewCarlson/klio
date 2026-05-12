fun caller(): Int {
    val f = fun(x: Int): Int {
        if (x > 0) return x * 2
        return -1
    }
    println(f(5))
    println(f(-3))
    return 99
}

fun main() {
    println(caller())
}

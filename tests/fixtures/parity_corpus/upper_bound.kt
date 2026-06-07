fun <T : Comparable<T>> maxOfPair(a: T, b: T): T = if (a >= b) a else b

fun main() {
    println(maxOfPair(3, 9))
    println(maxOfPair("alpha", "omega"))
}

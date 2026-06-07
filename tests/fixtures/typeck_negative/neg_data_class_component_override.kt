data class Pair2(val a: Int, val b: Int) {
    operator fun component1(): Int = a
}

fun main() {
    println(Pair2(1, 2))
}

data class Pair2(val a: Int, val b: Int) {
    fun copy(a: Int = this.a, b: Int = this.b): Pair2 = Pair2(a, b)
}

fun main() {
    println(Pair2(1, 2))
}

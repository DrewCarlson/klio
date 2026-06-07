value class Boxed(val x: Int) {
    init {
        require(x >= 0)
    }
}

fun main() {
    println(Boxed(1))
}

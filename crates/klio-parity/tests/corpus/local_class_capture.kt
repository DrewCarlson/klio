fun build(): Int {
    val factor = 7
    class Mul(val n: Int) {
        fun product(): Int = n * factor
    }
    return Mul(6).product()
}

fun main() {
    println(build())
}

const val PI: Double = 3.14
const val GREETING: String = "hello"
const val ANSWER: Int = 40 + 2
const val DERIVED: Int = ANSWER * 2

object Config {
    const val VERSION: String = "1.0"
}

fun main() {
    println(PI)
    println(GREETING)
    println(ANSWER)
    println(DERIVED)
    println(Config.VERSION)
}

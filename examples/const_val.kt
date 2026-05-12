const val PI: Double = 3.14
const val GREETING: String = "hello"
const val ANSWER: Int = 40 + 2
const val MESSAGE: String = "answer is $ANSWER"

object Config {
    const val VERSION: String = "1.0"
    const val MAX: Int = 100
}

fun main() {
    println(PI)
    println(GREETING)
    println(ANSWER)
    println(MESSAGE)
    println(Config.VERSION)
    println(Config.MAX)
}

fun main() {
    require(1 < 2)
    check(true)
    val v: String? = "hello"
    val nn = requireNotNull(v)
    println(nn)
    val nn2 = checkNotNull(v)
    println(nn2)
    try {
        require(false) { "bad input" }
    } catch (e: IllegalArgumentException) {
        println("caught: ${e.message}")
    }
    try {
        check(false) { "bad state" }
    } catch (e: IllegalStateException) {
        println("caught: ${e.message}")
    }
    try {
        error("boom")
    } catch (e: IllegalStateException) {
        println("caught: ${e.message}")
    }
    val n: Int? = null
    try {
        requireNotNull(n) { "must not be null" }
    } catch (e: IllegalArgumentException) {
        println("rnn: ${e.message}")
    }
    repeat(3) { i ->
        println("loop $i")
    }
}

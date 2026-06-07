class Producer<out T> {
    fun consume(item: T) {
        println(item)
    }
}

fun main() {
    val p = Producer<String>()
    p.consume("x")
}

class Producer<out T>(val item: T) {
    fun get(): T = item
}

fun main() {
    val ints: Producer<Int> = Producer(7)
    val any: Producer<Any> = ints
    println(any.get())
}

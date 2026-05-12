// M28 declaration-site variance.
class Producer<out T>(val item: T) {
    fun get(): T = item
}

class Sink<in T> {
    fun accept(item: T) {
        println(item)
    }
}

fun main() {
    val ints: Producer<Int> = Producer(7)
    // Producer<Int> is a subtype of Producer<Any> because T is `out`.
    val any: Producer<Any> = ints
    println(any.get())

    val anySink: Sink<Any> = Sink()
    // Sink<Any> is a subtype of Sink<Int> because T is `in`.
    val intSink: Sink<Int> = anySink
    intSink.accept(42)
}

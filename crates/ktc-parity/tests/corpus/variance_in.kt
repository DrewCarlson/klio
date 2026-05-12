class Sink<in T> {
    fun accept(item: T) {
        println(item)
    }
}

fun main() {
    val anySink: Sink<Any> = Sink()
    val intSink: Sink<Int> = anySink
    intSink.accept(42)
}

// A bare call inside a scope whose subject is a function value must keep
// walking to the outer receiver that really serves the name: `forEach`
// here belongs to the Iterable receiver, never to the closure subject.
fun <T> Iterable<T>.emitEach(action: (T) -> Unit) {
    with(action) { forEach { this(it) } }
}
fun main() {
    listOf(1, 2, 3).emitEach { println("v" + it) }
}

fun runIt(crossinline block: () -> Unit) {
    block()
}

fun main() {
    runIt { println("hi") }
}

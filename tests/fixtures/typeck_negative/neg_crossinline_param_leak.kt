var stored: (() -> Unit)? = null

inline fun runIt(crossinline action: () -> Unit) {
    stored = action
    action()
}

fun main() {
    runIt { println("hi") }
}

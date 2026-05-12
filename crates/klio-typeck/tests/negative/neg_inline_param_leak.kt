var stored: (() -> Unit)? = null

inline fun runIt(action: () -> Unit) {
    stored = action
    action()
}

fun main() {
    runIt { println("hi") }
}

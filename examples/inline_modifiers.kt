// M28 inline / crossinline parameter modifiers.
inline fun runThree(crossinline action: (Int) -> Unit) {
    action(1)
    action(2)
    action(3)
}

fun main() {
    runThree { i -> println(i) }
}

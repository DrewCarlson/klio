import kotlin.properties.Delegates

var label: String by Delegates.notNull<String>()

fun main() {
    try {
        println(label)
    } catch (e: IllegalStateException) {
        println("caught: ${e.message}")
    }
    label = "hi"
    println(label)
}

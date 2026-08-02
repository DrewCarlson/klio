class Screen
class Validator(val tag: String)

fun withScreen(block: Screen.() -> String): String = Screen().block()

fun Validator.describe(): String = "top-ext:" + tag

fun main() {
    fun Validator.render(): String = withScreen { describe() }
    println(Validator("z").render())
    // Explicit label through a nested lambda inside a local extension fn.
    fun Validator.labeled(): String = withScreen { this@labeled.tag }
    println(Validator("w").labeled())
}

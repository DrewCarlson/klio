class Greeter(val name: String) {
    fun hello(): String = "hi $name"
    fun shout(s: String): String = "$s!"
}

fun main() {
    val g = Greeter("Drew")
    val r: () -> String = g::hello
    println(r())
    val s: (String) -> String = g::shout
    println(s("hey"))
}

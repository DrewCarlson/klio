class Module(val tag: String)

fun lookup(name: String): String = "global:$name"
fun Module.lookup(name: String): String = "module($tag):$name"

fun Module.find(name: String): String = lookup(name)

inline fun <reified T> Module.findReified(): String = lookup(T::class.simpleName ?: "?")

fun main() {
    val m = Module("m1")
    println(m.find("a"))
    println(m.findReified<String>())
}

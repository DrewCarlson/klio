class Module(val tag: String)

fun lookup(name: String): String = "global:$name"
fun Module.lookup(name: String): String = "module($tag):$name"

fun Module.findPlain(name: String): String = lookup(name)
inline fun Module.findInline(name: String): String = lookup(name)
inline fun <reified T> Module.findReified(name: String): String = lookup(name)

fun main() {
    val m = Module("m1")
    println("plain   = " + m.findPlain("a"))
    println("inline  = " + m.findInline("a"))
    println("reified = " + m.findReified<String>("a"))
}

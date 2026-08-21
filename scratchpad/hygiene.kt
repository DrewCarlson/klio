fun builder(body: () -> String): String = "built(" + body() + ")"

inline fun wrap(s: String): String = builder { s }

fun useClean(): String = wrap("x")

fun useShadowed(): String {
    val builder = 42          // a local with the same name as the global fn
    return wrap("x") + "/" + builder
}

fun main() {
    println("clean    = " + useClean())
    println("shadowed = " + runCatching { useShadowed() }.getOrElse { "ERR " + it.message })
}

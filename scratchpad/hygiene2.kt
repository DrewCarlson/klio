class Box(val n: Int)

fun builder(body: () -> Int): Box = Box(body())

inline fun mid(v: Int): Box = builder { v }          // level 2: calls the global
inline fun outer(v: Int): Box = mid(v + 1)           // level 1: splices mid

fun clean(): Int = outer(1).n

fun shadowed(): Int {
    val builder = Box(99)                            // local shadows the global fn
    return outer(1).n + builder.n
}

fun main() {
    println("clean    = " + clean())
    println("shadowed = " + runCatching { shadowed() }.getOrElse { "ERR " + it.message })
}

class Box(val n: Int)

fun box(body: () -> Int): Box = Box(body())

inline fun mid(v: Int): Box = box { v }
inline fun outer(v: Int): Box = mid(v + 1)

fun main() {
    println("clean = " + outer(1).n)
    val box = Box(99)            // same name AND same type as box()'s result
    println("shadowed = " + runCatching { outer(1).n }.getOrElse { "ERR " + it.message } + " local=" + box.n)
}

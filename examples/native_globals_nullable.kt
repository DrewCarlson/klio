// Top-level properties and nullable references compiled to C. A global is a
// root for the life of the program, not a frame slot, and its initializer runs
// before `main` in declaration order. A field read through a null reference
// raises the same NullPointerException the interpreter would.
class Box(val v: Int)

// An `object` declaration is one instance, built before the program runs and
// rooted for its whole life.
object Registry {
    val label = "reg"
    var hits = 0
}

val greeting = "hi"
var counter = 0
val limit = 3

fun bump(): Int {
    counter = counter + 1
    return counter
}

fun pick(b: Box?): Int = if (b == null) -1 else b.v

fun main() {
    println(greeting)
    println(bump())
    println(bump())
    println(counter)
    println(limit)

    println(pick(Box(5)))
    println(pick(null))

    val s: String? = null
    println(s ?: "none")
    println(s == null)

    var seen = 0
    var i = 0
    while (i < limit) {
        seen = seen + bump()
        i = i + 1
    }
    println(seen)
    println(counter)

    println(Registry.label)
    Registry.hits = Registry.hits + 2
    Registry.hits = Registry.hits + 3
    println(Registry.hits)
}

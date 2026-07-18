// A `var` whose only references sit inside an anonymous object built by a
// factory lambda still boxes: the stamp counter increments through the
// object method write back into the enclosing scope.

fun main() {
    var order = 0
    val make = { name: String ->
        object {
            var stamp = -1
            fun touch() { stamp = order++ }
            override fun toString() = name + ":" + stamp
        }
    }
    val a = make("a")
    val b = make("b")
    a.touch()
    b.touch()
    println(a.toString())
    println(b.toString())
    println(order)
}

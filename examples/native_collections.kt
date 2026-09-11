// Lists compiled to C. Collection work is done directly against the runtime's
// own data structures, so a compiled list is a runtime list: it is traced by
// the collector and printed by the same renderer. The element type is carried
// where the emitter can see it, which is what lets arithmetic on an element
// compile to arithmetic rather than a dynamic unbox.
fun total(xs: List<Int>): Int {
    var s = 0
    var i = 0
    while (i < xs.size) {
        s = s + xs[i]
        i = i + 1
    }
    return s
}

fun main() {
    val xs = listOf(1, 2, 3, 4, 5)
    println(xs.size)
    println(xs[0])
    println(xs[4])
    println(total(xs))
    println(xs)

    val ys = mutableListOf(10, 20)
    ys.add(30)
    ys[0] = 11
    println(ys.size)
    println(ys[0])
    println(total(ys))
    println(ys)

    val names = listOf("a", "b")
    println(names.size)
    println(names[1])
}

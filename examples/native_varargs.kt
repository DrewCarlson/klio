// A `vararg` parameter takes ONE array, not one argument each: the call site
// collects the trailing positional arguments into an array of the parameter's
// own element type, which is what the callee iterates. A call that passes none
// still passes an array, an empty one.
fun total(vararg items: Int): Int {
    var sum = 0
    for (i in items) sum = sum + i
    return sum
}

fun widest(vararg values: Long): Long {
    var best = 0L
    for (v in values) if (v > best) best = v
    return best
}

fun path(root: String, vararg parts: String): String {
    var out = root
    for (p in parts) out = out + "/" + p
    return out
}

fun main() {
    println(total(1, 2, 3))
    println(total(7))
    println(total())
    println(widest(3L, 11L, 4L))
    println(path("root", "a", "b", "c"))
    println(path("solo"))
    // The array the callee receives is an array like any other.
    println(total(1, 2, 3) + total(4, 5))
}

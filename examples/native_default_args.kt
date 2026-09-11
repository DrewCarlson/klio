// Default arguments compiled to C. A default belongs to the CALL, not to the
// body: the callee takes every parameter like any other, and a call that omits
// one runs the thunk the declaration lowered for it, handed the arguments
// ahead of it. Each lands in a local first, because a later default may read
// an earlier one.
fun banner(text: String, fill: String = "-", width: Int = 4): String {
    var out = ""
    var i = 0
    while (i < width) {
        out = out + fill
        i = i + 1
    }
    return out + text + out
}

class Scale(val base: Int) {
    // A default on a method sees the receiver, so `off` reads a field.
    fun of(k: Int = 3, off: Int = base): Int = base * k + off
}

fun main() {
    println(banner("x"))
    println(banner("x", "="))
    println(banner("x", "=", 2))

    val s = Scale(4)
    println(s.of())
    println(s.of(2))
    println(s.of(2, 1))
}

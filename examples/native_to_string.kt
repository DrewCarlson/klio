// `toString()` compiled to C. A class that declares one dispatches to it; every
// other value renders the way the runtime renders it for printing, so one
// renderer answers both and there is no second spelling of a list, a number or
// a data class to drift from.
class Plain(val n: Int)

class Fancy(val n: Int) {
    override fun toString(): String = "fancy(" + n + ")"
}

data class Point(val x: Int, val y: Int)

enum class Flag { ON, OFF }

fun main() {
    println(Fancy(2).toString())
    println(Point(1, 2).toString())
    println(Flag.ON.toString())
    println(5.toString())
    println(true.toString())
    println("hi".toString())
    println(listOf(1, 2).toString())
    // A class with no override renders through the runtime, which knows the
    // shape of an instance.
    println(Plain(3).toString().length > 0)
    // Rendering inside a template is the same answer.
    println("" + Fancy(4) + " " + Point(3, 4))
}

val Int.cubed: Int get() = this * this * this

class Holder { var stored: Int = 0 }

var Holder.doubled: Int
    get() = stored * 2
    set(value) { stored = value / 2 }

fun main() {
    println(3.cubed)
    println((-2).cubed)
    val h = Holder()
    h.doubled = 10
    println(h.doubled)
    println(h.stored)
}

class Holder { var stored: Int = 0 }

var Holder.doubled: Int
    get() = stored * 2
    set(value) { stored = value / 2 }

fun main() {
    val h = Holder()
    h.doubled = 10
    println(h.doubled)
    println(h.stored)
    h.doubled = 42
    println(h.doubled)
    println(h.stored)
}

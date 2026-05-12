class Out<out T>(initial: T) {
    private var current: T = initial

    private fun stash(t: T) {
        current = t
    }

    fun show(): T = current
}

fun main() {
    val o = Out<Int>(42)
    println(o.show())
}

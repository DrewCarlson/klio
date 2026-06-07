// An `inner class` method that reads an enclosing-class property by
// bare name must resolve through the enclosing instance's *accessor*,
// not just a raw field slot. A getter-only outer property (no backing
// field) has to be invoked via its getter; the lookup must terminate
// even when several enclosing/iterator instances forward names to one
// another.
class Channel {
    private val _state = ArrayList<Int>()
    private val closeCause: String?
        get() = if (_state.size >= 3) "drained" else null

    fun push(v: Int) { _state.add(v) }

    inner class Cursor {
        fun report(): String {
            val cause = closeCause ?: return "open(${_state.size})"
            return "done:$cause"
        }
    }

    fun cursor(): Cursor = Cursor()
}

fun main() {
    val ch = Channel()
    val c = ch.cursor()
    println(c.report())
    ch.push(1); ch.push(2)
    println(c.report())
    ch.push(3)
    println(c.report())
}

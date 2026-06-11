// Companion members ride the implicit-receiver chain at their class's own
// depth: below the instance receiver and any with-subject, above the next
// receiver out and the top-level scope — for reads, calls, and writes.
val tag: String = "global"
fun mark(): String = "global-fn"
class Other
class Host {
    companion object {
        val tag: String = "companion"
        fun mark(): String = "companion-fn"
        var count = 0
    }
    fun read(): String = with(Other()) { tag }
    fun call(): String = mark()
    fun bump() { count = 5 }
}
fun main() {
    val h = Host()
    println(h.read())
    println(h.call())
    h.bump()
    println(Host.count)
}

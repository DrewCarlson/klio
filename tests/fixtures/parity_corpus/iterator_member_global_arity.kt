// An iterable instance is drainable, but a 2-argument `max(1, n)` is the
// imported kotlin.math.max global — the zero-argument collection `max`
// must not swallow it by draining the receiver and answering with its
// largest element.
import kotlin.math.max
class Track : Iterable<Int> {
    private val stops = listOf(9, 1, 2)
    override fun iterator(): Iterator<Int> = stops.iterator()
    fun capacity(n: Int): Int = max(1, n)
}
fun main() {
    println(Track().capacity(4))
    var biggest = 0
    for (s in Track()) if (s > biggest) biggest = s
    println(biggest)
}

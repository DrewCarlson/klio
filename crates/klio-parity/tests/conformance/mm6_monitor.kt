// MM6 — monitors. Single-threaded reduction: a synchronized block
// runs exactly once, in program order. The threaded guarantee
// (mutual exclusion, unlock-before-next-lock) is exercised by the
// threaded suite once threads land.
//> 1
//> 2
fun main() {
    val lock = Any()
    var n = 0
    synchronized(lock) { n += 1 }
    println(n)
    synchronized(lock) { n += 1 }
    println(n)
}

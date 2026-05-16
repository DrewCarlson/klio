// TL smoke — single-threaded reduction of a monitor-guarded counter.
// Today this runs on the serialized interpreter: the synchronized
// block executes in program order. When real thread spawning lands,
// the threaded variants (multiple threads contending the same monitor
// and asserting mutual exclusion / no lost update) move from the
// PENDING list into RUNNABLE and assert the same final output across
// every interleaving.
//> count=1000
fun main() {
    val lock = Any()
    var count = 0
    for (i in 0 until 1000) {
        synchronized(lock) { count += 1 }
    }
    println("count=$count")
}

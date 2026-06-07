// Real parallel sleep. Four `thread { Thread.sleep(300) }` are
// spawned as real OS threads and joined. Because each sleep suspends
// its own OS thread, wall time is ~0.3s (the four sleeps overlap),
// not ~1.2s (which serialized execution would take). The output is
// deterministic: every thread finishes, then `done` prints after the
// last join.
//> done
import kotlin.concurrent.thread

fun main() {
    val threads = (1..4).map {
        thread { Thread.sleep(300) }
    }
    for (t in threads) {
        t.join()
    }
    println("done")
}

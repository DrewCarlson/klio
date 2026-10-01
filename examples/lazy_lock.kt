// `lazy` initializes once under a monitor, as the JVM's does: the lock
// `lazy(lock)` names, else the lazy itself. A thread holding that lock keeps
// the first `value` read waiting until it lets go. Once the value is
// published a read takes no lock, so a thread holding the monitor keeps no
// reader of the published value waiting.
import kotlin.concurrent.Volatile
import kotlin.concurrent.thread

@Volatile var holding = false
@Volatile var asked = false
@Volatile var released = false
@Volatile var reads = 0

fun main() {
    val lock = Any()
    var runs = 0
    val named = lazy(lock) {
        runs++
        "made with the lock released: $released"
    }
    val holder = thread {
        synchronized(lock) {
            holding = true
            while (!asked) {}
            Thread.sleep(50)
            released = true
        }
    }
    while (!holding) {}
    asked = true
    println(named.value)
    holder.join()
    println(named.value + ", initializer runs: $runs")

    // A published value reads without the lazy's own monitor.
    val own = lazy { "published" }
    println(own.value)
    holding = false
    asked = false
    val owner = thread {
        synchronized(own) {
            holding = true
            while (!asked) {}
            while (reads < 3) {}
        }
    }
    while (!holding) {}
    asked = true
    val reader = thread {
        repeat(3) {
            check(own.value == "published")
            reads++
        }
    }
    reader.join()
    owner.join()
    println("reads while the monitor was held: $reads")

    // Racing first reads run the initializer once.
    var made = 0
    val shared = lazy { made++; Any() }
    val seen = arrayOfNulls<Any>(4)
    val ts = (0 until 4).map { i -> thread { seen[i] = shared.value } }
    ts.forEach { it.join() }
    println("racing readers saw one value: ${seen.all { it === seen[0] }}, initializer runs: $made")
}

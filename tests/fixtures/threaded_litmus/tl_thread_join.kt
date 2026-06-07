// Start- and join-happens-before. `thread { x = 7 }` spawns a real
// OS thread; `t.join()` establishes the happens-before so the main
// thread observes the write. Deterministic: the print follows join.
//> 7
import kotlin.concurrent.thread

fun main() {
    var x = 0
    val t = thread { x = 7 }
    t.join()
    println(x)
}

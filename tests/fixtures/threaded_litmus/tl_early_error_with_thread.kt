// A failing top-level initializer with an outstanding explicit thread
// must drain the run boundary on the error path too: the thread is
// joined (its output may appear), the dispatcher pool and the
// process-global registries are swept, and the process neither
// segfaults nor leaks the run's state into the next run.
//>! init fails

import kotlin.concurrent.thread

val t = thread { Thread.sleep(200) }
val boom: Int = error("init fails")

fun main() {
    println("never")
}

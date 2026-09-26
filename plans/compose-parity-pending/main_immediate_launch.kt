// Open (coroutines): Dispatchers.Main.immediate dispatches work that is
// already running on Main. Expected (JVM, Compose Desktop's Main):
//   before yield: initial value
//   after yield: value set by launch
//   after an immediate launch: value set by an immediate launch
//   done
// klio prints "after an immediate launch: value set by launch".
// lifecycle-runtime's commonTest (withStarted on a destroyed lifecycle waits
// forever) and lifecycle_registry.kt's clear order wait on it.

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield

fun main() {
    runBlocking(Dispatchers.Main) {
        var v = "initial value"
        launch(Dispatchers.Main) { v = "value set by launch" }
        println("before yield: $v")
        yield()
        println("after yield: $v")
        val job = launch(Dispatchers.Main.immediate) { v = "value set by an immediate launch" }
        println("after an immediate launch: $v")
        job.join()
    }
    println("done")
}

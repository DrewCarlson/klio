// GlobalScope work on a dispatcher is a daemon: it is not part of any
// runBlocking job tree, so runBlocking returns without it and the run
// ends without waiting for (or running) its remainder.
// kotlinc+kotlinx oracle output below ("daemon late" never prints).
//> main done

import kotlinx.coroutines.*

fun main() {
    GlobalScope.launch(Dispatchers.Default) { Thread.sleep(400); println("daemon late") }
    runBlocking { delay(50) }
    println("main done")
}

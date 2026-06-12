// A non-terminating daemon must not hang the program: main exits and
// the daemon is abandoned at the run boundary, exactly as JVM daemon
// threads die with the process. kotlinc+kotlinx oracle output below.
//> main done

import kotlinx.coroutines.*

fun main() {
    GlobalScope.launch(Dispatchers.Default) { while (true) { Thread.sleep(10) } }
    runBlocking { delay(50) }
    println("main done")
}

// A daemon task still queued when the run ends is dropped, never
// executed. kotlinc+kotlinx oracle output below.
//> main returns

import kotlinx.coroutines.*

fun main() {
    GlobalScope.launch(Dispatchers.Default) { println("queued daemon ran") }
    println("main returns")
}

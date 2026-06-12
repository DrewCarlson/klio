// A nested runBlocking on a pool worker joins its children, so their
// writes happen-before code after it. kotlinc+kotlinx oracle: box=42.
//> box=42

import kotlinx.coroutines.*

fun main() = runBlocking {
    var box = 0
    withContext(Dispatchers.Default) {
        runBlocking {
            launch(Dispatchers.Default) { Thread.sleep(100); box = 42 }
            Unit
        }
    }
    println("box=" + box)
}

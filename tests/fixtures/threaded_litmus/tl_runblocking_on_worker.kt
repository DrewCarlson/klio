// runBlocking executing on a pool worker joins its own launched
// children before returning, exactly like runBlocking anywhere else.
// kotlinc+kotlinx oracle output below.
//> inner root done
//> inner child
//> withContext done
//> outer done

import kotlinx.coroutines.*

fun main() = runBlocking {
    withContext(Dispatchers.Default) {
        runBlocking {
            launch(Dispatchers.Default) { Thread.sleep(150); println("inner child") }
            println("inner root done")
        }
        println("withContext done")
    }
    println("outer done")
}

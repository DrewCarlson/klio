// An independent-scope coroutine (its own `Job`, not in the runBlocking
// tree) that is explicitly awaited must complete before the awaiter
// proceeds, even when its body parks on a cooperative suspension — the
// awaited non-daemon scope is kept alive, unlike a fire-and-forget
// daemon. kotlinc+kotlinx oracle output below.
//> async-completion-line
//> awaited=42

import kotlinx.coroutines.*

fun main() = runBlocking {
    val scope = CoroutineScope(Job())
    val deferred = scope.async {
        delay(50)
        println("async-completion-line")
        42
    }
    val r = deferred.await()
    println("awaited=$r")
}

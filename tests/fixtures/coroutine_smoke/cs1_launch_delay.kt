// Launch + delay interleaving: the child runs at its virtual-time
// wakeup, between "after launch" and the parent's later resume.
//> start
//> after launch
//> child
//> end
import kotlinx.coroutines.*
fun main() = runBlocking {
    println("start")
    launch { delay(50); println("child") }
    println("after launch")
    delay(100)
    println("end")
}

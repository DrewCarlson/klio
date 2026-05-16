// Multiple launches resume in virtual-time order of their delays.
//> spawned
//> t2
//> t1
//> t0
import kotlinx.coroutines.*
fun main() = runBlocking {
    repeat(3) { i -> launch { delay((3 - i) * 10L); println("t$i") } }
    println("spawned")
}

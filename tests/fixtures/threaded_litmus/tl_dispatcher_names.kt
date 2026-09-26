// The shared dispatchers name themselves as on the JVM: ktor asserts that an
// engine's default dispatcher prints as Dispatchers.IO.
//> Dispatchers.Default
//> Dispatchers.IO
//> Dispatchers.Unconfined
import kotlinx.coroutines.*

fun main() {
    println(Dispatchers.Default)
    println(Dispatchers.IO)
    println(Dispatchers.Unconfined)
}

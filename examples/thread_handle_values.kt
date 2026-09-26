// A thread handle is a value like any other: a type test sees a klio.Thread,
// it passes through a Result and a list, and two handles of one thread are
// the same thread (===) while another thread's is not.
import kotlin.concurrent.thread

fun main() {
    val here = klio.Thread.currentThread()
    val again = klio.Thread.currentThread()
    println("is Thread: ${(here as Any) is klio.Thread}")
    println("same thread ===: ${here === again}, ==: ${here == again}")
    val viaResult = runCatching { klio.Thread.currentThread() }
    println("through a Result: ${viaResult.isSuccess}, ${viaResult.exceptionOrNull()}")
    var other: klio.Thread? = null
    val t = thread { other = klio.Thread.currentThread() }
    t.join()
    println("another thread ===: ${other === here}")
    println("list holds it: ${listOf<Any>(here).first() is klio.Thread}")
}

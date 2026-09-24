// Threads take the JVM's names. The program runs on "main". Each
// `thread { }` takes the next "Thread-N", a named one too, before its own
// name replaces it. A throwable that ends a thread goes to the thread's
// uncaught handler, which prints it on stderr under the thread's name, and
// the thread that joins it carries on.
import kotlin.concurrent.thread

fun fail(): Nothing = throw IllegalStateException("boom")

fun main() {
    println(Thread.currentThread().name)
    var first = ""
    thread { first = Thread.currentThread().name }.join()
    println(first)
    val failing = thread { fail() }
    failing.join()
    println(failing.name + " alive=" + failing.isAlive)
    val named = thread(name = "worker") { println("in " + Thread.currentThread().name) }
    named.join()
    var next = ""
    thread { next = Thread.currentThread().name }.join()
    println(next)
    println("main done")
}

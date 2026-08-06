// The thread handle is a declared type: its members resolve through the
// declaration, and the host still serves their bodies.
import kotlin.concurrent.thread

fun main() {
    val seen = mutableListOf<String>()
    val t = thread {
        seen.add("worker")
    }
    t.join()
    println(seen.joinToString())
    println(t.isAlive)
    println(t.name.startsWith("klio-thread-"))

    val many = (1..4).map { n -> thread { seen.add("w$n") } }
    many.forEach { it.join() }
    println(seen.size)
}

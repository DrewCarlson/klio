// MM8 — thread start/join (threaded). Thread.start happens-before
// the body; the body's completion happens-before join() returning,
// so the write in the thread is observed after join.
//> 7
import kotlin.concurrent.thread
fun main() {
    var x = 0
    val t = thread { x = 7 }
    t.join()
    println(x)
}

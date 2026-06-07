// MM8 — thread start/join, genuinely concurrent. Each spawned OS
// thread writes its own slot; `Thread.start` happens-before the
// body and the body's completion happens-before `join()` returning,
// so after joining all threads every write is visible. Deterministic
// sum: 0+1+...+7 = 28.
//> 28
import kotlin.concurrent.thread
fun main() {
    val slots = IntArray(8)
    val threads = ArrayList<Thread>()
    for (i in 0 until 8) {
        threads.add(thread { slots[i] = i })
    }
    for (t in threads) t.join()
    var sum = 0
    for (v in slots) sum += v
    println(sum)
}

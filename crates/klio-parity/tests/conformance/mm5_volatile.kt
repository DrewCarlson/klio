// MM5 — @Volatile / visibility, genuinely concurrent. A publisher OS
// thread fully writes the data array and then sets the @Volatile
// `ready` flag; the consumer waits for the flag and only then reads
// the data. The flag write happens-before the flag read, and the
// data writes are sequenced before the flag write, so the consumer
// can never observe ready==true with stale data. `join()` makes the
// observed result deterministic: every slot is the publisher's
// value, summing 1+2+...+16 = 136.
//> ok
//> 136
import kotlin.concurrent.thread

class Mailbox {
    val data = IntArray(16)
    @Volatile var ready: Boolean = false
}

fun main() {
    val ch = Mailbox()

    val publisher = thread {
        for (i in 0 until 16) ch.data[i] = i + 1
        ch.ready = true
    }

    val consumer = thread {
        while (!ch.ready) { /* spin until the publisher signals */ }
        // ready==true was observed: every prior data write must be
        // visible. A stale slot here would mean a visibility break.
        var sum = 0
        for (i in 0 until 16) {
            val v = ch.data[i]
            require(v == i + 1) { "flag set but data stale at $i: $v" }
            sum += v
        }
        require(sum == 136) { "wrong sum: $sum" }
    }

    publisher.join()
    consumer.join()
    println("ok")

    var total = 0
    for (v in ch.data) total += v
    println(total)
}

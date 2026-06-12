// AtomicRef compareAndSet claim semantics (identity CAS). Per round,
// four OS threads arrive at a spin gate and then race to claim a
// fresh null slot with their own object simultaneously; exactly one
// claim may succeed per round, and the published value must be the
// winner's object.
//> claims=50
import kotlin.concurrent.thread
import kotlinx.atomicfu.atomic

class Claim(val id: Int)

fun main() {
    var claimed = 0
    repeat(50) {
        val slot = atomic<Claim?>(null)
        val wins = atomic(0)
        val gate = atomic(0)
        val threads = ArrayList<Thread>()
        for (n in 0 until 4) {
            threads.add(thread {
                val mine = Claim(n)
                gate.incrementAndGet()
                while (gate.value < 4) {
                }
                if (slot.compareAndSet(null, mine)) {
                    wins.incrementAndGet()
                }
            })
        }
        for (t in threads) {
            t.join()
        }
        if (slot.value == null) {
            println("round lost its claim")
        }
        claimed += wins.value
    }
    println("claims=$claimed")
}

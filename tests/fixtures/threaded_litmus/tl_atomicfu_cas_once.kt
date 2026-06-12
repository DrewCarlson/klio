// AtomicBoolean compareAndSet claim semantics. Per round, four OS
// threads arrive at a spin gate and then race `compareAndSet(false,
// true)` on a fresh flag simultaneously; exactly one may win each
// round. An implementation whose compare and swap take separate
// borrows lets two racers both observe `false` and both report
// success, overcounting the winners.
//> winners=50 rounds=50
import kotlin.concurrent.thread
import kotlinx.atomicfu.atomic

fun main() {
    var totalWinners = 0
    repeat(50) {
        val flag = atomic(false)
        val winners = atomic(0)
        val gate = atomic(0)
        val threads = ArrayList<Thread>()
        for (n in 0 until 4) {
            threads.add(thread {
                gate.incrementAndGet()
                while (gate.value < 4) {
                }
                if (flag.compareAndSet(false, true)) {
                    winners.incrementAndGet()
                }
            })
        }
        for (t in threads) {
            t.join()
        }
        totalWinners += winners.value
    }
    println("winners=$totalWinners rounds=50")
}

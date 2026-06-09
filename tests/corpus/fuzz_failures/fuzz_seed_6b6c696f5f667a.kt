// fuzz_closures_suspend repro for seed=0x6b6c696f5f667a
// Reproduce: KLIO_FUZZ_SEED=0x6b6c696f5f667a KLIO_FUZZ_SEEDS=1 zig build test
import kotlinx.coroutines.*

object Obj {
    fun emit(tag: String, n: Int) { println("obj:$tag=$n") }
    fun bump(n: Int): Int = n + 1
}

fun main() = runBlocking {
    run {
        var acc0 = 0
        val step0 = { acc0 = acc0 + 1 }
        step0()
        step0()
        step0()
        step0()
        println("acc0=$acc0")
    }
    with(Obj) {
    with(Obj) {
    with(Obj) {
        emit("depth", bump(3))
    }
    }
    }
    var c0 = 0
    launch { delay(40L); c0 = c0 + 4; println("job0:$c0") }
    println("launched")
}

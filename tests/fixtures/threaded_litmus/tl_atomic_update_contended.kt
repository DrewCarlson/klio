// kotlin.concurrent.atomics inline `update` under real contention. Four OS
// threads each apply 5000 increments through `AtomicInt.update` (and the Long
// and Reference mirrors through their update families); the inline extension
// splices into the caller, so only a compare-and-set loop keeps concurrent
// transforms from losing updates — a plain store(transform(load())) splice
// loses increments under this schedule.
//> int=20000 long=20000 ref=20000
@file:OptIn(kotlin.concurrent.atomics.ExperimentalAtomicApi::class)

import kotlin.concurrent.atomics.AtomicInt
import kotlin.concurrent.atomics.AtomicLong
import kotlin.concurrent.atomics.AtomicReference
import kotlin.concurrent.atomics.update
import kotlin.concurrent.atomics.fetchAndUpdate
import kotlin.concurrent.atomics.updateAndFetch
import kotlin.concurrent.thread

fun main() {
    val counter = AtomicInt(0)
    val longCounter = AtomicLong(0L)
    val refCounter = AtomicReference(0)
    val threads = ArrayList<Thread>()
    for (n in 0 until 4) {
        threads.add(thread {
            repeat(5000) {
                counter.update { it + 1 }
                longCounter.fetchAndUpdate { it + 1L }
                refCounter.updateAndFetch { it + 1 }
            }
        })
    }
    for (t in threads) t.join()
    println("int=${counter.load()} long=${longCounter.load()} ref=${refCounter.load()}")
}

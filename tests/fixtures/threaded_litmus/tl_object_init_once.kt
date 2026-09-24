// An object and an enum class initialize once across real threads, as JVM
// class initialization does: a thread that finds another thread running the
// initializer waits for it to finish, then reads the finished instance.
// Eight OS threads race each first read while the initializer dawdles; each
// initializer must run once and every reader must see its finished values,
// never the instance it is still building.
//> objectRuns=1
//> objectSame=true
//> enumRuns=1
//> enumSame=true
@file:OptIn(kotlin.concurrent.atomics.ExperimentalAtomicApi::class)

import kotlin.concurrent.atomics.AtomicInt
import kotlin.concurrent.atomics.incrementAndFetch
import kotlin.concurrent.thread

val objectRuns = AtomicInt(0)
val enumRuns = AtomicInt(0)

object Slow {
    val value: Int

    init {
        objectRuns.incrementAndFetch()
        Thread.sleep(20)
        value = 42
    }
}

fun slowWeight(): Int {
    enumRuns.incrementAndFetch()
    Thread.sleep(20)
    return 7
}

enum class Kind(val weight: Int) { LIGHT(slowWeight()), HEAVY(9) }

fun race(read: () -> Int, want: Int): Boolean {
    val results = IntArray(8)
    val threads = ArrayList<Thread>()
    for (i in 0 until 8) {
        threads.add(thread { results[i] = read() })
    }
    for (t in threads) {
        t.join()
    }
    var same = true
    for (i in 0 until 8) {
        if (results[i] != want) same = false
    }
    return same
}

fun main() {
    val objectSame = race({ Slow.value }, 42)
    val enumSame = race({ Kind.HEAVY.weight }, 9)
    println("objectRuns=${objectRuns.load()}")
    println("objectSame=$objectSame")
    println("enumRuns=${enumRuns.load()}")
    println("enumSame=$enumSame")
}

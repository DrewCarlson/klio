// `select { }` over channel/timeout clauses and a `Semaphore` mediating
// access under coroutine contention. The select picks the first ready clause
// in biased registration order; `onTimeout(0)` is immediately ready; a
// `Semaphore(1)` serializes two coroutines so only one holds the permit at a
// time. Deterministic output throughout.
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.*
import kotlinx.coroutines.selects.*
import kotlinx.coroutines.sync.*

fun main() = runBlocking {
    // A ready onReceive clause wins over an empty channel's clause.
    val a = Channel<Int>(1)
    val b = Channel<Int>(1)
    a.send(7)
    val picked = select<String> {
        a.onReceive { "a=$it" }
        b.onReceive { "b=$it" }
    }
    println(picked)

    // onTimeout(0) is selected immediately (biased to the first ready clause).
    val empty = Channel<Int>(1)
    val timed = select<String> {
        empty.onReceive { "received $it" }
        onTimeout(0) { "timeout" }
    }
    println(timed)

    // A fan-in select over a rendezvous channel: the producer parks between its
    // two sends, and each onReceive select takes a value handed off by the
    // parked producer. Both values arrive in order.
    val rv = Channel<Int>()
    launch { rv.send(1); rv.send(2) }
    val drained = mutableListOf<Int>()
    repeat(2) { drained.add(select<Int> { rv.onReceive { it } }) }
    println(drained)

    // An onSend select that parks before any receiver exists is woken when a
    // later receive arrives: the parked select hands its value straight to the
    // new receiver, which then takes a second plain send.
    val out = Channel<Int>()
    val got = mutableListOf<Int>()
    val consumer = launch { repeat(2) { got.add(out.receive()) } }
    select<Unit> { out.onSend(10) {} }
    out.send(20)
    consumer.join()
    println(got)

    // A binary semaphore serializes two launches: the second acquirer
    // suspends until the first releases, so the critical sections do not
    // interleave and both run exactly once.
    val sem = Semaphore(1)
    val order = mutableListOf<Int>()
    val jobs = (1..2).map { i ->
        launch {
            sem.withPermit {
                order.add(i)
            }
        }
    }
    jobs.forEach { it.join() }
    println("permits=${sem.availablePermits} ran=${order.size}")
}

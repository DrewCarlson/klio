// End-to-end demo exercising all four kotlinx packs the interpreter
// ships with. Each section prints a small banner so the output is
// stable enough to gold-master against in a future test harness.

import kotlinx.atomicfu.atomic
import kotlinx.io.Buffer
import kotlinx.datetime.Instant
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime
import kotlinx.datetime.toInstant
import kotlinx.datetime.Duration
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.delay

fun atomicfuSection() {
    println("== atomicfu ==")
    val ai = atomic(0)
    repeat(5) { ai.incrementAndGet() }
    val al = atomic(10L)
    al.addAndGet(32L)
    val ab = atomic(false)
    val swapped = ab.compareAndSet(false, true)
    val ar = atomic<String?>(null)
    ar.compareAndSet(null, "hello")
    println("int=${ai.value}")
    println("long=${al.value}")
    println("bool=${ab.value} swapped=$swapped")
    println("ref=${ar.value}")
}

fun ioSection() {
    println("== kotlinx.io ==")
    val buf = Buffer()
    buf.writeInt(42)
    buf.writeLong(1_000_000_000_000L)
    buf.writeString("kt")
    println("size_before=${buf.size()}")
    val i = buf.readInt()
    val l = buf.readLong()
    val s = buf.readString()
    println("int=$i long=$l str=$s")
    println("empty=${buf.isEmpty()}")
}

fun datetimeSection() {
    println("== kotlinx.datetime ==")
    val pinned = Instant.fromEpochMilliseconds(1_700_000_000_000L)
    println("pinned=$pinned")
    val later = pinned + Duration.hours(2L)
    println("delta_min=${(later - pinned).inWholeMinutes}")
    val utc = TimeZone.of("UTC")
    val ldt = pinned.toLocalDateTime(utc)
    println("ldt=$ldt")
    val back = ldt.toInstant(utc)
    println("roundtrip=${back.toEpochMilliseconds() == 1_700_000_000_000L}")
}

fun coroutinesSection() {
    println("== kotlinx.coroutines ==")
    runBlocking {
        println("start")
        delay(10L)
        println("after-delay")
    }
    println("done")
}

fun main() {
    atomicfuSection()
    ioSection()
    datetimeSection()
    coroutinesSection()
}

// Weak references and cleaners across threads. Workers make objects, weak
// references to them and cleaners; the main thread keeps every other object
// and drops the rest. A collection clears exactly the weak references to the
// dropped objects, keeps the kept ones, whichever thread made them, and the
// cleaner thread runs one cleanup per dropped holder.
//> kept alive: 200
//> dropped cleared: 200
//> kept values: 40000
//> cleanups: 200 sum 40200
@file:OptIn(kotlin.experimental.ExperimentalNativeApi::class, kotlin.native.runtime.NativeRuntimeApi::class, kotlin.concurrent.atomics.ExperimentalAtomicApi::class)

import kotlin.concurrent.atomics.AtomicInt
import kotlin.concurrent.atomics.incrementAndFetch
import kotlin.concurrent.thread
import kotlin.native.ref.WeakReference
import kotlin.native.ref.createCleaner
import kotlin.native.runtime.GC

class Payload(val n: Int)

class Holder(val payload: Payload, count: AtomicInt, sum: AtomicInt) {
    private val cleaner = createCleaner(payload.n) {
        sum.addAndFetch(it)
        count.incrementAndFetch()
    }
}

class Made(val keep: List<Holder>, val keepRefs: List<WeakReference<Holder>>, val dropRefs: List<WeakReference<Holder>>)

fun make(base: Int, count: AtomicInt, sum: AtomicInt): Made {
    val keep = ArrayList<Holder>()
    val keepRefs = ArrayList<WeakReference<Holder>>()
    val dropRefs = ArrayList<WeakReference<Holder>>()
    for (i in 0 until 100) {
        val h = Holder(Payload(base + i), count, sum)
        if (i % 2 == 0) {
            keep.add(h)
            keepRefs.add(WeakReference(h))
        } else {
            dropRefs.add(WeakReference(h))
        }
    }
    return Made(keep, keepRefs, dropRefs)
}

fun main() {
    val count = AtomicInt(0)
    val sum = AtomicInt(0)
    val made = arrayOfNulls<Made>(4)
    val workers = (0 until 4).map { w ->
        thread { made[w] = make(w * 100 + 1, count, sum) }
    }
    workers.forEach { it.join() }
    val all = made.map { it!! }
    GC.collect()
    GC.collect()
    var waited = 0
    while (count.load() < 200 && waited < 500) {
        Thread.sleep(10)
        waited++
    }
    println("kept alive: ${all.sumOf { m -> m.keepRefs.count { it.get() != null } }}")
    println("dropped cleared: ${all.sumOf { m -> m.dropRefs.count { it.get() == null } }}")
    println("kept values: ${all.sumOf { m -> m.keep.sumOf { it.payload.n } }}")
    println("cleanups: ${count.load()} sum ${sum.load()}")
}

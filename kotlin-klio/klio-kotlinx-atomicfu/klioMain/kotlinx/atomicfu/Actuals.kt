// klio platform actuals for kotlinx.atomicfu.
//
// The upstream commonMain (consumed from the in-pack submodule)
// declares the public `expect` surface. This file supplies the
// matching klio `actual`s. klio runs real worker threads, so every
// operation body implements genuine atomic semantics by holding the
// receiver's monitor: correctness never depends on which dispatch
// route a call takes. The host bindings in `src/kotlinx_atomicfu`
// still shadow non-inline operations at dispatch time with a
// cell-locked read-modify-write as the fast path, but an inline
// member spliced at lowering (which a binding can never intercept)
// or any other unbound route lands on these bodies and observes the
// same semantics.

package kotlinx.atomicfu

import kotlin.reflect.KProperty

actual fun <T> atomic(initial: T, trace: TraceBase): AtomicRef<T> = AtomicRef(initial)
actual fun <T> atomic(initial: T): AtomicRef<T> = AtomicRef(initial)
actual fun atomic(initial: Int, trace: TraceBase): AtomicInt = AtomicInt(initial)
actual fun atomic(initial: Int): AtomicInt = AtomicInt(initial)
actual fun atomic(initial: Long, trace: TraceBase): AtomicLong = AtomicLong(initial)
actual fun atomic(initial: Long): AtomicLong = AtomicLong(initial)
actual fun atomic(initial: Boolean, trace: TraceBase): AtomicBoolean = AtomicBoolean(initial)
actual fun atomic(initial: Boolean): AtomicBoolean = AtomicBoolean(initial)

actual class AtomicRef<T> internal constructor(initial: T) {
    actual var value: T = initial
    actual inline operator fun getValue(thisRef: Any?, property: KProperty<*>): T = value
    actual inline operator fun setValue(thisRef: Any?, property: KProperty<*>, value: T) { this.value = value }
    actual fun lazySet(value: T) { this.value = value }
    actual fun compareAndSet(expect: T, update: T): Boolean = kotlin.synchronized(this) {
        if (value === expect) {
            value = update
            true
        } else false
    }
    actual fun getAndSet(value: T): T = kotlin.synchronized(this) {
        val old = this.value
        this.value = value
        old
    }
    override fun toString(): String = value.toString()
}

actual class AtomicBoolean internal constructor(initial: Boolean) {
    actual var value: Boolean = initial
    actual inline operator fun getValue(thisRef: Any?, property: KProperty<*>): Boolean = value
    actual inline operator fun setValue(thisRef: Any?, property: KProperty<*>, value: Boolean) { this.value = value }
    actual fun lazySet(value: Boolean) { this.value = value }
    actual fun compareAndSet(expect: Boolean, update: Boolean): Boolean = kotlin.synchronized(this) {
        if (value == expect) {
            value = update
            true
        } else false
    }
    actual fun getAndSet(value: Boolean): Boolean = kotlin.synchronized(this) {
        val old = this.value
        this.value = value
        old
    }
    override fun toString(): String = value.toString()
}

actual class AtomicInt internal constructor(initial: Int) {
    actual var value: Int = initial
    actual inline operator fun getValue(thisRef: Any?, property: KProperty<*>): Int = value
    actual inline operator fun setValue(thisRef: Any?, property: KProperty<*>, value: Int) { this.value = value }
    actual fun lazySet(value: Int) { this.value = value }
    actual fun compareAndSet(expect: Int, update: Int): Boolean = kotlin.synchronized(this) {
        if (value == expect) {
            value = update
            true
        } else false
    }
    actual fun getAndSet(value: Int): Int = kotlin.synchronized(this) {
        val old = this.value
        this.value = value
        old
    }
    actual fun getAndIncrement(): Int = getAndAdd(1)
    actual fun getAndDecrement(): Int = getAndAdd(-1)
    actual fun getAndAdd(delta: Int): Int = kotlin.synchronized(this) {
        val old = value
        value = old + delta
        old
    }
    actual fun addAndGet(delta: Int): Int = kotlin.synchronized(this) {
        value += delta
        value
    }
    actual fun incrementAndGet(): Int = addAndGet(1)
    actual fun decrementAndGet(): Int = addAndGet(-1)
    actual inline operator fun plusAssign(delta: Int) { addAndGet(delta) }
    actual inline operator fun minusAssign(delta: Int) { addAndGet(-delta) }
    override fun toString(): String = value.toString()
}

actual class AtomicLong internal constructor(initial: Long) {
    actual var value: Long = initial
    actual operator fun getValue(thisRef: Any?, property: KProperty<*>): Long = value
    actual operator fun setValue(thisRef: Any?, property: KProperty<*>, value: Long) { this.value = value }
    actual fun lazySet(value: Long) { this.value = value }
    actual fun compareAndSet(expect: Long, update: Long): Boolean = kotlin.synchronized(this) {
        if (value == expect) {
            value = update
            true
        } else false
    }
    actual fun getAndSet(value: Long): Long = kotlin.synchronized(this) {
        val old = this.value
        this.value = value
        old
    }
    actual fun getAndIncrement(): Long = getAndAdd(1L)
    actual fun getAndDecrement(): Long = getAndAdd(-1L)
    actual fun getAndAdd(delta: Long): Long = kotlin.synchronized(this) {
        val old = value
        value = old + delta
        old
    }
    actual fun addAndGet(delta: Long): Long = kotlin.synchronized(this) {
        value += delta
        value
    }
    actual fun incrementAndGet(): Long = addAndGet(1L)
    actual fun decrementAndGet(): Long = addAndGet(-1L)
    actual inline operator fun plusAssign(delta: Long) { addAndGet(delta) }
    actual inline operator fun minusAssign(delta: Long) { addAndGet(-delta) }
    override fun toString(): String = value.toString()
}

actual fun Trace(size: Int, format: TraceFormat): TraceBase = TraceBase.None
actual fun TraceBase.named(name: String): TraceBase = this
actual val traceFormatDefault: TraceFormat = TraceFormat()

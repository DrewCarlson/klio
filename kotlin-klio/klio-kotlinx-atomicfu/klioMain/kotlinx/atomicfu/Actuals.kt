// klio platform actuals for kotlinx.atomicfu.
//
// The upstream commonMain (consumed from the in-pack submodule)
// declares the public `expect` surface. This file supplies the
// matching klio `actual`s. The bodies are thin Kotlin; the host
// bindings in `src/kotlinx_atomicfu` shadow every atomic operation
// at dispatch time with a read-modify-write that holds the
// receiver's cell lock (atomic across worker threads), so the
// field-mutating bodies here are only a fallback that is never
// taken when the pack is loaded.

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
    actual fun compareAndSet(expect: T, update: T): Boolean { return false }
    actual fun getAndSet(value: T): T { return value }
    override fun toString(): String = value.toString()
}

actual class AtomicBoolean internal constructor(initial: Boolean) {
    actual var value: Boolean = initial
    actual inline operator fun getValue(thisRef: Any?, property: KProperty<*>): Boolean = value
    actual inline operator fun setValue(thisRef: Any?, property: KProperty<*>, value: Boolean) { this.value = value }
    actual fun lazySet(value: Boolean) { this.value = value }
    actual fun compareAndSet(expect: Boolean, update: Boolean): Boolean { return false }
    actual fun getAndSet(value: Boolean): Boolean { return false }
    override fun toString(): String = value.toString()
}

actual class AtomicInt internal constructor(initial: Int) {
    actual var value: Int = initial
    actual inline operator fun getValue(thisRef: Any?, property: KProperty<*>): Int = value
    actual inline operator fun setValue(thisRef: Any?, property: KProperty<*>, value: Int) { this.value = value }
    actual fun lazySet(value: Int) { this.value = value }
    actual fun compareAndSet(expect: Int, update: Int): Boolean { return false }
    actual fun getAndSet(value: Int): Int { return 0 }
    actual fun getAndIncrement(): Int { return 0 }
    actual fun getAndDecrement(): Int { return 0 }
    actual fun getAndAdd(delta: Int): Int { return 0 }
    actual fun addAndGet(delta: Int): Int { return 0 }
    actual fun incrementAndGet(): Int { return 0 }
    actual fun decrementAndGet(): Int { return 0 }
    actual inline operator fun plusAssign(delta: Int) {}
    actual inline operator fun minusAssign(delta: Int) {}
    override fun toString(): String = value.toString()
}

actual class AtomicLong internal constructor(initial: Long) {
    actual var value: Long = initial
    actual operator fun getValue(thisRef: Any?, property: KProperty<*>): Long = value
    actual operator fun setValue(thisRef: Any?, property: KProperty<*>, value: Long) { this.value = value }
    actual fun lazySet(value: Long) { this.value = value }
    actual fun compareAndSet(expect: Long, update: Long): Boolean { return false }
    actual fun getAndSet(value: Long): Long { return 0L }
    actual fun getAndIncrement(): Long { return 0L }
    actual fun getAndDecrement(): Long { return 0L }
    actual fun getAndAdd(delta: Long): Long { return 0L }
    actual fun addAndGet(delta: Long): Long { return 0L }
    actual fun incrementAndGet(): Long { return 0L }
    actual fun decrementAndGet(): Long { return 0L }
    actual inline operator fun plusAssign(delta: Long) {}
    actual inline operator fun minusAssign(delta: Long) {}
    override fun toString(): String = value.toString()
}

actual fun Trace(size: Int, format: TraceFormat): TraceBase = TraceBase.None
actual fun TraceBase.named(name: String): TraceBase = this
actual val traceFormatDefault: TraceFormat = TraceFormat()

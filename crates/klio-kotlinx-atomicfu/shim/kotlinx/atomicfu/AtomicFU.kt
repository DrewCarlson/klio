// Klio shim for kotlinx.atomicfu.
//
// The upstream commonMain sources rely on Kotlin/Native and Kotlin/JS
// intrinsics that klio does not currently parse. This file declares
// the surface area klio needs — class shapes plus simple Kotlin
// bodies — and the host-binding registry in klio-kotlinx-atomicfu's
// Rust side overrides every operation with a native implementation
// that wins at dispatch.

package kotlinx.atomicfu

class AtomicInt internal constructor(initial: Int) {
    var value: Int = initial
    fun compareAndSet(expected: Int, update: Int): Boolean { return false }
    fun getAndSet(value: Int): Int { return 0 }
    fun getAndIncrement(): Int { return 0 }
    fun getAndDecrement(): Int { return 0 }
    fun incrementAndGet(): Int { return 0 }
    fun decrementAndGet(): Int { return 0 }
    fun getAndAdd(delta: Int): Int { return 0 }
    fun addAndGet(delta: Int): Int { return 0 }
    fun plusAssign(delta: Int) {}
    fun minusAssign(delta: Int) {}
    override fun toString(): String = value.toString()
}

class AtomicLong internal constructor(initial: Long) {
    var value: Long = initial
    fun compareAndSet(expected: Long, update: Long): Boolean { return false }
    fun getAndSet(value: Long): Long { return 0L }
    fun getAndIncrement(): Long { return 0L }
    fun getAndDecrement(): Long { return 0L }
    fun incrementAndGet(): Long { return 0L }
    fun decrementAndGet(): Long { return 0L }
    fun getAndAdd(delta: Long): Long { return 0L }
    fun addAndGet(delta: Long): Long { return 0L }
    fun plusAssign(delta: Long) {}
    fun minusAssign(delta: Long) {}
    override fun toString(): String = value.toString()
}

class AtomicBoolean internal constructor(initial: Boolean) {
    var value: Boolean = initial
    fun compareAndSet(expected: Boolean, update: Boolean): Boolean { return false }
    fun getAndSet(value: Boolean): Boolean { return false }
    override fun toString(): String = value.toString()
}

class AtomicRef<T> internal constructor(initial: T) {
    var value: T = initial
    fun compareAndSet(expected: T, update: T): Boolean { return false }
    fun getAndSet(value: T): T { return value }
    override fun toString(): String = value.toString()
}

// Upstream kotlinx.atomicfu exposes `atomic(initial)` as an overload
// set spanning the primitive types plus a generic reference-typed
// fallback. klio's top-level overload resolution scores each
// candidate by formal-parameter-type vs argument-runtime-type and
// picks the most specific match, so all four overloads coexist
// under the same name.
fun atomic(initial: Int): AtomicInt = AtomicInt(initial)
fun atomic(initial: Long): AtomicLong = AtomicLong(initial)
fun atomic(initial: Boolean): AtomicBoolean = AtomicBoolean(initial)
fun <T> atomic(initial: T): AtomicRef<T> = AtomicRef(initial)

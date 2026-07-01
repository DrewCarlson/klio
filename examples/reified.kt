// Reified type parameters on inline functions.
class Foo

inline fun <reified T> isAnInstance(value: Any): Boolean = value is T
inline fun <reified T> sname(): String? = T::class.simpleName
inline fun <reified T> isInst(v: Any): Boolean = T::class.isInstance(v)

fun <T : Throwable> viaParam(c: kotlin.reflect.KClass<T>, e: Throwable): Boolean = c.isInstance(e)
inline fun <reified T : Throwable> direct(e: Throwable): Boolean = T::class.isInstance(e)
inline fun <reified T : Throwable> indirect(e: Throwable): Boolean = viaParam(T::class, e)

// The splice must survive a trailing lambda whose body compound-assigns a
// captured name: `ticker += 5L` is a `plusAssign` member call on a `val`,
// and `count += 1` is a genuine write to a captured `var`. Either shape
// routed the call away from the inline splice, dropping the reified
// binding, so `T::class` read a stale global. The block also throws,
// with `T::class` read after `runCatching`, pinning the unwind path.
class Ticker {
    var reading: Long = 0L
    operator fun plusAssign(delta: Long) {
        if (delta > 0L) throw IllegalStateException("overflow")
        reading += delta
    }
}

inline fun <reified T : Any> probeAfterFailure(block: () -> Unit): String {
    runCatching(block)
    return T::class.simpleName ?: "?"
}

fun main() {
    println(isAnInstance<String>("hi"))
    println(isAnInstance<String>(7))
    println(isAnInstance<Int>(7))

    // `T::class` on a user class and on a builtin type, used for both
    // reflection reads and member calls.
    println(sname<Foo>())
    println(isInst<Foo>(Foo()))
    println(isInst<IllegalArgumentException>(IllegalArgumentException("x")))

    val e: Throwable = IllegalArgumentException("x")
    println(direct<IllegalArgumentException>(e))
    println(indirect<IllegalArgumentException>(e))

    val ticker = Ticker()
    println(probeAfterFailure<IllegalStateException> { ticker += 5L })
    var count = 0
    println(probeAfterFailure<IllegalStateException> { count += 1; ticker += 5L })
    println(count)
}

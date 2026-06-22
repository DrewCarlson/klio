// Reified type parameters on inline functions.
class Foo

inline fun <reified T> isAnInstance(value: Any): Boolean = value is T
inline fun <reified T> sname(): String? = T::class.simpleName
inline fun <reified T> isInst(v: Any): Boolean = T::class.isInstance(v)

fun <T : Throwable> viaParam(c: kotlin.reflect.KClass<T>, e: Throwable): Boolean = c.isInstance(e)
inline fun <reified T : Throwable> direct(e: Throwable): Boolean = T::class.isInstance(e)
inline fun <reified T : Throwable> indirect(e: Throwable): Boolean = viaParam(T::class, e)

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
}

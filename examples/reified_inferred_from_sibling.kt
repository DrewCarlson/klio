// A reified type argument of a call passed to a generic function is
// inferred from the other arguments: in `same("text", lookup())` the
// `T` of `lookup<T : Any>(): T?` is a `String`, and `same`'s own `T` a
// `String?`, which holds `lookup`'s null.
import kotlin.reflect.KClass

val registry: Map<KClass<*>, Any> = mapOf(String::class to "text", Int::class to 42)

inline fun <reified T : Any> lookup(): T? = registry[T::class] as T?

fun <T> same(expected: T, actual: T): Boolean = expected == actual

inline fun <reified T : Any> nameOf(): String = T::class.simpleName ?: "?"

fun <T> pair(a: T, b: T): String = "$a/$b"

fun main() {
    println(same("text", lookup()))
    println(same(42, lookup()))
    println(same(1L, lookup()))
    val typed: String? = lookup()
    println(typed)
    println(pair("x", lookup()))
    println(pair(7, lookup()))
    println(nameOf<String>())
}

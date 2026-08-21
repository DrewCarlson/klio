// A `reified` type parameter is solved from whatever the call site makes
// evident — an explicit `<T>`, the expected type, or an ARGUMENT's own static
// type. The last one is what `f(42)` and `f(local)` rely on: with it unsolved
// the body's `T::class` has nothing to name.
//
// Run with: klio run examples/reified_from_argument.kt

import kotlin.reflect.KClass

inline fun <reified T : Any> nameOf(value: T): String = T::class.simpleName ?: "?"

class Registry {
    val entries = mutableListOf<String>()
    fun <T : Any> put(key: KClass<T>, value: T) {
        entries.add((key.simpleName ?: "?") + "=" + value)
    }
}

inline fun <reified T : Any> Registry.put(value: T): Unit = put(T::class, value)

interface Handler<T> { fun handle(v: T): String }

inline fun <reified T : Any> describe(handler: Handler<T>): String =
    (T::class.simpleName ?: "?") + " -> " + handler.handle(sampleOf())

@Suppress("UNCHECKED_CAST")
inline fun <reified T : Any> sampleOf(): T = when (T::class.simpleName) {
    "Int" -> 7 as T
    else -> "s" as T
}

fun main() {
    println("literal  = " + nameOf(42))
    println("string   = " + nameOf("hi"))

    val flag = true
    println("local    = " + nameOf(flag))

    // Each call solves its own `T`: a shared cell would answer the previous
    // call's type for every later one.
    println("mixed    = " + nameOf(1) + "," + nameOf("x") + "," + nameOf('c'))

    val r = Registry()
    r.put(3)
    r.put("three")
    println("registry = " + r.entries)

    // Solved through the argument's declared type ARGUMENT: an object
    // literal's supertype is where its type arguments are written.
    val ints = object : Handler<Int> { override fun handle(v: Int) = "int:" + v }
    println("handler  = " + describe(ints))
}

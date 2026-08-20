// A `reified` type parameter is bound at the call site and stays bound inside
// the function's body, including when the body passes it on as the type
// argument of ANOTHER reified call. Binding it needs no explicit `<T>` at the
// call site when an argument's own type says what it is.
//
// Run with: klio run examples/reified_type_param_forwarding.kt

open class Animal(val name: String)
class Dog(name: String) : Animal(name)
class Cat(name: String) : Animal(name)

inline fun <reified T> nameOf(): String = T::class.simpleName ?: "?"

inline fun <reified U> isA(v: Any): Boolean = v is U

inline fun <reified E> firstOfType(items: List<Any>): E? {
    for (i in items) if (i is E) return i
    return null
}

// The reified parameter is forwarded to three further reified calls.
inline fun <reified T : Animal> describe(a: T, others: List<Any>): String {
    val n = nameOf<T>()
    val ok = isA<T>(a)
    val found = firstOfType<T>(others)
    return n + "/" + ok + "/" + (found as? Animal)?.name
}

// A reified parameter whose only evidence is the argument's own type.
inline fun <reified T : Throwable> failsWith(cause: T, block: () -> Unit): String {
    var caught: Throwable? = null
    try {
        block()
    } catch (e: Throwable) {
        caught = e
    }
    val matched = caught != null && caught is T
    return nameOf<T>() + " expected=" + (cause is T) + " matched=" + matched
}

fun main() {
    val pets: List<Any> = listOf("s", Cat("mia"), Dog("rex"), 7)

    // No explicit type argument: each call binds from its own argument.
    println(describe(Dog("rex"), pets))
    println(describe(Cat("mia"), pets))
    // An explicit argument binds the same way.
    println(describe<Animal>(Dog("rex"), pets))

    // Two calls to the same function must not share a binding.
    println(failsWith(IllegalStateException("x")) { throw IllegalStateException("boom") })
    println(failsWith(IllegalArgumentException("y")) { throw IllegalStateException("boom") })
    println(failsWith(IllegalArgumentException("y")) { })

    // Standalone reified calls still read their own argument.
    println(nameOf<Dog>() + "," + nameOf<String>() + "," + nameOf<Int>())
    println("" + isA<Dog>(Dog("a")) + isA<Cat>(Dog("a")) + isA<Animal>(Cat("b")))
    println("" + firstOfType<Dog>(pets)?.name + "," + firstOfType<Cat>(pets)?.name)
    println("" + firstOfType<String>(pets) + "," + firstOfType<Int>(pets))
}

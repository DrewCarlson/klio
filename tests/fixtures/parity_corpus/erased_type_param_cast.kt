// `x as T` for an erased type parameter is an unchecked cast — it always
// succeeds at runtime. It must not be affected by a reified type-argument
// from an unrelated call (here the earlier `typeName<Int>()`).
inline fun <reified T : Any> typeName(): String = T::class.simpleName ?: "?"

fun <T : Any> uncheckedCast(x: Any): T = x as T

class Box {
    fun <T : Any> get(x: Any): T = x as T
}

fun main() {
    println(typeName<Int>())
    println(uncheckedCast<String>("hello"))
    println(typeName<Double>())
    println(Box().get<String>("world"))
}

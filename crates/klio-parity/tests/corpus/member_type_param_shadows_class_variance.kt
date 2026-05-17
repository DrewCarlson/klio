// A member that declares its own type parameter of the same name as
// a class variance parameter shadows it; the class's `in`/`out`
// variance does not constrain that member's signature. Upstream
// kotlinx-coroutines CancellableContinuationImpl:
// `class CancellableContinuationImpl<in T> { fun <T> getSuccessfulResult(): T }`.
class Box<in T>(private var slot: Any?) {
    fun put(v: T) { slot = v }

    @Suppress("UNCHECKED_CAST")
    fun <T> get(): T = slot as T

    @Suppress("UNCHECKED_CAST")
    fun <R> getAs(): R = slot as R
}

fun main() {
    val b = Box<String>("hi")
    b.put("yo")
    println(b.get<String>())
    println(b.getAs<String>())
}

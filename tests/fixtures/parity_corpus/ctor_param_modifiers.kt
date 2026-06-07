// Primary-constructor `val`/`var` parameters may carry modifiers
// (`final override`, `open`, `private`, `abstract`). Upstream
// kotlinx-coroutines CancellableContinuationImpl declares
// `final override val delegate: Continuation<T>`.
interface HasD { val d: Int }
open class Base(open val r: Int)

class C(
    final override val d: Int,
    private val s: Int,
    public open val t: Int
) : Base(t), HasD {
    fun sum(): Int = d + s + t
}

fun main() {
    val c = C(1, 2, 3)
    println(c.sum())
    println(c.d)
    println(c.t)
    val h: HasD = c
    println(h.d)
    println(Base(9).r)
}

// An overload whose parameter is typed by a bounded type parameter is
// applicable only to arguments within the bound, so `foo(B())` picks the
// `<S : B>` overload over the `<S : C>` one; and a top-level value holding
// an anonymous extension function is callable with receiver syntax on a
// builtin receiver.
interface A
open class B : A
open class C : A

abstract class X {
    fun <S1 : A> foo(s: S1): String = when (s) {
        is B -> foo(s)
        is C -> foo(s)
        else -> throw AssertionError(s)
    }
    abstract fun <S2 : B> foo(s: S2): String
    abstract fun <S3 : C> foo(s: S3): String
}

class Y : X() {
    override fun <S4 : B> foo(s: S4): String = "B-bound"
    override fun <S5 : C> foo(s: S5): String = "C-bound"
}

val join = fun String.(y: String): String = this + "+" + y

fun main() {
    println(Y().foo(B()))
    println(Y().foo(C()))
    println("O".join("K"))
    println(join("a", "b"))
}

sealed class Expr<T>
class IntExpr(val v: Int) : Expr<Int>()
class StrExpr(val v: String) : Expr<String>()

fun <T> eval(e: Expr<T>): T = when (e) {
    is IntExpr -> e.v as T
    is StrExpr -> e.v as T
    else -> error("impossible")
}

fun main() {
    val a: Int = eval(IntExpr(42))
    val b: String = eval(StrExpr("hi"))
    println(a)
    println(b)
}

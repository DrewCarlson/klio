import mylib.Box
import mylib.B
import mylib.pick as pickOriginal

abstract class Base {
    abstract fun <T1, R> Box<T1>.go(other: Box<T1>, f: (T1, T1) -> R): R
    fun run(): String {
        val x = B("a"); val y = B("b")
        return x.go(y) { p, q -> "$p$q" }.toString()
    }
}

class VarargUser : Base() {
    override fun <T1, R> Box<T1>.go(other: Box<T1>, f: (T1, T1) -> R): R =
        pickOriginal(this, other) { args -> f(args[0], args[1]) }
}

class IterableUser : Base() {
    override fun <T1, R> Box<T1>.go(other: Box<T1>, f: (T1, T1) -> R): R =
        pickOriginal(listOf(this, other)) { args -> f(args[0], args[1]) }
}

fun main() {
    println("VarargUser:");   println("  => " + VarargUser().run())
    println("IterableUser:"); println("  => " + IterableUser().run())
}

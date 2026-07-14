// A member always wins over an extension with the same name — including on the
// builtin types. The extension's own `this.toInt()` therefore reaches the
// MEMBER, which is what lets a platform actual be written as a thin forwarder
// rather than recursing into itself.

fun Long.toInt(): Int = -1

val LongArray.size: Int
    get() = -1

fun Long.describe(): String = "long " + this.toInt()

fun main() {
    val n: Long = 7L
    println("member toInt = " + n.toInt())
    println("extension = " + n.describe())

    val a = longArrayOf(10L, 20L, 30L)
    println("member size = " + a.size)
}

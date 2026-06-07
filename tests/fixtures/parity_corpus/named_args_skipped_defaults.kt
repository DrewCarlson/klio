// A named-argument call that skips a non-trailing defaulted
// parameter must evaluate that parameter's default, not pass null.
fun mk(a: Int = 1, b: Int = 2, c: Int = 3, tail: Int = 4): String =
    "a=$a b=$b c=$c tail=$tail sum=${a + b + c + tail}"

fun main() {
    println(mk(b = 10, c = 20))
    println(mk(a = 9))
    println(mk(tail = 100))
    println(mk(7, 8, 9, 10))
}

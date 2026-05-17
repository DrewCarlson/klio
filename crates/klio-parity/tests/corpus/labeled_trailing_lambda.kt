// A trailing lambda argument may carry a label (`call lbl@ { ... }`);
// the label binds the lambda so `return@lbl` targets it. Upstream
// kotlinx-coroutines uses this shape pervasively.
fun f(b: () -> Int): Int = b()
fun g(x: Int, b: () -> Int): Int = x + b()

fun main() {
    println(f sc@{ 5 })
    println(g(1) lbl@ { 2 })
    println(f outer@{ return@outer 9 })
}

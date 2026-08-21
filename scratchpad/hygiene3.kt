class Box(val n: Int)

fun builder(body: () -> Int): Box = Box(body())
fun runIt(b: () -> Int): Int = b()

inline fun mid(v: Int): Box = builder { v }
inline fun outer(v: Int): Box = mid(v + 1)

fun main() {
    // local shadowing a global fn, declared INSIDE a lambda body
    val r = runIt {
        val builder = Box(99)
        outer(1).n + builder.n
    }
    println("in lambda = " + r)
}

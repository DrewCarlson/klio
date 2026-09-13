// A function's name in value position compiled to C. `::twice` is the function
// itself, which is the same shape a lambda that captures nothing takes: one
// instance for the life of the program, dispatched through the same adapter.
fun twice(n: Int): Int = n * 2
fun shout(s: String): String = s + "!"
fun add(a: Int, b: Int): Int = a + b

fun apply1(f: (Int) -> Int, x: Int): Int = f(x)
fun apply2(f: (Int, Int) -> Int, a: Int, b: Int): Int = f(a, b)

fun main() {
    val g = ::twice
    println(g(3))
    println(apply1(::twice, 4))
    println(apply2(::add, 2, 5))
    val s = ::shout
    println(s("hey"))
    // The reference is one value: naming it twice names the same function.
    println(apply1(g, 10))
}

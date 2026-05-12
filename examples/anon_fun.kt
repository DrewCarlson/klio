fun apply(f: (Int) -> Int, x: Int): Int = f(x)

fun caller(): Int {
    val doubler = fun(x: Int): Int {
        if (x > 0) return x * 2
        return -1
    }
    println(doubler(5))
    println(doubler(-3))
    return 99
}

fun main() {
    val add = fun(a: Int, b: Int): Int = a + b
    println(add(3, 4))
    println(apply(fun(x: Int): Int = x * x, 6))
    println(caller())
}

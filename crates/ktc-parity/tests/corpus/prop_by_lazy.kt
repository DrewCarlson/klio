var calls = 0

fun compute(): Int {
    calls += 1
    return 99
}

val expensive: Int by lazy { compute() }

fun main() {
    println("before: $calls")
    println(expensive)
    println(expensive)
    println(expensive)
    println("after: $calls")
}

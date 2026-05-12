interface Counter {
    companion object { var n = 0 }
    fun inc() { n++ }
    fun reset() { n = 0 }
}

class A : Counter
class B : Counter

fun main() {
    A().inc()
    A().inc()
    B().inc()
    println(Counter.n)
    A().reset()
    println(Counter.n)
    B().inc()
    println(Counter.n)
}

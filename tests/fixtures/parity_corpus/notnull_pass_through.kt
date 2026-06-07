fun main() {
    val a: String? = "hello"
    val b: String = a!!
    println(b)
    println(b.length)
    val n: Int? = 42
    println(n!! + 1)
}

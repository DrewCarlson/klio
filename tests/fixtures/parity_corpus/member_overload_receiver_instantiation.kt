class Box<T>(val t: T) {
    fun put(x: T): String = "one"
    fun put(xs: List<T>): String = "list"
}
fun main() {
    val b = Box<List<String>>(listOf("s"))
    val arg: List<String> = listOf("a")
    println(b.put(arg))
    val b2 = Box<String>("s")
    println(b2.put(arg))
}

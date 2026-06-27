class Box(val v: Int)
fun Box(s: String): Box = Box(s.length)   // factory overload of the class name
fun main() {
    val a = Box(5)
    val b = Box("hello")
    println(a.v)
    println(b.v)
}

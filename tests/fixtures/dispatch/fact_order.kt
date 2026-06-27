fun Box(s: String): Box = Box(s.length)
class Box(val v: Int)
fun main() {
    println(Box(5).v)
    println(Box("hello").v)
}

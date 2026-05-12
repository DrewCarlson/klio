class Box(val n: Int)

fun main() {
    val a = Box(1)
    val b = Box(1)
    println(a.hashCode() == a.hashCode())
    println(a.hashCode() != b.hashCode())
}

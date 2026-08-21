class Box(val serializer: String)

fun serializer(): String = "GLOBAL"

fun take(k: String, s: String) = println("value:$k:$s")
fun take(k: String, f: (List<String>) -> String) = println("func:$k")

fun main() {
    val b = Box("s")
    val v = b.serializer
    println("direct = $v")
    take("a", b.serializer)
}

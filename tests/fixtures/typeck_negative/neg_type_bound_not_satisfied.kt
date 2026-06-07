fun <T : Int> id(x: T): T = x

fun main() {
    val s: String = id<String>("hi")
    println(s)
}

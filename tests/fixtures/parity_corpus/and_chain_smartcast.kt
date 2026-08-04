fun Any.tag(): String = "any"
fun String.tag(): String = "str:" + length

fun main() {
    val v: Any = "abc"
    println(v is String && v.tag() == "str:3")
    println(v !is String && v.tag() == "str:3")
    val n: Int? = 5
    println(n == null || n + 1 == 6)
    val m: Int? = null
    println(m != null && m + 1 == 6)
}

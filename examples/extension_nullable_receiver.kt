fun String?.orEmpty2(): String = this ?: ""

fun Int?.orZero(): Int = this ?: 0

fun main() {
    val s: String? = null
    println("[${s.orEmpty2()}]")
    val t: String? = "hello"
    println("[${t.orEmpty2()}]")
    val n: Int? = null
    println(n.orZero())
    val m: Int? = 42
    println(m.orZero())
}

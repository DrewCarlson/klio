fun main() {
    val n: String? = null
    println(n is String?)
    println(n is Int?)
    println(n !is Any?)
    val v: Any? = null
    println(v is String?)
}

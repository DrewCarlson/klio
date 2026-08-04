class St<T>(var v: T)
fun pick(key: Any?, calc: () -> String): String = "keyed:" + calc()
fun pick(calc: () -> String): String = "plain:" + calc()
fun main() {
    val s = St(1)
    println(pick(s) { "x" })
    println(pick { "y" })
}

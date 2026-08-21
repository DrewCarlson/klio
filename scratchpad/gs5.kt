class Contents { var tz: String? = null }
class Facade(val contents: Contents = Contents()) { var tz: String? by contents::tz }

fun churn(n: Int): Int {
    var acc = 0
    for (i in 0 until n) { val s = "x" + i; acc += s.length }
    return acc
}

fun main() {
    val f = Facade()
    f.tz = "America/" + "New_York"
    println("immediately  = " + f.tz)
    churn(50)
    println("after churn  = " + f.tz)
    println("via contents = " + f.contents.tz)
}

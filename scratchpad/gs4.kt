class Contents {
    var tz: String? = null
    var num: Int = 0
}

class Facade(val contents: Contents = Contents()) {
    var tz: String? by contents::tz
    var num: Int by contents::num
}

fun main() {
    val f = Facade()
    f.num = 7
    f.tz = "America/" + "New_York"
    println("tz=" + f.tz + " num=" + f.num)
    val g = Facade()
    g.tz = "Europe/Berlin".substring(0)
    println("g.tz=" + g.tz + " direct=" + g.contents.tz)
}

annotation class Marker
annotation class Tagged(val name: String, val priority: Int)

@Marker
class Plain(val tag: String)

@Tagged(name = "alpha", priority = 1)
class Decorated(val id: Int, val label: String)

fun main() {
    val p = Plain("hello")
    val d = Decorated(7, "world")
    println(p.tag)
    println(d.id)
    println(d.label)
}

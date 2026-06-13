package app
class Greeter { fun greet(name: String = "member"): String = "member-$name" }
fun main() {
    val g = Greeter()
    g.apply { println(greet()) }
}

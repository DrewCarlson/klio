annotation class Marker
annotation class Tagged(val name: String, val priority: Int)

@Marker
class Foo(val n: Int)

@Tagged(name = "bar", priority = 1)
class Bar(val label: String)

fun main() {
    val f = Foo(1)
    val b = Bar("hi")
    println(f.n)
    println(b.label)
}

class Foo
class Bar

fun main() {
    val a = Foo::class
    val b = Foo::class
    val c = Bar::class
    println(a == b)
    println(a == c)
    println(a != c)
    println(a.hashCode() == b.hashCode())
}

// expect-error: T0063
class Base {
    fun greet(): String = "hi"
}
class Derived : Base() {
    fun bye(): String = "bye"
}
fun main() { println(Derived().greet()) }

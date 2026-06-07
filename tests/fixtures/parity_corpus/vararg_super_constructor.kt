open class Base(vararg xs: String) {
    val items: List<String> = mutableListOf(*xs)
    fun show() = items.joinToString(",")
}
class One : Base("a")
class Two : Base("a", "b")
class Zero : Base()
fun main() {
    println(One().show())
    println(Two().show())
    println(Zero().show())
}

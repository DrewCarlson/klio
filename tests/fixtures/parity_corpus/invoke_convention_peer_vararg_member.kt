abstract class H<T>(val make: (Array<out String>) -> T) {
    fun make(vararg items: String): T = make(items)
}

class HH(make: (Array<out String>) -> List<String>) : H<List<String>>(make)

fun main() {
    val h = HH({ arr -> arr.toList() })
    println(h.make("a", "b"))
}

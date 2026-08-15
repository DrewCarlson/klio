// A declaration deprecated at level ERROR is un-callable without
// @Suppress("DEPRECATION_ERROR"): resolution never binds it, so the
// member wins even where the deprecated extension's signature matches
// the arguments more exactly (the stdlib's Java-compat
// MutableList.remove(index) must not steal remove(element)).
class Bag<T> {
    val items = mutableListOf<T>()
    fun put(v: T): String {
        items.add(v)
        return "member:$v"
    }
}

@Deprecated("Use put instead.", level = DeprecationLevel.ERROR)
fun Bag<Int>.put(v: Int): String = "deprecated-ext:$v"

fun main() {
    val bag = Bag<Int>()
    println(bag.put(3))
    val list = mutableListOf(0, 1, 2, 3, 4, 5, 6)
    val sub = list.subList(2, 5)
    println(sub.remove(3))
    println(list)
}

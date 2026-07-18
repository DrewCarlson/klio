// A MutableMap's keys / values / entries views write through for removal
// but never support insertion: add/addAll throw UnsupportedOperationException.

fun main() {
    val map = mutableMapOf(1 to "a", 2 to "b")
    try {
        map.keys.add(9)
        println("keys.add: no throw")
    } catch (e: UnsupportedOperationException) {
        println("keys.add: threw")
    }
    try {
        map.values.add("z")
        println("values.add: no throw")
    } catch (e: UnsupportedOperationException) {
        println("values.add: threw")
    }
    try {
        map.entries.addAll(emptyList())
        println("entries.addAll: no throw")
    } catch (e: UnsupportedOperationException) {
        println("entries.addAll: threw")
    }
    map.keys.remove(1)
    println("after keys.remove size=" + map.size)
    map.values.remove("b")
    println("after values.remove size=" + map.size)
}

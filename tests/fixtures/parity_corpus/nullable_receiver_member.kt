// A nullable receiver binds its member when the name declares no `T?`
// extension: Kotlin has only one legal target for `x.f()` there.
class Node(val label: String) {
    fun describe(): String = "node:$label"
}

fun show(n: Node?): String {
    if (n == null) return "none"
    return n.describe()
}

fun lengthOf(s: String?): Int {
    if (s == null) return -1
    return s.length
}

fun main() {
    println(show(Node("a")))
    println(show(null))
    println(lengthOf("abcd"))
    println(lengthOf(null))
    val maybe: String? = "xy"
    println(maybe?.uppercase() ?: "-")
    val absent: String? = null
    println(absent?.uppercase() ?: "-")
}

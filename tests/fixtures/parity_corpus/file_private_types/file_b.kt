// An object with a private nested class whose simple name collides with
// file_a.kt's file-private typealias (the ktor engines.Node shape).
object registry {
    private var head: Node? = null

    fun append(item: String) {
        head = Node(item, head)
    }

    fun render(): String {
        var out = ""
        var cur = head
        while (cur != null) {
            out += cur.item
            cur = cur.next
        }
        return out
    }

    private class Node(
        val item: String,
        val next: Node?
    )
}

fun main() {
    registry.append("x")
    registry.append("y")
    println(registry.render())
    println(walk(chain()))
}

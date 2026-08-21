class Node(val n: Int)
class NodeList {
    val nodes = listOf(Node(1), Node(2))
    fun close(flag: Int): Boolean { return flag > 0 }
    inline fun forEach(block: (Node) -> Unit) { for (n in nodes) block(n) }
}

class Holder(val tag: String) {
    private inline fun notifyHandlers(list: NodeList, cause: String?, predicate: (Node) -> Boolean) {
        var exception: String? = null
        list.forEach { node ->
            if (predicate(node)) {
                try {
                    println("  $tag ${node.n} $cause")
                } catch (ex: Throwable) {
                    exception = "Exception in handler $node for $this"
                }
            }
        }
        if (exception != null) println(exception)
    }

    private fun NodeList.notifyCompletion(cause: String?) {
        close(1)
        notifyHandlers(this, cause) { true }
    }

    fun run() { NodeList().notifyCompletion("c") }
}

fun main() { Holder("h").run(); println("ok") }

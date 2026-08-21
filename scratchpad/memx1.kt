class Node(val n: Int)
class Holder(val tag: String) {
    private inline fun helper(x: Node, p: (Node) -> Boolean): String =
        if (p(x)) tag + x.n else tag + "-"

    private fun plainHelper(x: Node): String = tag + "!" + x.n

    // A member EXTENSION on a different type: `this` is the Node, and a bare
    // call must reach Holder's own member through the dispatch receiver.
    private fun Node.viaInline(): String = helper(this) { true }
    private fun Node.viaPlain(): String = plainHelper(this)

    fun run(): String = Node(7).viaInline() + "/" + Node(8).viaPlain()
}

fun main() { println(Holder("h").run()) }

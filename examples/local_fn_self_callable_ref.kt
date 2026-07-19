// A `::name` reference to the ENCLOSING local function, taken from inside
// that function's own body, denotes the function itself. The plain name is
// unbound at that point (and a later same-named sibling could rebind it), so
// the reference must load the local fn's own closure through its mangled
// self-cell -- the same binding a bare self-call uses -- rather than a
// property of whatever the reference is later applied to. Used recursively
// through `forEach(::addToMap)`, this walks a tree.

class Node(val id: Int, val kids: List<Node>)

fun preorder(root: Node): List<Int> {
    val out = mutableListOf<Int>()
    fun visit(n: Node) {
        out.add(n.id)
        n.kids.forEach(::visit)
    }
    visit(root)
    return out
}

fun main() {
    val tree = Node(1, listOf(Node(2, listOf(Node(4, emptyList()))), Node(3, emptyList())))
    println(preorder(tree))

    // The self reference stored in a local then invoked.
    fun countdown(x: Int) {
        println(x)
        val self = ::countdown
        if (x > 0) self(x - 1)
    }
    countdown(2)
}

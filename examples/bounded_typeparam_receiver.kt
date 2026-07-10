// A generic extension with where-bounds never binds a receiver outside the
// bounds, even inside a member-extension body whose static receiver is a
// different type — `observeReads` must bind the node, not the draw scope.

interface Node { val id: Int }
interface Observer { fun onChanged(): String }

fun <T> T.observe(): String where T : Node, T : Observer = "observed:${id}:${onChanged()}"

interface CanvasScope { val width: Int }

class DrawImpl : CanvasScope { override val width = 99 }

class DrawNode : Node, Observer {
    override val id = 3
    override fun onChanged() = "ok"

    fun CanvasScope.draw(): String {
        // Candidates here include the CanvasScope receiver; only the node
        // satisfies the bounds.
        return observe()
    }
}

fun main() {
    val n = DrawNode()
    val r = with(n) { DrawImpl().draw() }
    println(r)
}

// Subcomposition — a child Composition reparented to its parent via
// rememberCompositionContext(). The child emits into its own node tree, yet
// recomposes under the parent's Recomposer: a state write that only the child
// read recomposes just the child, driven through the shared recomposer. This is
// the primitive SubcomposeLayout (lazy lists, constraint-driven content) needs.

import androidx.compose.runtime.AbstractApplier
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.CompositionContext
import androidx.compose.runtime.ComposeNode
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCompositionContext

class Node(val kind: String) {
    var text: String = ""
    val children = mutableListOf<Node>()

    fun dump(): String {
        val sb = StringBuilder()
        sb.append(kind)
        if (text.isNotEmpty()) {
            sb.append("[")
            sb.append(text)
            sb.append("]")
        }
        if (children.isNotEmpty()) {
            sb.append("{")
            for (c in children) sb.append(c.dump())
            sb.append("}")
        }
        return sb.toString()
    }
}

class NodeApplier(root: Node) : AbstractApplier<Node>(root) {
    override fun insertTopDown(index: Int, instance: Node) {
        current.children.add(index, instance)
    }
    override fun insertBottomUp(index: Int, instance: Node) {}
    override fun remove(index: Int, count: Int) {
        var i = 0
        while (i < count) {
            current.children.removeAt(index)
            i += 1
        }
    }
    override fun move(from: Int, to: Int, count: Int) {}
    override fun onClear() {
        root.children.clear()
    }
}

@Composable
fun Label(t: String) {
    ComposeNode<Node, NodeApplier>(
        factory = { Node("Label") },
        update = { set(t) { text = it } },
    )
}

fun main() {
    val recomposer = Recomposer()
    val count = mutableStateOf(0)

    // Parent composition into its own node tree.
    val parentRoot = Node("ParentRoot")
    val parent = Composition(NodeApplier(parentRoot), recomposer)

    var childContext: CompositionContext? = null
    parent.setContent {
        childContext = rememberCompositionContext()
        Label("parent")
    }

    // A child composition reparented to the parent's context — its own node tree,
    // but driven by the same recomposer.
    val childRoot = Node("ChildRoot")
    val child = Composition(NodeApplier(childRoot), childContext!!)
    child.setContent {
        Label("child=" + count.value)
    }

    println("initial:")
    println("  parent: " + parentRoot.dump())
    println("  child:  " + childRoot.dump())

    // Only the child read `count`. A write invalidates only the child; the parent's
    // recomposer recomposes it (proof it tracks the reparented subcomposition).
    count.value = 42
    recomposer.recompose()
    println("after count=42 + recompose:")
    println("  parent: " + parentRoot.dump())
    println("  child:  " + childRoot.dump())

    child.dispose()
    parent.dispose()
    println("disposed; child children=" + childRoot.children.size)
}

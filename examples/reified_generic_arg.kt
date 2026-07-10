// Reified type-argument inference from a generic-class argument: the
// dispatchForKind shape — `kind: NodeKind<T>` binds T from the argument's
// generic type (a ctor call with explicit type args, reached through an
// inline-val getter), so `is T` inside the spliced body checks the real class.
class NodeKind<T>(val mask: Int)

interface DrawNode
interface PointerNode

class Background : DrawNode
class Clickable : PointerNode

object Nodes {
    inline val Draw get() = NodeKind<DrawNode>(1)
    inline val Pointer get() = NodeKind<PointerNode>(2)
}

open class Node

inline fun <reified T> Node.dispatchForKind(kind: NodeKind<T>, block: (T) -> Unit) {
    if (this is T) block(this) else println("miss(mask=${kind.mask})")
}

class BgNode : Node(), DrawNode {
    override fun toString() = "BgNode"
}

fun main() {
    val n: Node = BgNode()
    n.dispatchForKind(Nodes.Draw) { println("draw: $it") }
    n.dispatchForKind(Nodes.Pointer) { println("pointer: $it") }
}

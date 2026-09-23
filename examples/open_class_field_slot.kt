// An open class's property can be read by index only when no subclass answers
// the name differently. The layout is base-prefixed, so a subclass instance
// holds the base's cell at the base's index; what breaks the read is an
// override, not the inheritance. Both cases are below, and they must print the
// subclass's answer wherever one exists.
//
// Run with: klio run examples/open_class_field_slot.kt

open class Node(val id: Int) {
    open val label: String = "node$id"
    val depth: Int = id * 2
}

// Overrides the stored property with an accessor: a read through `Node` must
// not take the base's cell.
class Named(id: Int, private val who: String) : Node(id) {
    override val label: String get() = "named:$who"
}

// Overrides it with its own stored cell.
class Tagged(id: Int) : Node(id) {
    override val label: String = "tagged$id"
}

// Adds nothing: the base's cell answers for it.
class Plain(id: Int) : Node(id)

// A body property, not a constructor one, and inherited through a class that
// overrides it two different ways. The accessor override contributes no cell,
// so a read that took the inherited slot would answer the base's seed.
open class Shape {
    open val sides: Int = 0
    val corners: Int = 7
}

class Square : Shape() {
    override val sides: Int get() = 4
}

class Tri : Shape() {
    override val sides: Int = 3
}

class Box : Shape()

fun readLabel(n: Node): String = n.label
fun readDepth(n: Node): Int = n.depth

fun main() {
    val nodes = listOf(Node(1), Named(2, "b"), Tagged(3), Plain(4))
    for (n in nodes) println(readLabel(n) + "/" + readDepth(n))

    // Read through the declared type as well as the runtime one.
    val named: Node = Named(7, "g")
    println(named.label)
    println((named as Named).label)

    // A base whose property no subclass touches, and one two subclasses
    // answer their own way. Read through the base type and the exact one.
    for (sh in listOf(Shape(), Square(), Tri(), Box())) {
        println("" + sh.sides + "," + sh.corners)
    }
    println(Square().sides)
    println(Tri().sides)
    println(Box().corners)
}

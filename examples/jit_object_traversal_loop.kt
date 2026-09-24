// Walking a linked structure built from `Node` objects: the loop guard is a
// null check on the `next` link, and the body reads a scalar field and calls
// a method on each node.
class Node(val v: Int, val next: Node?) {
    fun weight(): Int = v * 2
}

fun main() {
    var head: Node? = null
    var k = 0
    while (k < 1000) {
        head = Node(k, head)
        k = k + 1
    }

    var total = 0L
    var rounds = 0
    while (rounds < 2000) {
        var sum = 0
        var cur: Node? = head
        while (cur != null) {
            sum = sum + cur.v + cur.weight()
            cur = cur.next
        }
        total = total + sum
        rounds = rounds + 1
    }

    println("total=$total")
}

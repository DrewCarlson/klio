// A hot loop that walks a linked structure: the cursor is a boxed object register
// reassigned through an object field each iteration, the loop guard is an
// object-vs-null test, and the body reads a scalar field and calls a method on the
// node. The loop JIT keeps the cursor in the frame's register array (a GC root, so
// it survives the method call) and drives the traversal natively, delegating each
// object operation to a callback. Output must match with the JIT off (default) or
// on (KLIO_JIT=1).
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

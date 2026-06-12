// A file-private typealias over a class, with cross-file member walks
// through the alias (the kotlinx-coroutines LockFreeLinkedList shape).
class ListNode(val label: String) {
    var next: ListNode? = null
}

private typealias Node = ListNode

fun chain(): Node {
    val a = Node("a")
    val b = Node("b")
    a.next = b
    return a
}

fun walk(start: Node): String {
    var cur: Node? = start
    var out = ""
    while (cur != null) {
        out += cur.label
        val n = cur.next
        cur = n as Node?
    }
    return out
}

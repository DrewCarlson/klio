// A typealias constructs its expansion: `Node("a")` is a ListNode
// constructor call. This must hold in the default package too, where the
// alias registers under its bare name, and for a file-private alias whose
// simple name collides with a private nested class in another scope.
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

fun main() {
    var cur: ListNode? = chain()
    var out = ""
    while (cur != null) {
        out += cur.label
        cur = cur.next
    }
    println(out)
}

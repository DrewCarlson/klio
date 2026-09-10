// Methods called on a receiver the loop REBINDS each iteration (a linked-list
// cursor). `node.m()` lowers to a static call with the receiver moved into arg 0;
// lowering has already chosen the body, so the loop JIT splices it in place with
// no dispatch guard, and the body's `this`-field accesses read whichever receiver
// the iteration holds. Covers a no-arg method, one taking arguments, one that
// mutates a field, and a second class walked by the same shape.
// Output must match with the JIT off (--opt safe) or on (default).
class Node(val v: Int, var acc: Int, val next: Node?) {
    fun weight(): Int = v * 2
    fun scaled(m: Int, o: Int): Int = v * m + o
    fun bump(d: Int) {
        acc = acc + d
    }
    fun readAcc(): Int = acc
}

class Other(val v: Int, val next: Other?) {
    fun weight(): Int = v * 3
}

fun main() {
    var head: Node? = null
    var k = 0
    while (k < 200) {
        head = Node(k, 0, head)
        k += 1
    }

    var weights = 0L
    var cur: Node? = head
    while (cur != null) {
        weights += cur.weight().toLong()
        cur = cur.next
    }
    println("weights=$weights")

    var scaled = 0L
    cur = head
    while (cur != null) {
        scaled += cur.scaled(3, 7).toLong()
        cur = cur.next
    }
    println("scaled=$scaled")

    var mutated = 0L
    var round = 0
    while (round < 3) {
        cur = head
        while (cur != null) {
            cur.bump(round + 1)
            mutated += cur.readAcc().toLong()
            cur = cur.next
        }
        round += 1
    }
    println("mutated=$mutated")

    var oh: Other? = null
    k = 0
    while (k < 200) {
        oh = Other(k, oh)
        k += 1
    }
    var others = 0L
    var oc: Other? = oh
    while (oc != null) {
        others += oc.weight().toLong()
        oc = oc.next
    }
    println("others=$others")
}

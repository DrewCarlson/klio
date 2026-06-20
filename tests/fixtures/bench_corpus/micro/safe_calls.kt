// Null-safe call chains in a hot loop: each `?.` guards with a null
// comparison, which must be an identity check — never an `equals`
// member dispatch.
class Link(val v: Int, val next: Link?)
fun main() {
    val head = Link(1, Link(2, Link(3, null)))
    var s = 0
    var i = 0
    while (i < 40000) {
        val a = head.next?.next?.v ?: -1
        val b = head.next?.v ?: 0
        s = (s + a + b + i) and 0x7fffffff
        i += 1
    }
    println(s)
}

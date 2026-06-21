// Null-safe chains in a hot loop whose final value is a nullable scalar
// (`Int?` from a `?.` on a scalar field) folded with `?:`. The loop JIT keeps the
// nullable scalar in a register typed by its scalar kind plus a companion
// null-flag slot, so the null tests, the Elvis default, and the surrounding
// arithmetic all run natively. Output must match with the JIT off (default) or
// on (KLIO_JIT=1).
class Link(val v: Int, val next: Link?)

fun main() {
    val head = Link(1, Link(2, Link(3, null)))
    var s = 0
    var i = 0
    while (i < 200000) {
        val a = head.next?.next?.v ?: -1
        val b = head.next?.v ?: 0
        s = (s + a + b + i) and 0x7fffffff
        i = i + 1
    }
    println(s)
}

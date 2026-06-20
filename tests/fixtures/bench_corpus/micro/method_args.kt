// Instance methods called WITH arguments in a hot loop: the n-arg member
// dispatch path (cache keyed on the argument type signature) plus the
// per-call frame setup whose receiver chain must stay off the page
// allocator.
class Acc(var total: Int) {
    fun add(x: Int): Int { total += x; return total }
    fun mix(a: Int, b: Int): Int = a * 2 + b - total
}
fun main() {
    val acc = Acc(0)
    var s = 0
    var i = 0
    while (i < 40000) {
        s = (s + acc.add(i) + acc.mix(i, i + 1)) and 0x7fffffff
        i += 1
    }
    println(s)
}

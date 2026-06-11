// An anonymous-function body resolves bare names against the lexically
// enclosing receivers exactly like a lambda body: member calls, member
// reads, interpolation, and bare writes all reach the with-receiver.
class Box {
    fun payload(): String = "member-fn"
    val tag = "member-prop"
    var label = "init"
}
var label = "global"

fun main() {
    with(Box()) {
        val f = fun(): String { return payload() }
        println(f())
        val g = fun(): String { return "tag=$tag" }
        println(g())
        val w = fun() { label = "set-by-anon" }
        w()
        println(label)
    }
    println(label)
}

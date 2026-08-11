// A receiver lambda keeps its receiver context when ASSIGNED (not just
// declared): reassignment to a typed local and assignment into a field whose
// declared type is `Scope.() -> R` both resolve bare member calls through the
// receiver bound at invocation (androidx's CacheDrawScope draw-block field).
class Scope {
    var recorded: String? = null
    fun onDraw(s: String) { recorded = s }
}

class Node {
    var block: (Scope.() -> String)? = null
}

fun main() {
    var h: Scope.() -> String = { "init" }
    h = { onDraw("local"); "rl" }
    val s1 = Scope()
    println(h(s1) + " " + s1.recorded)

    val n = Node()
    n.block = { onDraw("field"); "rf" }
    val s2 = Scope()
    println(n.block!!.invoke(s2) + " " + s2.recorded)
}

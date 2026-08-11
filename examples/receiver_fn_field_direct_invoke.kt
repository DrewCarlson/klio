// A receiver-function-typed property invoked bare with an implicit receiver
// in scope runs WITH that receiver: block!!() directly inside scope.apply{}
// binds scope as the lambda's this (androidx CacheDrawScope's draw block).
class Scope {
    var recorded: String? = null
    fun onDraw(s: String) { recorded = s }
}

class Node {
    var block: (Scope.() -> String)? = null
    val scope = Scope()
    var result: String? = null
    fun direct() { scope.apply { result = block!!() } }
}

fun main() {
    val n = Node()
    n.block = { onDraw("hit"); "r" }
    n.direct()
    println(n.result + " " + n.scope.recorded)
}

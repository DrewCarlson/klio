// A bare member write inside an inline-spliced receiver lambda whose receiver
// does NOT declare the property lands on the enclosing class's member — not
// on a phantom dynamic field of the splice receiver.
class Scope

class Node {
    val scope = Scope()
    var result: String? = null
    fun run() {
        scope.apply { result = "wrote" }
    }
}

fun main() {
    val n = Node()
    n.run()
    println(n.result)
}

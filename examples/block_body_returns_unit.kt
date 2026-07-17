// A block-bodied function with no return statement returns Unit — never
// the value of its last statement. `fun f() { 42 }` yields Unit; the
// elvis on an invoked block body must see Unit, not a leaked tail value.
package examples.blockret

fun tail(): Unit {
    42
}

fun tailInferred() {
    "leak?"
}

fun lastIsCall() {
    listOf(1, 2, 3).sum()
}

fun main() {
    val a: Any = tail()
    val b: Any = tailInferred()
    val c: Any = lastIsCall()
    println(a)
    println(b)
    println(c)
    // The same rule holds for a LOCAL fun's block body — it lowers through
    // the lambda path but keeps function semantics, while an expression
    // body and a lambda literal keep their values.
    fun localTail() {
        42
    }
    fun localExpr() = 7
    val d: Any = localTail()
    println(d)
    println(localExpr())
    val lambdaKeepsValue = { 5 }
    println(lambdaKeepsValue())
}

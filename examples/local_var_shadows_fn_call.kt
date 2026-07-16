// A local `var` initialized with a literal does not shadow a same-named
// function at a call site: an Int is not invokable, so the call binds
// the function (the composer's movable-content insert pattern).
package p

private fun nodeIndex(a: Int, b: Int): Int = a * 10 + b

fun main() {
    var nodeIndex = 0
    nodeIndex += 1
    println(nodeIndex + nodeIndex(2, 3))
}

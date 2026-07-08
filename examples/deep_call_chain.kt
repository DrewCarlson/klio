// Regression: a deep method-call chain must typecheck in linear time. Re-typing
// the receiver at every level (as the checker used to for member-method calls)
// makes a chain of depth N cost O(2^N) — a 40-deep chain hung the type checker.
fun main() {
    val sb = StringBuilder()
    val x = 1.5f
    sb.append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x).append(x)
    println(sb.toString().length)
}

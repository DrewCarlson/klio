// A hot loop invoking a loop-invariant closure each iteration. The loop JIT keeps
// the closure boxed in the frame's register array and trampolines the call,
// passing scalar args through slots while the loop control runs natively. The
// closure captures and mutates an outer variable. Output must match with the JIT
// off (default) or on (KLIO_JIT=1).
fun main() {
    var acc = 0L
    val add = { n: Int -> acc += n.toLong() }
    var i = 0
    while (i < 200000) {
        add(i)
        i = i + 1
    }
    println(acc)
}

// A hot loop whose body is nothing but member calls on one object: the shape
// where the whole-function tier must NOT take the body off the fused walk. It
// compiles the method but the seam refuses a unit that can deopt, so yielding
// for it would buy a framed activation per call and run the compiled code
// never. Output must match with the JIT off (--opt safe) or on (default).
class Counter {
    var n = 0
    fun bump(k: Int) { n += k }
    fun value(): Int = n
}

fun main() {
    val c = Counter()
    var i = 0
    while (i < 200_000) {
        c.bump(1)
        i += 1
    }
    println("n=" + c.value())
}

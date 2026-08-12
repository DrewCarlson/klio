// Regression: a lexical local extension must bind on a receiver whose
// DECLARED type came from an explicit-generic factory call. The derived
// static type (`MutableList`, arguments erased) used to refute both the
// same-classifier arity check and the builtin List/MutableList hierarchy
// walk, so `l.allSame()` missed at runtime.
fun main() {
    val l = mutableListOf<Int>()
    l.add(1)
    l.add(1)
    fun List<Int>.allSame() = forEach { check(it == first()) }
    l.allSame()
    fun MutableList<Int>.total(): Int { var s = 0; for (x in this) s += x; return s }
    println(l.total())
    println("local-ext-declared-receiver ok")
}

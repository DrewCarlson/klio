// numeric fidelity: cross-type comparison through compareTo and
// natural ordering operators (kotlinc forbids cross-type `==` at compile
// time, so the test focuses on the operators that *are* legal).

fun main() {
    println(1 < 1L)
    println(1L < 2)
    println(1L < 1.5)
    println(1.5 > 1L)
    println(1.0f.compareTo(1.0f))
    println(2.0f.compareTo(1.0f))
    println(1.compareTo(1L))
    println(1L.compareTo(1))
    println(1L.compareTo(2L))
}

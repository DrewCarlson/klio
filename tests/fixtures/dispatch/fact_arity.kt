class Pt(val x: Int, val y: Int)
fun Pt(s: String): Pt = Pt(s.length, 0)
fun main() {
    println(Pt(1, 2).x)        // ctor, arity 2
    println(Pt("abc").x)       // factory, arity 1
}

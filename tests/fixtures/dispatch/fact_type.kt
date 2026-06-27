class Wrap(val n: Int)
fun Wrap(label: String): Wrap = Wrap(label.length)
fun describe(w: Wrap) = "n=${w.n}"
fun main() {
    val a = Wrap(10)     // should be ctor -> n=10
    println(describe(a))
}

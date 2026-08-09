// A generic class's type arguments infer from its constructor arguments
// (kotlinc's inference): a bare-E param takes its argument's type, an
// X<..., E, ...> param takes the argument's type argument at that position.
class Box<out E>(val data: Collection<E>)
class Pair2<A, B>(val a: A, val b: B)
fun main() {
    val bx = Box(listOf("a", "b"))
    println(bx.data.toTypedArray().asList())
    val p = Pair2("x", 3)
    println(p.a.length)
    println(p.b + 1)
}

// A local is not in scope inside its own initializer, so `val f = f()` calls
// the function `f`, not the local. Lowering re-asks about the initializer from
// a later point in the block, where the local IS bound, and the local shadowed
// the very call that produced it — so the local got no static type. Extensions
// resolve against the STATIC type, which is where that shows.
open class Base
class Derived : Base()

fun Base.tag(): String = "base"
fun Derived.tag(): String = "derived"

fun makeBase(): Base = Derived()
fun makeDerived(): Derived = Derived()

class Bag(private val items: List<String>) {
    fun iterator(): Iterator<String> = items.iterator()

    // The shape the stdlib is full of: the local takes the name of the member
    // call that fills it.
    fun joined(): String {
        val iterator = iterator()
        var out = ""
        while (iterator.hasNext()) out += iterator.next()
        return out
    }
}

fun main() {
    val makeBase = makeBase()
    println(makeBase.tag())

    val makeDerived = makeDerived()
    println(makeDerived.tag())

    println(Bag(listOf("a", "b", "c")).joined())

    // A name that DOES belong to an enclosing local must still win: this `pick`
    // is the lambda, not the function.
    val pick = { "lambda" }
    run {
        val pick = pick()
        println(pick)
    }
}

fun pick(): String = "function"

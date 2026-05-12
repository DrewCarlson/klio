// M28 upper bounds + multi-bound `where` clause.
interface Named { fun named(): String }
interface Sized { fun size(): Int }

class Tag(val n: String, val s: Int) : Named, Sized {
    override fun named(): String = n
    override fun size(): Int = s
}

fun <T : Comparable<T>> maxOfPair(a: T, b: T): T = if (a >= b) a else b

fun <T> describe(t: T): String where T : Named, T : Sized {
    return "${t.named()}#${t.size()}"
}

fun main() {
    println(maxOfPair(3, 9))
    println(maxOfPair("alpha", "omega"))
    println(describe(Tag("alpha", 3)))
}

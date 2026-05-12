interface Named { fun named(): String }
interface Sized { fun size(): Int }

class Tag(val n: String, val s: Int) : Named, Sized {
    override fun named(): String = n
    override fun size(): Int = s
}

fun <T> describe(t: T): String where T : Named, T : Sized {
    return "${t.named()}#${t.size()}"
}

fun main() {
    println(describe(Tag("alpha", 3)))
}

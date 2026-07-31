// A data class's `componentN` accessors are members of the class. They were
// synthesized only at dispatch time, so member resolution found nothing at a
// `component2()` call site and fell through to EXTENSION lookup — where the
// stdlib's `Map.Entry.component2` matched any class named `Entry` by simple
// head and read a `value` field the class does not have. The name in the
// program is correct Kotlin and must keep working unchanged.
data class Entry(val key: String, val num: Int)

data class Boxed<T>(val item: T, val tag: String)

// A hand-written accessor wins over the synthesized one, and destructuring
// goes through it.
data class Custom(val a: Int, val b: Int) {
    fun component2(): Int = b * 100
}

fun main() {
    val e = Entry("a", 1)
    println(e.component1() + "/" + e.component2())

    val (k, n) = e
    println(k + "/" + n)

    // The accessor's return type is the property's declared type, including
    // through a type parameter.
    val (items, tag) = Boxed(listOf(1, 2, 3), "t")
    println(items.sum().toString() + "/" + tag)

    println(Custom(1, 2).component2())
    val (p, q) = Custom(1, 2)
    println(p.toString() + "/" + q)

    // The real `Map.Entry` still resolves to its own accessors.
    val m = mapOf("x" to 1)
    for ((mk, mv) in m) println(mk + "=" + mv)
    for (me in m.entries) println(me.component1() + ":" + me.component2())

    // The rest of the data-class surface is unchanged.
    println(e.toString())
    println(e == Entry("a", 1))
    println(e.copy(num = 3).toString())
}

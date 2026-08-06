open class Base(val label: String)

class Derived(seed: Int, tag: String = seed.inv().toString(16)) : Base(tag.uppercase()) {
    constructor(seed1: Int, seed2: Int) : this(seed1 xor seed2, seed1.inv().toString(2))

    val shown: String = label
}

class Wrap(val items: Array<String>) {
    constructor(single: String) : this(listOf(single, single.uppercase()).toTypedArray())
    fun joined(): String = items.joinToString("/")
}

fun main() {
    println(Derived(5).shown)
    println(Derived(6, 3).shown)
    println(Wrap("ab").joined())
}

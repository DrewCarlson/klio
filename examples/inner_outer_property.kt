// An inner class reading the outer instance's overridden property must
// dispatch the override virtually (not read an inherited null/base backing
// slot). This is what makes AbstractMutableList work: its inner iterator
// reads the outer abstract `size`.

abstract class Base {
    abstract val sz: Int
    open val tag: Int = 1
    inner class View {
        fun viaAbstract(): Int = sz
        fun viaOpen(): Int = tag
    }
    fun view() = View()
}

class Impl : Base() {
    override val sz: Int get() = 42
    override val tag: Int get() = 100
}

class MyList<T> : AbstractMutableList<T>() {
    private val backing = ArrayList<T>()
    override val size: Int get() = backing.size
    override fun get(index: Int): T = backing[index]
    override fun add(index: Int, element: T) { backing.add(index, element) }
    override fun removeAt(index: Int): T = backing.removeAt(index)
    override fun set(index: Int, element: T): T = backing.set(index, element)
}

fun main() {
    val v = Impl().view()
    println("viaAbstract=${v.viaAbstract()}")
    println("viaOpen=${v.viaOpen()}")

    val l = MyList<Int>()
    l.add(1); l.add(2); l.add(3)
    l.add(0, 99)
    println("list=$l size=${l.size}")
    println("sum=${l.sum()} contains=${l.contains(2)} indexOf=${l.indexOf(3)}")
    println("equals=${l == listOf(99, 1, 2, 3)}")
    l.removeAt(0)
    println("afterRemove=$l")
}

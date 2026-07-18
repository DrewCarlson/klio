// A member extension declared in an enclosing class is a closer-scope
// candidate than a same-named, same-shape top-level extension: calls
// inside the class bind the member extension; calls outside see only
// the top-level one.

private fun IntArray.pick(i: Int): Int = 2000 + this[i]

class Owner {
    val arr = intArrayOf(5)

    private fun IntArray.pick(i: Int): Int = 1000 + this[i]

    fun inside(): Int = arr.pick(0)

    fun chained(): Int = arr.select(0)

    private fun IntArray.select(i: Int): Int = pick(i)
}

fun main() {
    println(Owner().inside())
    println(Owner().chained())
    println(intArrayOf(7).pick(0))
}

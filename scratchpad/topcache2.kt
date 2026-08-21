class Box(val n: Int) {
    companion object {
        fun get(n: Int): Box = cache[n] ?: Box(n).also { cache[n] = it }
        val ZERO: Box = Box(0)
        fun zeroPath(n: Int): Box = if (n == 0) ZERO else get(n)
    }
}

private var cache: MutableMap<Int, Box> = mutableMapOf()

fun main() {
    println("companion cache same = " + (Box.get(1) === Box.get(1)) + " size=" + cache.size)
    println("zero path same = " + (Box.zeroPath(0) === Box.ZERO))
}

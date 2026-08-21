class Box(val n: Int)

private var cache: MutableMap<Int, Box> = mutableMapOf()

fun get(n: Int): Box = cache[n] ?: Box(n).also { cache[n] = it }

private val roCache: MutableMap<Int, Box> = mutableMapOf()
fun getRo(n: Int): Box = roCache[n] ?: Box(n).also { roCache[n] = it }

fun main() {
    println("var cache same = " + (get(1) === get(1)) + " size=" + cache.size)
    println("val cache same = " + (getRo(1) === getRo(1)) + " size=" + roCache.size)
}

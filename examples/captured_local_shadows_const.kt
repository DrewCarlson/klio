// A local captured by an anonymous object is the nearest binding for its
// name inside the object's methods: nearer than a same-named top-level
// const (which must not const-inline over it) and nearer than a `count`
// member on a receiver published by the dispatch context.
private const val count = 100

interface Ticker {
    fun tick()
}

class Host(var count: Int) {
    fun runTicker(t: Ticker) {
        t.tick()
    }
}

fun makeTicker(): Pair<Ticker, () -> Int> {
    var count = 0
    val t = object : Ticker {
        override fun tick() {
            count++
        }
    }
    return Pair(t, { count })
}

fun main() {
    val (t, read) = makeTicker()
    val h = Host(500)
    h.runTicker(t)
    h.runTicker(t)
    println(read())
    println(h.count)
    println(count)
}

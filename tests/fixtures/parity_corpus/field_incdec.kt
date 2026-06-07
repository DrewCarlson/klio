class Counter {
    var n = 0
    private val log = IntArray(5)
    private var w = -1
    fun tick(): Int = ++n
    fun tock(): Int = n--
    fun record(v: Int) { log[++w] = v }
    fun dump(): String = log.joinToString(",") + " w=" + w
}
fun main() {
    val c = Counter()
    println(c.tick())   // 1
    println(c.tick())   // 2
    println(c.tock())   // 2 (post-dec returns old)
    println(c.n)        // 1
    c.record(10); c.record(20); c.record(30)
    println(c.dump())   // 10,20,30,0,0 w=2
    println(--c.n)      // 0
    println(c.n)        // 0
}

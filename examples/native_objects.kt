// Classes compiled to C. Instances are the runtime's own, allocated through it
// and traced by its collector: a compiled frame publishes the references it
// holds, because the collector is precisely rooted and never scans the native
// stack. `scripts/native-c-check.sh` re-runs this with a collection at every
// safe point, which is what proves the live reference below is published.
class Point(val x: Int, val y: Int)

class Counter(var n: Int, val step: Int) {
    fun bump() {
        n = n + step
    }
    fun doubled(): Int = n * 2
}

class Vec(val x: Int, val y: Int) {
    fun len2(): Int = x * x + y * y
    fun scaled(k: Int): Vec = Vec(x * k, y * k)
}

fun sum(p: Point): Int = p.x + p.y

fun main() {
    val p = Point(3, 4)
    println(sum(p))

    val c = Counter(0, 3)
    var i = 0
    while (i < 10) {
        c.bump()
        i = i + 1
    }
    println(c.n)
    println(c.doubled())

    val v = Vec(3, 4)
    println(v.len2())
    println(v.scaled(2).len2())

    // Allocation under a loop, with one instance kept live across it.
    var keep = Point(1, 1)
    var acc = 0
    i = 0
    while (i < 100000) {
        val q = Point(i, i + 1)
        acc = (acc + q.x + q.y) % 1000003
        if (i % 25000 == 0) keep = q
        i = i + 1
    }
    println(acc)
    println(keep.x + keep.y)
}

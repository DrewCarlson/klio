// Functions whose bodies inline enough helpers to need many registers:
// values kept live across loops, calls, inline lambdas and a sequence's
// yields; a catch and a finally reading values written before and inside
// the try; constructor and call arguments built from temporaries; a copy
// whose destination is written again while its source is still needed; and
// recursion through such a function.

inline fun mix(a: Int, b: Int): Int {
    val x = a * 31 + b
    val y = x xor (x ushr 7)
    val z = y * -1640531535
    return z xor (z ushr 15)
}

inline fun <T> measured(log: StringBuilder, label: String, block: () -> T): T {
    val before = log.length
    val r = block()
    log.append(label).append(':').append(log.length - before).append(';')
    return r
}

class Box(val a: Int, val b: Long, val c: String, val d: Double) {
    override fun toString() = "Box($a, $b, $c, $d)"
}

fun wide(seed: Int): Long {
    val a = mix(seed, 1)
    val b = mix(a, 2)
    val c = mix(b, 3)
    val d = mix(c, 4)
    val e = mix(d, 5)
    val f = mix(e, 6)
    val g = mix(f, 7)
    val h = mix(g, 8)
    var acc = 0L
    for (i in 0 until 5) {
        val t = mix(i, a) xor mix(b, i)
        acc = acc * 31 + (t + c).toLong()
        if (t and 1 == 0) acc = acc xor d.toLong() else acc += e
    }
    return acc + f + g.toLong() * h
}

fun guarded(n: Int): String {
    val a = mix(n, 11)
    val b = mix(a, 12)
    val c = mix(b, 13)
    val d = mix(c, 14)
    var stage = 0
    val out = StringBuilder()
    try {
        stage = 1
        out.append(mix(b, c) and 0xff)
        if (n % 3 == 0) throw IllegalStateException("stage $stage")
        stage = 2
        out.append(' ').append(mix(c, d) and 0xff)
    } catch (e: IllegalStateException) {
        out.append(" caught ").append(e.message).append(" at ").append(stage).append(" a=").append(a and 0xff)
    } finally {
        out.append(" finally b=").append(b and 0xff).append(" stage=").append(stage)
    }
    return out.append(" d=").append(d and 0xff).toString()
}

fun boxes(n: Int): List<Box> {
    val log = StringBuilder()
    val first = measured(log, "first") { Box(mix(n, 1), mix(n, 2).toLong() shl 3, "b" + (mix(n, 3) and 7), (mix(n, 4) and 15) / 4.0) }
    val second = measured(log, "second") {
        val x = mix(first.a, 5)
        val y = mix(x, 6)
        Box(x, y.toLong() - first.b, first.c + log.length, first.d * 2)
    }
    val third = Box(mix(second.a, first.a), first.b + second.b, log.toString(), second.d + first.d)
    return listOf(first, second, third)
}

fun copies(start: Int): String {
    val keep = mix(start, 0)
    var cur = keep
    val trail = StringBuilder()
    for (i in 1..4) {
        val before = cur
        cur = mix(cur, i)
        trail.append(before and 0xf).append('>').append(cur and 0xf).append(' ')
        if (i == 2) cur = keep
    }
    return trail.append("keep=").append(keep and 0xff).append(" cur=").append(cur and 0xff).toString()
}

fun wideSequence(n: Int) = sequence {
    val a = mix(n, 3)
    val b = mix(a, 4)
    val c = mix(b, 5)
    val d = mix(c, 6)
    for (i in 0 until 3) {
        val t = mix(i, a)
        yield(t xor b and 0xffff)
        yield((c + i) and 0xffff)
    }
    yield((a + b + c + d) and 0xffff)
}

fun depth(n: Int): Int {
    if (n == 0) return 0
    val a = mix(n, 21)
    val b = mix(a, 22)
    val c = mix(b, 23)
    val below = depth(n - 1)
    return (below * 7 + (a xor b xor c)) and 0xfffff
}

fun main() {
    println("wide: " + (0..4).map { wide(it) })
    for (n in 0..4) println("guarded $n: ${guarded(n)}")
    for (box in boxes(9)) println(box)
    println("copies: ${copies(5)}")
    println("sequence: " + wideSequence(2).toList())
    println("depth: " + (0..6).map { depth(it) })
}

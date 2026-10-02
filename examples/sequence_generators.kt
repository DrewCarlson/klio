// `sequence { }` and `iterator { }` producers run lazily, one element per pull: each
// `yield` suspends the producer where it stands and the next pull resumes it there,
// with its locals, its loops and its try blocks as they were. After its first
// suspension a producer's frame stays parked as it is, so a step copies nothing.

suspend fun SequenceScope<Int>.twice(x: Int) {
    yield(x)
    yield(x)
}

fun collatz(start: Long) = sequence {
    var n = start
    while (n != 1L) {
        yield(n)
        n = if (n % 2 == 0L) n / 2 else 3 * n + 1
    }
    yield(1L)
}

fun main() {
    val log = mutableListOf<String>()
    val lazy = sequence {
        for (i in 1..3) {
            log.add("make $i")
            yield(i)
        }
        log.add("done")
    }
    val it = lazy.iterator()
    log.add("first ${it.next()}")
    log.add("second ${it.next()}")
    println(log)

    println(sequence { yield(1); yieldAll(listOf(2, 3)); twice(4); yieldAll(sequenceOf(5, 6)) }.toList())
    println(collatz(27).count())
    println(iterator { for (c in "kotlin") yield(c.uppercaseChar()) }.asSequence().joinToString(""))

    // A try block and a finally around a yield.
    val events = mutableListOf<String>()
    val guarded = sequence {
        try {
            yield("a")
            yield("b")
        } finally {
            events.add("finally")
        }
        yield("c")
    }
    println("${guarded.toList()} $events")

    // An exception thrown after a few elements reaches the puller, and the iterator stays failed.
    val failing = sequence {
        yield(1)
        yield(2)
        throw IllegalStateException("stop at 3")
    }.iterator()
    val got = mutableListOf<Int>()
    try {
        while (failing.hasNext()) got.add(failing.next())
    } catch (e: IllegalStateException) {
        println("$got ${e.message}")
    }

    // At size: 200,000 steps through one producer, and a pipeline over an endless one.
    var sum = 0L
    for (x in sequence { for (i in 0 until 200_000) yield(i) }) sum += x
    val fibs = sequence {
        var a = 0L
        var b = 1L
        while (true) {
            yield(a)
            val t = a + b
            a = b
            b = t
        }
    }
    println("$sum ${fibs.filter { it % 2 == 0L }.take(30).last()} ${fibs.take(90).fold(0L) { acc, x -> acc xor x }}")
}

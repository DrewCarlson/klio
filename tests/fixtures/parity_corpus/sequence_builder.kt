fun main() {
    val s = sequence {
        yield(1)
        yield(2)
        yieldAll(listOf(3, 4))
    }
    println(s.toList())
    println(s.map { it * 10 }.filter { it > 15 }.toList())

    val fib = sequence {
        var a = 0
        var b = 1
        repeat(10) {
            yield(a)
            val next = a + b
            a = b
            b = next
        }
    }
    println(fib.toList())
    println(fib.take(5).toList())

    val nested = sequence {
        for (i in 1..3) {
            yieldAll((1..i).asSequence())
        }
    }
    println(nested.toList())
}

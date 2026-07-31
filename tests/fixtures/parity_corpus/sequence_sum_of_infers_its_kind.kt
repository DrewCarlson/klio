// `Sequence.sumOf` declares five overloads that differ ONLY in the selector's
// return type — `(T) -> Double` first, then Int, Long, UInt, ULong — and Kotlin
// picks between them by the lambda's INFERRED return type. A lambda carries no
// declared return type, so the pick fell to declaration order and the Double
// body ran, accumulating an Int sum as a Double. The host implementation reads
// the kind from the first value it computes, which is the answer Kotlin's typed
// selection reaches, and it serves a host sequence and an interpreted one alike.
fun main() {
    var seen = 0
    val data = sequenceOf("foo", "bar", "!")
    val piped = data.onEach { seen += it.length }

    println(piped.sumOf { it.length })
    println(seen)
    println(data.sumOf { it.length })
    println(data.map { it }.sumOf { it.length })
    println(data.filter { it.isNotEmpty() }.sumOf { it.length })
    println(listOf("foo", "bar", "!").sumOf { it.length })

    // A selector that really is Double still sums as Double.
    println(data.sumOf { it.length / 2.0 })

    // And a Long selector keeps its width.
    println(data.sumOf { it.length.toLong() * 1000000000L })
}

class Counter(val max: Int) {
    operator fun iterator(): CounterIter = CounterIter(max)
}

class CounterIter(val max: Int) {
    var i: Int = 0
    operator fun hasNext(): Boolean = i < max
    operator fun next(): Int {
        val v = i
        i += 1
        return v
    }
}

fun main() {
    for (n in Counter(4)) {
        println(n)
    }
    println("done")
}

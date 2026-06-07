class Range3(val n: Int)

class Range3Iter(var i: Int, val max: Int) {
    operator fun hasNext(): Boolean = i < max
    operator fun next(): Int {
        val v = i
        i += 1
        return v
    }
}

operator fun Range3.iterator(): Range3Iter = Range3Iter(0, n)

fun main() {
    for (v in Range3(3)) {
        println(v)
    }
    println("done")
}

fun readUntilZero(values: List<Int>): Int {
    var sum = 0
    var i = 0
    do {
        val v = values[i]
        if (v == 0) break
        sum += v
        i += 1
    } while (i < values.size)
    return sum
}

fun main() {
    println(readUntilZero(listOf(1, 2, 3, 0, 99)))
    var n = 5
    do {
        println(n)
        n -= 1
    } while (n > 0)
}

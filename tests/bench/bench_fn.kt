// bench_fn: lambdas called from the collection natives (map, filter, sumOf)
// and StringBuilder appends. Measured for user CPU by scripts/measure-row.py.
fun main() {
    var sum = 0L
    val xs = (1..200_000).toList()
    for (k in 0 until 20) {
        sum += xs.map { it * 2 }.filter { it % 3 == 0 }.sumOf { it.toLong() }
    }
    val sb = StringBuilder()
    for (i in 0 until 200_000) { sb.append(i % 10) }
    println(sum + sb.length)
}

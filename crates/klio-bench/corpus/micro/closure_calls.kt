// Closure capture + invoke in a loop: stresses closure Value clone
// and captured-cell borrow, both atomic after the value-model
// refactor.
fun main() {
    var acc = 0L
    val add = { n: Int -> acc += n.toLong() }
    var i = 0
    while (i < 50000) {
        add(i)
        i += 1
    }
    println(acc)
}

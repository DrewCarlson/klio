// A destructuring lambda parameter may carry a type annotation on the
// group, and a local declaration may carry a label (a no-op at runtime).
data class Point(val x: Int, val y: Int)

fun main() {
    val sum = { (a, b): Point -> a + b }
    println(sum(Point(3, 4)))

    val plain = { (a, b) -> a * b }
    println(plain(Point(3, 4)))

    label@ val n = 10
    tag@ fun triple() = n * 3
    println(n + triple())

    // A soft-keyword name (`inner`) works as a loop label.
    var hits = 0
    inner@ for (i in 1..3) {
        for (j in 1..3) { if (j == 2) continue@inner; hits++ }
    }
    println(hits)
}

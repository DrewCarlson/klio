class Counter(var count: Int) {
    inner class Bumper(val step: Int) {
        fun bump(): Int {
            count = count + step
            return count
        }
        fun outerCount(): Int = this@Counter.count
    }
}

fun main() {
    val c = Counter(10)
    val b = c.Bumper(3)
    println(b.bump())
    println(b.bump())
    println(b.outerCount())
    println(c.count)
}

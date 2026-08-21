fun main() {
    val m = mutableListOf(1, 2, 3)
    println("mutable flatMap = " + m.flatMap { listOf(it, it * 10) })
    val l: List<Int> = m
    println("list flatMap    = " + l.flatMap { listOf(it) })
    println("mutable map     = " + m.map { it * 2 })
    println("mutable filter  = " + m.filter { it > 1 })
    val ml: MutableList<Int> = mutableListOf(5)
    println("declared mutable= " + ml.flatMap { listOf(it) })
}

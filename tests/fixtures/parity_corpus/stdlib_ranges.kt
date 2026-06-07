fun main() {
    val r = 1..5
    println(r)
    println(r.toList())
    println(r.count())
    println(r.sum())
    println(r.reversed())
    println(r.reversed().toList())
    println((1 until 5).toList())
    println((10 downTo 1 step 2).toList())
    println((1..10 step 3).toList())
    println(r.contains(3))
    println(r.contains(99))
    val n = 7
    println(r.contains(n))
    for (i in 0..2) {
        println("i=$i")
    }
}

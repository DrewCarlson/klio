fun firstProductOver(limit: Int): Int {
    for (i in 1..10) {
        for (j in 1..10) {
            if (i * j > limit) return@firstProductOver i * j
        }
    }
    return -1
}

fun main() {
    outer@ for (i in 1..3) {
        for (j in 1..3) {
            if (i == 2 && j == 2) break@outer
            println("b $i,$j")
        }
    }
    println("---")
    skip@ for (i in 1..3) {
        for (j in 1..3) {
            if (j == 2) continue@skip
            println("c $i,$j")
        }
    }
    println("---")
    println(firstProductOver(20))
}

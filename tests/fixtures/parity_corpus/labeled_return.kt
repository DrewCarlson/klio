fun findFirst(): Int {
    for (i in 1..10) {
        for (j in 1..10) {
            if (i * j > 20) return@findFirst i * j
        }
    }
    return -1
}

fun main() {
    println(findFirst())
}

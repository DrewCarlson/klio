fun main() {
    outer@ for (i in 1..3) {
        outer@ for (j in 1..3) {
            if (j == 2) break@outer
            println("$i $j")
        }
    }
}

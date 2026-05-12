fun <R> run(block: () -> R): R = block()

fun main() {
    outer@ for (i in 1..3) {
        outer@ for (j in 1..3) {
            if (j == 2) break@outer
            println("$i $j")
        }
    }

    val r = lbl@ run {
        val inner = lbl@ run {
            return@lbl 1
        }
        inner + 10
    }
    println(r)
}

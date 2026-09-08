// A function-typed local declared inside a loop body is a plain block
// statement. The `->` in its type must not make the loop body parse as a
// lambda: the body has to run each iteration so the loop makes progress.

fun apply(n: Int, f: (Int) -> Int): Int = f(n)

fun main() {
    var i = 0
    var sum = 0
    while (i < 4) {
        val doubler: (Int) -> Int = { it * 2 }
        sum += apply(i, doubler)
        i++
    }
    println("while sum=$sum")

    var j = 0
    do {
        val label: (Int) -> String = { "n$it" }
        print(label(j) + " ")
        j++
    } while (j < 3)
    println()
}

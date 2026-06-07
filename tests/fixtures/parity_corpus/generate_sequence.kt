fun main() {
    println(generateSequence(1) { it + 1 }.take(5).toList())
    println(generateSequence(2) { it * 2 }.takeWhile { it < 100 }.toList())
    println(generateSequence(1) { it * 2 }.drop(2).take(4).toList())
    println(generateSequence(1) { if (it < 5) it + 1 else null }.toList())
}

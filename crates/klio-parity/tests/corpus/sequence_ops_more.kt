fun main() {
    println(sequenceOf(1, 2, 3, 4).runningFold(0) { a, b -> a + b }.toList())
    println(sequenceOf(1, 2, 3).scan(10) { a, b -> a + b }.toList())
    println(sequenceOf(1, 2, 3, 4).runningReduce { a, b -> a + b }.toList())
    println(sequenceOf(1, 2, 3).constrainOnce().toList())
    println(sequenceOf(1, 2, 3, 4).zipWithNext().toList())
    println(sequenceOf(1, 2, 3).zip(sequenceOf("a", "b", "c")).toList())
    println(sequenceOf(1, 2, 3).map { it * 2 }.zip(sequenceOf(9, 8, 7)).toList())
    println((1..6).asSequence().mapIndexed { i, v -> i to v }.filterIndexed { i, _ -> i % 2 == 0 }.toList())
}

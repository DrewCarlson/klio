// IntRange Display: `1..10` inclusive, `1..<10` exclusive (Kotlin 2.x prints
// "1 until 10" via toString; this test pins down what the current compiler
// actually emits and what we must match).
fun main() {
    println(1..10)
    println(1..<10)
}

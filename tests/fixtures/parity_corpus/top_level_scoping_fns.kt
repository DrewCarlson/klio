// Top-level `run { ... }`: runs the block, returns its result. No receiver
// (distinct from the `T.run` extension form which binds `this`).
fun main() {
    val x = run { 1 + 1 }
    println(x)

    val y = run {
        val a = 10
        val b = 32
        a + b
    }
    println(y)

    run {
        println("side effect")
    }

    val nested = run {
        val inner = run { 5 }
        inner * 2
    }
    println(nested)

    val s = run {
        val parts = listOf("a", "b", "c")
        parts.joinToString("-")
    }
    println(s)
}

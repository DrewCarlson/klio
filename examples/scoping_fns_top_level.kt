// M22 top-level scoping fns. `with(receiver) { ... }` binds the receiver as
// `this` and returns the lambda result. `run { ... }` is the no-receiver
// sibling: it runs the block and returns its value, useful for scoping a
// computation that needs intermediate locals when initializing a `val`.
// Both are top-level stdlib functions in Kotlin, distinct from the
// extension-receiver forms (`x.run`, `x.let`, ...).
fun main() {
    // Top-level `run` returns the block's result.
    val small = run { 1 + 1 }
    println(small)

    // Useful for initializing a `val` from a multi-statement block.
    val greeting = run {
        val name = "Kotlin"
        val year = 2026
        "Hello, $name ($year)"
    }
    println(greeting)

    // Unit-returning form: just executes the block.
    run {
        println("ran a side-effecting block")
    }

    // Nested `run`s compose; inner returns into outer.
    val total = run {
        val a = run { 10 }
        val b = run { 32 }
        a + b
    }
    println(total)

    // `with(receiver) { ... }` for comparison — receiver as `this`.
    val length = with("kotlin") {
        length + 1
    }
    println(length)
}

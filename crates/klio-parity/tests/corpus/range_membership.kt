fun main() {
    // Floating-point range membership (ClosedFloatingPointRange) — the
    // `lo <= x && x <= hi` form, not an integer progression.
    println(0.5 in 0.0..1.0)
    println(1.5 in 0.0..1.0)
    println(1.0 in 0.0..1.0)
    println(-0.1 in 0.0..1.0)
    println(0.8 in 0.0..1.0)

    // Half-open floating range (`..<`).
    println(1.0 in 0.0..<1.0)
    println(0.999 in 0.0..<1.0)

    // Float endpoints.
    println(3.0f in 1.0f..5.0f)
    println(5.5f in 1.0f..5.0f)

    // Integer / Char ranges and the negated form still hold.
    println(5 in 1..10)
    println(11 in 1..10)
    println(5 in 1..<5)
    println('c' in 'a'..'z')
    println('A' in 'a'..'z')
    println(5 !in 1..3)
    println(2 !in 1..3)

    // Mixed numeric endpoints and a computed test value.
    val q = 0.8
    println(q in 0.0..1.0)
    val n = 7
    println(n in 0..10)

    // A non-literal range still routes through contains().
    val r = 1..10
    println(5 in r)
}

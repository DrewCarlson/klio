fun main() {
    // Collection membership / dedup use Double.equals (bitwise): NaN
    // equals NaN, and -0.0 is distinct from 0.0 — unlike the == operator.
    println(listOf(Double.NaN, 0.0, -0.0, Double.NaN).distinct())
    println(setOf(Double.NaN, Double.NaN).size)
    println(setOf(0.0, -0.0).size)
    println(listOf(0.0, -0.0).distinct())
    println(hashSetOf(Double.NaN, Double.NaN).size)
    println(listOf(Double.NaN).contains(Double.NaN))
    println(listOf(0.0).contains(-0.0))
    println(listOf(0.0).contains(0.0))
    val m = hashMapOf(Double.NaN to "a")
    println(m.containsKey(Double.NaN))
    println(m[Double.NaN])
    // the == operator keeps IEEE semantics
    println(Double.NaN == Double.NaN)
    println(0.0 == -0.0)
    // ordinary values unaffected
    println(listOf(1.0, 2.0, 1.0, 3.0).distinct())
    println(setOf("a", "a", "b").size)
    // Float behaves the same
    println(listOf(Float.NaN, Float.NaN).distinct().size)
    println(setOf(0.0f, -0.0f).size)
    // indexOf uses equals too
    println(listOf(1.0, Double.NaN, 2.0).indexOf(Double.NaN))
}

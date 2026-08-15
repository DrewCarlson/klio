// Literal-step progressions lower as counted register loops (no iterator
// object, no virtual calls) with kotlinc's overflow-free last-element
// snapping. Outputs verified against kotlinc/JVM.
fun main() {
    var a = 0L
    for (i in 1..10 step 3) a += i          // 1,4,7,10 = 22
    for (i in 30 downTo 1 step 3) a += i    // 30..3 = 165
    for (i in 2..10 step 3) a += i          // 2,5,8 = 15
    for (i in -5..5 step 3) a += i          // -5,-2,1,4 = -2
    for (i in -3..-1 step 3) a += i         // -3
    for (i in 5 downTo 6 step 2) a += 1000  // empty
    for (i in 7..7 step 5) a += i           // 7
    var n = 0
    for (i in 1_000_000 downTo 1 step 3) n++
    println("a=$a n=$n")
    var l = 0L
    for (i in 1L..20L step 6) l += i        // 1,7,13,19 = 40
    println("l=$l")
}

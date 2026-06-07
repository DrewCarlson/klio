fun main() {
    val nan = Double.NaN
    println(nan == nan)
    println((nan as Any) == (nan as Any))
    val a: Any = nan
    val b: Any = nan
    println(a == b)
    val zero1 = 0.0
    val zero2 = -0.0
    println(zero1 == zero2)
    println((zero1 as Any) == (zero2 as Any))
    val z1: Any = zero1
    val z2: Any = zero2
    println(z1 == z2)
}

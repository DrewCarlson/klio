fun main() {
    val nan: Double = 0.0 / 0.0
    println(nan == nan)
    println((nan as Any) == (nan as Any))
    val zero1: Double = 0.0
    val zero2: Double = -0.0
    println(zero1 == zero2)
    println((zero1 as Any) == (zero2 as Any))
}

fun main() {
    // The deep-subnormal toString cases that Rust's shortest formatting
    // rendered differently from kotlinc; the Schubfach core matches the JVM.
    println(Double.MIN_VALUE)
    println(2.0 * Double.MIN_VALUE)
    println(Double.fromBits(10L))
    println(Double.fromBits(12L))
    println(Double.fromBits(20L))
    println(Float.MIN_VALUE)
    println(2.0f * Float.MIN_VALUE)
    println(Float.fromBits(3))
    println(Float.fromBits(71))
    // normals + boundaries still correct
    println(0.1)
    println(1.0 / 3.0)
    println(123456.789)
    println(1.0E20)
    println(1.0E7)
    println(0.001)
    println(Double.MAX_VALUE)
    println(Float.MAX_VALUE)
    println(-0.0)
    println(100.0)
    println(3.14159f)
    println(0.5f)
    println(1.0E-7)
}

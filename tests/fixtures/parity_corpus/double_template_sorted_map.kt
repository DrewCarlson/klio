fun main() {
    // A Double/Float in a string template or `+` concat must render the same
    // as println(x): Kotlin's 1.0E20 / 1.0E-7 / Infinity, not Rust's
    // 100000000000000000000 / 0.0000001 / inf.
    val x = 1e20
    val y = 1e-7
    println(x)
    println("$x")
    println("" + x)
    println("y=$y")
    println("big=${1.5e30}")
    println("small=${2.5e-9}")
    println("inf=${Double.POSITIVE_INFINITY}")
    println("ninf=${Double.NEGATIVE_INFINITY}")
    println("nan=${Double.NaN}")
    println("pi=${3.14159}")
    println("whole=${4.0}")
    val f = 1e20f
    println(f)
    println("f=$f")

    // toSortedMap(): entries ordered by natural key order.
    println(mapOf("c" to 3, "a" to 1, "b" to 2).toSortedMap())
    println(mapOf(3 to "x", 1 to "y", 2 to "z").toSortedMap())
}

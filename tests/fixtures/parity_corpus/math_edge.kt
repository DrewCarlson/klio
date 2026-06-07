import kotlin.math.*
fun main() {
    println(5.0.withSign(-1.0))
    println((-3.0).withSign(1.0))
    println(0.0.withSign(-1.0))
    println(2.5f.withSign(-1.0f))
    println(1.0.nextUp() > 1.0)
    println(1.0.nextDown() < 1.0)
    println(0.0.ulp > 0.0)
    println(1.0.nextTowards(2.0) > 1.0)
    println(1.0.nextTowards(0.0) < 1.0)
    println(5.0.nextTowards(5.0))
    println(Double.POSITIVE_INFINITY.ulp)
}

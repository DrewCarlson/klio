// expect-error: T0071
sealed class S
fun main() {
    val x = object : S() {}
    println(x)
}

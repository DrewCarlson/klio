// expect-error: T0071
sealed class S { class A : S() }
fun foo() {
    class Local : S()
}
fun main() { foo() }

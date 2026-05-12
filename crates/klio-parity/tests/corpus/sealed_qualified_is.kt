sealed class S {
    class A : S()
    class B(val n: Int) : S()
}

fun describe(s: S): String = when (s) {
    is S.A -> "a"
    is S.B -> "b=${s.n}"
}

fun main() {
    println(describe(S.A()))
    println(describe(S.B(5)))
}

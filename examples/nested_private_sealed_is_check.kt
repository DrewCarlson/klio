// An `is` check spelled through a PRIVATE nested owner (`is S.A` where `S`
// is a private nested sealed class and `A` carries its own companion)
// resolves to the lifted class, so a `when` over the subject reaches its
// branches instead of falling through to `Unit`.
class Tests {
    private sealed class S {
        class A(val v: Int) : S() { companion object { fun tag() = "a" } }
        class B(val v: Int) : S() { companion object { fun tag() = "b" } }
    }

    private object Namer {
        private const val nameA = "alpha"
        private const val nameB = "beta"

        fun describe(value: S): String {
            val (n, typeName) = when (value) {
                is S.A -> value.v to nameA
                is S.B -> value.v to nameB
            }
            return "$n:$typeName"
        }

        fun tag(value: S): String = when (value) {
            is S.A -> S.A.tag()
            is S.B -> S.B.tag()
        }
    }

    fun run() {
        println(Namer.describe(S.A(1)))
        println(Namer.describe(S.B(2)))
        println(Namer.tag(S.A(3)) + Namer.tag(S.B(4)))
        val values: List<S> = listOf(S.A(5), S.B(6))
        println(values.count { it is S.A })
    }
}

fun main() { Tests().run() }

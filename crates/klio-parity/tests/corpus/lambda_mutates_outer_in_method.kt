// A lambda inside a class method / companion that assigns an
// enclosing local (definite assignment / mutable capture) must run
// — previously the scope-fn callee was mis-lowered to `this.run`,
// invoking the receiver instance.
class Calc {
    fun split(s: Long): String {
        val a: Int
        val b: Int
        run {
            a = (s / 100).toInt()
            b = (s % 100).toInt()
        }
        return "$a.$b"
    }
    companion object {
        fun of(s: Long): String {
            var x = 0
            run { x = (s + 7).toInt() }
            return "x=$x"
        }
    }
}
fun main() {
    println(Calc().split(1234L))
    println(Calc.of(35L))
}

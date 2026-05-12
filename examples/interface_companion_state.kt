// `companion object` on an interface holds shared mutable state. Default
// methods on the interface reach the companion's `var` by simple name; the
// state is visible across every implementing class.
interface Tally {
    companion object { var n = 0 }
    fun add() { n++ }
}

class Alpha : Tally
class Beta : Tally

fun main() {
    Alpha().add()
    Alpha().add()
    Beta().add()
    println(Tally.n)
}

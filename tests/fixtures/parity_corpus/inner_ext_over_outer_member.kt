// Implicit-receiver call resolution is per-receiver, innermost-first: an
// extension applicable to the inner receiver outranks a member of the
// outer receiver. The candidate order is the receiver's, not
// "all members first".
class Outer {
    fun describe(): String = "outer-member"
}

class Inner

fun Inner.describe(): String = "inner-extension"

fun main() {
    with(Outer()) {
        with(Inner()) {
            println(describe())
        }
    }
    // Without the inner receiver the member binds.
    with(Outer()) {
        println(describe())
    }
}

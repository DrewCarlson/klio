// Both implicit receivers own a same-named member: the innermost wins.
class A {
    fun tag(): String = "a-member"
}

class B {
    fun tag(): String = "b-member"
}

fun main() {
    with(A()) {
        with(B()) {
            println(tag())
        }
    }
}

// Two interfaces supply a default body for `hello`; the subclass does
// not override. Expect T0013.

interface A {
    fun hello(): String = "A"
}

interface B {
    fun hello(): String = "B"
}

class C : A, B

fun main() {
    println(C().hello())
}

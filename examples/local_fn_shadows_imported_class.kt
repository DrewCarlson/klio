// A local function declared in an enclosing body shadows an imported
// same-named class at a bare call — including from inside a closure,
// where the binding arrives as a capture.
package p

import kotlin.test.Test

class Runner {
    fun go(block: () -> Unit) = block()
}

fun main() {
    fun Test(a: Int, b: Int) {
        println("local Test $a $b")
    }
    Runner().go { Test(1, 2) }
    Test(3, 4)
}

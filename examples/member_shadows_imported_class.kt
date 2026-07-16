// A member function named like an imported class: the member is the
// nearer-scope candidate at a bare call site, so `Test(...)` inside the
// class calls `fun Test`, never the imported `kotlin.test.Test`
// annotation's constructor — from the method body, a lambda, a nested
// lambda, and a coroutine block.
package examples.membershadow

import kotlin.test.Test
import kotlinx.coroutines.runBlocking

class C {
    fun Test(n: Int = 5, tag: String = "x"): String = "fn n=$n tag=$tag"

    fun direct(): String = Test(tag = "direct")

    fun viaLambda(): String {
        val f = { Test(tag = "lambda") }
        return f()
    }

    fun viaNestedLambda(): String {
        val outer = {
            val inner = { Test(tag = "nested") }
            inner()
        }
        return outer()
    }

    fun viaCoroutine(): String {
        var r = ""
        runBlocking { r = Test(tag = "coroutine") }
        return r
    }
}

fun main() {
    val c = C()
    println(c.direct())
    println(c.viaLambda())
    println(c.viaNestedLambda())
    println(c.viaCoroutine())
}

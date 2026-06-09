// A `suspend Receiver.() -> Unit` value invoked with a bound receiver
// (`b.block()`, where `block` is a fun-typed parameter) must be able to PARK
// inside its body and resume. The receiver-bound value-call runs on the main
// evaluator path so a `delay` snapshots frames up the call chain and the
// coroutine driver parks the continuation — instead of the suspension being
// flattened into a "suspended outside a driver" runtime error. A bare `n`
// inside the body resolves to the bound `Bar` receiver before and after each
// park, and distinct receivers stay distinct when two such calls interleave.
import kotlinx.coroutines.*

class Bar(val n: Int)

// Single park: the receiver-lambda body suspends once at `delay`.
suspend fun runOnce(b: Bar, block: suspend Bar.() -> Unit) {
    b.block()
}

// Multiple parks: the same shape suspends twice across one body, so the
// continuation re-enters the body at each suspension point.
suspend fun runTwice(b: Bar, block: suspend Bar.() -> Unit) {
    b.block()
}

// Returns the body's value so an `async` can await it.
suspend fun runReturning(b: Bar, block: suspend Bar.() -> String): String = b.block()

fun main() = runBlocking {
    val one = StringBuilder()
    runOnce(Bar(7)) {
        one.append("a$n")
        delay(5)
        one.append("|b$n")
    }
    println(one.toString())

    val many = StringBuilder()
    runTwice(Bar(9)) {
        many.append("a$n")
        delay(5)
        many.append("|b$n")
        delay(3)
        many.append("|c$n")
    }
    println(many.toString())

    // Two receiver-bound suspend value-calls interleave under `async`. Each
    // parks and resumes against its OWN bound receiver; the awaited results
    // preserve per-coroutine receiver identity across the parks.
    val a = async {
        runReturning(Bar(1)) {
            val before = "a$n"
            delay(10)
            "$before|b$n"
        }
    }
    val b = async {
        runReturning(Bar(2)) {
            val before = "a$n"
            delay(5)
            "$before|b$n"
        }
    }
    println(a.await())
    println(b.await())
}

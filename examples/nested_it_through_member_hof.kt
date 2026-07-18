// An `it` inside a `() -> R` block passed to a class/companion member
// resolves to the ENCLOSING lambda's `it`: the member's declared
// signature supplies the block's zero arity, so the parser-injected `it`
// is dropped instead of binding a null parameter.

class Runner {
    fun <T> enter(block: () -> T): T = block()

    companion object {
        inline fun <R> withThing(block: () -> R): R {
            val r = Runner()
            return r.enter(block)
        }

        fun <R> observeIt(block: () -> R): R = block()
    }
}

fun main() {
    repeat(3) {
        Runner.withThing {
            println("inline it=" + it)
        }
    }
    listOf(7, 8).forEach {
        Runner.observeIt {
            println("plain it=" + it)
        }
    }
}

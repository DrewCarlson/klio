// A bare return inside an argument lambda returns from the function the
// lambda is written in -- including a LOCAL fun -- and runs every finally
// it unwinds through, in a non-spliced (companion-inline) callee too.

class Runner {
    companion object {
        inline fun <R> withThing(block: () -> R): R {
            try {
                return block()
            } finally {
                println("finally: withThing")
            }
        }
    }
}

fun localReturn(): String {
    fun test() {
        Runner.withThing {
            println("inside")
            return
        }
        println("unreachable after early return")
    }
    test()
    return "after test"
}

fun nestedFinallys(): Int {
    fun inner(): Int {
        try {
            Runner.withThing {
                try {
                    return@inner 7
                } finally {
                    println("finally: lambda-local")
                }
            }
        } finally {
            println("finally: inner")
        }
        return -1
    }
    return inner()
}

fun main() {
    println(localReturn())
    println(nestedFinallys())
}

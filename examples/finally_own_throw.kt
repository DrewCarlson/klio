// A throw or return raised INSIDE a finally block must not re-enter that
// same finally: once control is in the finally, the try region is already
// exited, so neither its catches nor the finally itself may capture again.

fun plainFinallyThrow(): String {
    var n = 0
    return try {
        try {
            "body"
        } finally {
            n++
            println("plain fin $n")
            throw IllegalStateException("fin-throw")
        }
    } catch (e: Throwable) {
        "caught ${e.message} n=$n"
    }
}

fun branchyFinallyThrow(): String {
    // A multi-block finally: the elvis puts a branch between the finally's
    // entry and the throw, so the throw is raised in a later block.
    var n = 0
    val fallback: String? = null
    return try {
        try {
            "body"
        } finally {
            n++
            val label = fallback ?: "elvis"
            println("branchy fin $n $label")
            throw IllegalStateException("branchy-throw")
        }
    } catch (e: Throwable) {
        "caught ${e.message} n=$n"
    }
}

fun returnInFinally(): Int {
    try {
        return 1
    } finally {
        return 2
    }
}


fun breakContinueThroughFinally() {
    var log = ""
    var i = 0
    while (i < 3) {
        try {
            i++
            if (i == 2) continue
            log += "iter$i "
        } finally {
            log += "fin$i "
        }
    }
    println(log)
    outer@ for (a in 1..2) {
        try {
            for (b in 1..2) {
                try {
                    if (a == 1 && b == 2) break@outer
                } finally {
                    println("inner fin $a$b")
                }
            }
        } finally {
            println("outer fin $a")
        }
    }
}

fun main() {
    println(plainFinallyThrow())
    println(branchyFinallyThrow())
    println(returnInFinally())
    breakContinueThroughFinally()
}

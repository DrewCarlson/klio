// A `break` or `continue` leaves every try entered inside the loop before
// the enclosing finally bodies run: an exception thrown by such a finally
// is not caught by a catch the jump already left, and the finally runs
// once.
var log = ""

fun breakInsideNestedTry() {
    for (i in 1..2) {
        try {
            try {
                log += "try"
                break
            } catch (e: Throwable) {
                log += " catch"
            }
        } finally {
            log += " finally"
            throw IllegalStateException("from finally")
        }
    }
}

fun continueWithOuterFinally(): String {
    var out = ""
    for (i in 1..3) {
        try {
            try {
                if (i == 2) continue
                out += "$i"
            } catch (e: Throwable) {
                out += "c"
            }
        } finally {
            out += "f"
        }
    }
    return out
}

fun main() {
    try {
        breakInsideNestedTry()
    } catch (e: IllegalStateException) {
        log += " " + e.message
    }
    println(log)
    println(continueWithOuterFinally())
}

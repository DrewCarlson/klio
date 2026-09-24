// `assert` is the JVM stdlib's: runtime assertions are off unless the JVM runs
// with -ea, so a false assertion throws nothing and its message is never built.
fun main() {
    kotlin.assert(true)
    assert(1 + 1 == 3)
    var built = false
    assert(false) {
        built = true
        "message"
    }
    println(built)
    println("done")
}

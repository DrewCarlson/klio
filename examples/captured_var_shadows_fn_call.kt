// A captured outer `var` with a definite non-callable type does not shadow
// a same-named function for a CALL made inside a nested lambda: `key(key)`
// invokes the function with the variable as its argument.

fun key(n: Int, block: () -> Unit) {
    println("fn key " + n)
    block()
}

fun main() {
    var key = 1
    run {
        key(key) { println("inner ran") }
    }
    key = 2
    val f = {
        key(key) { println("inner ran again") }
    }
    f()
}
